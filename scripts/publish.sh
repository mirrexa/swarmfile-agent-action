#!/usr/bin/env bash
# Publish job: fetch the promoted branch from the hub into a clean checkout,
# push it to GitHub, and optionally open a PR. This is the only job that holds
# a repository-write token; it never executes agent output.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"
umask 077
# A self-hosted runner's exported GIT_DIR/GIT_WORK_TREE would make the
# "clean checkout" git calls operate on a different repository. Clear them
# before the first git invocation (the token unsets stay below).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT \
  GIT_TRACE GIT_CURL_VERBOSE GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE_CURL

need SWARMFILE_ORG_ID "org is required"
need SWARMFILE_REPOSITORY_ID "repository is required"
need SWARMFILE_API_KEY "api-key is required"
need SWARMFILE_GITHUB_TOKEN "github-token is required in publish mode"

ORG="$SWARMFILE_ORG_ID"
PROJECT="$SWARMFILE_REPOSITORY_ID"
HUB="${SWARMFILE_HUB_URL:-https://hub.swarmfile.com}"
BASE="${SWARMFILE_BASE_BRANCH:-main}"
PR_BASE="${SWARMFILE_PR_BASE:-$BASE}"
OPEN_PR="${SWARMFILE_OPEN_PR:-false}"
ISSUE="${SWARMFILE_ISSUE_NUMBER:-}"
GITHUB_TOKEN="$SWARMFILE_GITHUB_TOKEN"
PUBLISH_TOKEN="$GITHUB_TOKEN"
EXPECTED_HEAD="${SWARMFILE_EXPECTED_HEAD:-}"
ALLOW_WORKFLOW_CHANGES="${SWARMFILE_ALLOW_WORKFLOW_CHANGES:-false}"
PUBLISH_BRANCH="${SWARMFILE_PUBLISH_BRANCH:-}"
PROVENANCE="${SWARMFILE_PROVENANCE:-true}"

case "$OPEN_PR" in
  true|false) ;;
  *) fail "open-pr must be true or false" ;;
esac
case "$PROVENANCE" in
  true|false) ;;
  *) fail "provenance must be true or false" ;;
esac
if [ -n "$ISSUE" ] && ! require_numeric "$ISSUE"; then
  fail "issue-number must be numeric"
fi
check_hub_url "$HUB" "${SWARMFILE_GIT_INSECURE_HOSTS:-}"

label="$(sanitize_label "${SWARMFILE_LABEL:-agent}")"
[ -n "$label" ] || label=agent

# The policy is read from the BASE ref, never the working tree: the agent job
# may have checked out an untrusted head, and the working tree is exactly what
# the agent branch is trying to influence.
need GITHUB_WORKSPACE "publish mode must run after actions/checkout"
[ -d "$GITHUB_WORKSPACE/.git" ] || fail "GITHUB_WORKSPACE is not a git checkout"

# The agent job never touches this checkout, but a misconfigured caller can
# still leave a token in it. Refuse instead of silently pushing with it.
if git -C "$GITHUB_WORKSPACE" config --local --get-regexp '^http\..*\.extraheader$' >/dev/null 2>&1; then
  fail "the checkout has persisted credentials; use persist-credentials: false"
fi
origin_url="$(git -C "$GITHUB_WORKSPACE" remote get-url origin 2>/dev/null || true)"
expected="${GITHUB_SERVER_URL%/}/${GITHUB_REPOSITORY}"
case "$origin_url" in
  "$expected"|"$expected.git"|"git@github.com:$GITHUB_REPOSITORY.git"|"https://github.com/$GITHUB_REPOSITORY.git") ;;
  *)
    display_origin="$(printf '%s' "${origin_url:-missing}" | sed -E 's#(https?://)[^/@]+@#\1***@#')"
    fail "origin is not this repository: $display_origin"
    ;;
esac
git -C "$GITHUB_WORKSPACE" rev-parse --verify --quiet "origin/$BASE" >/dev/null \
  || fail "origin/$BASE is missing; check out the base branch with fetch-depth: 0"

if [ -n "$GITHUB_TOKEN" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::add-mask::$GITHUB_TOKEN"
fi
if [ -n "$SWARMFILE_API_KEY" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::add-mask::$SWARMFILE_API_KEY"
fi

# A PAT would let GitHub run workflows from the agent branch with that PAT's
# secrets. The built-in Actions token is an installation token (ghs_) and
# `/user` returns 403 for it; a user/PAT token returns 200. Require both shapes.
case "$GITHUB_TOKEN" in
  ghs_*) ;;
  *) fail "publish mode requires the built-in github.token (an installation token), not a PAT" ;;
