import crypto from 'node:crypto';
import path from 'node:path';
import { mkdir, writeFile } from 'node:fs/promises';
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import multer from 'multer';
import { pool, query } from '../db.js';
import { asyncHandler } from '../asyncHandler.js';
import { cliAuth, newCliToken, tokenHash } from '../middleware/cliAuth.js';
import { provisionManagedApp, appYaml } from '../appProvisioning.js';
import { config } from '../config.js';
import { signManifestWithManagedKey } from '../managedSigner.js';
import { computeBuildFingerprint, SUPPORTED_OTA_PROTOCOL_VERSION } from '../requestValidation.js';
import { ingestPatch, PatchIngestError } from '../patchIngest.js';
import {
  APP_LOGO_FIELD,
  APP_LOGO_MAX_BYTES,
  AppLogoError,
  deleteAppLogo,
  saveAppLogo,
} from '../appLogo.js';

export const cliRouter = Router();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 500 * 1024 * 1024 } });
const logoUpload = multer({ storage: multer.memoryStorage(), limits: { fileSize: APP_LOGO_MAX_BYTES } });
const releaseVersionPattern = /^[A-Za-z0-9._+-]+$/;
const supportedAbis = new Set(['arm64-v8a', 'armeabi-v7a', 'x86_64']);

cliRouter.post('/login', asyncHandler(async (req, res) => {
  const { email, password, label = 'app_updater-cli' } = req.body ?? {};
  const result = await query('select id, email, password_hash from users where email = $1', [(email ?? '').toLowerCase()]);
  const user = result.rows[0];
  if (!user || !(await bcrypt.compare(password ?? '', user.password_hash))) {
    return res.status(401).json({ error: 'Invalid email or password' });
  }
  const token = newCliToken();
  await query(
    `insert into cli_tokens (user_id, label, token_hash, expires_at)
     values ($1, $2, $3, now() + interval '90 days')`,
    [user.id, String(label).slice(0, 100), tokenHash(token)],
  );
  res.json({ token, email: user.email, expires_in_days: 90 });
}));

cliRouter.use(asyncHandler(cliAuth));

cliRouter.delete('/session', asyncHandler(async (req, res) => {
  await query('update cli_tokens set revoked = true where id = $1', [req.user.token_id]);
  res.status(204).end();
}));

async function memberApp(req, res, minimumRole = 'member') {
  const result = await query(
    `select a.*, m.role from apps a join app_members m on m.app_id = a.id
     where a.slug = $1 and m.user_id = $2`,
    [req.params.appSlug, req.user.id],
  );
  const app = result.rows[0];
  if (!app) {
    res.status(404).json({ error: 'Unknown app or no access' });
    return null;
  }
  if (minimumRole === 'owner' && app.role !== 'owner') {
    res.status(403).json({ error: 'App owner access required' });
    return null;
  }
  return app;
}

cliRouter.get('/apps', asyncHandler(async (req, res) => {
  const result = await query(
    `select a.slug, a.package_name, a.platform, m.role
     from apps a join app_members m on m.app_id = a.id
     where m.user_id = $1 order by a.created_at`,
    [req.user.id],
  );
  res.json(result.rows);
}));

cliRouter.post('/apps', asyncHandler(async (req, res) => {
  try {
    const app = await provisionManagedApp({
      userId: req.user.id,
      slug: req.body?.slug,
      packageName: req.body?.package_name,
    });
    const backendUrl = `${req.protocol}://${req.get('host')}`;
    res.status(201).json({ app, yaml: appYaml(app, backendUrl) });
  } catch (error) {
    if (error.status) return res.status(error.status).json({ error: error.message });
    throw error;
  }
}));

cliRouter.get('/apps/:appSlug/config', asyncHandler(async (req, res) => {
  const app = await memberApp(req, res);
  if (!app) return;
  const keyResult = await query(
    `select key_id, public_key_der_base64url as public_key
     from app_keys where app_id = $1 and active = true and revoked = false order by created_at`,
    [app.id],
  );
  const key = keyResult.rows[0];
  if (!key) return res.status(409).json({ error: 'App has no active signing key' });
  res.json({ app, yaml: appYaml({ ...app, ...key }, `${req.protocol}://${req.get('host')}`) });
}));

