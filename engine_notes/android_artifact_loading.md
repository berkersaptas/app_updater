# Android release artifact layout

For an Android release build, Flutter compiles the root Dart isolate and reachable Dart code to an
ELF shared object named `libapp.so`. The engine itself is a separate native library,
`libflutter.so`. In a conventional APK they are stored per ABI:

```text
lib/arm64-v8a/libapp.so
lib/arm64-v8a/libflutter.so
lib/armeabi-v7a/libapp.so
lib/armeabi-v7a/libflutter.so
lib/x86_64/libapp.so
lib/x86_64/libflutter.so
```

Only ABIs requested by the build are present. This POC builds only `android-arm64`, therefore the
expected entries are under `lib/arm64-v8a/`. A fat APK can contain all three pairs; an App Bundle
lets Play generate ABI-specific split APKs.

`libflutter.so` owns the engine, renderer, platform integration, Dart VM host, and snapshot-loading
code. `libapp.so` holds the application AOT snapshot symbols consumed by that exact engine/Dart
toolchain. It is not a general plugin and must match the base app's Flutter engine version, target
ABI, build mode, Dart defines, assets, and native/plugin contract.

Inspect a real output with:

```bash
./scripts/inspect_apk.sh patch_artifacts/base/base.apk
```

References in the pinned Flutter checkout:

- `packages/flutter_tools/lib/src/build_system/targets/android.dart` creates and copies Android AOT
  artifacts.
- `packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt` packages the ABI libraries.
- `engine/src/flutter/shell/platform/android/io/flutter/embedding/engine/loader/FlutterApplicationInfo.java`
  defines the default AOT name `libapp.so`.
