import { Router } from 'express';
import multer from 'multer';
import crypto from 'node:crypto';
import { query } from '../../db.js';
import { asyncHandler } from '../../asyncHandler.js';
import { requireUser, requireAppMember } from '../../middleware/portalAuth.js';
import { hashApiKey } from '../../middleware/adminAuth.js';
import { ingestPatch, PatchIngestError } from '../../patchIngest.js';
import { renderPage, escapeHtml } from '../../views/layout.js';
import { provisionManagedApp } from '../../appProvisioning.js';
import {
  APP_LOGO_FIELD,
  APP_LOGO_MAX_BYTES,
  AppLogoError,
  appLogoAbsolutePath,
  deleteAppLogo,
  findAppLogo,
  saveAppLogo,
} from '../../appLogo.js';

export const portalAppsRouter = Router();
const upload = multer({ storage: multer.memoryStorage() });
const logoUpload = multer({ storage: multer.memoryStorage(), limits: { fileSize: APP_LOGO_MAX_BYTES } });
const _cliGitUrl = 'https://github.com/berkersaptas/app_updater.git';

function appMark(app, size = 'small') {
  const label = escapeHtml(app.slug.slice(0, 1).toUpperCase());
  const className = size === 'large' ? 'app-logo app-logo-large' : 'app-logo';
  if (app.has_logo) {
    const params = new URLSearchParams();
    if (size === 'small') params.set('size', 'thumbnail');
    if (app.logo_sha256) params.set('v', app.logo_sha256);
    const suffix = params.size ? `?${params}` : '';
    return `<img class="${className}" src="/apps/${escapeHtml(app.slug)}/logo${suffix}" alt="${escapeHtml(app.slug)} logo">`;
  }
  return `<span class="${className} app-logo-fallback" aria-hidden="true">${label}</span>`;
}

function receivePortalLogo(req, res, next) {
  logoUpload.single(APP_LOGO_FIELD)(req, res, (error) => {
    if (!error) return next();
    const tooLarge = error instanceof multer.MulterError && error.code === 'LIMIT_FILE_SIZE';
    return res.status(tooLarge ? 413 : 400).send(renderPage(
      'Logo upload failed',
      `<p class="error">${tooLarge ? 'Logo must be 2 MB or smaller.' : 'Invalid logo upload.'}</p><p><a href="/apps/${escapeHtml(req.params.appSlug)}">Back</a></p>`,
      { user: req.user },
    ));
  });
}

portalAppsRouter.use(asyncHandler(requireUser));

portalAppsRouter.get('/', asyncHandler(async (req, res) => {
  const result = await query(
    `select a.slug, a.package_name, m.role, aa.sha256 as logo_sha256,
            (aa.id is not null) as has_logo
     from apps a join app_members m on m.app_id = a.id
     left join app_assets aa on aa.app_id = a.id and aa.kind = 'logo'
     where m.user_id = $1 order by a.created_at`,
    [req.user.id],
  );
  const rows = result.rows.map((app) => `
    <tr>
      <td><a class="app-link" href="/apps/${escapeHtml(app.slug)}">${appMark(app)}<span>${escapeHtml(app.slug)}</span></a></td>
      <td>${escapeHtml(app.package_name)}</td>
      <td>${escapeHtml(app.role)}</td>
    </tr>`).join('');

  res.send(renderPage('Dashboard', `
    <h2>Your apps</h2>
    <table><tr><th>Slug</th><th>Package</th><th>Your role</th></tr>${rows || '<tr><td colspan="3" class="muted">No apps yet</td></tr>'}</table>

    <h2>Create a new app</h2>
    <form method="post" action="/apps">
      <div><label>App slug <input name="slug" pattern="[a-z0-9-]+" required placeholder="my-app-android"></label></div>
      <div><label>Package name <input name="package_name" required placeholder="com.example.my_app"></label></div>
      <button type="submit">Create</button>
    </form>
  `, { user: req.user }));
}));

