import crypto from 'node:crypto';
import { config } from './config.js';
import { canonicalPayload } from './signatureVerify.js';

function encryptionKey() {
  const key = Buffer.from(config.signingMasterKey, 'utf8');
  if (key.length !== 32) throw new Error('SIGNING_MASTER_KEY must be exactly 32 UTF-8 bytes');
  return key;
}

export function encryptPrivateKey(privateKeyPem) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', encryptionKey(), iv);
  const encrypted = Buffer.concat([cipher.update(privateKeyPem, 'utf8'), cipher.final()]);
  return {
    encryptedPrivateKey: encrypted.toString('base64'),
    encryptionIv: iv.toString('base64'),
    encryptionTag: cipher.getAuthTag().toString('base64'),
  };
}

function decryptPrivateKey(signer) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', encryptionKey(), Buffer.from(signer.encryption_iv, 'base64'));
  decipher.setAuthTag(Buffer.from(signer.encryption_tag, 'base64'));
  return Buffer.concat([
    decipher.update(Buffer.from(signer.encrypted_private_key, 'base64')),
    decipher.final(),
  ]).toString('utf8');
}

export function signManifestWithManagedKey(manifest, signer) {
  return crypto.sign(
    'RSA-SHA256',
    Buffer.from(canonicalPayload(manifest), 'utf8'),
    decryptPrivateKey(signer),
  ).toString('base64url');
}
