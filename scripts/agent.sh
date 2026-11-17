#!/usr/bin/env bash
# Agent job: mount a fresh Swarmfile workspace, run the agent in a container
# with only the workspace bind-mounted, commit/promote, and leave the branch
# for the publish job. No GitHub checkout and no GitHub token are used here.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"
# shellcheck source=checkpoint-decision.sh
source "$here/checkpoint-decision.sh"
umask 077

need SWARMFILE_ORG_ID "org is required"
need SWARMFILE_REPOSITORY_ID "repository is required"
need SWARMFILE_API_KEY "api-key is required"
need SWARMFILE_COMMAND "command is required"

# The agent must never see the publish token. The action passes the input to
# this step even in agent mode; drop it before the engine or Docker see it.
unset SWARMFILE_GITHUB_TOKEN GITHUB_TOKEN GH_TOKEN

ORG="$SWARMFILE_ORG_ID"
PROJECT="$SWARMFILE_REPOSITORY_ID"
HUB="${SWARMFILE_HUB_URL:-https://hub.swarmfile.com}"
BASE="${SWARMFILE_BASE_BRANCH:-main}"
ISSUE="${SWARMFILE_ISSUE_NUMBER:-}"
PROMPT="${SWARMFILE_PROMPT:-}"
COMMAND="$SWARMFILE_COMMAND"
IMAGE="${SWARMFILE_CONTAINER_IMAGE:-node:24-bookworm}"
SETUP="${SWARMFILE_SETUP_COMMAND:-}"
AGENT_ENV="${SWARMFILE_AGENT_ENV:-ANTHROPIC_API_KEY,OPENAI_API_KEY}"
RUN_ID="${GITHUB_RUN_ID:-local}"
ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"

if ! require_numeric "$ISSUE"; then
  [ -z "$ISSUE" ] || fail "issue-number must be numeric"
fi
check_hub_url "$HUB" "${SWARMFILE_GIT_INSECURE_HOSTS:-}"

label="$(sanitize_label "${SWARMFILE_LABEL:-agent}")"
[ -n "$label" ] || label=agent
BRANCH="$(branch_for "$label")"
TTL="${SWARMFILE_TTL_DAYS:-1}"
case "$TTL" in
  ''|*[!0-9]*) fail "ttl-days must be a number" ;;
esac
[ "$TTL" -ge 1 ] && [ "$TTL" -le 30 ] || fail "ttl-days must be between 1 and 30"

WORK="$(new_work_dir)"
WORK="$(cd "$WORK" && pwd -P)"
CACHE="$WORK/cache"
BOOT="$WORK/boot"
AGENT="$WORK/agent"
CONFIG="$WORK/config.json"
ENGINE_LOG="$WORK/engine.log"
MOUNT_JSON="$WORK/mount.json"
CID_FILE="$WORK/agent.cid"
MOUNT_ID=""
ENGINE_PID=""
HOST_HOME="$WORK/home"
HOST_PID=""

if [ "${SWARMFILE_AGENT_PLAN_ONLY:-0}" = "1" ]; then
  jq -n \
    --arg org "$ORG" --arg repository "$PROJECT" --arg hub "$HUB" \
    --arg base "$BASE" --arg label "$label" --arg branch "$BRANCH" \
    --arg workspace "$AGENT" --arg image "$IMAGE" --argjson ttl "$TTL" \
    '{mode:"agent", org:$org, repository:$repository, hub:$hub, baseBranch:$base,
      label:$label, branch:$branch, workspace:$workspace, image:$image,
      ttlDays:$ttl}'
  exit 0
fi

command -v docker >/dev/null 2>&1 || fail "docker is required in the agent job"

mkdir -p "$CACHE" "$BOOT" "$AGENT"
printf '{}' > "$CONFIG"

export SWARMFILE_HUB_URL="$HUB"
export SWARMFILE_ORG_ID="$ORG"
export SWARMFILE_REPOSITORY_ID="$PROJECT"
export SWARMFILE_API_KEY
export SWARMFILE_BRANCH="$BASE"
export SWARMFILE_MOUNT_POINT="$BOOT"
export SWARMFILE_CACHE_DIR="$CACHE"
export SWARMFILE_CONFIG="$CONFIG"
export SWARMFILE_MACHINE_ID="gha-${RUN_ID}-${ATTEMPT}"
export SWARMFILE_HUB_ONLY=1
export SWARMFILE_NO_KEYCHAIN=1

