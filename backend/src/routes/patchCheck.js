import { Router } from 'express';
import { query } from '../db.js';
import { requireApp } from '../appLookup.js';
import { asyncHandler } from '../asyncHandler.js';

export const patchCheckRouter = Router();

patchCheckRouter.post('/apps/:appSlug/patch-check', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;

  const {
    channel = 'stable',
    release_version: releaseVersion,
    current_patch_number: currentPatchNumber,
    arch,
  } = req.body ?? {};
  if (!releaseVersion || currentPatchNumber === undefined || !arch) {
    return res
      .status(400)
      .json({ error: 'release_version, current_patch_number, and arch are required' });
  }

  // First filter only: release, arch (abi), release build mode, enabled, channel, and a higher
  // patch number than the device already has. This narrows candidates cheaply; the device's own
  // compatibility checks (engine revision, Dart version, signature) remain the authoritative gate,
  // same as today with locally-installed patches.
  const result = await query(
    `select * from patches
     where app_id = $1
       and release = $2
       and abi = $3
       and build_mode = 'release'
       and enabled = true
       and channel = $4
       and patch_number > $5
     order by patch_number desc
     limit 1`,
    [app.id, releaseVersion, arch, channel, currentPatchNumber],
  );

  const patch = result.rows[0];
  if (!patch) {
    return res.json({ patch_available: false });
  }

  const downloadUrl = `${req.protocol}://${req.get('host')}/v1/apps/${app.slug}/patches/${patch.patch_number}/artifact`;
  res.json({
    patch_available: true,
    patch: {
      number: patch.patch_number,
      artifact_kind: patch.artifact_kind,
      hash: patch.manifest.sha256,
      download_url: downloadUrl,
      manifest: patch.manifest,
    },
  });
}));
