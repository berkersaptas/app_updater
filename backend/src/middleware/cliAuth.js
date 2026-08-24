import crypto from 'node:crypto';
import { query } from '../db.js';

export function tokenHash(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

export function newCliToken() {
  return crypto.randomBytes(32).toString('base64url');
}

export async function cliAuth(req, res, next) {
  const authorization = req.get('Authorization') ?? '';
  const token = authorization.startsWith('Bearer ') ? authorization.slice(7) : '';
  if (!token) return res.status(401).json({ error: 'Bearer token required; run app_updater login' });
  const result = await query(
    `select t.id as token_id, u.id, u.email, u.is_root
     from cli_tokens t join users u on u.id = t.user_id
     where t.token_hash = $1 and t.revoked = false and t.expires_at > now()`,
    [tokenHash(token)],
  );
  const user = result.rows[0];
  if (!user) return res.status(401).json({ error: 'CLI token is invalid, expired, or revoked' });
  req.user = user;
  query('update cli_tokens set last_used_at = now() where id = $1', [user.token_id]).catch(() => {});
  next();
}
