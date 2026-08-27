# Application onboarding

This guide is for a Flutter developer connecting an application to an **existing shared App Updater
backend**. You do not need Docker, PostgreSQL, Nginx, or server access.

Before starting, obtain these from your platform administrator or application owner:

- the backend HTTPS URL, for example `https://updates.example.com`;
- permission to register a portal account, or an invitation to the application;
- the application slug if the application already exists.

If you are responsible for deploying the shared backend itself, stop here and use the
[server installation guide](docs/server_installation.md). A backend is installed once per
organization/environment, not once per developer or application.

## 1. Install the CLI

The developer or CI machine needs Flutter, Dart, Git, Android SDK, and a JDK. Use the same pinned
Flutter version that builds the application distributed through Google Play.

Install the CLI once:

```text
dart pub global activate --source git https://github.com/berkersaptas/app_updater.git --git-path app_updater_cli
```

Dart places global executables in:

- macOS/Linux: `$HOME/.pub-cache/bin`
- Windows: `%LOCALAPPDATA%\Pub\Cache\bin`

Add that directory to `PATH`, restart the terminal if necessary, and verify:

```bash
app_updater --help
```

Windows is supported without WSL or Git Bash.

## 2. Create an account and sign in

Open the backend URL in a browser. Register if self-registration is enabled. Otherwise ask an
administrator to enable access and an application owner to add your account to the application.

Authenticate the CLI:

```bash
app_updater login --backend-url https://updates.example.com
```

The CLI stores a revocable 90-day session with user-only filesystem permissions. It does not store
the backend's private signing key. End the session with:

```bash
app_updater logout
```

## 3. Connect the Flutter application

Open a terminal in the Flutter project root.

### Create a new application

Use this when no application record exists on the backend:

```bash
app_updater init \
  --create \
  --app-slug my-app-android \
  --package-name com.company.my_app
```

You become the application owner. The backend creates a managed signing key and the CLI downloads
only its public key. The launcher logo is discovered and uploaded when possible.

### Connect an existing application

Ask an owner to add your registered email as a member, then run:

```bash
app_updater init --app-slug my-app-android
```

`init` performs the standard project integration:

- creates the public `app_updater.yaml` configuration;
- adds the `app_updater` Flutter dependency;
- changes `MainActivity` to extend `FlutterOtaActivity`;
- adds automatic update startup to a standard `lib/main.dart`;
- uploads or retains the application logo according to the selected options.

The command is idempotent. Review all source changes before committing them.

Verify the connected project:

```bash
flutter pub get
flutter analyze
flutter build apk --debug
```

## 4. Register the first store release

Set the intended Google Play version in `pubspec.yaml`, use the correct production signing
configuration, and run:

```bash
app_updater release android
```

The command builds and uploads the release base with its exact Flutter/Dart/build identity. It then
prints an AAB path.

> [!IMPORTANT]
> Upload that exact AAB file to Google Play. Rebuilding afterward and uploading a different AAB can
> break the base identity required for future patches.

Keep the Flutter version and build environment reproducible in CI. Every new Google Play version
requires another `app_updater release android` before store submission.

## 5. Publish a Dart-only patch

Keep `pubspec.yaml` on the same store version and make only a supported Dart change:

```bash
app_updater patch android
```

The command:

1. resolves and downloads the registered store base;
2. builds the candidate with the current application toolchain;
3. rejects changes outside allowed Dart AOT output;
4. creates and uploads the binary diff;
5. receives a backend-signed manifest tied to that exact release.

If the change includes native code, a plugin with native code, manifest entries, permissions,
resources, assets, Flutter SDK, Dart SDK, ABI, or application version, create a new store release
instead.

## 6. Verify on a test device

Use a Google Play internal-testing build for the closest production test:

1. Install and open the registered store build. The application uses its packaged base normally.
2. Publish a visible Dart-only test change.
3. Cold-start the application. The patch is checked, downloaded, verified, and staged in the
   background.
4. Cold-start it again. The staged patch should now be active.
5. Disable the patch in the portal and verify fallback behavior on subsequent cold launches.

For the full positive and negative test matrix, follow
[end-to-end acceptance testing](docs/end_to_end_testing.md).

## Normal workflow after onboarding

```text
New Google Play version
    change version → app_updater release android → upload printed AAB

Dart-only fix for that version
    make Dart change → app_updater patch android → verify on test device
```

Users on older store versions remain on their own compatible release/patch line. The backend never
sends them a patch built for another version or Flutter toolchain.

## Common mistakes

### I do not have a backend URL

Ask the person responsible for your organization's shared infrastructure. Only that person should
follow [server installation](docs/server_installation.md). Application developers should not create
independent local production servers.

### `app_updater` is not found

Add Dart's global executable directory to `PATH` and restart the terminal.

### The store AAB was uploaded before `release`

Do not build a second AAB and pretend it is the same base. Register and publish a new store version.

### A patch is rejected

Read the CLI's changed-entry report. Restore native/resource/toolchain changes or publish a new
store release.

### A device downloads but does not immediately show the patch

This is expected. One launch stages the verified patch; the next cold launch activates it.

## Related documentation

- [CLI command reference](app_updater_cli/README.md)
- [Flutter package reference](app_updater/README.md)
- [Google Play compliance](docs/google_play_compliance.md)
- [Release and rollback behavior](docs/rollback_model.md)
