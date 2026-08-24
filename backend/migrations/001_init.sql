create extension if not exists pgcrypto;

create table apps (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  platform text not null check (platform in ('android', 'ios')),
  package_name text not null,
  created_at timestamptz not null default now()
);

create table app_keys (
  id uuid primary key default gen_random_uuid(),
  app_id uuid not null references apps(id) on delete cascade,
  key_id text not null,
  public_key_der_base64url text not null,
  algorithm text not null check (algorithm in ('ed25519', 'rsa_pkcs1_sha256')),
  active boolean not null default true,
  revoked boolean not null default false,
  created_at timestamptz not null default now(),
  unique (app_id, key_id)
);

create table patches (
  id uuid primary key default gen_random_uuid(),
  app_id uuid not null references apps(id) on delete cascade,
  manifest jsonb not null,
  release text generated always as (manifest ->> 'release') stored,
  patch_number int generated always as ((manifest ->> 'patch_number')::int) stored,
  artifact_kind text generated always as (manifest ->> 'artifact_kind') stored,
  abi text generated always as (manifest ->> 'abi') stored,
  build_mode text generated always as (manifest ->> 'build_mode') stored,
  channel text not null default 'stable',
  enabled boolean not null default true,
  artifact_relative_path text not null,
  artifact_size bigint not null,
  created_at timestamptz not null default now(),
  unique (app_id, patch_number)
);

create index patches_lookup_idx on patches (app_id, release, abi, build_mode, enabled);

create table patch_events (
  id uuid primary key default gen_random_uuid(),
  app_id uuid not null references apps(id) on delete cascade,
  patch_number int,
  event_type text not null,
  release_version text,
  platform text,
  arch text,
  payload jsonb not null,
  created_at timestamptz not null default now()
);

create index patch_events_app_idx on patch_events (app_id, created_at);
