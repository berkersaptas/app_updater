import { Router } from 'express';
import path from 'node:path';
import { query } from '../db.js';
import { requireApp } from '../appLookup.js';
import { config } from '../config.js';
import { asyncHandler } from '../asyncHandler.js';

export const artifactRouter = Router();

artifactRouter.get('/apps/:appSlug/patches/:patchNumber/artifact', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;

  const result = await query(
    'select * from patches where app_id = $1 and patch_number = $2 and enabled = true',
    [app.id, Number(req.params.patchNumber)],
  );
  const patch = result.rows[0];
  if (!patch) {
    return res.status(404).json({ error: `Unknown or disabled patch number: ${req.params.patchNumber}` });
  }

  const absolutePath = path.join(config.artifactStorageDir, patch.artifact_relative_path);
  res.sendFile(absolutePath, (error) => {
    if (error && !res.headersSent) {
      res.status(404).json({ error: 'Artifact file not found on disk' });
    }
  });
}));
