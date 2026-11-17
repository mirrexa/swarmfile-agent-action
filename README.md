# Swarmfile agent workspace — GitHub Action

Run a coding agent in a fresh Swarmfile **agent workspace** from GitHub, then
publish the result as a normal branch or pull request. Two modes are designed to
run in **two separate jobs**: an agent job with no repository write token, and a
publish job that holds the token and never runs agent code.

This is the GitHub-native half of Swarmfile's agent story. GitHub stays the code
host and the review surface; Swarmfile supplies the safe, mounted workspace
behind the agent.

> **Status:** first slice. Linux x86_64 runners only; the agent job needs
> Docker (container mode) and a FUSE-capable runner (the publish job needs
> neither). `run-on-host` is an explicit non-isolating fallback for FUSE-host
> runners where Docker cannot bind the mount (see the input and security notes
> below). The hosted agent job passes on `ubuntu-latest`; use a self-hosted
> runner if your image or network cannot mount. The action needs a release that
> includes the agent-workspace commands (**0.3.15+**); the installer resolves the
> newest published Linux `.deb` from the hub's anonymous release assets first
> (the custom domains challenge GitHub-hosted runners; the hub's `workers.dev`
> origin does not), then falls back to the stable update channel. The anonymous
> asset digest is a transport check served by the same origin; pass
> `deb-sha256` (or `deb-url` + `deb-sha256`) for an independent pin. Published at
> <https://github.com/marketplace/actions/swarmfile-agent-workspace>; use the
> GitHub tag cut from the **same release** that contains this source
> (`v0.3.17` once `release-oss.sh` step 3b cuts it; `v0.3.16` predates the
> resolver), or the vendored copy in this directory. `release-oss.sh` step 3b/6 publishes the
> GitHub source/tag from the same release when the host has a GitHub credential
> (otherwise the owner cuts it by hand). Prerequisites: `curl`, `jq`, `git`, and `gh` (the publish
> PR/provenance path).

## Security model

- **The agent job has no repository write token.** With the local copy it
  checks out only `.github/actions/swarmfile-agent` with
  `persist-credentials: false` so the composite action exists; the agent
  container sees only the mounted workspace, never that checkout. Once the
  action is published, use the public action ref and remove the checkout
  (`permissions: {}`). The Swarmfile repository key is held by the host engine;
  the engine's files and `/proc` are not in the container's namespace, so the
  container cannot read the key. The agent can still exfiltrate the workspace
  and the harness key; review the PR.
- **The publish job is the only job with the repository token.** It does not run
  the agent. It reads the repository policy from **`origin/<base>`**, and it
  fetches the promoted branch, verifies its head against the agent job's
  `head` whenever the branch has commits, and refuses changes to
  `.github/workflows`/`.github/actions` unless `allow-workflow-changes: true`.
  It always refuses a change to `.swarmfile/agents.yml`: an agent must not
  rewrite the policy that governs its next run. The gate reads raw NUL paths
  (`-z`, `core.quotePath=false`, `--no-renames`) so quoted/non-ASCII names and
  rename-out-of-`.github` cannot evade it. It pushes from a clean checkout with
  `GIT_ASKPASS`, an empty `core.hooksPath`, and `--no-verify` (the token is
  never in `git` argv), and ignores ambient `GH_REPO`/`GH_HOST`/`GH_TOKEN`.
  **Use `${{ github.token }}`:** a PAT makes GitHub run workflows from the
  agent's branch with that PAT's secrets. The publish job requires an
  installation token (`ghs_…`) and re-checks its `/user` 403 shape. Grant the
  publish job `contents: write` for the push plus `checks: write`,
  `statuses: write` and `pull-requests: write` for provenance. Even with the built-in token, your
  repository's CI runs the agent's code from the PR; do not expose secrets to
  untrusted PR code.
  **A push made with the built-in token does not trigger GitHub workflows.**
  Use `upstream_ci: pr_only` (CI on the PR) or a GitHub App token; the
  `on_push` mode is a signal to the caller's own workflow, not a trigger.
