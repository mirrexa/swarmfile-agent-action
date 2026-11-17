#!/usr/bin/env node
// Resolve the newest anonymous public `.deb` asset for this action.
//
// The release channel (`updates.swarmfile.com`) is reachable from ordinary
// machines, but GitHub-hosted runners are answered by the zone's bot challenge
// (a 403 "Just a moment…" page) before the request reaches the bucket. The
// hub's public release assets are served from its `workers.dev` origin, which
// carries no such challenge, and the release pipeline attaches the Linux `.deb`
// there. This resolver is the installer's first choice; the update channel stays
// the fallback (and a caller's `deb-url`/`deb-sha256` pin always wins).
//
// Anonymous. One JSON line on stdout:
//   {"tag":"agent-v0.3.17","name":"swarmfile_0.3.17_amd64.deb","url":"…","sha256":"…","size":123}
//
// Usage:
//   node resolve-install-deb.mjs [--hub URL] [--org swarmfile]
//                                [--repository swarmfile-agent-action]
//                                [--timeout-ms 20000]
//
// Exit 0 = resolved; 1 = no usable asset / network failure (the caller falls
// back); 2 = usage error.

import { pathToFileURL } from "node:url";

export const DEFAULT_HUB = "https://swarmfile-dispatch-production.mdodd.workers.dev";
const DEFAULT_ORG = "swarmfile";
const DEFAULT_REPOSITORY = "swarmfile-agent-action";
const DEFAULT_TIMEOUT_MS = 20_000;
/** A release with no post-attach asset is a normal short window; try the next
 *  few releases rather than failing outright. The public metadata is edge
 *  cached for 60 s, so a just-attached `.deb` can miss the first listing: the
 *  whole scan retries with a cache-busting query before giving up. */
const MAX_RELEASES = 5;
const LISTING_ATTEMPTS = 3;
const LISTING_RETRY_DELAY_MS = 1000;
const DEB_NAME_RE = /^swarmfile_[0-9][A-Za-z0-9._+-]*_amd64\.deb$/;
const SHA256_RE = /^[0-9a-f]{64}$/;

export class ResolveError extends Error {
  constructor(message, status = null) {
    super(message);
    this.name = "ResolveError";
    /** The HTTP status, when the error came from a response (429 is retried
     *  and, if it persists, stops the release scan instead of hammering the
     *  metadata bucket five more times). */
    this.status = status;
  }
}

export function parseArgs(argv) {
  const opts = {
    hub: DEFAULT_HUB,
    org: DEFAULT_ORG,
    repository: DEFAULT_REPOSITORY,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v === undefined) throw new ResolveError(`${arg} needs a value`);
      return v;
    };
    if (arg === "--hub") opts.hub = value();
    else if (arg === "--org") opts.org = value();
    else if (arg === "--repository") opts.repository = value();
    else if (arg === "--timeout-ms") {
      const n = Number(value());
      if (!Number.isInteger(n) || n < 1000 || n > 120_000) {
        throw new ResolveError("--timeout-ms must be an integer between 1000 and 120000");
      }
      opts.timeoutMs = n;
    } else if (arg === "--help" || arg === "-h") opts.help = true;
    else throw new ResolveError(`unknown argument: ${arg}`);
  }
  opts.hub = normalizeHub(opts.hub);
  if (!/^[a-z0-9][a-z0-9-]*$/i.test(opts.org)) throw new ResolveError("--org is not a valid slug");
  if (!/^[a-z0-9][a-z0-9-]*$/i.test(opts.repository)) {
    throw new ResolveError("--repository is not a valid slug");
  }
  return opts;
}

/** The workers.dev origin is HTTPS; a loopback HTTP origin is accepted so the
 *  resolver's own test can point at a local server. */
export function normalizeHub(hub) {
  const raw = String(hub ?? "").trim().replace(/\/+$/, "");
  if (!raw) throw new ResolveError("--hub is empty");
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new ResolveError(`--hub is not a URL: ${raw}`);
  }
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new ResolveError("--hub must be https (plain HTTP is allowed only on loopback)");
  }
  return raw;
}

export function assetUrl(hub, org, repository, name, tag) {
  return (
    `${hub}/public/${encodeURIComponent(org)}/${encodeURIComponent(repository)}` +
    `/assets/${encodeURIComponent(name)}?tag=${encodeURIComponent(tag)}`
  );
}

/** One release's asset list -> the Linux `.deb` to install, or null. The hub
 *  returns every attached asset; a release's `.deb` is unique in practice, and
 *  a row without a valid digest is skipped rather than trusted. */
export function pickDebAsset(assets) {
  for (const asset of Array.isArray(assets) ? assets : []) {
    const name = String(asset?.name ?? "");
    const sha256 = String(asset?.sha256 ?? "").toLowerCase();
    if (DEB_NAME_RE.test(name) && SHA256_RE.test(sha256)) {
      return {
        name,
        sha256,
        size: Number(asset.size) || 0,
      };
    }
  }
  return null;
}

/** Retry a 429/5xx a bounded number of times. The public metadata endpoints
 *  carry the page-read budget (60/IP/min), and a CI fleet behind one NAT can
 *  trip it; without this the installer falls back to the challenged update
 *  channel exactly under the burst it was built for. A `Retry-After` in
 *  seconds is honoured up to 2 s (a larger window is not a useful CI wait; the
 *  next attempt runs after the delay or the caller falls back). */
