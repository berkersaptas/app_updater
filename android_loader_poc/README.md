# Device experiment

Prerequisites: Flutter 3.44.6-compatible toolchain, an arm64 Android device visible to `adb`, and
the POC package ID `com.berkersaptas.app_updater_sample`.

```bash
./scripts/build_base.sh
adb install -r patch_artifacts/base/base.apk
adb shell am force-stop com.berkersaptas.app_updater_sample
adb shell monkey -p com.berkersaptas.app_updater_sample 1
```

Confirm `Hello v1`, then build and install only the alternate AOT artifact:

```bash
./scripts/build_patched.sh
./scripts/install_patch_artifact.sh patch_artifacts/patched/libapp.so
adb shell am force-stop com.berkersaptas.app_updater_sample
adb shell monkey -p com.berkersaptas.app_updater_sample 1
adb logcat -s OtaPatchLoader FlutterLoader flutter
```

Confirm `Hello v2`. Do **not** install `patched.apk`; it exists only as the build container from
which the alternate `libapp.so` is extracted.

Inspect the native state through the shell-only provider:

```bash
adb shell content read \
  --uri content://com.berkersaptas.app_updater_sample.ota-installer/state
```

Inspect lifecycle retention with:

```bash
adb shell content call \
  --uri content://com.berkersaptas.app_updater_sample.ota-installer \
  --method lifecycleStatus
```

To test hash fallback, reactivate the installed artifact with a 64-character zero hash, then
force-stop/relaunch. The app should display `Hello v1`, and state should become `failed`:

```bash
adb shell content call \
  --uri content://com.berkersaptas.app_updater_sample.ota-installer \
  --method activate \
  --arg '1.0.0+1~1~0000000000000000000000000000000000000000000000000000000000000000~83675ed27633283e7fc296c8bca22e841224c096~3.12.2~arm64-v8a~release'
```

To test missing-file fallback, install/reactivate the patch, delete only its artifact, and restart:

```bash
adb shell content delete \
  --uri content://com.berkersaptas.app_updater_sample.ota-installer/patches/1/libapp.so
```

The APK stays non-debuggable and Dart is compiled in release AOT mode. A POC-only exported content
provider accepts writes exclusively from callers holding the signature-level
`android.permission.DUMP` permission (the adb shell UID). Remove this provider from any production
application. The debug signing key used here is likewise not a production signing model.

Do not hand-edit compatibility values for normal installation. `build_patched.sh` generates
`patch_artifacts/patched/patch_manifest.json`, and `install_patch_artifact.sh` reads it by default.
