#!/usr/bin/env bash
# Install the Swarmfile engine/CLI (agent mode) or only the git helper
# (publish mode) on a Linux runner.
#
# A pinned .deb URL or SHA-256 always wins over a preinstalled toolchain, so a
# pin cannot be silently bypassed. Without a pin, the newest Linux .deb attached
# to the agent-action public release is resolved through the hub's anonymous
# assets on its workers.dev origin (the unchallenged path for GitHub-hosted
# runners), with the update channel as the fallback; either path is verified
# against a published digest before any binary runs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MODE="${SWARMFILE_MODE:-agent}"
case "$MODE" in
  agent|publish) ;;
  *) fail "mode must be agent or publish" ;;
esac
GIT_ONLY=false
[ "$MODE" = "publish" ] && GIT_ONLY=true

# A fresh directory per run: a fixed path lets a prior step (or a poisoned
# RUNNER_TEMP) plant the binaries this action later adds to PATH.
TOOLS="$(mktemp -d "${RUNNER_TEMP:-/tmp}/swarmfile-action.XXXXXX")"
BIN="$TOOLS/root/usr/bin"
MANIFEST="${SWARMFILE_UPDATE_MANIFEST:-https://updates.swarmfile.com/stable/latest.json}"
# The hub's workers.dev origin serves the anonymous release assets without the
# custom domain's bot challenge, which is what GitHub-hosted runners hit. The
# action input (install-asset-hub) sets this; an empty value disables the path.
ASSET_HUB="${SWARMFILE_INSTALL_ASSET_HUB-https://swarmfile-dispatch-production.mdodd.workers.dev}"
RESOLVER="$SCRIPT_DIR/resolve-install-deb.mjs"
INSTALL_DEPS="${SWARMFILE_INSTALL_DEPS:-true}"
DEB="$TOOLS/swarmfile.deb"
curl_proto=(--proto '=https,file' --proto-redir '=https' --tlsv1.2)

require_agent_features() {
  local cli="$1" help
  help="$("$cli" mounts new --help 2>&1 || true)"
  case "$help" in
    *--ttl-days*) ;;
    *) fail "this release predates workspace TTLs; set deb-url to a 0.3.13+ .deb" ;;
  esac
  case "$help" in
    *--conflict-mode*) ;;
    *) fail "this release predates per-mount conflict modes; set deb-url to a 0.3.13+ .deb" ;;
  esac
  "$cli" mounts promote --help >/dev/null 2>&1 \
    || fail "this release predates mounts promote; set deb-url to a 0.3.13+ .deb"
  "$cli" commit --help >/dev/null 2>&1 \
    || fail "this release predates the commit fallback; set deb-url to a 0.3.13+ .deb"
  "$cli" agent --help >/dev/null 2>&1 \
    || fail "this release predates agent sessions; set deb-url to a 0.3.13+ .deb"
  "$cli" checkpoint --help >/dev/null 2>&1 \
    || fail "this release predates checkpoints; set deb-url to a 0.3.13+ .deb"
  "$cli" git index --help 2>&1 | grep -c -- '--json' >/dev/null \
    || fail "this release predates the canonical-head binding; set deb-url to a 0.3.15+ .deb"
}

case "$(uname -s)" in
  Linux) ;;
  *) fail "this action supports Linux x86_64 runners; $(uname -s) is not supported" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ;;
  *) fail "this action supports x86_64 runners; $(uname -m) is not supported" ;;
esac

pinned=false
if [ -n "${SWARMFILE_DEB_URL:-}" ] || [ -n "${SWARMFILE_DEB_SHA256:-}" ]; then
  pinned=true
fi

# A preinstalled toolchain (a runner image that already ships Swarmfile) skips
# both the .deb download and the dependency install; a pin still wins over it.
preinstalled=false
if ! $pinned; then
  if $GIT_ONLY; then
    command -v git-remote-swarmfile >/dev/null 2>&1 && preinstalled=true
  elif command -v swarmfile-engine >/dev/null 2>&1 \
    && command -v swarmfile >/dev/null 2>&1 \
    && command -v git-remote-swarmfile >/dev/null 2>&1; then
    preinstalled=true
  fi
fi
if $preinstalled; then
  say "using the preinstalled Swarmfile toolchain; skipping the .deb download and dependency install"
