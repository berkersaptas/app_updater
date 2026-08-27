# Production Server Installation

This guide deploys the App Updater backend on a Linux server behind HTTPS. It uses Docker Compose,
a managed PostgreSQL database, and persistent filesystem storage for release, patch, and application
logo artifacts.

The server does **not** need Flutter, Dart, the Android SDK, Java, Xcode, or an iOS toolchain.
Flutter builds and binary-diff generation happen on a developer machine or in CI. The server only
authenticates users, stores metadata and artifacts, validates uploads, signs managed patch metadata,
and serves device requests.

## Recommended production topology

```text
Flutter developers / CI ─┐
Android applications ────┼── HTTPS ── reverse proxy ── backend:8080 ── PostgreSQL
Portal users ─────────────┘                         └── persistent artifact directory
```

- Publish only ports `80` and `443` to the internet.
- Bind the backend to loopback or a private container network.
- Do not expose PostgreSQL publicly.
- Run one backend replica with the current filesystem artifact implementation. Multiple replicas
  require a shared POSIX filesystem and additional concurrency testing.
- Use a DNS name such as `updates.example.com`; mobile clients must never depend on a private IP,
  `localhost`, or `adb reverse` in production.

## 1. Requirements

- A supported Linux server with Docker Engine and Docker Compose v2
- A DNS record pointing the chosen hostname to the server
- A valid TLS certificate, normally managed by the reverse proxy or your infrastructure
- PostgreSQL 16 or a compatible managed PostgreSQL service
- Persistent storage large enough for release snapshots, patches, and logos
- A backup destination separate from the application server

Size CPU, memory, database connections, storage, and bandwidth from your application count, release
size, patch frequency, device population, and retention policy. Artifact downloads usually dominate
bandwidth and storage.

At the network boundary, allow administrative SSH only from trusted source addresses, allow public
HTTP/HTTPS on `80`/`443`, and deny public access to backend port `8080` and PostgreSQL port `5432`.

## 2. Prepare directories and secrets

The following paths are examples. Keep the repository, runtime data, and secrets separate:

```text
/opt/app-updater/                 checked-out repository
/etc/app-updater/backend.env      production environment variables
/srv/app-updater/artifacts/       persistent artifact storage
```

Copy or clone the repository to `/opt/app-updater`, then check out a reviewed release tag or exact
commit. Install Docker Engine, the Docker Compose plugin, and Nginx using the supported package
source for your Linux distribution. Confirm the runtime before continuing:

```bash
docker version
docker compose version
nginx -v
```

Provision a dedicated PostgreSQL database and login role through your managed database console or
as a database administrator. Make the application role the database owner, or grant it permission
to create tables, indexes, and the trusted `pgcrypto` extension used by the first migration. Do not
reuse a PostgreSQL superuser in `DATABASE_URL`. Verify TLS, firewall rules, and connectivity from the
application server before starting the backend.

Create three independent secrets:

```bash
openssl rand -hex 32  # SESSION_SECRET
openssl rand -hex 32  # ADMIN_API_KEY
openssl rand -hex 16  # SIGNING_MASTER_KEY: exactly 32 ASCII bytes
```

Store them in your secret manager. If a root-readable environment file is used, restrict it to
mode `600`. Back up `SIGNING_MASTER_KEY` separately: losing or changing it makes existing managed
application signing keys unreadable. Do not commit secrets to the repository.

Create `/etc/app-updater/backend.env` with production values:

```dotenv
DATABASE_URL=postgresql://app_updater:REPLACE_ME@db.example.internal:5432/app_updater?sslmode=require
PORT=8080
ARTIFACT_STORAGE_DIR=/data/artifacts

ADMIN_API_KEY=REPLACE_WITH_A_LONG_RANDOM_VALUE
SESSION_SECRET=REPLACE_WITH_A_LONG_RANDOM_VALUE
SIGNING_MASTER_KEY=REPLACE_WITH_EXACTLY_32_BYTES

ALLOW_FULL_AOT_LIBRARY=false
TRUST_PROXY=true
SECURE_COOKIES=true
```