esac
api="${GITHUB_API_URL:-https://api.github.com}"
user_status="$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" \
  | curl -sS -K - -H 'Accept: application/vnd.github+json' \
      -o /dev/null -w '%{http_code}' "$api/user" 2>/dev/null || echo 000)"
[ "$user_status" = "403" ] \
  || fail "publish mode requires the built-in github.token (a PAT can execute workflows from the agent branch with its secrets)"

WORK="$(new_work_dir)"
WORK="$(cd "$WORK" && pwd -P)"
EMPTY_HOOKS="$WORK/empty-hooks"
ASKPASS="$WORK/askpass.sh"
POLICY="$WORK/agents.yml"
CHANGED_PATHS="$WORK/changed-paths"
mkdir -p "$EMPTY_HOOKS" "$WORK/cache"
printf '{}' > "$WORK/config.json"

command -v node >/dev/null 2>&1 \
  || fail "node is required to read .swarmfile/agents.yml (GitHub-hosted runners include it)"
if git -C "$GITHUB_WORKSPACE" cat-file -e "origin/$BASE:.swarmfile/agents.yml" 2>/dev/null; then
  git -C "$GITHUB_WORKSPACE" show "origin/$BASE:.swarmfile/agents.yml" > "$POLICY"
else
  : > "$POLICY"
fi
policy_json="$(node "$here/read-policy.mjs" "$POLICY")" \
  || fail "invalid .swarmfile/agents.yml at origin/$BASE"
policy_prefix="$(printf '%s' "$policy_json" | jq -r '.branch_prefix // empty' 2>/dev/null || true)"
[ -n "$policy_prefix" ] || policy_prefix=agents
UPSTREAM_PUSH="$(printf '%s' "$policy_json" | jq -r '.upstream_push // empty' 2>/dev/null || true)"
UPSTREAM_CI="$(printf '%s' "$policy_json" | jq -r '.upstream_ci // empty' 2>/dev/null || true)"
# The policy is the connector-level CI choice: pr_only opens a PR, on_push
# pushes without one, none pushes without a PR. The caller's workflow still
# owns its own triggers; a push made with the built-in github.token does not
# trigger GitHub workflows.
if [ "$UPSTREAM_CI" = "pr_only" ]; then OPEN_PR=true; fi
if [ "$UPSTREAM_CI" = "on_push" ] || [ "$UPSTREAM_CI" = "none" ]; then OPEN_PR=false; fi
if [ "$UPSTREAM_CI" = "on_push" ]; then
  say "note: pushes made with the built-in github.token do not trigger GitHub workflows; use pr_only (CI on the PR) or a GitHub App token"
fi
# The agent job returns its promoted branch. Prefer it over re-deriving the
# name from this job's policy view, which can be one base-branch commit behind.
if [ -n "$PUBLISH_BRANCH" ]; then
  BRANCH="$PUBLISH_BRANCH"
else
  BRANCH="$(branch_for "$label" "$policy_prefix")"
fi
case "$BRANCH" in
  ''|*[!A-Za-z0-9._/-]*) fail "invalid publish branch: $BRANCH" ;;
esac
case "$BRANCH" in
  "$BASE"|"$PR_BASE"|main|master|HEAD)
    fail "refusing to publish $BRANCH: the base/default branch is never an agent publish target"
    ;;
esac
git check-ref-format "refs/heads/$BRANCH" \
  || fail "invalid publish branch: $BRANCH"

case "$UPSTREAM_PUSH" in
  never)
    say "upstream_push=never; $BRANCH stays on the hub and is not pushed"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      delim="SWARMFILE_$(date +%s)_$RANDOM"
      {
        echo "branch<<$delim"
        echo "$BRANCH"
        echo "$delim"
        echo "changed<<$delim"
        echo "false"
        echo "$delim"
      } >> "$GITHUB_OUTPUT"
    fi
    exit 0
    ;;
  manual)
    if [ "${SWARMFILE_MANUAL_PUSH:-false}" != "true" ]; then
      say "upstream_push=manual; set manual-push: true to publish $BRANCH"
      if [ -n "${GITHUB_OUTPUT:-}" ]; then
        delim="SWARMFILE_$(date +%s)_$RANDOM"
        {
          echo "branch<<$delim"
          echo "$BRANCH"
          echo "$delim"
          echo "changed<<$delim"
          echo "false"
          echo "$delim"
        } >> "$GITHUB_OUTPUT"
      fi
      exit 0
    fi
    ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is required on the runner"

