import { Router } from 'express';
import crypto from 'node:crypto';
import { query } from '../../db.js';
import { asyncHandler } from '../../asyncHandler.js';
import { hashApiKey, requireRoot } from '../../middleware/adminAuth.js';

export const operatorsRouter = Router();

operatorsRouter.post('/operators', requireRoot, asyncHandler(async (req, res) => {
  const { name } = req.body ?? {};
  if (!name) {
    return res.status(400).json({ error: 'name is required' });
  }

  const apiKey = crypto.randomBytes(24).toString('base64url');
  try {
    const result = await query(
      `insert into operators (name, api_key_hash) values ($1, $2) returning id, name, revoked, created_at`,
      [name, hashApiKey(apiKey)],
    );
    // api_key is returned once, here, and never again — only its hash is stored.
    res.status(201).json({ ...result.rows[0], api_key: apiKey });
  } catch (error) {
    if (error.code === '23505') {
      return res.status(409).json({ error: `Operator name already exists: ${name}` });
    }
    throw error;
  }
}));

operatorsRouter.delete('/operators/:id', requireRoot, asyncHandler(async (req, res) => {
  const result = await query(
    `update operators set revoked = true where id = $1 returning id, name, revoked, created_at`,
    [req.params.id],
  );
  if (result.rowCount === 0) {
    return res.status(404).json({ error: `Unknown operator id: ${req.params.id}` });
  }
  res.json(result.rows[0]);
}));

operatorsRouter.get('/operators', asyncHandler(async (req, res) => {
  const result = await query(
    'select id, name, revoked, created_at from operators order by created_at',
  );
  res.json(result.rows);
}));

operatorsRouter.get('/actions', asyncHandler(async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 100, 500);
  const result = await query(
    'select * from admin_actions order by created_at desc limit $1',
    [limit],
  );
  res.json(result.rows);
}));
