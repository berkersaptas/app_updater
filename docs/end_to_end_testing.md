# End-to-End Acceptance Testing

This guide validates one complete application path: shared backend, Flutter build, registered Google
Play base, patch generation, device staging, activation, disablement, and compatibility rejection.

Run it before onboarding production applications and after material backend, CLI, or Android runtime
changes. Use a disposable application and a non-production backend, or a dedicated test application
on a Google Play internal-testing track.

## Prerequisites

- A healthy backend: `/healthz` and `/readyz` both return `{"ok":true}`
- A portal account with permission to create a test application
- The CLI authenticated to that backend
- A pinned Flutter toolchain
- A production-like Android signing configuration
- An authorized `arm64-v8a` device visible in `adb devices`
- An obvious baseline marker such as `Version A` in the test UI

Record these values before starting:

| Value | Example |
|---|---|
| Backend | `https://updates-test.example.com` |
| App slug | `acceptance-app-android` |
| Package name | `com.company.acceptance_app` |
| Store version | `1.0.0+1` |
| ABI | `arm64-v8a` |
| Flutter version | Output of `flutter --version` |
| Baseline UI | `Version A` |
| Patched UI | `Version B` |

## 1. Connect the test application

```bash
app_updater init \
  --create \
  --app-slug acceptance-app-android \
  --package-name com.company.acceptance_app

flutter pub get
flutter analyze
```

Review `app_updater.yaml`, `pubspec.yaml`, `lib/main.dart`, and Android integration changes. Confirm
that no private key or backend administrative credential appears in the project.

## 2. Register the store base

Set the UI to `Version A` and the intended store version, then run:

```bash
app_updater release android
```

Save the printed AAB path, release identity, Flutter/Dart versions, ABI, and base hash in the test
record. Use that exact AAB for the device test:

- preferred: upload it to a Google Play internal-testing track and install from Play;
- isolated local test: install an APK built from the same reviewed baseline and follow the local
  runtime test procedure used by the repository.

Do not rebuild and substitute another AAB after registration.

## 3. Confirm baseline behavior

Cold-start the installed application and verify:

- `Version A` is visible;
- startup succeeds when no patch exists;
- the application still starts if the backend is temporarily unavailable;
- the portal shows the registered release and device check/event activity.

## 4. Publish a valid Dart-only patch

Change only Dart implementation compiled into `libapp.so`, for example `Version A` to `Version B`.
Keep the application version and Flutter toolchain unchanged:

```bash
app_updater patch android
```

Confirm the CLI reports the expected base release, accepts only permitted archive changes, uploads a
binary diff, and returns the assigned patch number.

## 5. Verify staging and activation

1. Cold-start the baseline application while the backend is reachable.
2. Wait for the update check and download to complete.
3. Confirm the application still shows `Version A` during the staging launch.
4. Fully stop the process.
5. Cold-start again.
6. Confirm `Version B` is visible and the patch state/event is active.

Patch activation on the next cold launch is intentional. A hot reload, route change, or background
resume is not an activation test.

## 6. Verify emergency disablement

Disable the patch from the portal. Cold-start the device with backend connectivity, then cold-start
again if required by the state transition. Confirm the runtime no longer selects the disabled patch
and falls back to its last-known-good or packaged store base.

Re-enable only after the expected rollback evidence is recorded.

## 7. Verify negative compatibility paths

Each case must fail safely and leave the packaged application usable:

- Change a native/plugin/resource/asset entry and confirm `patch` is rejected.
- Change the Flutter or Dart SDK and confirm `patch` is rejected.
- Change `versionName+versionCode` and confirm the old release is not reused.
- Request a patch using a forged or partial build identity and confirm no patch is returned.
- Use another platform or ABI and confirm the patch does not match.
- Corrupt the artifact or signature in an isolated test and confirm device verification rejects it.
- Interrupt a download and confirm no partial artifact becomes active.
- Simulate backend unavailability and confirm application startup still succeeds.

## 8. Verify a new store version

Increment the application version, restore a reviewed baseline, and run:

```bash
app_updater release android
```

Confirm the backend creates a separate release line. A device on the older store version must remain
on its compatible older line; it must not receive the new version's patches.

## Acceptance criteria

- [ ] The exact registered AAB is the artifact submitted to the test/store track.
- [ ] The baseline starts without a patch and during backend outage.
- [ ] A valid Dart-only patch is accepted and remains release-bound.
- [ ] First cold launch stages; the next cold launch activates.
- [ ] Hash, signature, ABI, toolchain, version, and base identity are enforced.
- [ ] Native, plugin, resource, asset, and toolchain changes are rejected.
- [ ] Disablement produces a safe fallback.
- [ ] Older store versions do not receive newer release-line patches.
- [ ] Portal and device events provide enough evidence to diagnose failure.

Repository maintainers can additionally run the automated device acceptance tooling documented in
the scripts directory, but automation does not replace the production-like Play installation test.

## Related documentation

- [Application onboarding](../GETTING_STARTED.md)
- [Server installation](server_installation.md)
- [Rollback model](rollback_model.md)
- [Google Play compliance](google_play_compliance.md)