portalAppsRouter.post('/', asyncHandler(async (req, res) => {
  const { slug, package_name: packageName } = req.body ?? {};
  if (!slug || !/^[a-z0-9-]+$/.test(slug) || !packageName) {
    return res.status(400).send(renderPage('Create app', `<p class="error">A lowercase/hyphen slug and a package name are required.</p><p><a href="/">Back</a></p>`, { user: req.user }));
  }

  let appRow;
  try {
    appRow = await provisionManagedApp({ userId: req.user.id, slug, packageName });
  } catch (error) {
    if (error.status === 409) {
      return res.status(409).send(renderPage('Create app', `<p class="error">App slug already exists: ${escapeHtml(slug)}</p><p><a href="/">Back</a></p>`, { user: req.user }));
    }
    throw error;
  }

  res.send(renderPage('App created', `
    <div class="notice"><strong>${escapeHtml(slug)} is ready.</strong> Signing is managed by the service; there are no API or private keys to copy.</div>
    <h2>Connect a Flutter project</h2>
    <p class="muted">Once per machine:</p>
    <pre>dart pub global activate --source git ${escapeHtml(_cliGitUrl)} --git-path app_updater_cli</pre>
    <p class="muted">Then run these from the Flutter project:</p>
    <pre>app_updater login --backend-url ${escapeHtml(`${req.protocol}://${req.get('host')}`)}
app_updater init --app-slug ${escapeHtml(slug)}
app_updater release android
app_updater patch android</pre>
    <p class="muted"><code>release android</code> is run for each store version. Later hot updates for that version use <code>patch android</code>.</p>
    <p><a href="/apps/${escapeHtml(slug)}">Go to ${escapeHtml(slug)}</a></p>
  `, { user: req.user }));
}));

portalAppsRouter.get('/:appSlug', asyncHandler(requireAppMember('member')), asyncHandler(async (req, res) => {
  const logo = await findAppLogo(req.appRow.id);
  req.appRow.has_logo = Boolean(logo);
  req.appRow.logo_sha256 = logo?.sha256;
  const membersResult = await query(
    `select u.id, u.email, m.role from app_members m join users u on u.id = m.user_id
     where m.app_id = $1 order by m.created_at`,
    [req.appRow.id],
  );
  const patchesResult = await query(
    'select patch_number, artifact_kind, enabled, created_at from patches where app_id = $1 order by patch_number desc',
    [req.appRow.id],
  );
  const publishKeysResult = await query(
    'select id, label, revoked, created_at from app_publish_keys where app_id = $1 order by created_at desc',
    [req.appRow.id],
  );

  const memberRows = membersResult.rows.map((member) => `
    <tr>
      <td>${escapeHtml(member.email)}</td>
      <td>${escapeHtml(member.role)}</td>
      <td>${req.membership.role === 'owner' ? `
        <form class="inline" method="post" action="/apps/${escapeHtml(req.appRow.slug)}/members/${escapeHtml(member.id)}/delete">
          <button type="submit">Remove</button>
        </form>` : ''}</td>
    </tr>`).join('');

  const patchRows = patchesResult.rows.map((patch) => `
    <tr>
      <td>${patch.patch_number}</td>
      <td>${escapeHtml(patch.artifact_kind)}</td>
      <td>${patch.enabled ? 'enabled' : 'disabled'}</td>
      <td>
        <form class="inline" method="post" action="/apps/${escapeHtml(req.appRow.slug)}/patches/${patch.patch_number}/toggle">
          <input type="hidden" name="enabled" value="${patch.enabled ? 'false' : 'true'}">
          <button type="submit">${patch.enabled ? 'Disable' : 'Enable'}</button>
        </form>
      </td>
    </tr>`).join('');

  const publishKeyRows = publishKeysResult.rows.map((k) => `
    <tr>
      <td>${escapeHtml(k.label)}</td>
      <td>${k.revoked ? 'revoked' : 'active'}</td>
      <td>${!k.revoked ? `
        <form class="inline" method="post" action="/apps/${escapeHtml(req.appRow.slug)}/publish-keys/${escapeHtml(k.id)}/revoke">
          <button type="submit">Revoke</button>
        </form>` : ''}</td>
    </tr>`).join('');

  res.send(renderPage(req.appRow.slug, `
    <section class="app-profile">
      ${appMark(req.appRow, 'large')}
      <div>
        <h2>${escapeHtml(req.appRow.slug)}</h2>
        <p class="muted">${escapeHtml(req.appRow.package_name)}</p>
      </div>
    </section>
    ${req.membership.role === 'owner' ? `
      <form method="post" action="/apps/${escapeHtml(req.appRow.slug)}/logo" enctype="multipart/form-data">
        <label>App logo <input type="file" name="logo" accept="image/png,image/jpeg,image/webp" required></label>
        <button type="submit">${logo ? 'Replace logo' : 'Upload logo'}</button>
      </form>
      <p class="muted">PNG, JPEG or WebP; at least 128×128 pixels; maximum 2 MB.</p>
      ${logo ? `<form class="inline" method="post" action="/apps/${escapeHtml(req.appRow.slug)}/logo/delete"><button type="submit">Remove logo</button></form>` : ''}
    ` : ''}

    <h2>Members</h2>
    <table><tr><th>Email</th><th>Role</th><th></th></tr>${memberRows}</table>
    ${req.membership.role === 'owner' ? `
    <form method="post" action="/apps/${escapeHtml(req.appRow.slug)}/members">
      <label>Invite by email <input type="email" name="email" required></label>
      <select name="role"><option value="member">member</option><option value="owner">owner</option></select>
      <button type="submit">Invite</button>
    </form>` : '<p class="muted">Only owners can invite/remove members.</p>'}

    <h2>Legacy publish keys</h2>
    <p class="muted">Only needed by the old manual <code>app_updater publish</code> command. The recommended
      <code>login / release / patch</code> flow does not use these keys.</p>
    <table><tr><th>Label</th><th>State</th><th></th></tr>${publishKeyRows || '<tr><td colspan="3" class="muted">No publish keys yet</td></tr>'}</table>
    <form method="post" action="/apps/${escapeHtml(req.appRow.slug)}/publish-keys">
      <label>Label <input name="label" placeholder="my-laptop" required></label>
      <button type="submit">Generate publish key</button>
    </form>

    <h2>Patches</h2>
    <table><tr><th>#</th><th>Kind</th><th>State</th><th></th></tr>${patchRows || '<tr><td colspan="4" class="muted">No patches yet</td></tr>'}</table>
    <form method="post" action="/apps/${escapeHtml(req.appRow.slug)}/patches" enctype="multipart/form-data">
      <div>Manifest <input type="file" name="manifest" required></div>
      <div>Artifact <input type="file" name="artifact" required></div>
      <button type="submit">Upload patch</button>
    </form>
  `, { user: req.user }));
}));

portalAppsRouter.get('/:appSlug/logo', asyncHandler(requireAppMember('member')), asyncHandler(async (req, res) => {
  const asset = await findAppLogo(req.appRow.id);
  if (!asset) return res.status(404).send('Logo not found');
  const etag = `"${asset.sha256}-${req.query.size === 'thumbnail' ? '64' : '256'}"`;
  if (req.get('if-none-match') === etag) return res.status(304).end();
  res.set({
    'Cache-Control': 'private, max-age=86400',
    'Content-Type': asset.mime_type,
    ETag: etag,
  });
  res.sendFile(appLogoAbsolutePath(asset, req.query.size === 'thumbnail'));
}));

portalAppsRouter.post(
  '/:appSlug/logo',
  asyncHandler(requireAppMember('owner')),
  receivePortalLogo,
  asyncHandler(async (req, res) => {
    try {
      await saveAppLogo(req.appRow, req.file?.buffer);
      res.redirect(303, `/apps/${req.appRow.slug}`);
    } catch (error) {
      if (error instanceof AppLogoError) {
        return res.status(error.status).send(renderPage(
          'Logo upload failed',
          `<p class="error">${escapeHtml(error.message)}</p><p><a href="/apps/${escapeHtml(req.appRow.slug)}">Back</a></p>`,
          { user: req.user },
        ));
      }
      throw error;
    }
  }),
);

portalAppsRouter.post('/:appSlug/logo/delete', asyncHandler(requireAppMember('owner')), asyncHandler(async (req, res) => {
  await deleteAppLogo(req.appRow.id);
  res.redirect(303, `/apps/${req.appRow.slug}`);
}));

portalAppsRouter.post('/:appSlug/members', asyncHandler(requireAppMember('owner')), asyncHandler(async (req, res) => {
  const { email, role } = req.body ?? {};
  if (!email || !['owner', 'member'].includes(role)) {
    return res.status(400).send('email and a valid role are required');
  }
  const userResult = await query('select id from users where email = $1', [email.toLowerCase()]);
  const invitee = userResult.rows[0];
  if (!invitee) {
    return res.status(404).send(renderPage('Invite failed', `<p class="error">No account found for ${escapeHtml(email)} — they need to register first.</p><p><a href="/apps/${escapeHtml(req.appRow.slug)}">Back</a></p>`, { user: req.user }));
  }
  await query(
    `insert into app_members (app_id, user_id, role) values ($1, $2, $3)
     on conflict (app_id, user_id) do update set role = excluded.role`,
    [req.appRow.id, invitee.id, role],
  );
  res.redirect(303, `/apps/${req.appRow.slug}`);
}));

portalAppsRouter.post('/:appSlug/members/:userId/delete', asyncHandler(requireAppMember('owner')), asyncHandler(async (req, res) => {
  const ownerCountResult = await query(
    `select count(*) from app_members where app_id = $1 and role = 'owner'`,
    [req.appRow.id],
  );
  const targetResult = await query(
    'select role from app_members where app_id = $1 and user_id = $2',
    [req.appRow.id, req.params.userId],
  );
  const target = targetResult.rows[0];
  if (target?.role === 'owner' && Number(ownerCountResult.rows[0].count) <= 1) {
    return res.status(400).send(renderPage('Cannot remove', `<p class="error">This app must keep at least one owner.</p><p><a href="/apps/${escapeHtml(req.appRow.slug)}">Back</a></p>`, { user: req.user }));
  }
  await query('delete from app_members where app_id = $1 and user_id = $2', [req.appRow.id, req.params.userId]);
  res.redirect(303, `/apps/${req.appRow.slug}`);
}));

portalAppsRouter.post('/:appSlug/publish-keys', asyncHandler(requireAppMember('member')), asyncHandler(async (req, res) => {
  const { label } = req.body ?? {};
  if (!label) {
    return res.status(400).send(renderPage('Generate publish key', `<p class="error">A label is required.</p><p><a href="/apps/${escapeHtml(req.appRow.slug)}">Back</a></p>`, { user: req.user }));
  }

  const rawKey = crypto.randomBytes(32).toString('base64url');
  await query(
    `insert into app_publish_keys (app_id, created_by, label, api_key_hash) values ($1, $2, $3, $4)`,
    [req.appRow.id, req.user.id, label, hashApiKey(rawKey)],
  );

  res.send(renderPage('Publish key created', `
    <div class="warn">
      <strong>Save this key now — it is shown only this once and is never stored on the server.</strong>
      It only works for <code>${escapeHtml(req.appRow.slug)}</code>, not other apps.
    </div>
    <pre>${escapeHtml(rawKey)}</pre>
    <h2>Use it with the CLI</h2>
    <pre>APP_UPDATER_API_KEY=${escapeHtml(rawKey)} app_updater publish --base-apk /path/to/archived-release.apk --private-key ~/.app_updater/keys/${escapeHtml(req.appRow.slug)}/....pem</pre>
    <p><a href="/apps/${escapeHtml(req.appRow.slug)}">Back to ${escapeHtml(req.appRow.slug)}</a></p>
  `, { user: req.user }));
}));

portalAppsRouter.post('/:appSlug/publish-keys/:keyId/revoke', asyncHandler(requireAppMember('member')), asyncHandler(async (req, res) => {
  await query(
    'update app_publish_keys set revoked = true where id = $1 and app_id = $2',
    [req.params.keyId, req.appRow.id],
  );
  res.redirect(303, `/apps/${req.appRow.slug}`);
}));

portalAppsRouter.post(
  '/:appSlug/patches',
  asyncHandler(requireAppMember('member')),
  upload.fields([{ name: 'manifest', maxCount: 1 }, { name: 'artifact', maxCount: 1 }]),
  asyncHandler(async (req, res) => {
    try {
      await ingestPatch(req.appRow, req.files?.manifest?.[0], req.files?.artifact?.[0]);
      res.redirect(303, `/apps/${req.appRow.slug}`);
    } catch (error) {
      if (error instanceof PatchIngestError) {
        return res.status(error.status).send(renderPage('Upload failed', `<p class="error">${escapeHtml(error.message)}</p><p><a href="/apps/${escapeHtml(req.appRow.slug)}">Back</a></p>`, { user: req.user }));
      }
      throw error;
    }
  }),
);

portalAppsRouter.post('/:appSlug/patches/:patchNumber/toggle', asyncHandler(requireAppMember('member')), asyncHandler(async (req, res) => {
  const enabled = req.body?.enabled === 'true';
  await query(
    'update patches set enabled = $1 where app_id = $2 and patch_number = $3',
    [enabled, req.appRow.id, Number(req.params.patchNumber)],
  );
  res.redirect(303, `/apps/${req.appRow.slug}`);
}));