# Do not inherit a self-hosted runner's Swarmfile config/cache or gh target.
export SWARMFILE_HUB_URL="$HUB"
export SWARMFILE_ORG_ID="$ORG"
export SWARMFILE_REPOSITORY_ID="$PROJECT"
export SWARMFILE_API_KEY
export SWARMFILE_GIT_INSECURE_HOSTS="${SWARMFILE_GIT_INSECURE_HOSTS:-}"
export SWARMFILE_CONFIG="$WORK/config.json"
export SWARMFILE_CACHE_DIR="$WORK/cache"
export SWARMFILE_NO_KEYCHAIN=1
# The hub helper must never see a GitHub credential. The token is kept in the
# non-exported PUBLISH_TOKEN and handed only to the askpass process inside the
# single push command; gh gets it after the hub fetch.
unset SWARMFILE_BRANCH SWARMFILE_GITHUB_TOKEN GITHUB_TOKEN GH_TOKEN GH_REPO
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
GH_HOST="${GITHUB_SERVER_URL#https://}"
GH_HOST="${GH_HOST#http://}"
GH_HOST="${GH_HOST%%/*}"
export GH_HOST

say "fetching $BRANCH from the hub"
git -C "$GITHUB_WORKSPACE" -c core.hooksPath="$EMPTY_HOOKS" fetch --no-tags \
  "swarmfile://$ORG/$PROJECT" "refs/heads/$BRANCH:refs/remotes/swarmfile/$BRANCH"

count="$(git -C "$GITHUB_WORKSPACE" rev-list --count "origin/$BASE..refs/remotes/swarmfile/$BRANCH")" \
  || fail "could not compare $BRANCH with origin/$BASE"

# expected-head binds the bytes this job pushes to the commit the agent job
# actually produced. It is required whenever there is something to push; a
# confirmed no-change run has no agent commit to bind (and pushes nothing).
github_head=""
if [ "${count:-0}" -gt 0 ]; then
  github_head="$(git -C "$GITHUB_WORKSPACE" rev-parse "refs/remotes/swarmfile/$BRANCH")"
  [ -n "$EXPECTED_HEAD" ] \
    || fail "expected-head is required when the agent branch has commits"
  fetched_trailer="$(git -C "$GITHUB_WORKSPACE" log -1 --format=%B \
    "refs/remotes/swarmfile/$BRANCH" | sed -n 's/^Swarmfile-Commit: //p' | tail -1)"
  if [ "$fetched_trailer" != "$EXPECTED_HEAD" ]; then
    # Keep the diagnosis actionable: the common miss is a synthetic snapshot
    # tip (no trailer by design), where the agent commit is the parent. Print
    # both subjects/trailers so the next hosted run identifies the shape
    # without another round trip. The binding itself stays strict.
    fetched_subject="$(git -C "$GITHUB_WORKSPACE" log -1 --format=%s \
      "refs/remotes/swarmfile/$BRANCH" 2>/dev/null || true)"
    parent_trailer="$(git -C "$GITHUB_WORKSPACE" log -1 --format=%B \
      "refs/remotes/swarmfile/$BRANCH^" 2>/dev/null \
      | sed -n 's/^Swarmfile-Commit: //p' | tail -1 || true)"
    fail "the fetched head (git $github_head, subject \"${fetched_subject:-<none>}\", trailer \"${fetched_trailer:-<none>}\") does not carry the agent job's Swarmfile commit ($EXPECTED_HEAD); parent trailer is \"${parent_trailer:-<none>}\""
  fi
