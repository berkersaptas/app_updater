# App Updater for Flutter

App Updater is a self-hosted, Shorebird-style OTA update system for Dart-only fixes in Android
Flutter applications. Native code, plugins, Android resources, assets, and new store versions still
go through Google Play. iOS code push is intentionally out of scope; iOS releases continue through
App Store Connect and TestFlight.

This guide starts from a developer machine where App Updater has never been installed.

## 1. Install the `app_updater` command

`app_updater` is not an operating-system command. It is the executable exposed by the Dart CLI
package in this repository. Install it once:

```text
dart pub global activate --source git https://github.com/berkersaptas/app_updater.git --git-path app_updater_cli
```

The repository is public and installs directly. No additional dependency service or repository
configuration is required.

Dart places globally activated commands in:

- macOS/Linux: `$HOME/.pub-cache/bin`
- Windows: `%LOCALAPPDATA%\Pub\Cache\bin`

Add that directory to `PATH` if Dart reports that activation succeeded but the terminal cannot find
the command. For Zsh on macOS:

```bash
echo 'export PATH="$HOME/.pub-cache/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

On Windows, add `%LOCALAPPDATA%\Pub\Cache\bin` to the user `Path` environment variable and open a
new PowerShell window.

Verify the installation:

```bash
# macOS/Linux
which app_updater
app_updater --help
```

```powershell
# Windows
where.exe app_updater
app_updater --help
```

The main commands are:

```text
login
logout
init
release
patch
publish
```

`publish` is the legacy flow for installations that manage their own signing material. New
applications should use `login`, `init`, `release`, and `patch`.

## 2. Prerequisites

Flutter includes the Dart SDK. Install Flutter, Git, Android Studio/Android SDK, and a JDK. The
normal `login`, `init`, `release`, and `patch` flow does not require Bash, WSL, `curl`, `unzip`, or
other Unix tools. Check the toolchain with:

```bash
flutter --version
dart --version
git --version
java -version
jar --version
flutter doctor
```

To update the CLI later, run the same `dart pub global activate` command again.

## 3. Sign in to the App Updater service

The backend must be running, and the developer must have an email/password account created through
its web portal. Sign in once on each development machine:

```bash
app_updater login --backend-url https://updates.example.com
```

The CLI asks for the account email and password and creates a revocable 90-day CLI session. Session
information is stored with user-only permissions at:

```text
~/.app_updater/credentials.json
```

On Windows, the same `.app_updater/credentials.json` path is created under the current user's home
directory. Later commands reuse this session without asking for the password again.

To revoke the server session and remove the local credentials:

```bash
app_updater logout
```

## 4. Connect a Flutter application

Open a terminal at the Flutter project root:

```bash
cd /path/to/my_flutter_app
```

Create the application in the backend and connect the project:

```text
app_updater init --create --app-slug my-app-android --package-name com.company.my_app
```

If the application already exists or a teammate has granted access:

```bash
app_updater init --app-slug my-app-android
```

`init`:

- writes the public `app_updater.yaml` runtime configuration;
- adds the public `app_updater` Flutter dependency;
- changes `MainActivity` to extend `FlutterOtaActivity`;
- adds `AppUpdater.instance.autoUpdate()` to a standard `lib/main.dart` entry point;
- creates the app owner and an RSA-3072 managed signer when `--create` is used.

The private signing key is never sent to the developer. The backend encrypts it with AES-256-GCM
under `SIGNING_MASTER_KEY` and uses it only to sign validated patch manifests.

For a non-standard Android project or `main.dart` layout, the CLI stops and prints the required
manual edit instead of guessing.

Verify the first integration:

```bash
flutter pub get
flutter analyze
flutter build apk --debug
```

## 5. Create the first Google Play release

Start with a normal Flutter version in `pubspec.yaml`:

```yaml
version: 1.0.0+1
```

Build and register the release:

```bash
app_updater release android
```

The command:

1. builds an AAB with `flutter build appbundle --release`;
2. validates the target ABI's `libapp.so`;
3. records the release, Flutter engine, Dart version, ABI, source commit, and AAB hash;
4. stores the AAB as the immutable patch base for this release;
5. prints the exact artifact that must be uploaded to Play Console.

Example output:

```text
Registered my-app-android release 1.0.0+1 (arm64-v8a).
Upload this exact artifact to Play:
.../build/app/outputs/bundle/release/app-release.aab
```

Upload that exact AAB. The artifact stored by App Updater and the artifact submitted to Google Play
must be the same build.

## 6. Publish a Dart-only hotfix

Fix the Dart code without changing the `pubspec.yaml` version:

```yaml
version: 1.0.0+1
```

Then run:

```bash
app_updater patch android
```

The CLI automatically:

1. downloads the registered base AAB for `1.0.0+1` and the target ABI;
2. builds a patch AAB from the current source;
3. compares the base and patch bundle contents;
4. creates a binary diff and uploads it to the backend.

Only Dart's `base/lib/<abi>/libapp.so` output and its
`BUNDLE-METADATA/.../libapp.so.sym` debug metadata may change. The patch is rejected and a new Play
release is required if any of these change:

- Android manifest or DEX content;
- native or plugin libraries;
- Android resources;
- Flutter assets;
- Flutter engine or Dart SDK;
- ABI or build mode.

The backend revalidates compatibility, assigns the next patch number, signs the manifest with the
managed RSA signer, and publishes the diff. The developer does not manage patch numbers, manifests,
signing keys, or local base APK/AAB paths.

## 7. What happens on the device?

The device runs the `1.0.0+1` release installed from Google Play. After startup, the updater checks
the backend using the installed release, ABI, and current patch number.

When a patch is available:

1. the manifest schema, trusted key, and RSA signature are verified;
2. the diff is downloaded and its declared size is checked;
3. the diff is applied to the base `libapp.so` from the installed APK;
4. the reconstructed `libapp.so` SHA-256 hash is verified;
5. the patch is staged atomically for the next launch.

The current launch continues on the store release. The patch is verified again and activated on the
next cold launch. If it cannot boot successfully, the runtime falls back to the last-known-good
patch or the library bundled in the APK. Bad patches are quarantined to prevent crash loops.

The complete flow has been verified on a Xiaomi 2211133G running Android 16/API 36 on arm64-v8a:

```text
Release: 1.0.0+1
First launch: Hello v1
Patch: 2, managed RSA, 34,608-byte binary diff
Second cold launch: Hello v2
Runtime state: active
Steady state: OtaNoUpdateAvailable
```

## 8. Move to a new store version

Increment the Flutter version:

```yaml
version: 1.1.0+2
```

Register the new store build:

```bash
app_updater release android
```

Release lines remain independent:

```text
1.0.0+1
  ├── patch 1
  └── patch 2

