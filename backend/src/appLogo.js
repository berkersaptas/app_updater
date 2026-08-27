import crypto from 'node:crypto';
import path from 'node:path';
import { mkdir, unlink, writeFile } from 'node:fs/promises';
import sharp from 'sharp';

import { config } from './config.js';
import { query } from './db.js';

export const APP_LOGO_MAX_BYTES = 2 * 1024 * 1024;
export const APP_LOGO_FIELD = 'logo';
const acceptedFormats = new Set(['png', 'jpeg', 'webp']);
const maxInputDimension = 4096;

export class AppLogoError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.name = 'AppLogoError';
    this.status = status;
  }
}

export async function transformAppLogo(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) {
    throw new AppLogoError('A logo file is required');
  }
  if (buffer.length > APP_LOGO_MAX_BYTES) {
    throw new AppLogoError('Logo must be 2 MB or smaller', 413);
  }

  let image;
  let metadata;
  try {
    image = sharp(buffer, {
      failOn: 'warning',
      limitInputPixels: maxInputDimension * maxInputDimension,
      sequentialRead: true,
    }).rotate();
    metadata = await image.metadata();
  } catch {
    throw new AppLogoError('Logo is not a valid PNG, JPEG, or WebP image');
  }

  if (!acceptedFormats.has(metadata.format)) {
    throw new AppLogoError('Logo must be a PNG, JPEG, or WebP image');
  }
  if (!metadata.width || !metadata.height || metadata.width < 128 || metadata.height < 128) {
    throw new AppLogoError('Logo dimensions must be at least 128x128 pixels');
  }
  if (metadata.width > maxInputDimension || metadata.height > maxInputDimension) {
    throw new AppLogoError(`Logo dimensions must not exceed ${maxInputDimension}x${maxInputDimension} pixels`);
  }

  // Re-encoding strips source metadata. A centered square crop gives the portal a predictable,
  // safe shape while preserving the original logo at two practical display densities.
  const large = await image
    .clone()
    .resize(256, 256, { fit: 'cover', position: 'centre' })
    .webp({ quality: 90, effort: 4 })
    .toBuffer();
  const thumbnail = await image
    .clone()
    .resize(64, 64, { fit: 'cover', position: 'centre' })
    .webp({ quality: 86, effort: 4 })
    .toBuffer();

  return {
    large,
    thumbnail,
    sha256: crypto.createHash('sha256').update(large).digest('hex'),
    mimeType: 'image/webp',
    width: 256,
    height: 256,
  };
}

async function writeOnce(filePath, contents) {
  await mkdir(path.dirname(filePath), { recursive: true });
  try {
    await writeFile(filePath, contents, { flag: 'wx', mode: 0o644 });
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
}

export async function saveAppLogo(app, buffer) {
  const logo = await transformAppLogo(buffer);
  const directory = path.posix.join('app-assets', app.slug);
  const relativePath = path.posix.join(directory, `${logo.sha256}-256.webp`);
  const thumbnailRelativePath = path.posix.join(directory, `${logo.sha256}-64.webp`);

  await Promise.all([
    writeOnce(path.join(config.artifactStorageDir, relativePath), logo.large),
    writeOnce(path.join(config.artifactStorageDir, thumbnailRelativePath), logo.thumbnail),
  ]);

  const previous = await findAppLogo(app.id);
  const result = await query(
    `insert into app_assets (
       app_id, kind, relative_path, thumbnail_relative_path, sha256,
       mime_type, width, height, size
     ) values ($1, 'logo', $2, $3, $4, $5, $6, $7, $8)
     on conflict (app_id, kind) do update set
       relative_path = excluded.relative_path,
       thumbnail_relative_path = excluded.thumbnail_relative_path,
       sha256 = excluded.sha256,
       mime_type = excluded.mime_type,
       width = excluded.width,
       height = excluded.height,
       size = excluded.size,
       updated_at = now()
     returning *`,
    [
      app.id,
      relativePath,
      thumbnailRelativePath,
      logo.sha256,
      logo.mimeType,
      logo.width,
      logo.height,
      logo.large.length,
    ],
  );
  if (previous && previous.sha256 !== logo.sha256) {
    await Promise.all([
      unlink(path.join(config.artifactStorageDir, previous.relative_path)).catch((error) => {
        if (error.code !== 'ENOENT') throw error;
      }),
      unlink(path.join(config.artifactStorageDir, previous.thumbnail_relative_path)).catch((error) => {
        if (error.code !== 'ENOENT') throw error;
      }),
    ]);
  }
  return result.rows[0];
}

export async function findAppLogo(appId) {
  const result = await query(
    `select * from app_assets where app_id = $1 and kind = 'logo'`,
    [appId],
  );
  return result.rows[0] ?? null;
}

export async function deleteAppLogo(appId) {
  const result = await query(
    `delete from app_assets where app_id = $1 and kind = 'logo' returning *`,
    [appId],
  );
  const asset = result.rows[0];
  if (!asset) return false;
  await Promise.all([
    unlink(path.join(config.artifactStorageDir, asset.relative_path)).catch((error) => {
      if (error.code !== 'ENOENT') throw error;
    }),
    unlink(path.join(config.artifactStorageDir, asset.thumbnail_relative_path)).catch((error) => {
      if (error.code !== 'ENOENT') throw error;
    }),
  ]);
  return true;
}

export function appLogoAbsolutePath(asset, thumbnail = false) {
  const relativePath = thumbnail ? asset.thumbnail_relative_path : asset.relative_path;
  return path.join(config.artifactStorageDir, relativePath);
}
