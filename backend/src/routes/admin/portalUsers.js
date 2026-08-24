import { Router } from 'express';
import { query } from '../../db.js';
import { asyncHandler } from '../../asyncHandler.js';
import { requireRoot } from '../../middleware/adminAuth.js';

export const portalUsersRouter = Router();

// Promoting/demoting root access for the developer portal goes through the root operator key
// rather than raw SQL: it needs no database access, and (unlike a manual `update users ...`) it
// automatically lands in admin_actions since it's just another /admin/* request.
portalUsersRouter.post('/portal-users/:email/promote', requireRoot, asyncHandler(async (req, res) => {
  const result = await query(
    `update users set is_root = true where email = $1 returning id, email, is_root`,
    [req.params.email.toLowerCase()],
  );
  if (result.rowCount === 0) {
    return res.status(404).json({ error: `No portal user with email: ${req.params.email}` });
  }
  res.json(result.rows[0]);
}));

portalUsersRouter.delete('/portal-users/:email/promote', requireRoot, asyncHandler(async (req, res) => {
  const result = await query(
    `update users set is_root = false where email = $1 returning id, email, is_root`,
    [req.params.email.toLowerCase()],
  );
  if (result.rowCount === 0) {
    return res.status(404).json({ error: `No portal user with email: ${req.params.email}` });
  }
  res.json(result.rows[0]);
}));

portalUsersRouter.get('/portal-users', requireRoot, asyncHandler(async (req, res) => {
  const result = await query(
    'select id, email, is_root, created_at from users order by created_at',
  );
  res.json(result.rows);
}));