if [ -n "$SWARMFILE_API_KEY" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::add-mask::$SWARMFILE_API_KEY"
fi

sf() { swarmfile --cache-dir "$CACHE" "$@"; }
engine_log() {
  [ -f "$ENGINE_LOG" ] || return 0
  printf '::group::swarmfile engine log\n'
  tail -n 120 "$ENGINE_LOG" || true
  for f in "$CACHE"/*.log "$CACHE"/*/*.log; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"
    tail -n 120 "$f" || true
  done
  find "$CACHE" -maxdepth 2 -type f -print 2>/dev/null | head -40 || true
  printf '::endgroup::\n'
}
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$HOST_PID" ]; then
    kill -- "-$HOST_PID" >/dev/null 2>&1 || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  if [ -f "$CID_FILE" ]; then
    docker rm -f "$(cat "$CID_FILE")" >/dev/null 2>&1 || true
  fi
  if [ -f "$CACHE/control.json" ] || { [ -n "$ENGINE_PID" ] && kill -0 "$ENGINE_PID" 2>/dev/null; }; then
    swarmfile-engine --quit >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      [ -f "$CACHE/control.json" ] || break
      sleep 0.25
    done
    if [ -n "$ENGINE_PID" ]; then
      kill "$ENGINE_PID" 2>/dev/null || true
      wait "$ENGINE_PID" 2>/dev/null || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

say "starting the engine for $ORG/$PROJECT on $BASE"
# Keep the preinstalled-toolchain diagnostics with the engine log; a missing
# shared library or an ABI mismatch otherwise reads as an empty log.
{
  printf 'engine=%s\n' "$(command -v swarmfile-engine)"
  ldd "$(command -v swarmfile-engine)" 2>&1 || true
  swarmfile-engine --version 2>&1 || printf 'engine --version exit=%s\n' "$?"
  swarmfile-engine --build-info 2>&1 || true
  swarmfile-engine --print-env-vars 2>&1 | head -40 || true
  printf 'config=%s\n' "$SWARMFILE_CONFIG"
  cat "$SWARMFILE_CONFIG" 2>&1 || true
} >>"$ENGINE_LOG" 2>&1
RUST_BACKTRACE=1 RUST_LOG=debug swarmfile-engine >>"$ENGINE_LOG" 2>&1 &
ENGINE_PID=$!

ready=0
for _ in $(seq 1 240); do
  if [ -f "$CACHE/control.json" ] && sf status --json >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
    # The release engine may daemonize (the parent exits 0 while a child owns
    # the control socket). Give the socket a grace period before declaring a
    # startup failure; an in-process engine never reaches this branch.
    for _ in $(seq 1 20); do
      if [ -f "$CACHE/control.json" ] && sf status --json >/dev/null 2>&1; then
        ready=1
        break 2
      fi
      sleep 0.5
    done
    wait "$ENGINE_PID" 2>/dev/null
    printf 'engine exit=%s\n' "$?" >>"$ENGINE_LOG"
    engine_log
    fail "the engine exited during startup"
  fi
  sleep 0.5
done
[ "$ready" = "1" ] || {
  engine_log
  fail "the engine did not become ready (control socket)"
}

say "waiting for the boot mount"
mount_state=""
for _ in $(seq 1 600); do
  mount_state="$(sf mounts status default --json 2>/dev/null | jq -r '.mountState // empty' 2>/dev/null || true)"
  [ "$mount_state" = "mounted" ] && break
  [ "$mount_state" = "failed" ] && {
    engine_log
    fail "the boot mount failed"
  }
  sleep 1
done
[ "$mount_state" = "mounted" ] || {
  engine_log
  fail "the boot mount did not attach (state: ${mount_state:-unknown})"
}

say "waiting for the initial change feed"
synced=0
for _ in $(seq 1 600); do
  if sf status --json 2>/dev/null | jq -e '.lastSequenceId > 0' >/dev/null 2>&1; then
    synced=1
    break
  fi
  sleep 1
done
[ "$synced" = "1" ] || {
  engine_log
  fail "the repository never reached a synced state; is the git view enabled and the repository non-empty?"
}

say "reading .swarmfile/agents.yml"
command -v node >/dev/null 2>&1 \
  || fail "node 18+ is required to read .swarmfile/agents.yml (install-deps: true installs it)"
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' >/dev/null 2>&1 \
  || fail "node 18+ is required to read .swarmfile/agents.yml (install-deps: true installs it)"
# Fail closed: a malformed policy is a configuration error, not "use defaults".
policy_json="$(node "$here/read-policy.mjs" "$BOOT/.swarmfile/agents.yml")" \
  || fail "invalid .swarmfile/agents.yml"
policy_get() { printf '%s' "$policy_json" | jq -r --arg key "$1" 'if has($key) then .[$key] else empty end' 2>/dev/null || true; }
policy_ttl="$(policy_get ttl_days)"; [ -n "$policy_ttl" ] || policy_ttl=1
TTL="${SWARMFILE_TTL_DAYS:-$policy_ttl}"
case "$TTL" in
  ''|*[!0-9]*) fail "ttl-days must be a number" ;;
