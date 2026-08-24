import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { pool } from './db.js';

const migrationsDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'migrations',
);

const legacyMarkers = {
  '001_init.sql': `select to_regclass('public.apps') is not null as present`,
  '002_operators.sql': `select to_regclass('public.operators') is not null as present`,
  '003_users.sql': `select to_regclass('public.users') is not null as present`,
  '004_root_users.sql': `select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'users' and column_name = 'is_root'
  ) as present`,
  '005_publish_keys.sql': `select to_regclass('public.app_publish_keys') is not null as present`,
  '006_cli_releases.sql': `select to_regclass('public.releases') is not null as present`,
};

async function migrate() {
  const client = await pool.connect();
  try {
    await client.query('select pg_advisory_lock($1)', [73912461]);
    await client.query(`create table if not exists schema_migrations (
      name text primary key,
      applied_at timestamptz not null default now()
    )`);
    const files = (await readdir(migrationsDir))
      .filter((name) => /^\d+_.+\.sql$/.test(name))
      .sort();
    for (const name of files) {
      const applied = await client.query(
        'select 1 from schema_migrations where name = $1',
        [name],
      );
      if (applied.rowCount) continue;

      const marker = legacyMarkers[name];
      if (marker) {
        const existing = await client.query(marker);
        if (existing.rows[0]?.present) {
          await client.query('insert into schema_migrations (name) values ($1)', [name]);
          console.log(`Baselined existing migration ${name}`);
          continue;
        }
      }

      const sql = await readFile(path.join(migrationsDir, name), 'utf8');
      await client.query('begin');
      try {
        await client.query(sql);
        await client.query('insert into schema_migrations (name) values ($1)', [name]);
        await client.query('commit');
        console.log(`Applied migration ${name}`);
      } catch (error) {
        await client.query('rollback');
        throw error;
      }
    }
  } finally {
    await client.query('select pg_advisory_unlock($1)', [73912461]).catch(() => {});
    client.release();
    await pool.end();
  }
}

migrate().catch((error) => {
  console.error('Migration failed', error);
  process.exitCode = 1;
});