const GET_ATTEMPTS = 3;
const GET_MAX_RETRY_WAIT_MS = 2000;

function retryWaitMs(res, attempt) {
  const raw = res.headers.get("retry-after");
  const seconds = raw == null ? NaN : Number(raw);
  if (Number.isFinite(seconds) && seconds >= 0) {
    return Math.min(GET_MAX_RETRY_WAIT_MS, Math.max(250, Math.round(seconds * 1000)));
  }
  return Math.min(GET_MAX_RETRY_WAIT_MS, 250 * 2 ** attempt);
}

async function getJson(url, timeoutMs, fetchImpl) {
  let lastError = null;
  for (let attempt = 0; attempt < GET_ATTEMPTS; attempt++) {
    let res;
    try {
      res = await fetchImpl(url, {
        headers: { accept: "application/json", "user-agent": "swarmfile-agent-action-installer" },
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (e) {
      lastError = new ResolveError(`GET ${url} failed: ${e?.message ?? e}`);
      if (attempt + 1 < GET_ATTEMPTS) {
        await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** attempt));
        continue;
      }
      throw lastError;
    }
    if (res.ok) {
      try {
        return await res.json();
      } catch (e) {
        throw new ResolveError(`GET ${url} did not return JSON: ${e?.message ?? e}`, res.status);
      }
    }
    const body = await res.text().catch(() => "");
    const detail = body.replace(/\s+/g, " ").slice(0, 160);
    lastError = new ResolveError(
      `GET ${url} answered ${res.status}${detail ? `: ${detail}` : ""}`,
      res.status,
    );
    const retryable = res.status === 429 || res.status >= 500;
    if (!retryable || attempt + 1 >= GET_ATTEMPTS) throw lastError;
    await new Promise((resolve) => setTimeout(resolve, retryWaitMs(res, attempt)));
  }
  throw lastError ?? new ResolveError(`GET ${url} failed`);
}

/**
 * Resolve `{tag, name, url, sha256, size}` for the newest release that carries
 * a verified Linux `.deb`. Throws `ResolveError` when none is available.
 */
export async function resolveInstallDeb(options = {}) {
  const hub = normalizeHub(options.hub ?? DEFAULT_HUB);
  const org = options.org ?? DEFAULT_ORG;
  const repository = options.repository ?? DEFAULT_REPOSITORY;
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const fetchImpl = options.fetchImpl ?? fetch;

  const attempts = options.listingAttempts ?? LISTING_ATTEMPTS;
  const retryDelayMs = options.listingRetryDelayMs ?? LISTING_RETRY_DELAY_MS;
  const tried = new Set();
  let sawListing = false;
  for (let attempt = 0; attempt < attempts; attempt++) {
    // A cache-buster key makes the retry miss the edge-cached empty listing;
    // an unknown query parameter is ignored by the public route.
    const cacheBust = attempt === 0 ? "" : `cacheBust=${Date.now()}-${attempt}`;
    const listUrl =
      `${hub}/public/${encodeURIComponent(org)}/${encodeURIComponent(repository)}/releases` +
      (cacheBust ? `?${cacheBust}` : "");
    const listing = await getJson(listUrl, timeoutMs, fetchImpl);
    const releases = (Array.isArray(listing?.releases) ? [...listing.releases] : []).sort(
      (a, b) => Number(b?.publishedAt ?? 0) - Number(a?.publishedAt ?? 0),
    );
    if (releases.length > 0) sawListing = true;
    for (const release of releases.slice(0, MAX_RELEASES)) {
      const tag = String(release?.tagName ?? "").trim();
      if (!tag) continue;
      tried.add(tag);
      const assetsUrl =
        `${hub}/public/${encodeURIComponent(org)}/${encodeURIComponent(repository)}` +
        `/assets?tag=${encodeURIComponent(tag)}` +
        (cacheBust ? `&${cacheBust}` : "");
      let body;
      try {
        body = await getJson(assetsUrl, timeoutMs, fetchImpl);
      } catch (e) {
        // A sustained 429 means the shared metadata budget is exhausted; trying
        // four more releases would only make it worse. Everything else (a
        // release being unpublished, a 404) may be release-specific.
        if (e instanceof ResolveError && e.status === 429) throw e;
        options.log?.(`${tag}: ${e?.message ?? e}`);
        continue;
      }
      const asset = pickDebAsset(body?.assets);
      if (!asset) continue;
      return {
        tag,
        name: asset.name,
        url: assetUrl(hub, org, repository, asset.name, tag),
        sha256: asset.sha256,
        size: asset.size,
      };
    }
    if (attempt + 1 < attempts) {
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
  }
  const detail = tried.size > 0 ? `tried ${[...tried].join(", ")}` : sawListing ? "no releases" : "no published releases";
  throw new ResolveError(`no linux .deb asset on ${org}/${repository} (${detail})`);
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(`resolve-install-deb: ${e.message}`);
    process.exitCode = 2;
    return;
  }
  if (opts.help) {
    console.log(
      "usage: node resolve-install-deb.mjs [--hub URL] [--org SLUG] [--repository SLUG] [--timeout-ms N]",
    );
    return;
  }
  try {
    const result = await resolveInstallDeb({ ...opts, log: (line) => console.error(line) });
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (e) {
    console.error(`resolve-install-deb: ${e?.message ?? e}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
