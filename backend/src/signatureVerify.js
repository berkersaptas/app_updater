import crypto from 'node:crypto';

/**
 * Canonical signing payload, byte-for-byte identical to what
 * scripts/write_manifest_payload.sh produces and PatchSignatureVerifier.kt verifies against.
 * Field order and format must never change independently in the two places.
 */
export function canonicalPayload(manifest) {
  return (
    `schema_version=${manifest.schema_version}\n` +
    `release=${manifest.release}\n` +
    `patch_number=${manifest.patch_number}\n` +
    `artifact_kind=${manifest.artifact_kind}\n` +
    `engine_revision=${manifest.engine_revision}\n` +
    `dart_version=${manifest.dart_version}\n` +
    `abi=${manifest.abi}\n` +
    `build_mode=${manifest.build_mode}\n` +
    `sha256=${manifest.sha256}\n` +
    `signature_key_id=${manifest.signature_key_id}\n` +
    `signature_algorithm=${manifest.signature_algorithm}\n`
  );
}

/**
 * Verifies a manifest's signature against a base64url-encoded DER (SPKI) public key. Mirrors
 * ota_runtime_android's PatchSignatureVerifier.kt exactly: ed25519 verified raw, rsa_pkcs1_sha256
 * verified as SHA256withRSA (PKCS#1 v1.5).
 */
export function verifyManifestSignature(manifest, publicKeyDerBase64url) {
  const publicKeyDer = Buffer.from(publicKeyDerBase64url, 'base64url');
  const signature = Buffer.from(manifest.signature, 'base64url');
  const message = Buffer.from(canonicalPayload(manifest), 'utf8');
  const publicKey = crypto.createPublicKey({
    key: publicKeyDer,
    format: 'der',
    type: 'spki',
  });

  if (manifest.signature_algorithm === 'ed25519') {
    return crypto.verify(null, message, publicKey, signature);
  }
  if (manifest.signature_algorithm === 'rsa_pkcs1_sha256') {
    return crypto.verify('RSA-SHA256', message, publicKey, signature);
  }
  return false;
}