elif [ -n "$EXPECTED_HEAD" ]; then
  # A no-change run's expected head is the BASE BRANCH'S SWARMFILE head, not
  # the GitHub base SHA (the agent reports the former; the git commit is the
  # latter, so comparing them could never match). Read the hub head instead.
  base_head="$(printf 'header = "Authorization: Bearer %s"\n' "$SWARMFILE_API_KEY" \
    | curl -fsS -K - "${HUB%/}/orgs/$ORG/repositories/$PROJECT/branches" 2>/dev/null \
    | jq -r --arg b "$BASE" '(.branches // .)[] | select(.name == $b) | (.headCommitHash // .head_commit_hash // empty)' 2>/dev/null \
    | head -1)"
  [ -n "$base_head" ] \
    || fail "could not read the base branch's canonical commit from the hub"
  [ "$EXPECTED_HEAD" = "$base_head" ] \
    || fail "the branch has no commits over origin/$BASE but expected-head ($EXPECTED_HEAD) is not the base's canonical commit ($base_head); the agent commit is missing"
  say "the branch has no commits over origin/$BASE; expected-head matches the base's canonical commit"
fi

# `-z` + `core.quotePath=false` + `--no-renames` is the gate's contract:
# quoted/non-ASCII paths and a rename out of .github must not evade it.
if [ "$ALLOW_WORKFLOW_CHANGES" != "true" ] || [ "${count:-0}" -gt 0 ]; then
  git -C "$GITHUB_WORKSPACE" -c core.quotePath=false diff --no-renames -z --name-only \
    "origin/$BASE..refs/remotes/swarmfile/$BRANCH" > "$CHANGED_PATHS" \
    || fail "could not read the branch diff"
  protected=false
  policy_changed=false
  if [ "${count:-0}" -gt 0 ]; then
    while IFS= read -r -d '' changed; do
      case "$changed" in
        .swarmfile/agents.yml)
          protected=true
          policy_changed=true
          break
          ;;
        .github/workflows/*|.github/actions/*)
          if [ "$ALLOW_WORKFLOW_CHANGES" != "true" ]; then
            protected=true
            break
          fi
          ;;
        # The pilot/action repository's action lives at its root; a branch
        # changing it would run the changed publish path on the next merge.
        action.yml|scripts/*)
          if [ -f action.yml ] && [ -f scripts/publish.sh ] && [ "$ALLOW_WORKFLOW_CHANGES" != "true" ]; then
            protected=true
            break
          fi
          ;;
      esac
    done < "$CHANGED_PATHS"
  fi
  if [ "$protected" = "true" ]; then
    if [ "$policy_changed" = "true" ]; then
      fail "the agent branch changes .swarmfile/agents.yml; review and merge a policy change outside the agent workflow"
    fi
    fail "the agent branch changes .github/workflows, .github/actions or this repository's action source; set allow-workflow-changes: true only if you trust the agent"
  fi
fi

changed=false
pushed=false
pr_url=""
if [ "${count:-0}" -gt 0 ]; then
  changed=true
  say "pushing $BRANCH to $GITHUB_REPOSITORY"
  cat > "$ASKPASS" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf 'x-access-token\n' ;;
  *) printf '%s\n' "$PUBLISH_TOKEN" ;;
esac
EOF
  chmod 0700 "$ASKPASS"
  push_url="${GITHUB_SERVER_URL%/}/${GITHUB_REPOSITORY}.git"
  PUBLISH_TOKEN="$PUBLISH_TOKEN" GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
    git -C "$GITHUB_WORKSPACE" \
      -c core.hooksPath="$EMPTY_HOOKS" -c credential.helper= \
      push --no-verify "$push_url" "refs/remotes/swarmfile/$BRANCH:refs/heads/$BRANCH"
  pushed=true
else
  say "the branch has no commits over origin/$BASE; nothing to push"
fi

if [ "$OPEN_PR" = "true" ] && [ "$changed" = "true" ] && [ "$pushed" = "true" ]; then
  command -v gh >/dev/null 2>&1 || fail "open-pr is true but the GitHub CLI (gh) is not installed"
  export GH_TOKEN="${GH_TOKEN:-$PUBLISH_TOKEN}"
  [ -n "${GH_TOKEN:-}" ] || fail "open-pr is true but no GitHub token is available"
  existing="$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$BRANCH" --json url --jq '.[0].url // empty' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    pr_url="$existing"
  else
    title="${SWARMFILE_PR_TITLE:-Agent changes}"
    body="${SWARMFILE_PR_BODY:-}"
    [ "${#title}" -le 256 ] || fail "pr-title is too long"
    [ "${#body}" -le 60000 ] || fail "pr-body is too long"
    if [ -n "$ISSUE" ]; then
      if [ -n "$body" ]; then body="$body"$'\n\n'; fi
      body="${body}Closes #$ISSUE"
    fi
    pr_url="$(gh pr create --repo "$GITHUB_REPOSITORY" --head "$BRANCH" --base "$PR_BASE" \
      --title "$title" --body "$body")"
  fi
  say "pull request: $pr_url"
fi

# R223 B3 — fetch the hub-signed agent-session manifest before publishing the
# check. The hub verifies the branch's confirmed head and signs a digest with
# the identity key it publishes at /history/signing-key. Failure is a warning,
# not a failed publish: without a manifest we simply do not post a successful
# signed check (a required check stays unsatisfied).
manifest_ok=false
manifest_sha=""
manifest_key=""
manifest_signature=""
manifest_canonical=""
manifest_checkpoints=""
manifest_count=0
if [ "$PROVENANCE" = "true" ] && [ "$pushed" = "true" ] && [ -n "$github_head" ]; then
  if hub_allows_manifest "$HUB"; then
    manifest_url="${HUB%/}/orgs/$ORG/repositories/$PROJECT/agent-session-manifest"
  else
    say "signed manifest skipped: the hub URL must be HTTPS or loopback"
    manifest_url=""
  fi
  run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
  if [ -n "$manifest_url" ] && printf 'header = "Authorization: Bearer %s"\n' "$SWARMFILE_API_KEY" \
    | curl -sS -f -G -K - -H "Accept: application/json" \
        --data-urlencode "branch=$BRANCH" \
        --data-urlencode "head=$EXPECTED_HEAD" \
        --data-urlencode "baseBranch=$BASE" \
        --data-urlencode "label=$label" \
        --data-urlencode "runId=$run_id" \
        --data-urlencode "githubCommit=$github_head" \
        "$manifest_url" -o "$WORK/manifest.json"; then
    manifest_sha="$(jq -r '.sha256 // empty' "$WORK/manifest.json" 2>/dev/null || true)"
    manifest_key="$(jq -r '.signature.keyId // empty' "$WORK/manifest.json" 2>/dev/null || true)"
    manifest_signature="$(jq -r '.signature.signature // empty' "$WORK/manifest.json" 2>/dev/null || true)"
    manifest_canonical="$(jq -r '.canonical // empty' "$WORK/manifest.json" 2>/dev/null || true)"
    manifest_count="$(jq -r '.manifest.checkpoints | length' "$WORK/manifest.json" 2>/dev/null || echo 0)"
    if [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] && [ -n "$manifest_key" ] \
       && [ -n "$manifest_signature" ] && [ -n "$manifest_canonical" ] \
       && node "$here/verify-manifest.mjs" "$WORK/manifest.json" "$BRANCH" "$EXPECTED_HEAD" "$PROJECT" "$github_head"; then
      manifest_ok=true
      manifest_checkpoints="$(jq -r '.manifest.checkpoints[:50][] | "- `\(.seq)` `\(.commit[0:12])`"' "$WORK/manifest.json" 2>/dev/null || true)"
      cat > "$WORK/check.txt" <<EOF
Swarmfile signed agent-session manifest

sha256: $manifest_sha
key_id: $manifest_key
public_key: $(jq -r '.signature.publicKey // empty' "$WORK/manifest.json")
github_commit: $(jq -r '.manifest.githubCommit // empty' "$WORK/manifest.json")
checkpoints_truncated: $(jq -r '.manifest.checkpointsTruncated // false' "$WORK/manifest.json")
signature: $manifest_signature
canonical_base64: $manifest_canonical
domain: swarmfile-agent-manifest-v1
public_key_url: ${HUB%/}/orgs/$ORG/repositories/$PROJECT/history/signing-key

The digest is SHA-256 of the canonical JSON decoded from canonical_base64.
Verify the Ed25519 signature over "swarmfile-agent-manifest-v1\n<sha256>\n<key_id>\n"
with the published key.

The canonical_base64 value above is the complete canonical manifest JSON.
The check's head_sha must equal github_commit (when present); that binding is
the GitHub side, while the hub verified the branch's confirmed head.
EOF
      if [ "$(wc -c < "$WORK/check.txt")" -gt 60000 ]; then
        # A GitHub check text is capped at 65,535 characters. A valid but
        # huge manifest must fail closed instead of posting a truncated,
        # unverifiable check.
        say "signed manifest too large for a GitHub check; no success check posted"
        manifest_ok=false
      fi
    fi
  else
    say "signed manifest skipped (the hub did not return a manifest; is the signing key configured?)"
  fi
fi

# R222 adoption item 12 / R223 B4 — make the agent's identity and checkpoint
# timeline visible on GitHub. A repo can require the `swarmfile/agent` check;
# a caller that does not grant checks/statuses/pull-requests write gets a
# warning, not a failed publish.
if [ "$PROVENANCE" = "true" ] && [ "$pushed" = "true" ] && [ -n "$github_head" ] && [ "$manifest_ok" = "true" ]; then
  if command -v gh >/dev/null 2>&1; then
    export GH_TOKEN="${GH_TOKEN:-$PUBLISH_TOKEN}"
    jq -n       --arg name "swarmfile/agent"       --arg head "$github_head"       --arg title "Swarmfile agent provenance"       --arg summary "Agent $label · branch $BRANCH · GitHub ${github_head:0:12} · Swarmfile ${EXPECTED_HEAD:0:12} · signed manifest $manifest_sha"       --rawfile text "$WORK/check.txt"       --arg details "$pr_url"       '{name:$name, head_sha:$head, status:"completed", conclusion:"success",
        output:{title:$title, summary:$summary, text:$text}}
       + (if $details != "" then {details_url:$details} else {} end)' > "$WORK/check.json"
    if gh api "repos/$GITHUB_REPOSITORY/check-runs" --method POST --input "$WORK/check.json" >/dev/null 2>&1; then
      say "signed provenance check posted on ${github_head:0:12}"
    else
      say "signed provenance check skipped (the token needs checks: write)"
    fi
  else
    say "signed provenance check skipped (gh is not installed)"
  fi
fi

if [ "$PROVENANCE" = "true" ] && [ "$pushed" = "true" ] && [ -n "$github_head" ] && [ "$manifest_ok" = "true" ]; then
  if command -v gh >/dev/null 2>&1; then
    export GH_TOKEN="${GH_TOKEN:-$PUBLISH_TOKEN}"
    desc="agent $label at $BRANCH (signed swarmfile ${EXPECTED_HEAD:0:12})"
    status_args=(api "repos/$GITHUB_REPOSITORY/statuses/$github_head" -f state=success       -f context=swarmfile/agent -f "description=${desc:0:140}")
    if [ -n "$pr_url" ]; then
      status_args+=(-f "target_url=$pr_url")
    fi
    if gh "${status_args[@]}" >/dev/null 2>&1; then
      say "provenance status posted on ${github_head:0:12}"
    else
      say "provenance status skipped (the token needs statuses: write)"
    fi
  else
    say "provenance status skipped (gh is not installed)"
  fi
fi

if [ "$PROVENANCE" = "true" ] && [ -n "$pr_url" ]; then
  if command -v gh >/dev/null 2>&1; then
    # The backticks in the printf format are Markdown, not a command.
    # shellcheck disable=SC2016
    provenance_body="$(printf '**Swarmfile agent provenance**\n\n- Agent: `%s`\n- Branch: `%s`\n- GitHub commit: `%s`\n- Swarmfile commit: `%s`\n\nThe agent job (and local checks, if enabled) succeeded. The workspace and its checkpoints are on the Swarmfile hub.\n'       "$label" "$BRANCH" "$github_head" "$EXPECTED_HEAD")"
    if [ "$manifest_ok" = "true" ]; then
      provenance_body="${provenance_body}
- Signed manifest: \`${manifest_sha}\` (key \`${manifest_key}\`)
- Checkpoints: ${manifest_count}

${manifest_checkpoints}
"
    fi
    if gh pr comment "$pr_url" --body "$provenance_body" >/dev/null 2>&1; then
      say "provenance comment posted on the pull request"
    else
      say "provenance comment skipped (the token needs pull-requests: write)"
    fi
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  delim="SWARMFILE_$(date +%s)_$RANDOM"
  {
    echo "branch<<$delim"
    echo "$BRANCH"
    echo "$delim"
    echo "changed<<$delim"
    echo "$changed"
    echo "$delim"
    if [ -n "$pr_url" ]; then
      echo "pr-url<<$delim"
      echo "$pr_url"
      echo "$delim"
    fi
  } >> "$GITHUB_OUTPUT"
fi

say "done"
