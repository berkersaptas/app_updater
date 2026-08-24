import crypto from 'node:crypto';
import { pool } from './db.js';
import { encryptPrivateKey } from './managedSigner.js';

export async function provisionManagedApp({ userId, slug, packageName }) {
  if (!slug || !/^[a-z0-9-]+$/.test(slug) || !packageName) {
    const error = new Error('A lowercase/hyphen slug and package_name are required');
    error.status = 400;
    throw error;
  }
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 3072,
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  const keyId = `managed-rsa-${new Date().toISOString().slice(0, 10).replaceAll('-', '')}`;
  const encrypted = encryptPrivateKey(privateKey);
  const client = await pool.connect();
  try {
    await client.query('begin');
    const appResult = await client.query(
      `insert into apps (slug, platform, package_name) values ($1, 'android', $2) returning *`,
      [slug, packageName],
    );
    const app = appResult.rows[0];
    await client.query(`insert into app_members (app_id, user_id, role) values ($1, $2, 'owner')`, [app.id, userId]);
    const publicKeyBase64Url = publicKey.toString('base64url');
    await client.query(
      `insert into app_keys (app_id, key_id, public_key_der_base64url, algorithm)
       values ($1, $2, $3, 'rsa_pkcs1_sha256')`,
      [app.id, keyId, publicKeyBase64Url],
    );
    await client.query(
      `insert into app_managed_signers
       (app_id, key_id, algorithm, encrypted_private_key, encryption_iv, encryption_tag)
       values ($1, $2, 'rsa_pkcs1_sha256', $3, $4, $5)`,
      [app.id, keyId, encrypted.encryptedPrivateKey, encrypted.encryptionIv, encrypted.encryptionTag],
    );
    await client.query('commit');
    return { ...app, key_id: keyId, public_key: publicKeyBase64Url };
  } catch (error) {
    await client.query('rollback');
    if (error.code === '23505') error.status = 409;
    throw error;
  } finally {
    client.release();
  }
}

export function appYaml(app, backendUrl) {
  return `app_slug: ${app.slug}\nbackend_url: ${backendUrl}\ntrusted_keys:\n  - key_id: ${app.key_id}\n    algorithm: rsa_pkcs1_sha256\n    public_key: ${app.public_key}\nrevoked_key_ids: []\n`;
}
