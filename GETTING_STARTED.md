# Getting started

App Updater is a self-hosted Android OTA system for Dart-only Flutter fixes. Native,
plugin, Android resource, and asset changes still go through Google Play.

Use this file for a quick local evaluation. For a production installation, begin with the
[production server installation guide](docs/server_installation.md), then return to
[the first production setup](README.md#first-production-setup) to
connect a developer machine, Flutter application, store release, and test device.

## Run the service

For local development:

```bash
docker compose up -d --build
curl http://localhost:8081/healthz
curl http://localhost:8081/readyz
```

PowerShell health check:

```powershell
Invoke-WebRequest http://localhost:8081/healthz
```

The backend runs numbered database migrations automatically on startup, including for an existing
Postgres volume. Before production, set strong values for `SESSION_SECRET`, `ADMIN_API_KEY`, and
the exactly 32-byte `SIGNING_MASTER_KEY`; use HTTPS, `TRUST_PROXY=true`, `SECURE_COOKIES=true`, and
durable database/artifact backups. The Compose defaults are development-only and must not be
exposed to the internet.

## Install and connect

Install once:

```text
dart pub global activate --source git https://github.com/berkersaptas/app_updater.git --git-path app_updater_cli
```

The connected CLI workflow is native on Windows, macOS, and Linux. Windows requires Flutter, Git,
Android SDK, and a JDK on `PATH`; it does not require WSL or Git Bash.

Register an email/password account at `http://localhost:8081/`, then from the Flutter project:

```bash
app_updater login --backend-url http://localhost:8081
app_updater init --create --app-slug my-app-android --package-name com.example.my_app
```

For an app already created by a teammate or in the portal, omit `--create` and `--package-name`:

```bash
app_updater init --app-slug my-app-android
```

There are no API or signing keys to copy. `login` stores a revocable session locally; `init`
downloads only the public runtime configuration and performs the standard Flutter/Android edits.

## Normal release lifecycle

Before submitting each new `pubspec.yaml` version to Play:

```bash
app_updater release android
```

Upload the exact printed `app-release.aab` to Play. App Updater stores it as the immutable base for that
version.

For later Dart-only fixes while `pubspec.yaml` still has that version:

```bash
app_updater patch android
```

When you increment the version for a new market release, run `app_updater release android` again and
upload that newly built AAB. Nothing must be reset: each installed version identifies itself as
`versionName+versionCode`, and the backend serves only patches built for that exact release and ABI.
Older users remain on the older patch line until they update from Play.

`patch android` downloads the correct base automatically and blocks changes outside Dart's
`libapp.so` (the corresponding AAB Dart-symbol metadata may change with it). It also blocks a
different Flutter/Dart toolchain. A native/plugin/resource/asset
change therefore produces a clear instruction to create another Play release instead of an unsafe
OTA update.

The web portal remains useful for teammates, patch visibility, and emergency enable/disable. The
old `app_updater publish` plus manually managed keys remains compatible for legacy apps, but it is not
the recommended onboarding path.

## Expected device behavior

The release launches normally while the updater downloads and stages a patch in the background.
The patch becomes active on the next cold launch; a successfully active device then reports no
update available. This exact connected flow was verified on Android 16/arm64: `Hello v1` on the
release launch, `Hello v2` and patch state `active` on the following launch.

See [app_updater_cli/README.md](app_updater_cli/README.md) for CLI options,
[docs/google_play_compliance.md](docs/google_play_compliance.md) for the policy boundary, and
[backend/README.md](backend/README.md) for operating the service.