fi

node18() {
  node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' >/dev/null 2>&1
}

command -v curl >/dev/null 2>&1 || fail "missing required runner tool: curl"

# Node is needed to parse .swarmfile/agents.yml on both the agent and publish
# paths. Use the distro package (Ubuntu 24.04 supplies Node 18) rather than an
# unverified `curl | sudo bash`; a runner older than 18 must install Node itself.
if [ "$INSTALL_DEPS" = "true" ] && ! $preinstalled; then
  sudo apt-get update -qq
  if ! node18; then
    say "installing the distro Node 18+ (required for the policy reader)"
    sudo apt-get install -y -qq nodejs npm
  fi
  if ! command -v jq >/dev/null 2>&1; then
    sudo apt-get install -y -qq jq
  fi
  # The engine binary links libfuse/libssl even when only the git helper is
  # used (GIT_ONLY); install those runtime libs for both modes.
  say "installing the engine runtime libraries"
  sudo apt-get install -y -qq libfuse2 libssl3 2>/dev/null \
    || sudo apt-get install -y -qq libfuse2t64 libssl3t64
  if ! $GIT_ONLY; then
    sudo apt-get install -y -qq fuse3 2>/dev/null || true
  fi
fi
node18 || fail "Node 18+ is required to read .swarmfile/agents.yml; install Node 18+ or set install-deps: true"
command -v jq >/dev/null 2>&1 || fail "jq is required; leave install-deps: true or install it on the runner"

if ! $pinned; then
  if $GIT_ONLY; then
    if command -v git-remote-swarmfile >/dev/null 2>&1; then
      say "using the preinstalled git-remote-swarmfile"
      if ldd "$(command -v git-remote-swarmfile)" 2>/dev/null | grep -c 'not found' >/dev/null ; then
        ldd "$(command -v git-remote-swarmfile)" >&2 || true
        fail "git-remote-swarmfile has unresolved shared libraries; install the missing packages or set install-deps: true"
      fi
      exit 0
    fi
  elif command -v swarmfile-engine >/dev/null 2>&1 \
    && command -v swarmfile >/dev/null 2>&1 \
    && command -v git-remote-swarmfile >/dev/null 2>&1; then
    say "using the preinstalled Swarmfile engine, CLI and git helper"
    require_agent_features "$(command -v swarmfile)"
    for tool in swarmfile-engine swarmfile git-remote-swarmfile; do
      if ldd "$(command -v "$tool")" 2>/dev/null | grep -c 'not found' >/dev/null ; then
        ldd "$(command -v "$tool")" >&2 || true
        fail "$tool has unresolved shared libraries; install the missing packages or set install-deps: true"
      fi
    done
    # The preinstalled path skips the .deb extraction but still needs a usable
    # FUSE device for the agent job (the publish job is GIT_ONLY).
    if [ ! -e /dev/fuse ]; then
      fail "/dev/fuse is not available on this runner; Swarmfile needs a FUSE-capable Linux runner"
    fi
    if [ ! -w /dev/fuse ]; then
      sudo chmod 666 /dev/fuse 2>/dev/null || true
      [ -w /dev/fuse ] || fail "/dev/fuse is not writable by $(id -un); the engine cannot mount"
    fi
    exit 0
  fi
fi

command -v dpkg-deb >/dev/null 2>&1 || fail "missing required runner tool: dpkg-deb (needed to install the release .deb)"
mkdir -p "$TOOLS" "$BIN"

deb_url="${SWARMFILE_DEB_URL:-}"
asset_sha=""
if [ -z "$deb_url" ] && [ -n "$ASSET_HUB" ] && ! $pinned; then
  say "resolving the release .deb from $ASSET_HUB"
  if resolved="$(node "$RESOLVER" --hub "$ASSET_HUB" 2>"$TOOLS/resolve.err")"; then
    asset_tag="$(printf '%s' "$resolved" | jq -r '.tag // empty')"
    asset_name="$(printf '%s' "$resolved" | jq -r '.name // empty')"
    deb_url="$(printf '%s' "$resolved" | jq -r '.url // empty')"
    asset_sha="$(printf '%s' "$resolved" | jq -r '.sha256 // empty')"
    if [ -n "$deb_url" ] && [ -n "$asset_sha" ]; then
      say "using ${asset_name:-the linux .deb} from $asset_tag"
    else
      deb_url=""; asset_sha=""
    fi
  fi
  if [ -z "$deb_url" ]; then
    say "the public release asset is unavailable; falling back to the update channel"
    [ -s "$TOOLS/resolve.err" ] && sed 's/^/  /' "$TOOLS/resolve.err" >&2
  fi
