import express from 'express';
import session from 'express-session';
import connectPgSimple from 'connect-pg-simple';
import { config } from './config.js';
import { pool } from './db.js';
import { adminAuth, requireUnscopedOperator } from './middleware/adminAuth.js';
import { asyncHandler } from './asyncHandler.js';
import { appsRouter } from './routes/admin/apps.js';
import { keysRouter } from './routes/admin/keys.js';
import { patchesRouter } from './routes/admin/patches.js';
import { operatorsRouter } from './routes/admin/operators.js';
import { portalUsersRouter } from './routes/admin/portalUsers.js';
import { patchCheckRouter } from './routes/patchCheck.js';
import { eventsRouter } from './routes/events.js';
import { artifactRouter } from './routes/artifact.js';
import { authRouter } from './routes/auth.js';
import { portalAppsRouter } from './routes/portal/apps.js';
import { query } from './db.js';
import { requireUser, requireRootUser } from './middleware/portalAuth.js';
import { renderPage, escapeHtml } from './views/layout.js';
import { cliRouter } from './routes/cli.js';

const app = express();
if (config.trustProxy) app.set('trust proxy', 1);
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

const PgSession = connectPgSimple(session);
app.use(session({
  store: new PgSession({ pool, tableName: 'session' }),
  secret: config.sessionSecret,
  resave: false,
  saveUninitialized: false,
  cookie: {
    maxAge: 30 * 24 * 60 * 60 * 1000,
    httpOnly: true,
    sameSite: 'lax',
    secure: config.secureCookies,
  },
}));

app.get('/healthz', (req, res) => res.json({ ok: true }));
app.get('/readyz', asyncHandler(async (req, res) => {
  await query('select 1');
  res.json({ ok: true });
}));

app.use('/v1', patchCheckRouter);
app.use('/v1', eventsRouter);
app.use('/v1', artifactRouter);
app.use('/v1/cli', cliRouter);

// patchesRouter checks req.scopedAppId against the :appSlug in its own handlers, so an app-scoped
// publish key (see routes/portal/apps.js) can use it for its one app — it must be mounted before
// the requireUnscopedOperator-guarded routers below, otherwise their guard middleware runs (and
// rejects scoped keys) for every /admin/* request that reaches it, even ones patchesRouter would
// have matched further down the chain.
app.use('/admin', asyncHandler(adminAuth), patchesRouter);
app.use('/admin', asyncHandler(adminAuth), requireUnscopedOperator, appsRouter);
app.use('/admin', asyncHandler(adminAuth), requireUnscopedOperator, keysRouter);
app.use('/admin', asyncHandler(adminAuth), requireUnscopedOperator, operatorsRouter);
app.use('/admin', asyncHandler(adminAuth), requireUnscopedOperator, portalUsersRouter);

// Self-service developer portal: session-authenticated, per-app membership permissions.
// Fully separate from the operator/API-key admin model above.
app.use('/auth', authRouter);
app.use('/apps', portalAppsRouter);
app.get('/', (req, res) => res.redirect(303, req.session?.userId ? '/apps' : '/auth/login'));

// Ops-facing view of the operator/API-key audit trail (admin_actions), gated behind a portal
// user's is_root flag (set directly in the DB — there is no self-service way to become root).
app.get('/admin-log', asyncHandler(requireUser), asyncHandler(requireRootUser), asyncHandler(async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 100, 500);
  const result = await query(
    'select operator_name, method, path, status_code, created_at from admin_actions order by created_at desc limit $1',
    [limit],
  );
  const rows = result.rows.map((row) => `
    <tr>
      <td>${escapeHtml(row.operator_name)}</td>
      <td>${escapeHtml(row.method)}</td>
      <td>${escapeHtml(row.path)}</td>
      <td>${row.status_code ?? ''}</td>
      <td>${escapeHtml(new Date(row.created_at).toISOString())}</td>
    </tr>`).join('');
  res.send(renderPage('Admin log', `
    <p class="muted">Last ${result.rows.length} operator/API-key admin actions (successful, denied, and unrecognized-key attempts alike).</p>
    <table><tr><th>Operator</th><th>Method</th><th>Path</th><th>Status</th><th>When</th></tr>${rows || '<tr><td colspan="5" class="muted">No admin actions recorded yet</td></tr>'}</table>
  `, { user: req.user }));
}));

// eslint-disable-next-line no-unused-vars
app.use((error, req, res, next) => {
  console.error(error);
  res.status(500).json({ error: 'Internal server error' });
});

app.listen(config.port, () => {
  console.log(`app-updater backend listening on :${config.port}`);
});
