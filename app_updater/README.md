# app_updater

Self-hosted OTA code push for Flutter — as a normal Flutter/Dart package, not a
native Android library you wire in by hand. This wraps `ota_runtime_android` (device-side patch
selection, verification, lifecycle) and `backend/` (the production installer contract) behind a
Dart API with the native/runtime machinery hidden behind the plugin boundary.

**One config file, no platform-specific editing.** Add the `pubspec.yaml` dependency, write one
`app_updater.yaml` at your Flutter project root, and one native one-liner
(`class MainActivity : FlutterOtaActivity()`) — nothing else to touch in `android/` (or, once it
exists, `ios/`). Device-verified end to end (2026-08-17): a real RSA-signed `binary_diff` patch,
served from the real Dockerized `backend/`, delivered through this exact setup with zero manual
`AndroidManifest.xml`/`build.gradle.kts` edits — see
`docs/architecture_and_remaining_work.md`.

## Install

```yaml
# pubspec.yaml
dependencies:
  app_updater:
    git:
      url: https://github.com/berkersaptas/app_updater.git
      path: app_updater
```

`app_updater.yaml` (at your Flutter project root, next to `pubspec.yaml`) is the *only* config
file. Do not hand-write its trusted key block. The connected CLI creates or selects the app and
writes the public configuration:

```bash
app_updater login --backend-url https://ota.example.com
app_updater init --create --app-slug my-app-android --package-name com.example.my_app
```

That produces exactly this shape (you never need to construct it by hand):

```yaml
app_slug: my-app-android
backend_url: https://ota.example.com
trusted_keys:
  - key_id: release-2026-q3
    algorithm: rsa_pkcs1_sha256
    public_key: <base64url-encoded DER public key>
revoked_key_ids: []
```

`app_updater/android/build.gradle.kts` reads this file **and** your project's own Flutter
toolchain (`flutter --version --machine`) automatically, every time your app builds, and generates
everything `ota_runtime_android` needs (`<meta-data>` entries) into its own manifest — which merges
into your app's final manifest. You never write or see that XML. See `sample_app/app_updater.yaml`
for a real working example (dev keys, local backend).

The public git dependency contains the canonical `ota_runtime_android` sources, which the plugin
compiles directly. No additional package repository or app-level repository edit is required.

## The one native touch point

Android's Flutter embedding needs the patched AOT library path *before* the Flutter engine (and
therefore the Dart VM, and therefore this package's own platform channel) exists. That single
requirement can't be satisfied from Dart, or from build-time codegen, no matter how the rest of this
package is shipped — startup-time AOT selection requires engine/embedding hooks, not just a pub
package. Concretely, extend `FlutterOtaActivity` instead of `FlutterActivity`:

```kotlin
// android/app/src/main/kotlin/.../MainActivity.kt
package com.example.myapp

import com.berkersaptas.app_updater.FlutterOtaActivity

class MainActivity : FlutterOtaActivity()
```

Everything else — reading your config, reporting boot success, checking for and installing
updates — is automatic or a normal Dart call.

## Dart usage

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppUpdater.instance.autoUpdate();
  runApp(const MyApp());
}
```

No arguments needed — `autoUpdate()` reports boot success and checks for an update, in the correct
order, exactly once, after the first frame renders, using `app_slug`/`backend_url` from
`app_updater.yaml`. Pass `baseUrl`/`appSlug` explicitly only to override the config file for a
specific call (e.g.
pointing a debug build at a different backend).

Expected lifecycle: the release continues running while a patch is staged, and the patch is
selected on the next cold launch. This was verified through the connected managed-signing workflow
on Android 16/arm64 (`Hello v1` → stage → `Hello v2`, state `active`).

For manual control (e.g. to show update UI), use `markBootSuccess()` and `checkForUpdate()`
directly — `checkForUpdate()` must still only be called after `markBootSuccess()` has completed (see
the class doc comment on `OtaUpdateClient` in `ota_runtime_android` for why).

```dart
final status = await AppUpdater.instance.status();
```

gives a snapshot of local patch lifecycle state (current state, last-known-good, quarantine/bad-patch
counts) for a debug screen or telemetry.

## What this package does not do

- Does not implement iOS. `ota_runtime_ios` is still a contract skeleton with no execution — see
  `docs/ios_runtime_decision.md`. `app_updater.yaml` is designed to be platform-agnostic so an
  iOS equivalent of the Gradle codegen (an Xcode build phase script, most likely) can consume the
  exact same file without a second config format.
- Does not eliminate the one native `FlutterOtaActivity` subclass; removing that requirement would
  require a custom Flutter engine/CLI and is explicitly out of scope. See
  `docs/ota_architecture_principles.md`.
- The current distribution is a public git path dependency. The building machine only needs network
  access to clone this repository; no additional dependency service must be configured.
