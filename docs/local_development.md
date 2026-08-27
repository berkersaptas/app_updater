# Local Development

This guide is for repository contributors and isolated evaluation. It runs a development backend
and PostgreSQL on the same computer.

> [!WARNING]
> Application developers connecting to an existing organizational backend do not need this setup.
> Use [application onboarding](../GETTING_STARTED.md). The local Compose secrets, passwords, ports,
> and plain HTTP endpoint are not suitable for production.

## Prerequisites

- Docker Engine and Docker Compose v2
- Flutter and Dart SDKs
- Git
- Android SDK
- JDK, including `jar`
- An Android device or emulator for runtime testing

```bash
docker --version
docker compose version
flutter --version
dart --version
git --version
java -version
flutter doctor
```

## Start the local stack

From the repository root:

```bash
docker compose up -d --build
docker compose ps
curl --fail http://localhost:8081/healthz
curl --fail http://localhost:8081/readyz
```

Compose starts PostgreSQL on host port `5432`, the backend on `8081`, and persistent development
volumes for database and artifact data. Numbered migrations run automatically at backend startup.

Inspect startup problems with:

```bash
docker compose logs --tail=100 backend postgres
```

## Create a local account

Open `http://localhost:8081`, register a developer account, and then install the CLI:

```text
dart pub global activate --source git https://github.com/berkersaptas/app_updater.git --git-path app_updater_cli
```

```bash
app_updater login --backend-url http://localhost:8081
```

## Connect a disposable Flutter application

From its project root:

```bash
app_updater init \
  --create \
  --app-slug local-test-android \
  --package-name com.example.local_test

flutter pub get
flutter analyze
flutter build apk --debug
```

Do not reuse the local application slug, keys, or configuration in production.

## Reach the backend from a USB device

For an application configured with `http://localhost:8081`:

```bash
adb reverse tcp:8081 tcp:8081
```

The repository sample uses device port `8080` and host port `8081`:

```bash
adb reverse tcp:8080 tcp:8081
```

Production applications use a public HTTPS backend URL and do not use `adb reverse`.

## Run tests

Backend:

```bash
cd backend
npm ci
npm test
```

CLI and shared Dart packages:

```bash
cd app_updater_cli
dart pub get
dart test

cd ../ota_core
dart pub get
dart test
```

Flutter plugin:

```bash
cd app_updater
flutter pub get
flutter test
flutter analyze
```

Android runtime:

```bash
cd ota_runtime_android
./gradlew test
```

Portal acceptance test, run from the repository root:

```bash
./scripts/verify_portal.sh
```

For a real release/patch/device scenario, use
[end-to-end acceptance testing](end_to_end_testing.md).

## Stop the local stack

```bash
docker compose down
```

This preserves named volumes. Do not add `-v` unless you intentionally want to delete all local
database and artifact state.

## Production boundary

The local stack intentionally favors convenience. A production platform administrator must follow
[production server installation](server_installation.md), including managed secrets, HTTPS, private
networking, durable PostgreSQL and artifact backups, monitoring, and recovery testing.