- **Provenance has two layers.** When the hub has its signing key, the
  publish job fetches the hub-signed agent-session manifest, verifies its
  SHA-256 and Ed25519 signature locally, and posts a `swarmfile/agent`
  **check run** whose text carries the digest, public key, signature,
  canonical manifest (base64), GitHub/Swarmfile commits and truncation flags.
  The PR comment carries the checkpoint timeline. The manifest is identity
  only (harness, label, run id, branch, base/head, checkpoint hashes, entry
  names); prompts and model output stay on the hub. A `swarmfile/agent`
  commit status is posted **only after the same validation**, so an unsigned
  run can never satisfy a required check/status. Requiring the check on
  `main` requires `checks: write`; a missing signing key, an invalid manifest
  or a missing token leaves it unsatisfied.
- **The `.deb` is verified** against the release asset's digest, the release's
  `SHA256SUMS`, or `deb-sha256`. Without a pin, a **preinstalled**
  `swarmfile-engine`/`swarmfile`/`git-remote-swarmfile` on `PATH` is used
  before the download (remove an old copy or pin; otherwise the agent feature
  floor fails). With no preinstalled toolchain, the installer resolves the
  newest Linux `.deb` attached to the `swarmfile-agent-action` public release
  through the hub's anonymous asset API on its `workers.dev` origin (the
  `install-asset-hub` input); the custom domains answer GitHub-hosted runners
  with a bot-challenge 403. If that asset is absent, it falls back to the
  `update-manifest` channel. Setting `deb-url`/`deb-sha256` always wins and
  ignores a preinstalled toolchain. On a host that cannot reach either channel
  (an air-gapped mirror), install `swarmfile-engine`, `swarmfile` and
  `git-remote-swarmfile` on `PATH` in an earlier workflow step; the installer
  uses that toolchain instead of fetching the `.deb`. The rest of the install
  still needs `curl`, Node 18+ and `jq` (and a FUSE-capable runner for agent
  mode); `dpkg-deb` is only required for the `.deb` path, so set
  `install-deps: false` only when those are already present.
- **Pin everything you can:** the container image, the harness version, and
  third-party actions. Do not put secrets other than the harness key in the
  agent job. `agent-env` refuses `SWARMFILE_*`, `GITHUB_*`, `ACTIONS_*` and
  `GH_TOKEN`, so a typo cannot hand the agent the repository or repository key.

## What it does

### Agent mode

1. Extracts and verifies the Swarmfile engine/CLI/helper from the Linux `.deb`.
2. Starts a headless engine for one repository and waits for the boot mount.
3. Opens a fresh `agent/<label>-<6 hex>` workspace with `--conflict-mode hard`
   (the repository policy may choose `soft`).
4. Runs your command in a container with only that workspace mounted. Local
   checks (`local_checks: true`) run in that same container after the harness,
   never on the runner. The container gets the prompt and the harness
   environment, not the Swarmfile key or a GitHub token.
5. Drains and confirms the `Agent: <label>` commit. A failure leaves the
   ephemeral `agent/...` workspace and its TTL untouched; only a confirmed
   change is promoted to the deterministic
   `agents/<label>-<run>-<attempt>` branch. Outputs are written only when the
   agent (and local checks) succeed; a confirmed no-change run keeps the
   `agent/...` workspace, emits the base head and the publish job pushes
   nothing.

### Publish mode

1. Installs only the git helper.
2. Verifies the clean checkout, origin, and `origin/<base>`, then reads
   `.swarmfile/agents.yml` from `origin/<base>` (never the working tree).
3. Fetches the promoted branch, verifies the head's `Swarmfile-Commit` trailer
   equals the agent job's canonical `head` when there are commits, refuses
   changes to `.github/workflows`/`.github/actions` (and always to
   `.swarmfile/agents.yml`), pushes it to GitHub, and optionally opens a PR and
   closes the issue.
