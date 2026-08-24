import 'dotenv/config';
import { fullAotLibraryAllowedFromEnv } from './artifactPolicy.js';

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

export const config = {
  port: Number(process.env.PORT ?? 8080),
  databaseUrl: required('DATABASE_URL'),
  adminApiKey: required('ADMIN_API_KEY'),
  artifactStorageDir: process.env.ARTIFACT_STORAGE_DIR ?? '/data/artifacts',
  sessionSecret: required('SESSION_SECRET'),
  // Safe-by-default Play/production posture: only Shorebird-style binary diffs may be uploaded.
  // Local POC environments that deliberately exercise whole-libapp replacement must opt in.
  allowFullAotLibrary: fullAotLibraryAllowedFromEnv(),
  signingMasterKey: required('SIGNING_MASTER_KEY'),
};