`TRUST_PROXY=true` tells the backend to trust one directly connected reverse proxy. Enable it only
when clients cannot connect directly to the backend port. The proxy must replace, rather than append
untrusted values to, `X-Forwarded-Proto` and related headers. `SECURE_COOKIES=true` requires HTTPS and
prevents portal session cookies from being sent over plain HTTP.

Keep `ALLOW_FULL_AOT_LIBRARY=false` in production. Production distribution is based on release-bound
binary differences, not unrestricted whole-library replacement.

## 3. Create a production Compose file

The repository's `docker-compose.yml` includes a local PostgreSQL service and development defaults.
Do not use those defaults for production. Create `/opt/app-updater/compose.production.yml`:

```yaml
services:
  backend:
    build:
      context: .
      dockerfile: backend/Dockerfile
    restart: unless-stopped
    env_file:
      - /etc/app-updater/backend.env
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - /srv/app-updater/artifacts:/data/artifacts
```

Ensure the mounted artifact directory is writable by the container. The backend automatically runs
numbered database migrations at startup under a PostgreSQL advisory lock, so concurrent migration
execution is prevented.

Build and start the service from a reviewed release tag or commit:

```bash
cd /opt/app-updater
docker compose -f compose.production.yml build --pull
docker compose -f compose.production.yml up -d
docker compose -f compose.production.yml logs --tail=100 backend
```

## 4. Configure HTTPS reverse proxying

The example below uses Nginx. Set the upload limit above the backend's 500 MB request limit and allow
enough time for large uploads and downloads.

```nginx
server {
    listen 80;
    server_name updates.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name updates.example.com;

    ssl_certificate     /etc/letsencrypt/live/updates.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/updates.example.com/privkey.pem;

    client_max_body_size 550m;
    proxy_read_timeout 900s;
    proxy_send_timeout 900s;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

Use your organization's standard TLS policy, certificate automation, WAF, request throttling, and
DDoS controls. Restrict `/auth/register` through VPN, identity-aware proxy, or another controlled
onboarding mechanism if public self-registration is not desired. The backend currently permits
account registration by default.

## 5. Validate the installation

The liveness endpoint confirms that the HTTP process is running. The readiness endpoint also checks
the database connection:

```bash
curl --fail https://updates.example.com/healthz
curl --fail https://updates.example.com/readyz
```

Both should return `{"ok":true}`. Then perform a real acceptance flow:

1. Open `https://updates.example.com`, register the first portal account, and sign in.
2. Install the CLI on a Flutter developer machine or CI runner, not on the server.
3. Run `app_updater login --backend-url https://updates.example.com`.
4. Connect a test application with `app_updater init --create --app-slug test-app-android`.
5. Build and register a store-equivalent base with `app_updater release android`.
6. Make a Dart-only change and publish it with `app_updater patch android`.
7. Verify download, staged activation, event reporting, disabling, and rollback on a test device.