4. With `provenance: true` (the default), fetches and verifies the hub-signed
   manifest, posts a `swarmfile/agent` check run and a signed-only commit
   status naming the agent, branch and both commit ids, and comments the
   provenance plus checkpoint timeline on the PR. The token needs
   `checks: write`, `statuses: write` and `pull-requests: write`; a caller
   without them gets a warning, not a failed publish. A repository can require
   the `swarmfile/agent` check on `main`. The signed manifest/check is
   **hosted-hub only**; a community server without the route leaves the check
   unsatisfied rather than passing unsigned.

## Requirements

- An Ubuntu x86_64 runner with Docker in the agent job and `/dev/fuse` on the
  agent host. The publish job needs git, the helper, Node 18+, jq and curl.
- A Swarmfile repository that mirrors the GitHub repository and has git access
  enabled. See [Keeping GitHub and Swarmfile together](https://swarmfile.com/docs/guides/git-and-swarmfile)
  and [Coding agents](https://swarmfile.com/docs/guides/coding-agents).
- A repository-scoped Swarmfile API key (`sf_key_…`) stored as a GitHub secret.
- A harness image/command that can run non-interactively.

## Quick start

Use the published action (the Marketplace listing tracks the current release):

```yaml
- uses: mirrexa/swarmfile-agent-action@v0.3.16
```

> `v0.3.16` predates the asset resolver. Cut `v0.3.17` from this source with
> `release-oss.sh` step 3b (or by hand) to get the workers.dev `.deb` path; on
> `v0.3.16`, pin `deb-url`/`deb-sha256` or use a runner with a preinstalled
> toolchain.

To vendor a copy instead, use this directory's `action.yml` and `scripts/`:

```sh
mkdir -p .github/actions/swarmfile-agent
cp -R action.yml scripts .github/actions/swarmfile-agent/
```

**Mirror the repository first when the publish job should open a PR.** The
publish job pushes a branch onto GitHub, so the Swarmfile repository must share
the GitHub history; a scratch project with unrelated commits cannot produce a
PR. Import once (the source's default branch and commit ids are preserved):

```sh
swarmfile git import https://github.com/<owner>/<repo>.git \
  --threshold-bytes <largest historical blob + 1>
```

Then mint a repository-scoped API key (**Settings → API keys**) and store it as
the `SWARMFILE_API_KEY` secret. The workflow's `org` is the **org id** and
`repository` the **repository id**, both printed by `swarmfile repository list`
or the dashboard URL. The mirror's default branch must match `base-branch`.

Add `examples/issue-agent.yml` as `.github/workflows/issue-agent.yml`, set the
secrets, replace the `org`/`repository` values, and label an issue
`swarmfile-agent`. The workflow is the coordinator MVP: a per-issue concurrency
group queues duplicate labels, the agent job runs without a repository write
token, the publish job holds the token, opens a PR, posts the signed check and
removes the label so the issue is not re-queued. It comments the PR/run URL on
the issue.

## Inputs

| Input | Mode | Required | Default | Meaning |
|---|---|---|---|---|
| `mode` | both | no | `agent` | `agent` or `publish` |
| `org` | both | yes | — | Swarmfile organization id |
| `repository` | both | yes (or `project`) | — | Swarmfile repository id |
| `project` | both | deprecated | — | alias for `repository`, kept for pre-rename workflows |
| `api-key` | both | yes | — | repository-scoped key; use a secret |
| `hub-url` | both | no | `https://hub.swarmfile.com` | hub or community-server URL; the signed manifest fetch requires HTTPS/loopback and is hosted-hub only |
| `git-insecure-hosts` | both | no | empty | plain-HTTP hosts accepted by the git helper (never the manifest/API key fetch) |
| `label` | both | no | `agent` | workspace/session label and published branch |
| `ttl-days` | agent | no | policy, then 1 | workspace lifetime before the archive sweep |
| `base-branch` | both | no | `main` | branch the workspace forks from and the PR targets |
| `command` | agent | yes in practice | empty | command run in the workspace |
| `prompt` | agent | no | empty | `SWARMFILE_PROMPT` for the command |
| `container-image` | agent | no | policy, then `node:24-bookworm` | image with bash and your harness |
| `setup-command` | agent | no | empty | command run in the container before `command` |
| `agent-env` | agent | no | `ANTHROPIC_API_KEY,OPENAI_API_KEY` | host env names passed into the container |
| `run-on-host` | agent | no | `false` | run the command on the runner instead of a container; **bypasses isolation** (see security notes) |
| `local-check-command` | agent | no | empty | run inside the agent container after the harness when `local_checks` is true |
| `post-command` | agent | no | empty | run inside the agent container after the harness and local checks (a final trusted scan/step) |
| `manual-push` | publish | no | `false` | allow a push when `upstream_push` is `manual` |
| `branch` | publish | no | empty | the agent job's `branch` output (preferred over re-deriving it) |
| `open-pr` | publish | no | `false` | open a PR for the pushed branch |
| `pr-base` | publish | no | `base-branch` | PR base |
| `pr-title` | publish | no | `Agent changes` | PR title |
| `pr-body` | publish | no | empty | PR body; `Closes #<issue-number>` is appended |
| `issue-number` | both | no | empty | numeric issue number |
| `github-token` | publish | yes | empty | the built-in `${{ github.token }}`; a PAT is refused |
| `expected-head` | publish | required when the branch has commits | empty | agent job `head`; the fetched head's `Swarmfile-Commit` trailer must match |
| `allow-workflow-changes` | publish | no | `false` | allow `.github/workflows`/`.github/actions` changes (never `.swarmfile/agents.yml`) |
| `provenance` | publish | no | `true` | fetch the signed manifest, post the `swarmfile/agent` check run + commit status and PR provenance/checkpoint comment (`checks: write`, `statuses: write`, `pull-requests: write`) |
| `update-manifest` | both | no | stable manifest | update-channel manifest |
| `install-asset-hub` | both | no | the hub's production `workers.dev` origin | public origin that serves the anonymous release assets (the unchallenged `.deb` channel); empty forces `update-manifest` |
| `deb-url` | both | no | empty | explicit `.deb` URL |
| `deb-sha256` | both | no | empty | `.deb` checksum; a pin always wins over preinstalled tools |
| `install-deps` | agent | no | `true` | apt-install FUSE/runtime packages |

Outputs: `branch`, `head`, `changed`, `pr-url`.

## Repository policy: `.swarmfile/agents.yml`

Commit one policy file to the repository; the action and the MCP server read it,
and the engine hook surface will consume the remaining fields.

```yaml
# .swarmfile/agents.yml
max_concurrent: 20
branch_prefix: agents
ttl_days: 2
checkpoint_idle_secs: 30
conflict_mode: hard
image: node:24-bookworm
paths_deny:
  - secrets/**
local_checks: false
upstream_push: session_end
upstream_ci: pr_only
merge_diff3: true
```

| Field | Default | Applied by |
|---|---|---|
| `max_concurrent` | engine cap | engine `mounts new` refuses past it (best effort under concurrency; the hub's workspace cap is the hard ceiling) |
| `branch_prefix` | `agents` | action agent/publish branch names |
| `ttl_days` | 1 | action/MCP workspace TTL |
| `checkpoint_idle_secs` | engine default (30) | engine `mounts new` applies it to `agent/*` workspaces without a restart |
| `conflict_mode` | `hard` | engine `mounts new` (the action/MCP pass it explicitly) |
| `image` | `node:24-bookworm` | action agent container |
| `paths_deny` | none | engine `mounts new` excludes them (a separate deny filter, not `!` folding) |
| `merge_diff3` | false unless set | engine merge when `.swarmfile/merge.yml` is absent |
| `local_checks` | false | action runs `local-check-command` inside the agent container |
| `upstream_push` | — | action: `never` or `manual` (needs `manual-push: true`) |
| `upstream_ci` | — | action: `pr_only` opens a PR; `on_push`/`none` push without one. The caller's workflow sets `on: pull_request` / `on: push` accordingly; the action cannot disable GitHub's triggers, and a built-in-token push does not trigger workflows |

The parser is deliberately flat (scalars plus string arrays); comments and
inline/block arrays are supported. It fails closed: an unknown key, a wrong
type or an out-of-range value fails the job. The action input `ttl-days` and
`container-image` are empty by default so the policy wins; an explicit input
still overrides it. The MCP `create_workspace` takes its TTL/conflict defaults
from `SWARMFILE_MCP_POLICY_ROOT` (when set) or the current mount, and
best-effort refuses past `max_concurrent`.

The reader uses Node 18+. GitHub-hosted runners have it; `install-deps: true`
installs Node 20 when the runner's Node is older, and a runner without Node 18+
fails closed rather than silently using defaults.

## Security notes that still matter

- Treat the issue text as untrusted. Anyone who can label issues can spend your
  harness key and run the agent's image.
- The agent container has network access and the workspace; prompt injection can
  leak the workspace and the harness key. Do not put unrelated secrets in the
  agent job.
- In **container mode** the agent cannot read the Swarmfile key or the GitHub
  token, but it can write arbitrary code into the branch; review the PR. Keep
  `main` protected.
- **`run-on-host` is not a security boundary.** The command runs as the
  runner user with the runner's files, the engine's environment (including the
  API key), the engine control socket/cache, and the GitHub output files
  visible. Use it only with trusted commands on a dedicated runner; the shipped
  default is `false`.
- The publish job checks the checkout for persisted credentials; leave
  `persist-credentials: false` on `actions/checkout`.
- Pin the harness, image (prefer a digest), and actions. The example pins a
  Claude Code version; `node:24-bookworm` is a mutable tag, so pin its digest
  for production.
- Use the built-in `${{ github.token }}`, not a PAT. The publish job refuses
  workflow/action changes by default; a PAT would still let GitHub execute the
  agent's own code in your existing CI with that PAT's secrets.
- On a shared self-hosted runner, the agent job's `/dev/fuse` access and FUSE
  mount are machine-wide. Prefer an ephemeral runner (GitHub-hosted or a
  disposable VM).

## Limitations

- Linux x86_64 only; the macOS/Windows legs are follow-ups.
- The agent job needs Docker and a FUSE-capable host; the publish job does not.
- The action opens the workspace and commits once at the end. Per-turn
  checkpoints require a harness hook inside the container that calls
  `swarmfile checkpoint --if-changed`; the container does not have the CLI by
  default.
- Large files follow the repository's git-view threshold. A managed community
  repository refuses native LFS ingest; keep the mirror LFS-free or use the hosted
  hub. The action does not push LFS objects to GitHub.
- The branch is authored by the Swarmfile user id
  (`…@users.noreply.swarmfile.com`), not a per-agent git author. The `Agent:`
  session header and branch name carry the agent identity; a per-agent author
  override is a later feature.
- The `.deb` is the release build: the public asset channel is preferred, then
  the update channel. A release that predates agent sessions/checkpoints is
  refused; the stable channel is 0.3.16 at the time of writing, which satisfies
  the 0.3.15 floor. A preinstalled older toolchain is used before the asset —
  remove it or pin a 0.3.15+ `deb-url`.

## Development

```sh
bash -n scripts/install.sh
bash -n scripts/agent.sh
bash -n scripts/publish.sh
SWARMFILE_MODE=agent SWARMFILE_AGENT_PLAN_ONLY=1 \
  SWARMFILE_ORG_ID=org_example SWARMFILE_REPOSITORY_ID=proj_example \
  SWARMFILE_API_KEY=sf_key_example SWARMFILE_COMMAND=true \
  SWARMFILE_CONTAINER_IMAGE=node:24-bookworm \
  bash scripts/run.sh
```

## License

MIT OR Apache-2.0.