cliRouter.put(
  '/apps/:appSlug/logo',
  (req, res, next) => logoUpload.single(APP_LOGO_FIELD)(req, res, (error) => {
    if (!error) return next();
    const status = error instanceof multer.MulterError && error.code === 'LIMIT_FILE_SIZE' ? 413 : 400;
    return res.status(status).json({ error: status === 413 ? 'Logo must be 2 MB or smaller' : 'Invalid logo upload' });
  }),
  asyncHandler(async (req, res) => {
    const app = await memberApp(req, res, 'owner');
    if (!app) return;
    try {
      const asset = await saveAppLogo(app, req.file?.buffer);
      res.json({
        sha256: asset.sha256,
        mime_type: asset.mime_type,
        width: asset.width,
        height: asset.height,
        logo_url: `/apps/${encodeURIComponent(app.slug)}/logo?v=${asset.sha256}`,
      });
    } catch (error) {
      if (error instanceof AppLogoError) return res.status(error.status).json({ error: error.message });
      throw error;
    }
  }),
);

cliRouter.delete('/apps/:appSlug/logo', asyncHandler(async (req, res) => {
  const app = await memberApp(req, res, 'owner');
  if (!app) return;
  await deleteAppLogo(app.id);
  res.status(204).end();
}));

cliRouter.post('/apps/:appSlug/releases', upload.single('artifact'), asyncHandler(async (req, res) => {
  const app = await memberApp(req, res);
  if (!app) return;
  const {
    release_version: releaseVersion,
    engine_revision: engineRevision,
    dart_version: dartVersion,
    abi,
    ota_protocol_version: otaProtocolVersionRaw,
    base_sha256: baseSha256,
    build_fingerprint: buildFingerprint,
    source_commit: sourceCommit,
  } = req.body ?? {};
  const otaProtocolVersion = Number(otaProtocolVersionRaw);
  if (!req.file || !releaseVersion || !engineRevision || !dartVersion || !abi || !baseSha256 || !buildFingerprint) {
    return res.status(400).json({ error: 'artifact and complete exact-build metadata are required' });
  }
  if (!releaseVersionPattern.test(releaseVersion) || !supportedAbis.has(abi)) {
    return res.status(400).json({ error: 'Invalid release_version or unsupported ABI' });
  }
  const expectedFingerprint = computeBuildFingerprint({
    otaProtocolVersion,
    releaseVersion,
    engineRevision,
    dartVersion,
    arch: abi,
    buildMode: 'release',
    baseSha256,
  });
  if (
    otaProtocolVersion !== SUPPORTED_OTA_PROTOCOL_VERSION ||
    !/^[0-9a-f]{64}$/.test(baseSha256) ||
    buildFingerprint !== expectedFingerprint
  ) {
    return res.status(400).json({ error: 'Invalid OTA protocol, base SHA-256, or build fingerprint' });
  }
  const relativePath = path.join('releases', app.slug, releaseVersion, abi, 'base.aab');
  const absolutePath = path.join(config.artifactStorageDir, relativePath);
  const hash = crypto.createHash('sha256').update(req.file.buffer).digest('hex');
  const client = await pool.connect();
  try {
    await client.query('begin');
    const existingRelease = await client.query(
      'select * from releases where app_id = $1 and release_version = $2 for update',
      [app.id, releaseVersion],
    );
    let release = existingRelease.rows[0];
    if (release && (release.engine_revision !== engineRevision || release.dart_version !== dartVersion)) {
      await client.query('rollback');
      return res.status(409).json({
        error: 'Release metadata is immutable and does not match the registered Flutter toolchain',
      });
    }
    if (!release) {
      const releaseResult = await client.query(
        `insert into releases (app_id, release_version, engine_revision, dart_version, source_commit, created_by)
         values ($1, $2, $3, $4, $5, $6) returning *`,
        [app.id, releaseVersion, engineRevision, dartVersion, sourceCommit || null, req.user.id],
      );
      release = releaseResult.rows[0];
    }
    const existing = await client.query(
      'select 1 from release_artifacts where release_id = $1 and abi = $2',
      [release.id, abi],
    );
    if (existing.rowCount) {
      await client.query('rollback');
      return res.status(409).json({ error: 'Release artifact is immutable and already registered' });
    }
    await mkdir(path.dirname(absolutePath), { recursive: true });
    await writeFile(absolutePath, req.file.buffer, { flag: 'wx' });
    await client.query(
      `insert into release_artifacts (
         release_id, abi, artifact_relative_path, artifact_sha256, artifact_size,
         ota_protocol_version, base_sha256, build_fingerprint
       ) values ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        release.id,
        abi,
        relativePath,
        hash,
        req.file.buffer.length,
        otaProtocolVersion,
        baseSha256,
        buildFingerprint,
      ],
    );
    await client.query('commit');
    res.status(201).json({
      ...release,
      abi,
      artifact_sha256: hash,
      artifact_size: req.file.buffer.length,
      ota_protocol_version: otaProtocolVersion,
      base_sha256: baseSha256,
      build_fingerprint: buildFingerprint,
    });
  } catch (error) {
    await client.query('rollback');
    if (error.code === 'EEXIST') return res.status(409).json({ error: 'Release artifact already exists on disk' });
    throw error;
  } finally {
    client.release();
  }
}));

cliRouter.get('/apps/:appSlug/releases/:releaseVersion/artifact', asyncHandler(async (req, res) => {
  const app = await memberApp(req, res);
  if (!app) return;
  const result = await query(
    `select ra.* from release_artifacts ra join releases r on r.id = ra.release_id
     where r.app_id = $1 and r.release_version = $2 and ra.abi = $3`,
    [app.id, req.params.releaseVersion, req.query.abi],
  );
  const artifact = result.rows[0];
  if (!artifact) return res.status(404).json({ error: 'Registered release artifact not found for ABI' });
  res.sendFile(path.join(config.artifactStorageDir, artifact.artifact_relative_path));
}));

cliRouter.post('/apps/:appSlug/patches', upload.single('artifact'), asyncHandler(async (req, res) => {
  const app = await memberApp(req, res);
  if (!app) return;
  if (!req.file || !req.body?.manifest) return res.status(400).json({ error: 'artifact and manifest are required' });
  let manifest;
  try {
    manifest = JSON.parse(req.body.manifest);
  } catch {
    return res.status(400).json({ error: 'manifest is not valid JSON' });
  }
  const releaseResult = await query(
    `select r.engine_revision, r.dart_version, ra.ota_protocol_version,
            ra.base_sha256, ra.build_fingerprint
     from releases r join release_artifacts ra on ra.release_id = r.id
     where r.app_id = $1 and r.release_version = $2 and ra.abi = $3`,
    [app.id, manifest.release, manifest.abi],
  );
  if (!releaseResult.rowCount) {
    return res.status(409).json({ error: 'Run app_updater release android for this version and ABI before patching' });
  }
  const release = releaseResult.rows[0];
  if (manifest.engine_revision !== release.engine_revision || manifest.dart_version !== release.dart_version) {
    return res.status(409).json({
      error: 'Flutter/Dart toolchain differs from the registered store release; rebuild the patch with the release toolchain',
    });
  }
  if (
    manifest.ota_protocol_version !== release.ota_protocol_version ||
    manifest.base_sha256 !== release.base_sha256 ||
    manifest.build_fingerprint !== release.build_fingerprint
  ) {
    return res.status(409).json({
      error: 'Patch exact-build identity differs from the registered store release',
    });
  }
  const signerResult = await query('select * from app_managed_signers where app_id = $1', [app.id]);
  const signer = signerResult.rows[0];
  if (!signer) return res.status(409).json({ error: 'This legacy app has no managed signer' });
  const numberResult = await query(
    'select coalesce(max(patch_number), 0) + 1 as next from patches where app_id = $1',
    [app.id],
  );
  manifest = {
    ...manifest,
    patch_number: Number(numberResult.rows[0].next),
    signature_key_id: signer.key_id,
    signature_algorithm: signer.algorithm,
  };
  manifest.signature = signManifestWithManagedKey(manifest, signer);
  const manifestFile = { buffer: Buffer.from(JSON.stringify(manifest), 'utf8') };
  try {
    const patch = await ingestPatch(app, manifestFile, req.file);
    res.status(201).json(patch);
  } catch (error) {
    if (error instanceof PatchIngestError) {
      return res.status(error.status).json({ error: error.message, details: error.details });
    }
    throw error;
  }
}));
