import crypto from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { query } from './db.js';
import { validateManifest } from './manifestSchema.js';
import { verifyManifestSignature } from './signatureVerify.js';
import { config } from './config.js';
import { artifactKindAllowed } from './artifactPolicy.js';

export class PatchIngestError extends Error {
  constructor(status, message, details) {
    super(message);
    this.status = status;
    this.details = details;
  }
}

/**
 * Validates and stores a signed patch upload (schema, trusted-key signature, and for
 * full_aot_library the artifact hash), shared between the operator-key admin route
 * (routes/admin/patches.js) and the session-authenticated portal route
 * (routes/portal/patches.js) so both auth models enforce identical rules.
 */
export async function ingestPatch(app, manifestFile, artifactFile) {
  if (!manifestFile || !artifactFile) {
    throw new PatchIngestError(400, 'Both manifest and artifact files are required');
  }

  let manifest;
  try {
    manifest = JSON.parse(manifestFile.buffer.toString('utf8'));
  } catch {
    throw new PatchIngestError(400, 'manifest is not valid JSON');
  }

  const schemaResult = validateManifest(manifest);
  if (!schemaResult.valid) {
    throw new PatchIngestError(400, 'Manifest failed schema validation', schemaResult.errors);
  }

  if (!artifactKindAllowed(manifest.artifact_kind, config.allowFullAotLibrary)) {
    throw new PatchIngestError(
      422,
      'full_aot_library uploads are disabled: Play/production patches must use binary_diff',
    );
  }

  const keyResult = await query(
    `select * from app_keys where app_id = $1 and key_id = $2`,
    [app.id, manifest.signature_key_id],
  );
  const trustedKey = keyResult.rows[0];
  if (!trustedKey) {
    throw new PatchIngestError(400, `Unknown signature_key_id for this app: ${manifest.signature_key_id}`);
  }
  if (trustedKey.revoked) {
    throw new PatchIngestError(400, `signature_key_id is revoked: ${manifest.signature_key_id}`);
  }
  if (trustedKey.algorithm !== manifest.signature_algorithm) {
    throw new PatchIngestError(
      400,
      `signature_algorithm mismatch: key is ${trustedKey.algorithm}, manifest says ${manifest.signature_algorithm}`,
    );
  }

  let signatureValid = false;
  try {
    signatureValid = verifyManifestSignature(manifest, trustedKey.public_key_der_base64url);
  } catch (error) {
    throw new PatchIngestError(400, `Signature verification failed: ${error.message}`);
  }
  if (!signatureValid) {
    throw new PatchIngestError(400, 'Manifest signature does not verify against the registered key');
  }

  // artifact_size is the byte size of the uploaded file itself (unlike sha256, which for
  // binary_diff refers to the reconstructed target, not the diff blob) — cheap to check for
  // both artifact kinds, before the more expensive SHA-256 check below.
  if (artifactFile.buffer.length !== manifest.artifact_size) {
    throw new PatchIngestError(
      400,
      `Artifact size does not match manifest: expected ${manifest.artifact_size}, got ${artifactFile.buffer.length}`,
    );
  }

  // manifest.sha256 is always the hash of the final loadable artifact (see
  // ota_runtime_android's PatchLoader, which checks it post-resolve regardless of artifact
  // kind). For full_aot_library the uploaded file *is* that artifact, so we can check it here.
  // For binary_diff the uploaded file is a diff blob against the base artifact; only the
  // device, after reconstruction, can verify that hash — same reasoning as
  // scripts/install_patch_artifact.sh.
  if (manifest.artifact_kind === 'full_aot_library') {
    const actualSha256 = crypto.createHash('sha256').update(artifactFile.buffer).digest('hex');
    if (actualSha256 !== manifest.sha256.toLowerCase()) {
      throw new PatchIngestError(
        400,
        `Artifact SHA-256 does not match manifest: expected ${manifest.sha256}, got ${actualSha256}`,
      );
    }
  }

  const artifactFileName = manifest.artifact_kind === 'binary_diff' ? 'libapp.so.diff' : 'libapp.so';
  const relativePath = path.join(app.slug, String(manifest.patch_number), artifactFileName);
  const absolutePath = path.join(config.artifactStorageDir, relativePath);
  await mkdir(path.dirname(absolutePath), { recursive: true });
  await writeFile(absolutePath, artifactFile.buffer);

  try {
    const result = await query(
      `insert into patches (app_id, manifest, artifact_relative_path, artifact_size)
       values ($1, $2, $3, $4) returning *`,
      [app.id, manifest, relativePath, artifactFile.buffer.length],
    );
    return result.rows[0];
  } catch (error) {
    if (error.code === '23505') {
      throw new PatchIngestError(409, `Patch number already exists for this app: ${manifest.patch_number}`);
    }
    throw error;
  }
}
