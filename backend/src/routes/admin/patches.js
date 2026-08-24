import { Router } from 'express';
import multer from 'multer';
import { query } from '../../db.js';
import { requireApp } from '../../appLookup.js';
import { ingestPatch, PatchIngestError } from '../../patchIngest.js';
import { asyncHandler } from '../../asyncHandler.js';

export const patchesRouter = Router();

const upload = multer({ storage: multer.memoryStorage() });

// An app-scoped publish key (req.scopedAppId, set by adminAuth) may only ever act on the one app
// it was issued for; an unscoped operator/root key can act on any app, as before.
function scopeAllows(req, app) {
  return !req.scopedAppId || req.scopedAppId === app.id;
}

patchesRouter.post(
  '/apps/:appSlug/patches',
  upload.fields([{ name: 'manifest', maxCount: 1 }, { name: 'artifact', maxCount: 1 }]),
  asyncHandler(async (req, res) => {
    const app = await requireApp(req, res);
    if (!app) return;
    if (!scopeAllows(req, app)) {
      return res.status(403).json({ error: 'This publish key is not valid for this app' });
    }

    try {
      const patch = await ingestPatch(app, req.files?.manifest?.[0], req.files?.artifact?.[0]);
      res.status(201).json(patch);
    } catch (error) {
      if (error instanceof PatchIngestError) {
        return res.status(error.status).json({ error: error.message, details: error.details });
      }
      throw error;
    }
  }),
);

patchesRouter.patch('/apps/:appSlug/patches/:patchNumber', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;
  if (!scopeAllows(req, app)) {
    return res.status(403).json({ error: 'This publish key is not valid for this app' });
  }

  const { enabled } = req.body ?? {};
  if (typeof enabled !== 'boolean') {
    return res.status(400).json({ error: 'enabled (boolean) is required' });
  }

  const result = await query(
    `update patches set enabled = $1 where app_id = $2 and patch_number = $3 returning *`,
    [enabled, app.id, Number(req.params.patchNumber)],
  );
  if (result.rowCount === 0) {
    return res.status(404).json({ error: `Unknown patch number: ${req.params.patchNumber}` });
  }
  res.json(result.rows[0]);
}));

patchesRouter.get('/apps/:appSlug/patches', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;
  if (!scopeAllows(req, app)) {
    return res.status(403).json({ error: 'This publish key is not valid for this app' });
  }

  const result = await query(
    'select * from patches where app_id = $1 order by patch_number',
    [app.id],
  );
  res.json(result.rows);
}));