fi
if [ -z "$deb_url" ]; then
  say "reading $MANIFEST"
  meta="$TOOLS/latest.json"
  curl -fsSL "${curl_proto[@]}" --retry 3 --retry-delay 2 -o "$meta" "$MANIFEST" \
    || fail "could not fetch $MANIFEST (a runner behind the zone's bot challenge: leave install-asset-hub at its default, or set deb-url/deb-sha256)"
  deb_url="$(jq -r '.platforms["linux-x86_64"].url // empty' "$meta")"
  [ -n "$deb_url" ] || fail "the update manifest has no linux-x86_64 .deb URL"
fi

say "downloading $deb_url"
curl -fL "${curl_proto[@]}" --retry 3 --retry-delay 2 -o "$DEB" "$deb_url" \
  || fail "could not download $deb_url"

if [ -n "${SWARMFILE_DEB_SHA256:-}" ]; then
  echo "${SWARMFILE_DEB_SHA256}  $DEB" | sha256sum -c - \
    || fail "the downloaded .deb does not match SWARMFILE_DEB_SHA256"
elif [ -n "$asset_sha" ]; then
  echo "${asset_sha}  $DEB" | sha256sum -c - \
    || fail "the downloaded .deb does not match the release asset digest"
else
  sums="$TOOLS/SHA256SUMS"
  sums_url="$(dirname "$deb_url")/SHA256SUMS"
  say "verifying against $sums_url"
  curl -fsSL "${curl_proto[@]}" --retry 3 --retry-delay 2 -o "$sums" "$sums_url" \
    || fail "could not fetch $sums_url; set deb-sha256 to verify a custom mirror"
  line_hash="$(awk -v f="$(basename "$deb_url")" '$2 == f { print $1; exit }' "$sums")"
  [ -n "$line_hash" ] || fail "SHA256SUMS has no entry for $(basename "$deb_url")"
  printf '%s  %s\n' "$line_hash" "$DEB" | sha256sum -c - \
    || fail "the downloaded .deb does not match SHA256SUMS"
fi

rm -rf "$TOOLS/root"
mkdir -p "$TOOLS/root"
dpkg-deb -x "$DEB" "$TOOLS/root" || fail "could not extract $DEB"

if $GIT_ONLY; then
  [ -x "$BIN/git-remote-swarmfile" ] || fail "the .deb does not contain usr/bin/git-remote-swarmfile"
  if ldd "$BIN/git-remote-swarmfile" 2>/dev/null | grep -c 'not found' >/dev/null ; then
    ldd "$BIN/git-remote-swarmfile" >&2 || true
    fail "git-remote-swarmfile has unresolved shared libraries"
  fi
else
  for tool in swarmfile-engine swarmfile git-remote-swarmfile; do
    [ -x "$BIN/$tool" ] || fail "the .deb does not contain usr/bin/$tool"
  done
  for tool in swarmfile-engine swarmfile git-remote-swarmfile; do
    if ldd "$BIN/$tool" 2>/dev/null | grep -c 'not found' >/dev/null ; then
      ldd "$BIN/$tool" >&2 || true
      fail "$tool has unresolved shared libraries; install the missing packages or set install-deps: true"
    fi
  done
  if [ ! -e /dev/fuse ]; then
    fail "/dev/fuse is not available on this runner; Swarmfile needs a FUSE-capable Linux runner"
  fi
  if [ ! -w /dev/fuse ]; then
    sudo chmod 666 /dev/fuse 2>/dev/null || true
    [ -w /dev/fuse ] || fail "/dev/fuse is not writable by $(id -un); the engine cannot mount"
  fi
  require_agent_features "$BIN/swarmfile"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$BIN" >> "$GITHUB_PATH"
fi
export PATH="$BIN:$PATH"

say "installed:"
"$BIN/swarmfile" --version 2>/dev/null || true
"$BIN/swarmfile-engine" --version 2>/dev/null || true