esac
[ "$TTL" -ge 1 ] && [ "$TTL" -le 30 ] || fail "ttl-days must be between 1 and 30"
CONFLICT="$(policy_get conflict_mode)"
case "$CONFLICT" in
  soft|hard) ;;
  *) CONFLICT=hard ;;
esac
IMAGE="${SWARMFILE_CONTAINER_IMAGE:-$(policy_get image)}"
[ -n "$IMAGE" ] || IMAGE=node:24-bookworm
case "$IMAGE" in
  ''|-*|*[!A-Za-z0-9._:/@-]*) fail "invalid container image reference: $IMAGE" ;;
esac
BRANCH_PREFIX="$(policy_get branch_prefix)"
[ -n "$BRANCH_PREFIX" ] || BRANCH_PREFIX=agents
BRANCH="$(branch_for "$label" "$BRANCH_PREFIX")"
LOCAL_CHECKS="$(policy_get local_checks)"
LOCAL_CHECK_COMMAND="${SWARMFILE_LOCAL_CHECK_COMMAND:-}"
POST_COMMAND="${SWARMFILE_POST_COMMAND:-}"
if [ "$LOCAL_CHECKS" = "true" ] && [ -z "$LOCAL_CHECK_COMMAND" ]; then
  fail "local_checks is true but local-check-command is empty"
fi

say "opening an agent workspace"
if ! sf mounts new "$AGENT" --json --label "$label" --ttl-days "$TTL" \
  --conflict-mode "$CONFLICT" --wait > "$MOUNT_JSON"; then
  engine_log
  [ -s "$MOUNT_JSON" ] && cat "$MOUNT_JSON" >&2
  fail "could not open the agent workspace"
