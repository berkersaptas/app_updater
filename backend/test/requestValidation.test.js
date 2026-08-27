import assert from 'node:assert/strict';
import test from 'node:test';

import {
  computeBuildFingerprint,
  parsePositivePatchNumber,
  sendFileErrorStatus,
  validatePatchCheck,
  validatePatchEvent,
} from '../src/requestValidation.js';

const buildMetadata = {
  otaProtocolVersion: 2,
  releaseVersion: '1.0.0+1',
  engineRevision: 'a'.repeat(40),
  dartVersion: '3.12.2',
  arch: 'arm64-v8a',
  buildMode: 'release',
  baseSha256: 'b'.repeat(64),
};
const validCheck = {
  channel: 'stable',
  release_version: '1.0.0+1',
  current_patch_number: 0,
  platform: 'android',
  arch: 'arm64-v8a',
  ota_protocol_version: buildMetadata.otaProtocolVersion,
  engine_revision: buildMetadata.engineRevision,
  dart_version: buildMetadata.dartVersion,
  build_mode: buildMetadata.buildMode,
  base_sha256: buildMetadata.baseSha256,
  build_fingerprint: computeBuildFingerprint(buildMetadata),
};

test('patch-check accepts a valid matching Android request', () => {
  const result = validatePatchCheck(validCheck, 'android');
  assert.equal(result.valid, true);
  assert.equal(result.matchesAppPlatform, true);
  assert.equal(result.otaCapable, true);
});

test('legacy client is safely treated as incapable instead of receiving a patch', () => {
  const legacy = {
    channel: validCheck.channel,
    release_version: validCheck.release_version,
    current_patch_number: validCheck.current_patch_number,
    platform: validCheck.platform,
    arch: validCheck.arch,
  };
  const result = validatePatchCheck(legacy, 'android');
  assert.equal(result.valid, true);
  assert.equal(result.otaCapable, false);
});

test('patch-check rejects partial or forged build identity', () => {
  const partial = { ...validCheck };
  delete partial.base_sha256;
  assert.equal(validatePatchCheck(partial, 'android').valid, false);
  assert.equal(
    validatePatchCheck({ ...validCheck, build_fingerprint: 'c'.repeat(64) }, 'android').valid,
    false,
  );
});

test('patch-check treats another valid platform as non-matching', () => {
  const result = validatePatchCheck({ ...validCheck, platform: 'ios' }, 'android');
  assert.equal(result.valid, true);
  assert.equal(result.matchesAppPlatform, false);
});

test('patch-check rejects malformed current patch numbers', () => {
  for (const current_patch_number of [-1, '1', 'abc', 1.5, null]) {
    const result = validatePatchCheck({ ...validCheck, current_patch_number }, 'android');
    assert.equal(result.valid, false, `unexpectedly accepted ${current_patch_number}`);
  }
});

test('patch-check requires platform and rejects unknown platforms', () => {
  const missing = { ...validCheck };
  delete missing.platform;
  assert.equal(validatePatchCheck(missing, 'android').valid, false);
  assert.equal(validatePatchCheck({ ...validCheck, platform: 'windows' }, 'android').valid, false);
});

const validEvent = {
  type: 'PatchInstallSuccess',
  patch_number: 1,
  release_version: '1.0.0+1',
  platform: 'android',
  arch: 'arm64-v8a',
};

test('patch events require complete, correctly typed metadata', () => {
  assert.equal(validatePatchEvent(validEvent, 'android').valid, true);
  assert.equal(validatePatchEvent({ type: validEvent.type }, 'android').valid, false);
  assert.equal(validatePatchEvent({ ...validEvent, patch_number: 0 }, 'android').valid, false);
  assert.equal(validatePatchEvent({ ...validEvent, platform: 'ios' }, 'android').valid, false);
  assert.equal(validatePatchEvent({ ...validEvent, type: 'MadeUpEvent' }, 'android').valid, false);
});

test('artifact patch number parsing accepts only safe positive integers', () => {
  assert.deepEqual(parsePositivePatchNumber('1'), { valid: true, value: 1 });
  for (const value of ['0', '-1', 'abc', '1.5', '9007199254740992']) {
    assert.equal(parsePositivePatchNumber(value).valid, false, `unexpectedly accepted ${value}`);
  }
});

test('sendFile errors preserve HTTP status and classify missing files', () => {
  assert.equal(sendFileErrorStatus({ status: 416 }), 416);
  assert.equal(sendFileErrorStatus({ code: 'ENOENT' }), 404);
  assert.equal(sendFileErrorStatus(new Error('boom')), 500);
});