The complete application-side procedure and negative-path checks are in the
[first-time end-to-end walkthrough](../README.md#first-time-user-end-to-end-walkthrough).

## 6. Multiple applications and Flutter versions

A single backend can serve many applications built with different Flutter versions. Flutter is not
installed on the server and there is no global server-side Flutter version. Compatibility is scoped
to each immutable application release:

- Application slug separates applications.
- Platform and release identity separate Android builds.
- Exact build metadata ties each patch to the matching store base.
- The CLI uses the Flutter toolchain belonging to that application's repository to produce its
  release snapshot and patch.
- A device only receives a patch compatible with its own registered base; it does not receive the
  newest patch from an unrelated Flutter version or store release.

CI should pin Flutter independently for every application, for example with a version manager or a
container image. Never generate a patch with a different toolchain or source baseline from the store
binary it targets. If a base was published without being registered, ship and register a new store
release; do not guess its compatibility metadata afterward.

## 7. Backups and recovery

A usable backup consists of one consistent set of:

- PostgreSQL data
- The complete artifact directory
- `SIGNING_MASTER_KEY` and the remaining production secrets
- The deployed source revision and environment configuration, without exposing secret values

Use managed database snapshots or `pg_dump`, and snapshot the artifact volume on a coordinated
schedule. Keep copies encrypted, off-host, access-controlled, and retention-tested. Regularly
restore into an isolated environment and run `/readyz`, portal login, patch check, and artifact
download tests.

For disaster recovery, stop writes, restore the database and matching artifact snapshot, restore the
original signing master key, start the backend, and validate readiness before restoring traffic.
A database-only backup may reference missing artifact files; an artifact-only backup lacks release,
authorization, signing, and audit metadata.

## 8. Upgrade and rollback

Before every upgrade:

1. Read the release notes and inspect new migrations.
2. Take and verify database, artifact, and secret backups.
3. Check out the intended tag or commit.
4. Rebuild and start the backend.
5. Confirm `/healthz`, `/readyz`, portal login, and a test patch check.

```bash
cd /opt/app-updater
docker compose -f compose.production.yml build --pull
docker compose -f compose.production.yml up -d
docker compose -f compose.production.yml logs --tail=100 backend
```

Do not run `docker compose down -v`; it can delete named data volumes. Database migrations are
forward-applied automatically and may not be reversible by merely starting an older image. When an
upgrade cannot be safely rolled back in place, restore the pre-upgrade database and artifact backup.

## 9. Monitoring and operations

Monitor at least:

- `/healthz` for process liveness and `/readyz` for database readiness
- HTTP latency, `4xx`/`5xx` rates, and upload/download failures
- PostgreSQL availability, connections, storage, and backup freshness
- Artifact volume capacity, inode usage, and backup freshness
- TLS certificate expiry and DNS health
- Patch failure/crash-loop events and administrative audit records

Keep one backend replica unless shared artifact storage has been explicitly introduced and tested.
For large device populations, migrate artifacts to durable object storage/CDN before horizontal
scaling; the current implementation natively writes to a POSIX filesystem.

## 10. Troubleshooting

### Portal login succeeds but immediately returns to the login page

Confirm the browser uses HTTPS, `TRUST_PROXY=true`, `SECURE_COOKIES=true`, and the reverse proxy sends
`X-Forwarded-Proto: https`. Also ensure the backend is not directly reachable from the internet.

### Generated configuration contains an `http://` backend URL

The proxy is not forwarding the original HTTPS protocol or the backend is not trusting the direct
proxy. Check `X-Forwarded-Proto` and `TRUST_PROXY`.

### Upload returns HTTP 413

Increase the reverse proxy request-body limit. The Nginx example uses `550m` to leave headroom above
the backend's 500 MB limit.

### `/healthz` works but `/readyz` fails

The process is alive but PostgreSQL is unavailable or `DATABASE_URL` is invalid. Inspect backend and
database logs, network policy, credentials, TLS settings, and connection limits.

### Managed signing fails after a server migration

Verify that the original, exactly 32-byte `SIGNING_MASTER_KEY` was restored unchanged. Replacing it
does not re-encrypt existing managed private keys.

### Devices cannot check for patches

Verify public DNS and certificate chains from the device network, not only from the server. Confirm
the device configuration uses the public HTTPS URL and that firewall/WAF rules allow the patch-check,
artifact-download, and event endpoints.

## Production security checklist

- [ ] Only HTTPS is public; backend and database ports are private.
- [ ] Production secrets are unique, access-controlled, backed up, and absent from Git.
- [ ] `TRUST_PROXY=true` is used only behind one controlled reverse proxy.
- [ ] `SECURE_COOKIES=true` and `ALLOW_FULL_AOT_LIBRARY=false`.
- [ ] Public registration is intentionally allowed or restricted externally.
- [ ] PostgreSQL and artifact backups have passed a restoration test.
- [ ] Artifact storage capacity and integrity are monitored.
- [ ] Root bootstrap credentials are not used for routine publishing.
- [ ] Signer rotation, key revocation, patch disablement, and incident rollback are rehearsed.
- [ ] A canary/test-device process is used before broad activation.
