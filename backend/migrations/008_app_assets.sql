create table app_assets (
  id uuid primary key default gen_random_uuid(),
  app_id uuid not null references apps(id) on delete cascade,
  kind text not null check (kind in ('logo')),
  relative_path text not null,
  thumbnail_relative_path text not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  mime_type text not null,
  width int not null check (width > 0),
  height int not null check (height > 0),
  size bigint not null check (size > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (app_id, kind)
);

create index app_assets_app_idx on app_assets (app_id);
