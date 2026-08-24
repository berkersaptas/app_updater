import { query } from './db.js';

export async function findAppBySlug(slug) {
  const result = await query('select * from apps where slug = $1', [slug]);
  return result.rows[0] ?? null;
}

export async function requireApp(req, res) {
  const app = await findAppBySlug(req.params.appSlug);
  if (!app) {
    res.status(404).json({ error: `Unknown app: ${req.params.appSlug}` });
    return null;
  }
  return app;
}
