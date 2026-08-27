import { Router } from 'express';
import { query } from '../db.js';
import { requireApp } from '../appLookup.js';
import { asyncHandler } from '../asyncHandler.js';
import { validatePatchEvent } from '../requestValidation.js';

export const eventsRouter = Router();

eventsRouter.post('/apps/:appSlug/events', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;

  const body = req.body ?? {};
  const validation = validatePatchEvent(body, app.platform);
  if (!validation.valid) return res.status(400).json({ error: validation.error });
  const { type, patchNumber, releaseVersion, platform, arch } = validation.values;

  await query(
    `insert into patch_events (app_id, patch_number, event_type, release_version, platform, arch, payload)
     values ($1, $2, $3, $4, $5, $6, $7)`,
    [app.id, patchNumber, type, releaseVersion, platform, arch, body],
  );
  res.status(202).json({ accepted: true });
}));
