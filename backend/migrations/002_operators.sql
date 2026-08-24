create table operators (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  api_key_hash text not null unique,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);

create table admin_actions (
  id uuid primary key default gen_random_uuid(),
  operator_name text not null,
  method text not null,
  path text not null,
  status_code int,
  created_at timestamptz not null default now()
);

create index admin_actions_created_idx on admin_actions (created_at);