1.1.0+2
  └── no patches yet
```

Users who have not updated from Play remain on the `1.0.0+1` patch line. Users who install the new
store release move to `1.1.0+2`. A patch for the old release can never run on the new release. To
hotfix `1.1.0+2`, keep that version unchanged and run `app_updater patch android`.

A new store release does not require resetting App Updater or onboarding the application again.

## Daily workflow

Once per development machine:

```text
dart pub global activate --source git https://github.com/berkersaptas/app_updater.git --git-path app_updater_cli
app_updater login --backend-url https://updates.example.com
```

Once per Flutter project:

```bash
app_updater init --app-slug my-app-android
```

For every Google Play version:

```bash
app_updater release android
```

For every Dart-only hotfix to that version:

```bash
app_updater patch android
```

## Command flow

```text
app_updater release android
  → global Dart executable
  → saved App Updater session
  → pubspec.yaml + app_updater.yaml
  → flutter build appbundle --release
  → immutable release base uploaded to the backend
```

## Further documentation

- [GETTING_STARTED.md](GETTING_STARTED.md): local backend setup and short onboarding guide.
- [app_updater_cli/README.md](app_updater_cli/README.md): CLI behavior and legacy commands.
- [app_updater/README.md](app_updater/README.md): Flutter plugin API and integration details.
- [backend/README.md](backend/README.md): backend operation and endpoints.
- [docs/google_play_compliance.md](docs/google_play_compliance.md): Google Play and Dart-only
  boundaries.
- [docs/architecture_and_remaining_work.md](docs/architecture_and_remaining_work.md): architecture
  and remaining operational production work.

## Maintainer acceptance tests

The provider, rollback, and device lifecycle suite is intended for repository maintainers:
These repository-level acceptance helpers are Bash scripts; on Windows, run them from WSL or Git
Bash. Application developers do not need these scripts for `release` or `patch`.

Windows maintainers can run the native CLI/plugin/runtime verification suite from PowerShell:

```powershell
.\scripts\verify_windows_cli.ps1
```

```bash
./scripts/run_device_acceptance.sh
```

The network binary-diff acceptance suite resets the backend database and reinstalls the test APK:

```bash
./scripts/run_binary_diff_acceptance.sh
```

Do not run the second script against a real or shared backend; it executes
`docker compose down -v`.

## Production boundary

The code path and developer workflow have been verified on a real device. A fleet production
deployment still requires HTTPS and a reverse proxy, durable artifact storage or CDN, managed
Postgres with backups, monitoring and alerting, staged rollout controls, signer rotation, and
KMS/HSM-backed signing custody.

App Updater is not a store-policy bypass mechanism. The publisher remains responsible for the
Google Play compliance of every application and patch.