fi
MOUNT_ID="$(jq -r '.mountId // empty' "$MOUNT_JSON")"
MOUNT_PATH="$(jq -r '.mountPoint // empty' "$MOUNT_JSON")"
AGENT_BRANCH="$(jq -r '.branch // empty' "$MOUNT_JSON")"
[ -n "$MOUNT_ID" ] || {
  cat "$MOUNT_JSON" >&2
  fail "mounts new returned no mountId"
}
[ -n "$MOUNT_PATH" ] && [ -d "$MOUNT_PATH" ] || {
  engine_log
  fail "mounts new returned no attached mountPoint"
}
MOUNT_PATH="$(realpath "$MOUNT_PATH")"
case "$MOUNT_PATH" in
  "$WORK"/*) ;;
  *) fail "mounts new returned a path outside the action workspace: $MOUNT_PATH" ;;
esac
if [[ ! "$AGENT_BRANCH" =~ ^agent/[a-z0-9-]+-[0-9a-f]{6}$ ]]; then
  fail "mounts new returned an unexpected workspace branch: $AGENT_BRANCH"
fi
say "workspace $MOUNT_ID on $AGENT_BRANCH at $MOUNT_PATH"

say "opening an agent session"
session_started=false
if sf --mount "$MOUNT_ID" agent start "$label" >"$WORK/session.log" 2>&1; then
  session_started=true
else
  say "warning: agent sessions are unavailable in this engine; using a plain checkpoint"
fi

say "running the agent in $IMAGE"
say "mount path: $(stat -c '%F mode=%a owner=%U:%G' "$MOUNT_PATH" 2>/dev/null || echo unknown)"
ls -ld "$MOUNT_PATH" 2>&1 || true
mount | grep -F " $MOUNT_PATH " 2>/dev/null || true
IFS=',' read -r -a env_names <<< "$AGENT_ENV"
docker_args=(
  docker run --rm --init --cidfile "$CID_FILE"
  --user "$(id -u):$(id -g)"
  --mount "type=bind,source=$MOUNT_PATH,target=/workspace" -w /workspace
  --tmpfs "/tmp:rw,exec,size=2g"
  -e HOME=/tmp/home
)
for name in "${env_names[@]}"; do
  name="${name//[[:space:]]/}"
  case "$name" in
    '') ;;
    SWARMFILE_*|GITHUB_*|ACTIONS_*|GH_TOKEN)
      fail "agent-env may not pass $name; it is a host secret or control variable" ;;
    *) docker_args+=(-e "$name") ;;
  esac
done
docker_args+=(
  -e "SWARMFILE_PROMPT=$PROMPT"
  -e "SWARMFILE_ISSUE_NUMBER=$ISSUE"
  -e "SWARMFILE_ORG_ID=$ORG"
  -e "SWARMFILE_REPOSITORY_ID=$PROJECT"
  -e "SWARMFILE_HUB_URL=$HUB"
)
agent_body=""
if [ -n "$SETUP" ]; then
  agent_body="$agent_body"$'\n'"$SETUP"
fi
agent_body="$agent_body"$'\n'"$COMMAND"
# Local checks run in the same container as the harness, never on the host:
# repo-authored test code must not see the runner's env, boot mount or control
# socket. They are trusted workflow input (the command string), but the code
# they execute is the agent branch's. run-on-host is the explicit exception.
if [ "$LOCAL_CHECKS" = "true" ]; then
  agent_body="$agent_body"$'\n'"echo '[checks] running local checks'"
  agent_body="$agent_body"$'\n'"$LOCAL_CHECK_COMMAND"
fi
# A final command runs after the harness and the repo-authored local checks, so
# a workflow-supplied scan (trusted input) sees everything the branch produced.
if [ -n "$POST_COMMAND" ]; then
  agent_body="$agent_body"$'\n'"$POST_COMMAND"
fi
agent_script="set -e"$'\n'"mkdir -p /tmp/home; cd /workspace"$'\n'"$agent_body"
host_script="set -e"$'\n'"mkdir -p \"$HOST_HOME\"; cd \"$MOUNT_PATH\""$'\n'"$agent_body"
docker_args+=(-- "$IMAGE" bash -c "$agent_script")

agent_status=0
set +e
case "${SWARMFILE_RUN_ON_HOST:-0}" in 1|true|TRUE)
  # Some hosted runners cannot bind a FUSE workspace into Docker (the daemon
  # sees the mount as a file or gets EACCES). This mode runs the harness on
  # the runner with a scrubbed environment; it is an explicit opt-in and
  # bypasses container isolation.
  say "running the agent on the host (run-on-host enabled; NO container isolation)"
  mkdir -p "$HOST_HOME"
  chmod 700 "$HOST_HOME"
  host_env=(HOME="$HOST_HOME" PATH="$PATH")
  for name in "${env_names[@]}"; do
    name="${name//[[:space:]]/}"
    case "$name" in
      ''|SWARMFILE_*|GITHUB_*|ACTIONS_*|GH_TOKEN) ;;
      *) if [ -n "${!name:-}" ]; then host_env+=("$name=${!name}"); fi ;;
    esac
  done
  host_env+=(
    "SWARMFILE_PROMPT=$PROMPT"
    "SWARMFILE_ISSUE_NUMBER=$ISSUE"
    "SWARMFILE_ORG_ID=$ORG"
    "SWARMFILE_REPOSITORY_ID=$PROJECT"
    "SWARMFILE_HUB_URL=$HUB"
  )
  if command -v setsid >/dev/null 2>&1; then
    setsid env -i "${host_env[@]}" bash -c "$host_script" >"$WORK/host-agent.log" 2>&1 &
    HOST_PID=$!
    tail -n +1 -f "$WORK/host-agent.log" --pid="$HOST_PID" 2>/dev/null | sed 's/^/[agent] /' | tee "$WORK/agent.log" || true
    wait "$HOST_PID" || agent_status=$?
    # Kill the session's remaining process group (a harness may leave a
    # background child); the leader has exited, so this is best-effort.
    kill -- "-$HOST_PID" 2>/dev/null || true
    HOST_PID=""
  else
    env -i "${host_env[@]}" bash -c "$host_script" 2>&1 | sed 's/^/[agent] /' | tee "$WORK/agent.log"
    agent_status=${PIPESTATUS[0]}
  fi
  ;;
*)
  "${docker_args[@]}" 2>&1 | sed 's/^/[agent] /' | tee "$WORK/agent.log"
  agent_status=${PIPESTATUS[0]}
  ;;
esac
set -e

# Checkpoint the LIVE agent session before ending it. The session manager's
# commit path is what derives/stores the canonical commit hash; a staged
# submit from `agent done` leaves the commit provisional.
say "checkpointing the agent workspace"
committed=false
drained=false
no_changes=false
attempt=0
while :; do
  attempt=$((attempt + 1))
  [ "$attempt" -le 3 ] || break
  cp_json="$(sf --mount "$MOUNT_ID" checkpoint --json --wait 60 2>/dev/null || true)"
  if [ -z "$cp_json" ]; then
    fail "could not drain the workspace (no checkpoint response)"
  fi
  checkpointed="$(printf '%s' "$cp_json" | jq -r '.checkpointed // false' 2>/dev/null || echo false)"
  reason="$(printf '%s' "$cp_json" | jq -r '.reason // empty' 2>/dev/null || true)"
  changeset="$(printf '%s' "$cp_json" | jq -r '.changesetId // empty' 2>/dev/null || true)"
  decision="$(checkpoint_decision "$checkpointed" "$reason" "$changeset")"
  case "$decision" in
    committed)
      committed=true
      drained=true
      break
      ;;
    no_changes)
      no_changes=true
      drained=true
      break
      ;;
    submit)
      if sf --mount "$MOUNT_ID" commit -m "Agent: $label"; then
        committed=true
        drained=true
        break
      fi
      ;;
    retry)
      say "waiting for the hub commit (attempt $attempt)"
      [ "$attempt" -ge 3 ] && break
      sleep 5
      continue
      ;;
    *)
      fail "could not confirm the agent's commit (reason: ${reason:-missing})"
      ;;
  esac
  if [ "$attempt" -ge 3 ]; then break; fi
  sleep 2
done

[ "$drained" = "true" ] || fail "could not drain or confirm the workspace commit"
if [ "$committed" != "true" ] && [ "$no_changes" != "true" ]; then
  fail "could not confirm the agent's commit; refusing to promote an unverified workspace"
fi

# End the session only AFTER the commit. `agent done` writes the session
# transcript; a failure here cannot invalidate a commit the checkpoint already
# confirmed, but it must be visible.
if [ "$session_started" = "true" ]; then
  agent_done_rc=0
  sf --mount "$MOUNT_ID" agent "done" --name "$label" >"$WORK/session-end.log" 2>&1 || agent_done_rc=$?
  [ "$agent_done_rc" = "0" ] || say "warning: agent done exited $agent_done_rc after the commit was confirmed"
fi

# A failure preserves the workspace and its TTL; never promote it into a
# permanent named branch just to report an error.
if [ "$agent_status" -ne 0 ]; then
  say "the agent command exited $agent_status; the workspace $AGENT_BRANCH stays on the hub (workspace TTL ${TTL}d)"
  exit "$agent_status"
fi

# Only a confirmed change is promoted. A confirmed no-change run keeps the
# ephemeral workspace/TTL and publishes nothing.
published_branch="$AGENT_BRANCH"
if [ "$no_changes" = "true" ]; then
  say "no changes; leaving the workspace $AGENT_BRANCH on the hub (TTL ${TTL}d)"
else
  say "promoting $BRANCH"
  promote_status=0
  sf mounts promote "$MOUNT_ID" "$BRANCH" || promote_status=$?
  [ "$promote_status" = "0" ] || fail "mounts promote failed (exit $promote_status)"
  published_branch="$BRANCH"
fi

# Derive/upload the commit objects and submit the claims on the promoted
# branch. A commit on the ephemeral workspace can stay provisional; the named
# branch is what the publish job fetches, and promotion closes the agent mount.
if [ "$committed" = "true" ]; then
  say "confirming the promoted branch (git index)"
  CONFIRM_DIR="$(mktemp -d "$WORK/confirm.XXXXXX")"
  if ! sf mounts open "$CONFIRM_DIR" --branch "$published_branch" --json --wait >"$WORK/confirm.json" 2>&1; then
    cat "$WORK/confirm.json" >&2 || true
    fail "could not open the promoted branch to confirm the commit"
  fi
  CONFIRM_ID="$(jq -r '.mountId // empty' "$WORK/confirm.json" 2>/dev/null || true)"
  if [ -z "$CONFIRM_ID" ]; then
    cat "$WORK/confirm.json" >&2 || true
    fail "the confirmation mount has no id"
  fi
  if ! git_index_json="$(sf --mount "$CONFIRM_ID" git index --json 2>"$WORK/git-index.err")"; then
    cat "$WORK/git-index.err" >&2 || true
    [ -n "${git_index_json:-}" ] && printf '%s\n' "$git_index_json" >&2
    fail "git index could not confirm the agent commit"
  fi
  printf '%s' "$git_index_json" > "$WORK/git-index.json"
  # The index response is the authoritative head: the branch row can lag it
  # by a tick, and the publish job fetches the final head.
  # Select the outcome for the branch's HEAD seq, not the last derived
  # ancestor: a confirmed head may sit on a provisional parent, and "last"
  # would then hand the publish job the ancestor's hash.
  index_seq="$(printf '%s' "$git_index_json" | jq -r '.seq // empty' 2>/dev/null || true)"
  index_head="$(printf '%s' "$git_index_json" \
    | jq -r --arg seq "${index_seq:-}" '(.outcomes // []) | map(select((.seq|tostring) == $seq and .derivedHash != null)) | last | .derivedHash // empty' 2>/dev/null || true)"
  sf mounts close "$CONFIRM_ID" >/dev/null 2>&1 || true
fi

# The branch row's head is the canonical commit the publish job binds to.
# Read the agent branch (its head is set by the checkpoint above) for a
# changed run; a base head is only valid for a confirmed no-change run.
# Read the branch head from the hub directly (not the engine's per-mount
# cache). The repository key is the same credential the engine used; the header
# stays out of argv via curl's stdin config.
head=""
if [ -n "${index_head:-}" ]; then
  head="$index_head"
else
  head_branch="$published_branch"
  [ "$no_changes" = "true" ] && head_branch="$BASE"
  HEAD_TRIES="${SWARMFILE_HEAD_TRIES:-30}"
  HEAD_SLEEP_SECS="${SWARMFILE_HEAD_SLEEP_SECS:-1}"
  for _ in $(seq 1 "$HEAD_TRIES"); do
    head="$(printf 'header = "Authorization: Bearer %s"\n' "$SWARMFILE_API_KEY" \
      | curl -fsS -K - "${HUB%/}/orgs/$ORG/repositories/$PROJECT/branches" 2>/dev/null \
      | jq -r --arg b "$head_branch" '(.branches // .)[] | select(.name == $b) | (.headCommitHash // .head_commit_hash // empty)' 2>/dev/null \
      | head -1)"
    [ -n "$head" ] && break
    sleep "$HEAD_SLEEP_SECS"
  done
  # The engine's branch list is a second view when the direct read is blocked.
  if [ -z "$head" ]; then
    head="$(sf --json branch list --all 2>/dev/null \
      | jq -r --arg b "$head_branch" '(.branches // .)[] | select(.name == $b) | (.headCommitHash // .head_commit_hash // empty)' 2>/dev/null \
      | head -1)"
  fi
fi
if [ "$no_changes" != "true" ] && [ -z "$head" ]; then
  fail "the agent commit is not confirmed on $published_branch (headCommitHash is null); refusing to publish"
fi
[ -n "$head" ] || fail "could not read the branch's canonical commit from the hub"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "branch<<SWARMFILE_BRANCH_END"
    echo "$published_branch"
    echo "SWARMFILE_BRANCH_END"
    echo "head<<SWARMFILE_HEAD_END"
    echo "$head"
    echo "SWARMFILE_HEAD_END"
  } >> "$GITHUB_OUTPUT"
fi
say "agent workspace ready on $published_branch at $head"
