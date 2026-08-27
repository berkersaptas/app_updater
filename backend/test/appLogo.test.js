import assert from 'node:assert/strict';
import test from 'node:test';
import sharp from 'sharp';

process.env.DATABASE_URL ??= 'postgresql://unused:unused@localhost:5432/unused';
process.env.ADMIN_API_KEY ??= 'test-admin-key';
process.env.SESSION_SECRET ??= 'test-session-secret';
process.env.SIGNING_MASTER_KEY ??= Buffer.alloc(32, 7).toString('base64');

const {
  APP_LOGO_MAX_BYTES,
  AppLogoError,
  transformAppLogo,
} = await import('../src/appLogo.js');

test('logo processing strips input format and creates normalized WebP variants', async () => {
  const source = await sharp({
    create: { width: 320, height: 180, channels: 4, background: '#336699' },
  }).png().withMetadata({ comment: 'private source metadata' }).toBuffer();

  const result = await transformAppLogo(source);
  const largeMetadata = await sharp(result.large).metadata();
  const thumbnailMetadata = await sharp(result.thumbnail).metadata();

  assert.equal(result.mimeType, 'image/webp');
  assert.match(result.sha256, /^[0-9a-f]{64}$/);
  assert.deepEqual([largeMetadata.width, largeMetadata.height], [256, 256]);
  assert.deepEqual([thumbnailMetadata.width, thumbnailMetadata.height], [64, 64]);
  assert.equal(largeMetadata.exif, undefined);
});

test('logo processing rejects malformed, unsupported, small, and oversized inputs', async () => {
  await assert.rejects(() => transformAppLogo(Buffer.from('not an image')), AppLogoError);

  const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"></svg>');
  await assert.rejects(() => transformAppLogo(svg), /PNG, JPEG, or WebP/);

  const small = await sharp({
    create: { width: 127, height: 128, channels: 3, background: '#fff' },
  }).png().toBuffer();
  await assert.rejects(() => transformAppLogo(small), /at least 128x128/);

  await assert.rejects(
    () => transformAppLogo(Buffer.alloc(APP_LOGO_MAX_BYTES + 1)),
    (error) => error instanceof AppLogoError && error.status === 413,
  );
});
