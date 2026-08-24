create table cli_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  label text not null,
  token_hash text not null unique,
  revoked boolean not null default false,
  expires_at timestamptz not null,
  last_used_at timestamptz,
  created_at timestamptz not null default now()
);
create index cli_tokens_user_idx on cli_tokens (user_id, created_at desc);

create table app_managed_signers (
  app_id uuid primary key references apps(id) on delete cascade,
  key_id text not null,
  algorithm text not null check (algorithm in ('rsa_pkcs1_sha256')),
  encrypted_private_key text not null,
  encryption_iv text not null,
  encryption_tag text not null,
  created_at timestamptz not null default now()
);

create table releases (
  id uuid primary key default gen_random_uuid(),
  app_id uuid not null references apps(id) on delete cascade,
  release_version text not null,
  engine_revision text not null,
  dart_version text not null,
  build_mode text not null default 'release' check (build_mode = 'release'),
  source_commit text,
  created_by uuid references users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (app_id, release_version)
);

create table release_artifacts (
  id uuid primary key default gen_random_uuid(),
  release_id uuid not null references releases(id) on delete cascade,
  abi text not null,
  artifact_relative_path text not null,
  artifact_sha256 text not null,
  artifact_size bigint not null,
  created_at timestamptz not null default now(),
  unique (release_id, abi)
);
