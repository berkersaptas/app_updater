import crypto from 'node:crypto';
import { config } from '../config.js';
import { query } from '../db.js';

export function hashApiKey(key) {
  return crypto.createHash('sha256').update(key).digest('hex');
}

async function recordAdminAction(operatorName, method, path, statusCode) {
  try {
    await query(
      `insert into admin_actions (operator_name, method, path, status_code) values ($1, $2, $3, $4)`,
      [operatorName, method, path, statusCode],
    );
  } catch (error) {
    console.error('Failed to record admin action', error);
  }
}

/**
 * Resolves the caller to an operator (the static ADMIN_API_KEY is the "root" bootstrap operator,
 * needed to create the first real operator; every other admin key is a row in `operators`) or, as
 * a narrower alternative, an app-scoped publish key (a row in `app_publish_keys`, self-issued by
 * an app member from the portal — see routes/portal/apps.js) that only ever proves access to the
 * one app it belongs to. Either way, every admin/ingestion request is recorded in `admin_actions`
 * for audit, regardless of outcome.
 */
export async function adminAuth(req, res, next) {
  const key = req.get('X-Api-Key');
  let operatorName = 'unknown';
  req.scopedAppId = null;

  if (key === config.adminApiKey) {
    operatorName = 'root';
  } else if (key) {
    const operatorResult = await query(
      'select name from operators where api_key_hash = $1 and revoked = false',
      [hashApiKey(key)],
    );
    if (operatorResult.rows[0]) {
      operatorName = operatorResult.rows[0].name;
    } else {
      const publishKeyResult = await query(
        `select pk.app_id, a.slug from app_publish_keys pk join apps a on a.id = pk.app_id
         where pk.api_key_hash = $1 and pk.revoked = false`,
        [hashApiKey(key)],
      );
      const publishKey = publishKeyResult.rows[0];
      if (publishKey) {
        operatorName = `publish-key:${publishKey.slug}`;
        req.scopedAppId = publishKey.app_id;
      }
    }
  }

  req.operatorName = operatorName;
  res.on('finish', () => {
    recordAdminAction(operatorName, req.method, req.originalUrl, res.statusCode);
  });

  if (operatorName === 'unknown') {
    return res.status(401).json({ error: 'Invalid, missing, or revoked X-Api-Key' });
  }
  next();
}

export function requireRoot(req, res, next) {
  if (req.operatorName !== 'root') {
    return res.status(403).json({ error: 'Root API key required' });
  }
  next();
}

/** Blocks app-scoped publish keys from routers that aren't scoped to a single app. */
export function requireUnscopedOperator(req, res, next) {
  if (req.scopedAppId) {
    return res.status(403).json({ error: 'An app-scoped publish key cannot be used here' });
  }
  next();
}
