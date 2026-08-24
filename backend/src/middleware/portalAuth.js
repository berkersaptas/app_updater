import { query } from '../db.js';

export async function requireUser(req, res, next) {
  const userId = req.session?.userId;
  if (!userId) {
    return res.redirect(303, '/auth/login');
  }
  const result = await query('select id, email, is_root, created_at from users where id = $1', [userId]);
  const user = result.rows[0];
  if (!user) {
    req.session.userId = null;
    return res.redirect(303, '/auth/login');
  }
  req.user = user;
  next();
}

export function requireRootUser(req, res, next) {
  if (!req.user.is_root) {
    return res.status(403).send('Root access required');
  }
  next();
}

/**
 * Loads the app named by req.params.appSlug and checks req.user's membership. Attaches both
 * req.app (the app row) and req.membership ({role}) for handlers to use.
 */
export function requireAppMember(minRole = 'member') {
  return async (req, res, next) => {
    const appResult = await query('select * from apps where slug = $1', [req.params.appSlug]);
    const app = appResult.rows[0];
    if (!app) return res.status(404).send('Unknown app');

    const memberResult = await query(
      'select role from app_members where app_id = $1 and user_id = $2',
      [app.id, req.user.id],
    );
    const membership = memberResult.rows[0];
    if (!membership || (minRole === 'owner' && membership.role !== 'owner')) {
      return res.status(403).send('You do not have access to this app');
    }

    req.appRow = app;
    req.membership = membership;
    next();
  };
}
