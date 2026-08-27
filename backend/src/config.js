import 'dotenv/config';
import { fullAotLibraryAllowedFromEnv } from './artifactPolicy.js';

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

function booleanValue(name, defaultValue = false) {
  const value = process.env[name];
  if (value == null || value === '') return defaultValue;
  if (['true', '1'].includes(value.toLowerCase())) return true;
  if (['false', '0'].includes(value.toLowerCase())) return false;
  throw new Error(`${name} must be true/false or 1/0`);
}

export const config = {
  port: Number(process.env.PORT ?? 8080),
  databaseUrl: required('DATABASE_URL'),
  adminApiKey: required('ADMIN_API_KEY'),
  artifactStorageDir: process.env.ARTIFACT_STORAGE_DIR ?? '/data/artifacts',
  sessionSecret: required('SESSION_SECRET'),
  // Safe-by-default Play/production posture: only release-bound binary diffs may be uploaded.
  // Local POC environments that deliberately exercise whole-libapp replacement must opt in.
  allowFullAotLibrary: fullAotLibraryAllowedFromEnv(),
  signingMasterKey: required('SIGNING_MASTER_KEY'),
  // Enable only when exactly one trusted reverse proxy sits in front of Express.
  trustProxy: booleanValue('TRUST_PROXY'),
  // Production HTTPS deployments should opt in after TRUST_PROXY is enabled.
  secureCookies: booleanValue('SECURE_COOKIES'),
};
