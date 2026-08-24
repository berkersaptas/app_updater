# Loader design

```text
MainActivity.onCreate
  -> PatchStateStore.read (AtomicFile)
  -> reject unfinished pending_boot from the previous process
  -> exact release + engine + Dart + ABI + build-mode compatibility check
  -> canonical filesDir containment + .so + existence + SHA-256
  -> write pending_boot before starting Dart
  -> FlutterEngine(context, --aot-shared-library-name=<patch>)
  -> packaged libapp.so remains the engine fallback candidate
  -> first Flutter frame
  -> MethodChannel(ota_runtime).markBootSuccess
  -> write active
```

State writes use Android `AtomicFile`, avoiding a truncated JSON file after a process/power loss.
An unreadable state is treated as no patch. Invalid artifacts are marked `failed` and disabled.

The base APK embeds the engine revision, Dart version, and build mode as generated Android
`BuildConfig` values. Runtime package metadata supplies versionName/versionCode, and Android
supplies the process ABI. `build_patched.sh` records the corresponding values in
`patch_manifest.json`; the installer and native loader both validate them.

The state vocabulary is `none`, `pending`, `pending_boot`, `active`, `failed`, and `disabled`.
`pending_boot` is the crash-detection marker described by the phase requirements even though it was
omitted from their initial five-value list.

Every patched process start changes `active` back to `pending_boot` and requires a fresh first-frame
signal. This deliberately conservative policy means a kill/crash before that signal disables the
patch on the next start.
