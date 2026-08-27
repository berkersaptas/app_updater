import { Router } from 'express';
import { query } from '../db.js';
import { requireApp } from '../appLookup.js';
import { asyncHandler } from '../asyncHandler.js';
import { validatePatchCheck } from '../requestValidation.js';

export const patchCheckRouter = Router();

patchCheckRouter.post('/apps/:appSlug/patch-check', asyncHandler(async (req, res) => {
  const app = await requireApp(req, res);
  if (!app) return;

  const validation = validatePatchCheck(req.body, app.platform);
  if (!validation.valid) return res.status(400).json({ error: validation.error });
  if (!validation.matchesAppPlatform) return res.json({ patch_available: false });
  if (!validation.otaCapable) {
    return res.json({ patch_available: false, client_upgrade_required: true });
  }
  const {
    channel,
    releaseVersion,
    currentPatchNumber,
    arch,
    otaProtocolVersion,
    engineRevision,
    dartVersion,
    buildMode,
    baseSha256,
    buildFingerprint,
  } = validation.values;

  // Exact build identity is the server-side distribution gate. Device-side signature,
  // compatibility, and reconstructed SHA checks remain a second independent fail-closed layer.
  const result = await query(
    `select p.* from patches p
     join app_keys k
       on k.app_id = p.app_id
      and k.key_id = p.manifest ->> 'signature_key_id'
      and k.active = true
      and k.revoked = false
     where p.app_id = $1
       and p.release = $2
       and p.abi = $3
       and p.build_mode = $6
       and p.enabled = true
       and p.channel = $4
       and p.patch_number > $5
       and (p.manifest ->> 'ota_protocol_version')::int = $7
       and p.manifest ->> 'engine_revision' = $8
       and p.manifest ->> 'dart_version' = $9
       and p.manifest ->> 'base_sha256' = $10
       and p.manifest ->> 'build_fingerprint' = $11
     order by p.patch_number desc
     limit 1`,
    [
      app.id,
      releaseVersion,
      arch,
      channel,
      currentPatchNumber,
      buildMode,
      otaProtocolVersion,
      engineRevision,
      dartVersion,
      baseSha256,
      buildFingerprint,
    ],
  );

  const patch = result.rows[0];
  if (!patch) {
    if (currentPatchNumber > 0) {
      const currentResult = await query(
        `select p.enabled, k.active as key_active, k.revoked as key_revoked
         from patches p
         left join app_keys k
           on k.app_id = p.app_id
          and k.key_id = p.manifest ->> 'signature_key_id'
         where p.app_id = $1 and p.patch_number = $2`,
        [app.id, currentPatchNumber],
      );
      const current = currentResult.rows[0];
      const withdrawn = current && (
        !current.enabled || current.key_active !== true || current.key_revoked !== false
      );
      if (withdrawn) {
        return res.json({ patch_available: false, rollback_patch_number: currentPatchNumber });
      }
    }
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
