create table users (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  password_hash text not null,
  created_at timestamptz not null default now()
);

create table app_members (
  app_id uuid not null references apps(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  role text not null check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (app_id, user_id)
);

create table "session" (
  sid varchar not null collate "default",
  sess json not null,
  expire timestamp(6) not null,
  primary key (sid)
);

create index session_expire_idx on "session" (expire);
