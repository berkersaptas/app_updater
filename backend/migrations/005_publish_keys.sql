create table app_publish_keys (
  id uuid primary key default gen_random_uuid(),
  app_id uuid not null references apps(id) on delete cascade,
  created_by uuid references users(id) on delete set null,
  label text not null,
  api_key_hash text not null unique,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);

create index app_publish_keys_app_idx on app_publish_keys (app_id);
