# Flutter Android startup and AOT selection

The POC was checked against local Flutter `3.44.6` (framework commit
`ee80f08bbf97172ec030b8751ceab557177a34a6`, Dart `3.12.2`). These internals are not a stable public
contract and must be revalidated after upgrading Flutter.

1. Android launches `MainActivity`, a `FlutterActivity`.
2. `MainActivity.provideFlutterEngine` creates a `FlutterEngine` before Dart starts.
3. `FlutterEngine` calls `FlutterLoader.startInitialization` and
   `FlutterLoader.ensureInitializationComplete`, passing the supplied engine arguments.
4. In release mode `FlutterLoader.ensureInitializationComplete` builds an ordered list of
   `--aot-shared-library-name=` candidates. Earlier entries take precedence; packaged `libapp.so`
   name/path entries remain fallbacks.
5. `FlutterJNI.init` forwards the arguments through JNI.
6. Android shell/engine code resolves the AOT shared library and maps the snapshot from it.
7. `DartExecutor.executeDartEntrypoint` starts the root isolate.

The relevant embedding implementation is:

- `FlutterEngine.java`: constructors accepting `String[] dartVmArgs`.
- `FlutterLoader.java`: `ensureInitializationComplete`,
  `maybeAddAotSharedLibraryNameArg`, and `getSafeAotSharedLibraryName`.
- `FlutterEngineFlags.java`: `AOT_SHARED_LIBRARY_NAME`.
- `FlutterJNI.java`: `init`/`nativeInit` boundary.

This Flutter revision accepts a command-line AOT path only after canonicalizing it and verifying
that it is a `.so` below the application's `filesDir`. `MainActivity` supplies the verified patch
as the first candidate. If it supplies no argument, the embedding adds and loads the packaged base
artifact normally.

The selection must happen before the process-wide Dart VM starts. Installing a patch while the app
process remains alive is insufficient: force-stop and relaunch the app. A second engine in an
already-running VM cannot reliably replace the VM's AOT snapshot choice.
