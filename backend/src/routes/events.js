import { Router } from 'express';
import { query } from '../db.js';
import { requireApp } from '../appLookup.js';
import { asyncHandler } from '../asyncHandler.js';

export const eventsRouter = Router();

const KNOWN_EVENT_TYPES = new Set([
  'PatchInstallStarted',
  'PatchInstallSuccess',
  'PatchInstallFailure',
  'PatchLaunchSuccess',
  'PatchLaunchFailure',
  'PatchMarkedBad',
]);

eventsRouter.post('/apps/:appSlug/events', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;

  const body = req.body ?? {};
  const { type, patch_number: patchNumber, release_version: releaseVersion, platform, arch } = body;
  if (!type || !KNOWN_EVENT_TYPES.has(type)) {
    return res.status(400).json({ error: `Unknown event type: ${type}` });
  }

  await query(
    `insert into patch_events (app_id, patch_number, event_type, release_version, platform, arch, payload)
     values ($1, $2, $3, $4, $5, $6, $7)`,
    [app.id, patchNumber ?? null, type, releaseVersion ?? null, platform ?? null, arch ?? null, body],
  );
  res.status(202).json({ accepted: true });
}));
