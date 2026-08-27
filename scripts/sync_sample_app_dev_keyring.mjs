#!/usr/bin/env node

import { readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const repoDir = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
const configPath = process.env.OTA_SAMPLE_CONFIG ?? join(repoDir, 'sample_app/app_updater.yaml');
const keyDir = process.env.OTA_DEV_KEY_DIR ?? join(repoDir, 'keys');

const keys = [
  ['dev-ed25519-v1', 'dev-ed25519-v1_public.der'],
  ['dev-rsa-v1', 'dev-rsa-v1_public.der'],
];

const lines = (await readFile(configPath, 'utf8')).split('\n');

for (const [keyId, filename] of keys) {
  const publicKey = (await readFile(join(keyDir, filename))).toString('base64url');
  const keyLine = lines.findIndex((line) => line.trim() === `- key_id: ${keyId}`);
  const nextKeyLine = lines.findIndex(
    (line, index) => index > keyLine && line.trim().startsWith('- key_id:'),
  );
  const sectionEnd = nextKeyLine === -1 ? lines.length : nextKeyLine;
  const publicKeyLine = lines.findIndex(
    (line, index) => index > keyLine && index < sectionEnd && line.trim().startsWith('public_key:'),
  );
  if (keyLine === -1 || publicKeyLine === -1) {
    throw new Error(`Could not find trusted key '${keyId}' in ${configPath}`);
  }
  const indentation = lines[publicKeyLine].match(/^\s*/)[0];
  lines[publicKeyLine] = `${indentation}public_key: ${publicKey}`;
}

const temporaryPath = join(dirname(configPath), `.app_updater.yaml.${process.pid}.tmp`);
await writeFile(temporaryPath, lines.join('\n'), { mode: 0o600 });
await rename(temporaryPath, configPath);
console.log(`Synchronized sample app dev keyring: ${configPath}`);
