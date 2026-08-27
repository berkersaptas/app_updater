export const KNOWN_PATCH_EVENT_TYPES = new Set([
  'PatchInstallStarted',
  'PatchInstallSuccess',
  'PatchInstallFailure',
  'PatchLaunchSuccess',
  'PatchLaunchFailure',
  'PatchMarkedBad',
]);

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

export function validatePatchCheck(body, appPlatform) {
  const {
    channel = 'stable',
    release_version: releaseVersion,
    current_patch_number: currentPatchNumber,
    platform,
    arch,
    ota_protocol_version: otaProtocolVersion,
    engine_revision: engineRevision,
    dart_version: dartVersion,
    build_mode: buildMode,
    base_sha256: baseSha256,
    build_fingerprint: buildFingerprint,
  } = body ?? {};

  if (!nonEmptyString(releaseVersion) || !nonEmptyString(platform) || !nonEmptyString(arch)) {
    return { valid: false, error: 'release_version, current_patch_number, platform, and arch are required' };
  }
  if (!Number.isInteger(currentPatchNumber) || currentPatchNumber < 0) {
    return { valid: false, error: 'current_patch_number must be a non-negative integer' };
  }
  if (!['android', 'ios'].includes(platform)) {
    return { valid: false, error: 'platform must be android or ios' };
  }
  if (!nonEmptyString(channel)) {
    return { valid: false, error: 'channel must be a non-empty string' };
  }

  const capabilityValues = [
    otaProtocolVersion,
    engineRevision,
    dartVersion,
    buildMode,
    baseSha256,
    buildFingerprint,
  ];
  if (capabilityValues.every((value) => value === undefined)) {
    return {
      valid: true,
      otaCapable: false,
      matchesAppPlatform: platform === appPlatform,
      values: { channel, releaseVersion, currentPatchNumber, platform, arch },
    };
  }
  if (capabilityValues.some((value) => value === undefined)) {
    return { valid: false, error: 'OTA capability fields must be provided together' };
  }
  if (otaProtocolVersion !== SUPPORTED_OTA_PROTOCOL_VERSION) {
    return {
      valid: true,
      otaCapable: false,
      matchesAppPlatform: platform === appPlatform,
      values: { channel, releaseVersion, currentPatchNumber, platform, arch },
    };
  }
  if (!/^[0-9a-f]{40}$/.test(engineRevision) || !nonEmptyString(dartVersion)) {
    return { valid: false, error: 'Invalid engine_revision or dart_version' };
  }
  if (buildMode !== 'release') {
    return { valid: false, error: 'build_mode must be release' };
  }
  if (!/^[0-9a-f]{64}$/.test(baseSha256) || !/^[0-9a-f]{64}$/.test(buildFingerprint)) {
    return { valid: false, error: 'Invalid base_sha256 or build_fingerprint' };
  }
  const expectedFingerprint = computeBuildFingerprint({
    otaProtocolVersion,
    releaseVersion,
    engineRevision,
    dartVersion,
    arch,
    buildMode,
    baseSha256,
  });
  if (buildFingerprint !== expectedFingerprint) {
    return { valid: false, error: 'build_fingerprint does not match the supplied build metadata' };
  }

  return {
    valid: true,
    otaCapable: true,
    matchesAppPlatform: platform === appPlatform,
    values: {
      channel,
      releaseVersion,
      currentPatchNumber,
      platform,
      arch,
      otaProtocolVersion,
      engineRevision,
      dartVersion,
      buildMode,
      baseSha256,
      buildFingerprint,
    },
  };
}

export function computeBuildFingerprint({
  otaProtocolVersion,
  releaseVersion,
  engineRevision,
  dartVersion,
  arch,
  buildMode,
  baseSha256,
}) {
  const payload =
    `ota_protocol_version=${otaProtocolVersion}\n` +
    `release=${releaseVersion}\n` +
    `engine_revision=${engineRevision}\n` +
    `dart_version=${dartVersion}\n` +
    `abi=${arch}\n` +
    `build_mode=${buildMode}\n` +
    `base_sha256=${baseSha256}\n`;
  return crypto.createHash('sha256').update(payload, 'utf8').digest('hex');
}

export function validatePatchEvent(body, appPlatform) {
  const {
    type,
    patch_number: patchNumber,
    release_version: releaseVersion,
    platform,
    arch,
  } = body ?? {};

  if (!KNOWN_PATCH_EVENT_TYPES.has(type)) {
    return { valid: false, error: `Unknown event type: ${type}` };
  }
  if (!Number.isInteger(patchNumber) || patchNumber <= 0) {
    return { valid: false, error: 'patch_number must be a positive integer' };
  }
  if (!nonEmptyString(releaseVersion) || !nonEmptyString(platform) || !nonEmptyString(arch)) {
    return { valid: false, error: 'release_version, platform, and arch are required' };
  }
  if (!['android', 'ios'].includes(platform)) {
    return { valid: false, error: 'platform must be android or ios' };
  }
  if (platform !== appPlatform) {
    return { valid: false, error: `Event platform does not match app platform: ${appPlatform}` };
  }

  return { valid: true, values: { type, patchNumber, releaseVersion, platform, arch } };
}

export function parsePositivePatchNumber(value) {
  if (!/^[1-9][0-9]*$/.test(String(value))) {
    return { valid: false, error: 'patchNumber must be a positive integer' };
  }
  const patchNumber = Number(value);
  if (!Number.isSafeInteger(patchNumber)) {
    return { valid: false, error: 'patchNumber is outside the supported integer range' };
  }
  return { valid: true, value: patchNumber };
}

export function sendFileErrorStatus(error) {
  if (Number.isInteger(error?.status) && error.status >= 400 && error.status < 600) {
    return error.status;
  }
  return error?.code === 'ENOENT' ? 404 : 500;
}
import crypto from 'node:crypto';

export const SUPPORTED_OTA_PROTOCOL_VERSION = 2;
