# app_updater_cli

The recommended developer workflow is four commands:

```bash
app_updater login --backend-url https://updates.example.com
app_updater init --app-slug my-app-android
app_updater release android
app_updater patch android
```

No API key, patch-signing key, hand-written manifest, archived local base APK, or `curl` command is
required. The CLI keeps a revocable 90-day login session in `~/.app_updater/credentials.json` with
user-only file permissions. The service manages each app's signing key and signs only manifests it
has validated.

## Install

```bash
dart pub global activate --source git https://github.com/berkersaptas/app_updater.git \
  --git-path app_updater_cli
```

The CLI installs directly from the public repository. Ensure `~/.pub-cache/bin` is on `PATH`.

## First-time setup

Create an account in the service's web portal, then log in once:

```bash
app_updater login --backend-url https://updates.example.com
```

From an existing Flutter project, connect an app you can access:

```bash
app_updater init --app-slug my-app-android
```

If the app does not exist yet, create it without opening another portal page:

```bash
app_updater init --create \
  --app-slug my-app-android \
  --package-name com.example.my_app
```

`init` writes the public runtime configuration, adds the Flutter dependency, switches
`MainActivity` to `FlutterOtaActivity`, and wires `autoUpdate()` into a normal
`lib/main.dart`. It is safe to run again. Unusual project layouts are left unchanged with a precise
manual instruction instead of being guessed.

## Store releases and patches

For every version that will be submitted to Google Play, run:

```bash
app_updater release android
```

This builds `app-release.aab`, registers that exact immutable AAB and its Flutter/Dart toolchain as
the patch base, then prints the artifact path. Upload that exact file to Play. This is the important
handoff: when `pubspec.yaml` later changes from `1.0.0+1` to `1.0.1+2`, the next `release android`
creates a separate base. Old installations continue to request patches for `1.0.0+1`; new installs
request patches for `1.0.1+2`.

For a Dart-only fix to the current `pubspec.yaml` version:

```bash
app_updater patch android
```

The CLI downloads the registered store base, rebuilds the app, rejects Android/native/resource/
asset/plugin changes, creates a binary diff of `libapp.so`, and uploads it. The backend verifies the
registered release, ABI, Flutter engine, and Dart version; assigns the patch number; signs the
manifest with the managed app key; and publishes it.

For AABs, the Dart-generated `libapp.so.sym` under `BUNDLE-METADATA` is allowed to change together
with `libapp.so`; it is debugging metadata and is not executable device content. All other bundle
entries remain byte-checked.

If native code, dependencies, Android files, resources, or assets changed, make a new store release
and run `app_updater release android` again. The backend rejects whole-library patches by default.

The current connected workflow targets one ABI at a time and defaults to `android-arm64`. Use
`--target-platform android-arm`, `android-x64`, or `android-arm64` as needed. Run
`app_updater <command> android --help` for all options.

The complete connected path is device-verified on Android 16/arm64: the release displayed
`Hello v1`, patch 2 staged on the first launch, and the next cold launch verified the managed RSA
signature and displayed `Hello v2` with runtime state `active`.

## Legacy workflow

`app_updater publish` remains for existing installations that manage their own private signing key,
app-scoped publish key, and archived APK. New apps should use `release android` and `patch android`.

The shell helpers under `scripts/` are bundled so a globally activated CLI does not depend on a
checkout of this infrastructure repository.
