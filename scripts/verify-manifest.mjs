#!/usr/bin/env node
/**
 * R223 B3 — verify the hub's signed agent-session manifest before the publish
 * job posts a success check. The shell owns HTTP; this owns the cryptographic
 * and identity checks (Node is already a publish-mode requirement).
 *
 *   node verify-manifest.mjs <manifest.json> <branch> <hub-head> <repository> \
 *     <github-head> [signing-key.json]
 *
 * The optional `signing-key.json` is the hub's `/history/signing-key` body
 * (`{keys:[{keyId,publicKey}]}`). When present the manifest's key must be one
 * of the published keys; the publish path always fetches it. The canonical
 * JSON is parsed and used for the identity checks (the outer `manifest` is only
 * a convenience copy and must match it).
 */
import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";

const [file, expectedBranch, expectedHead, expectedRepository, expectedGithub, signingKeyFile] =
  process.argv.slice(2);
const fail = (message) => {
  console.error(`manifest rejected: ${message}`);
  process.exit(1);
};
if (!file || !expectedBranch || !expectedHead || !expectedRepository) {
  fail(
    "usage: verify-manifest.mjs <manifest.json> <branch> <head> <repository> <github-head> [signing-key.json]",
  );
}

let body;
try {
  body = JSON.parse(readFileSync(file, "utf8"));
} catch (error) {
  fail(`unreadable JSON (${String(error)})`);
}

const hash = /^[0-9a-f]{64}$/;
const pub = /^[0-9a-f]{64}$/;
const sig = /^[0-9a-f]{128}$/;
if (!hash.test(body.sha256 ?? "")) fail("sha256 is not 64 lowercase hex");
if (!body.canonical || typeof body.canonical !== "string") fail("canonical is missing");
if (!body.signature || typeof body.signature !== "object") fail("signature is missing");
if (!pub.test(body.signature.publicKey ?? "")) fail("public key is not 64 lowercase hex");
if (!sig.test(body.signature.signature ?? "")) fail("signature is not 128 lowercase hex");
if (typeof body.signature.keyId !== "string" || !body.signature.keyId) fail("keyId is missing");

const canonical = Buffer.from(body.canonical, "base64");
const digest = createHash("sha256").update(canonical).digest("hex");
if (digest !== body.sha256) fail("canonical does not hash to sha256");

const domain = "swarmfile-agent-manifest-v1\n";
const payload = Buffer.from(`${domain}${body.sha256}\n${body.signature.keyId}\n`);
// Ed25519 SPKI DER prefix + the raw 32-byte public key.
const der = Buffer.concat([
  Buffer.from("302a300506032b6570032100", "hex"),
  Buffer.from(body.signature.publicKey, "hex"),
]);
const publicKey = createPublicKey({ key: der, format: "der", type: "spki" });
if (!verify(null, payload, publicKey, Buffer.from(body.signature.signature, "hex"))) {
  fail("Ed25519 signature does not verify");
}

// The signature covers the canonical JSON. Parse it and use it for identity:
// the outer `manifest` copy is unsigned and must not be trusted on its own.
let signed;
try {
  signed = JSON.parse(canonical.toString("utf8"));
} catch {
  fail("canonical is not JSON");
}
if (!signed || typeof signed !== "object") fail("canonical is not a JSON object");
const signedRepository = signed.repository ?? signed.project;
if (signed.kind !== "swarmfile-agent-session") fail("unexpected signed manifest kind");
if (signed.branch !== expectedBranch) fail("signed branch does not match the request");
if (signed.headCommit !== expectedHead) fail("signed headCommit does not match the request");
if (signedRepository !== expectedRepository) fail("signed repository does not match the request");
if (signed.githubCommit && expectedGithub && signed.githubCommit !== expectedGithub) {
  fail("signed githubCommit does not match the GitHub commit");
}

const manifest = body.manifest;
if (!manifest || typeof manifest !== "object") fail("manifest is missing");
const outerRepository = manifest.repository ?? manifest.project;
if (manifest.kind !== signed.kind) fail("outer manifest kind does not match the signed canonical");
if (manifest.branch !== signed.branch) fail("outer manifest branch does not match the signed canonical");
if (manifest.headCommit !== signed.headCommit) fail("outer manifest headCommit does not match the signed canonical");
if (outerRepository !== signedRepository) fail("outer manifest repository does not match the signed canonical");
if ((manifest.githubCommit ?? null) !== (signed.githubCommit ?? null)) {
  fail("outer manifest githubCommit does not match the signed canonical");
}

if (process.env.SWARMFILE_REQUIRE_PUBLISHED_KEY === "1" && !signingKeyFile) {
  fail("the published signing key is required (SWARMFILE_REQUIRE_PUBLISHED_KEY=1)");
}
if (signingKeyFile) {
  let published;
  try {
    published = JSON.parse(readFileSync(signingKeyFile, "utf8"));
  } catch (error) {
    fail(`published signing key is unreadable (${String(error)})`);
  }
  const keys = Array.isArray(published?.keys) ? published.keys : [];
  const entry = keys.find((key) => key?.keyId === body.signature.keyId);
  if (!entry) fail("published signing key does not contain this keyId");
  if (String(entry.publicKey ?? "").toLowerCase() !== body.signature.publicKey) {
    fail("published signing key does not match the manifest's key");
  }
}
console.log("manifest verified");
