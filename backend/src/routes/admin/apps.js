import { Router } from 'express';
import { query } from '../../db.js';
import { asyncHandler } from '../../asyncHandler.js';

export const appsRouter = Router();

appsRouter.post('/apps', asyncHandler(async (req, res) => {
  const { slug, platform, package_name: packageName } = req.body ?? {};
  if (!slug || !platform || !packageName) {
    return res.status(400).json({ error: 'slug, platform, and package_name are required' });
  }
  if (!['android', 'ios'].includes(platform)) {
    return res.status(400).json({ error: 'platform must be android or ios' });
  }
  try {
    const result = await query(
      `insert into apps (slug, platform, package_name) values ($1, $2, $3) returning *`,
      [slug, platform, packageName],
    );
    res.status(201).json(result.rows[0]);
  } catch (error) {
    if (error.code === '23505') {
      return res.status(409).json({ error: `App slug already exists: ${slug}` });
    }
    throw error;
  }
}));

appsRouter.get('/apps', asyncHandler(async (req, res) => {
  const result = await query('select * from apps order by created_at');
  res.json(result.rows);
}));
