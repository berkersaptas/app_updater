import { Router } from 'express';
import path from 'node:path';
import { query } from '../db.js';
import { requireApp } from '../appLookup.js';
import { config } from '../config.js';
import { asyncHandler } from '../asyncHandler.js';
import { parsePositivePatchNumber, sendFileErrorStatus } from '../requestValidation.js';

export const artifactRouter = Router();

artifactRouter.get('/apps/:appSlug/patches/:patchNumber/artifact', asyncHandler(async (req, res, next) => {
  const app = await requireApp(req, res);
  if (!app) return;
  const parsedPatchNumber = parsePositivePatchNumber(req.params.patchNumber);
  if (!parsedPatchNumber.valid) return res.status(400).json({ error: parsedPatchNumber.error });

  const result = await query(
    `select p.* from patches p
     join app_keys k
       on k.app_id = p.app_id
      and k.key_id = p.manifest ->> 'signature_key_id'
      and k.active = true
      and k.revoked = false
     where p.app_id = $1 and p.patch_number = $2 and p.enabled = true`,
    [app.id, parsedPatchNumber.value],
  );
  const patch = result.rows[0];
  if (!patch) {
    return res.status(404).json({ error: `Unknown or disabled patch number: ${req.params.patchNumber}` });
  }

  const absolutePath = path.join(config.artifactStorageDir, patch.artifact_relative_path);
  res.sendFile(absolutePath, (error) => {
    if (!error) return;
    if (res.headersSent) return next(error);
    const status = sendFileErrorStatus(error);
    const message = status === 416
      ? 'Requested artifact range is not satisfiable'
      : status === 404
        ? 'Artifact file not found on disk'
        : 'Artifact download failed';
    res.status(status).json({ error: message });
  });
}));
