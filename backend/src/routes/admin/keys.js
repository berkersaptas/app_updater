import { Router } from 'express';
import { query } from '../../db.js';
import { requireApp } from '../../appLookup.js';
import { asyncHandler } from '../../asyncHandler.js';

export const keysRouter = Router();

keysRouter.post('/apps/:appSlug/keys', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;

  const { key_id: keyId, public_key_der_base64url: publicKey, algorithm } = req.body ?? {};
  if (!keyId || !publicKey || !algorithm) {
    return res
      .status(400)
      .json({ error: 'key_id, public_key_der_base64url, and algorithm are required' });
  }
  if (!['ed25519', 'rsa_pkcs1_sha256'].includes(algorithm)) {
    return res.status(400).json({ error: 'algorithm must be ed25519 or rsa_pkcs1_sha256' });
  }

  try {
    const result = await query(
      `insert into app_keys (app_id, key_id, public_key_der_base64url, algorithm)
       values ($1, $2, $3, $4) returning *`,
      [app.id, keyId, publicKey, algorithm],
    );
    res.status(201).json(result.rows[0]);
  } catch (error) {
    if (error.code === '23505') {
      return res.status(409).json({ error: `Key id already registered for this app: ${keyId}` });
    }
    throw error;
  }
}));

keysRouter.delete('/apps/:appSlug/keys/:keyId', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;

  const result = await query(
    `update app_keys set revoked = true where app_id = $1 and key_id = $2 returning *`,
    [app.id, req.params.keyId],
  );
  if (result.rowCount === 0) {
    return res.status(404).json({ error: `Unknown key id: ${req.params.keyId}` });
  }
  res.json(result.rows[0]);
}));

keysRouter.get('/apps/:appSlug/keys', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;

  const result = await query(
    'select * from app_keys where app_id = $1 order by created_at',
    [app.id],
  );
  res.json(result.rows);
}));
