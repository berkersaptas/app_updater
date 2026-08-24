// app_updater: `init` wires a Flutter project up to app_updater (pubspec dependency,
// app_updater.yaml, MainActivity, Dart startup), and release/patch manage the OTA lifecycle.
// patch — the "build, sign, upload" that used to mean hand-crafting a manifest + artifact and
// curl-ing them to the backend. Run from inside a company app's own Flutter project; no clone of
// the app_updater infra repo required.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:yaml/yaml.dart';
import 'package:app_updater_cli/src/connected_workflow.dart';

const _repoUrl = 'https://github.com/berkersaptas/app_updater.git';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<void>(
    'app_updater',
    'Wire up and publish patches for a self-hosted, Shorebird-style OTA-updated Flutter app.',
  )
    ..addCommand(LoginCommand())
    ..addCommand(LogoutCommand())
    ..addCommand(_InitCommand())
    ..addCommand(ReleaseCommand())
    ..addCommand(PatchCommand())
    ..addCommand(_PublishCommand());

  try {
    await runner.run(arguments);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 2;
  } catch (e) {
    stderr.writeln('error: $e');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

class _InitCommand extends Command<void> {
  @override
  final name = 'init';
  @override
  final description =
      'Wire an existing Flutter project up to app_updater: pubspec dependency, '
      'app_updater.yaml, MainActivity, and Dart startup.';

  _InitCommand() {
    argParser
      ..addOption('project-dir',
          defaultsTo: '.', help: 'Flutter project root (has pubspec.yaml).')
      ..addOption('yaml-file',
          help:
              'Path to a saved copy of the app_updater.yaml block the portal showed you '
              'when creating the app. Legacy/offline alternative to app_updater login.')
      ..addOption('app-slug',
          help: 'Existing app to connect, or slug for --create.')
      ..addOption('package-name', help: 'Required with --create.')
      ..addFlag('create',
          negatable: false, help: 'Create a managed-signing app from the CLI.');
  }

  @override
  Future<void> run() async => _init(argResults!);
}

Future<void> _init(ArgResults args) async {
  final projectDir = Directory(args['project-dir'] as String).absolute;
  if (!File('${projectDir.path}/pubspec.yaml').existsSync()) {
    throw '${projectDir.path} does not look like a Flutter project (no pubspec.yaml).';
  }

  final configTarget = File('${projectDir.path}/app_updater.yaml');
  final yamlFile = args['yaml-file'] as String?;
  if (yamlFile != null) {
    File(yamlFile).copySync(configTarget.path);
    stdout.writeln('==> Wrote app_updater.yaml');
  } else if (configTarget.existsSync()) {
    stdout.writeln('==> app_updater.yaml already present, leaving it alone');
  } else {
    await writeConnectedConfig(args, projectDir);
  }

  _ensurePubspecDependency(projectDir);
  _ensureMainActivity(projectDir);
  _ensureDartEntrypoint(projectDir);

  stdout.writeln();
  stdout.writeln('Project setup is complete.');
  stdout.writeln('For the next Play release: app_updater release android');
  stdout.writeln('For a Dart-only hotfix afterward: app_updater patch android');
}

void _ensurePubspecDependency(Directory projectDir) {
  final file = File('${projectDir.path}/pubspec.yaml');
  final text = file.readAsStringSync();
  if (text.contains('app_updater:')) {
    stdout.writeln(
        '==> pubspec.yaml already depends on app_updater, leaving it alone');
    return;
  }
  final match =
      RegExp(r'^dependencies:[ \t]*$', multiLine: true).firstMatch(text);
  if (match == null) {
    stdout.writeln(
        '==> Could not find a "dependencies:" section in pubspec.yaml — add this by hand:');
    stdout.writeln(_dependencyBlock);
    return;
  }
  final updated =
      text.replaceRange(match.end, match.end, '\n$_dependencyBlock');
  file.writeAsStringSync(updated);
  stdout.writeln('==> Added app_updater to pubspec.yaml');
}

const _dependencyBlock = '  app_updater:\n'
    '    git:\n'
    '      url: $_repoUrl\n'
    '      path: app_updater\n'
    '      ref: master\n';

void _ensureMainActivity(Directory projectDir) {
  final kotlinDir = Directory('${projectDir.path}/android/app/src/main/kotlin');
  if (!kotlinDir.existsSync()) {
    stdout.writeln(
        '==> No android/app/src/main/kotlin found — extend FlutterOtaActivity by hand, see app_updater_cli/README.md');
    return;
  }
  final matches = kotlinDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('MainActivity.kt'))
      .toList();
  if (matches.isEmpty) {
    stdout.writeln(
        '==> No MainActivity.kt found under ${kotlinDir.path} — extend FlutterOtaActivity by hand, see app_updater_cli/README.md');
    return;
  }

  final file = matches.first;
  var text = file.readAsStringSync();
  if (text.contains('FlutterOtaActivity')) {
    stdout.writeln(
        '==> ${file.path} already extends FlutterOtaActivity, leaving it alone');
    return;
  }
  if (!text.contains(': FlutterActivity()')) {
    stdout.writeln(
        '==> ${file.path} doesn\'t look like the default template (no ": FlutterActivity()") — extend FlutterOtaActivity by hand, see app_updater_cli/README.md');
    return;
  }

  text = text.replaceFirst(': FlutterActivity()', ': FlutterOtaActivity()');
  if (text.contains('import io.flutter.embedding.android.FlutterActivity')) {
    text = text.replaceFirst(
      'import io.flutter.embedding.android.FlutterActivity',
      'import com.berkersaptas.app_updater.FlutterOtaActivity',
    );
  } else {
    final pkgMatch = RegExp(r'^package .+$', multiLine: true).firstMatch(text);
    if (pkgMatch != null) {
      text = text.replaceRange(pkgMatch.end, pkgMatch.end,
          '\n\nimport com.berkersaptas.app_updater.FlutterOtaActivity');
    }
  }
  file.writeAsStringSync(text);
  stdout.writeln('==> ${file.path} now extends FlutterOtaActivity');
}

void _ensureDartEntrypoint(Directory projectDir) {
  final file = File('${projectDir.path}/lib/main.dart');
  if (!file.existsSync()) {
    stdout.writeln(
        '==> No lib/main.dart found — call AppUpdater.instance.autoUpdate() after WidgetsFlutterBinding.ensureInitialized() in your entrypoint');
    return;
  }
  var text = file.readAsStringSync();
  if (!text.contains("package:app_updater/app_updater.dart")) {
    text = "import 'package:app_updater/app_updater.dart';\n$text";
  }
  if (text.contains('AppUpdater.instance.autoUpdate()')) {
    file.writeAsStringSync(text);
    stdout.writeln('==> lib/main.dart already starts AppUpdater');
    return;
  }
  final main = RegExp(
          r'(?:Future\s*<\s*void\s*>|void)\s+main\s*\([^)]*\)\s*(?:async\s*)?\{')
      .firstMatch(text);
  if (main == null) {
    stdout.writeln(
        '==> Could not safely update lib/main.dart — call AppUpdater.instance.autoUpdate() after WidgetsFlutterBinding.ensureInitialized()');
    return;
  }
  final binding =
      text.indexOf('WidgetsFlutterBinding.ensureInitialized();', main.end);
  if (binding >= 0) {
    final insertAt =
        binding + 'WidgetsFlutterBinding.ensureInitialized();'.length;
    text = text.replaceRange(
        insertAt, insertAt, '\n  AppUpdater.instance.autoUpdate();');
  } else {
    text = text.replaceRange(main.end, main.end,
        '\n  WidgetsFlutterBinding.ensureInitialized();\n  AppUpdater.instance.autoUpdate();');
  }
  file.writeAsStringSync(text);
  stdout.writeln('==> Wired automatic update startup into lib/main.dart');
}

// ---------------------------------------------------------------------------
// publish
// ---------------------------------------------------------------------------

class _PublishCommand extends Command<void> {
  @override
  final name = 'publish';
  @override
  final description =
      'Build the release APK, sign a patch manifest, and upload it.';

  _PublishCommand() {
    argParser
      ..addOption('project-dir',
          defaultsTo: '.',
          help: 'Flutter project root (has pubspec.yaml + app_updater.yaml).')
      ..addOption('entrypoint', defaultsTo: 'lib/main.dart')
      ..addOption('target-platform',
          defaultsTo: 'android-arm64',
          allowed: ['android-arm64', 'android-arm', 'android-x64'])
      ..addOption('artifact-kind',
          defaultsTo: 'binary_diff',
          allowed: ['full_aot_library', 'binary_diff'])
      ..addOption(
        'base-apk',
        help:
            'Required for binary_diff: the archived release APK currently in users\' hands, '
            'built for the same single ABI. Used for both the base libapp.so and Dart-only checks.',
      )
      ..addFlag(
        'allow-full-aot-library',
        negatable: false,
        help:
            'Development/POC escape hatch. Production backends reject full .so uploads by default.',
      )
      ..addOption('patch-number',
          help: 'Defaults to (highest existing patch number for this app) + 1.')
      ..addOption('key-id',
          help:
              'Defaults to the only entry in app_updater.yaml\'s trusted_keys, if there is exactly one.')
      ..addOption('algorithm',
          allowed: ['ed25519', 'rsa_pkcs1_sha256'],
          help: 'Defaults to the chosen key\'s algorithm in app_updater.yaml.')
      ..addOption('private-key',
          mandatory: true,
          help: 'Path to the PEM private key matching --key-id.')
      ..addOption('api-key',
          help:
              'Publish key for this app (from the portal). Defaults to the APP_UPDATER_API_KEY env var.');
  }

  @override
  Future<void> run() async => _publish(argResults!);
}

Future<void> _publish(ArgResults args) async {
  final projectDir = Directory(args['project-dir'] as String).absolute;
  final configFile = File('${projectDir.path}/app_updater.yaml');
  if (!configFile.existsSync()) {
    throw 'No app_updater.yaml in ${projectDir.path} (run "app_updater init" first, or run this from your Flutter project root).';
  }
  final config = loadYaml(configFile.readAsStringSync()) as YamlMap;
  final appSlug = config['app_slug'] as String;
  final backendUrl =
      (config['backend_url'] as String).replaceAll(RegExp(r'/+$'), '');
  final trustedKeys =
      (config['trusted_keys'] as YamlList?) ?? YamlList.wrap(const []);

  final apiKey = (args['api-key'] as String?) ??
      Platform.environment['APP_UPDATER_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    throw 'No API key: pass --api-key or set APP_UPDATER_API_KEY to a publish key from the app\'s page in the portal.';
  }

  String? keyId = args['key-id'] as String?;
  String? algorithm = args['algorithm'] as String?;
  if (keyId == null) {
    if (trustedKeys.length == 1) {
      keyId = trustedKeys.first['key_id'] as String;
    } else {
      throw '--key-id is required (app_updater.yaml has ${trustedKeys.length} trusted keys).';
    }
  }
  if (algorithm == null) {
    final match =
        trustedKeys.cast<YamlMap>().where((k) => k['key_id'] == keyId);
    if (match.isEmpty) {
      throw '--algorithm is required (key_id "$keyId" is not in app_updater.yaml\'s trusted_keys).';
    }
    algorithm = match.first['algorithm'] as String;
  }

  final privateKey = File(args['private-key'] as String);
  if (!privateKey.existsSync()) {
    throw 'Private key not found: ${privateKey.path}';
  }

  final artifactKind = args['artifact-kind'] as String;
  final baseApkPath = args['base-apk'] as String?;
  if (artifactKind == 'binary_diff' &&
      (baseApkPath == null || !File(baseApkPath).existsSync())) {
    throw '--base-apk is required and must point to the archived, currently shipped release APK. '
        'This is required to prove the patch changes Dart code only.';
  }
  if (artifactKind == 'full_aot_library' &&
      args['allow-full-aot-library'] != true) {
    throw 'full_aot_library is a development/POC artifact and is blocked by default. '
        'Use binary_diff with --base-apk for Play/production patches. Pass '
        '--allow-full-aot-library only against an explicitly configured non-production backend.';
  }

  final targetPlatform = args['target-platform'] as String;
  final abi = const {
    'android-arm64': 'arm64-v8a',
    'android-arm': 'armeabi-v7a',
    'android-x64': 'x86_64',
  }[targetPlatform]!;

  var patchNumber = int.tryParse(args['patch-number'] as String? ?? '');
  if (patchNumber == null) {
    patchNumber = await _nextPatchNumber(backendUrl, appSlug, apiKey);
    stdout.writeln('==> Auto-selected patch number: $patchNumber');
  }

  final outputDir = Directory('${projectDir.path}/build/app_updater_patch')
    ..createSync(recursive: true);
  final cliDir = File(Platform.script.toFilePath())
      .parent
      .parent; // bin/.. -> app_updater_cli package root
  final scriptsDir = '${cliDir.path}/scripts';

  stdout.writeln('==> Building the release APK');
  await _run(
      'flutter',
      [
        'build',
        'apk',
        '--release',
        '--target',
        args['entrypoint'] as String,
        '--target-platform',
        targetPlatform
      ],
      cwd: projectDir.path);
  final apk =
      File('${projectDir.path}/build/app/outputs/flutter-apk/app-release.apk');
  if (!apk.existsSync()) throw 'Expected APK not found: ${apk.path}';

  stdout.writeln('==> Extracting libapp.so');
  await _run('bash',
      ['$scriptsDir/extract_artifacts.sh', apk.path, abi, outputDir.path]);

  File? baseLibappSo;
  if (artifactKind == 'binary_diff') {
    final baseApk = File(baseApkPath!);
    stdout.writeln('==> Verifying this is a Dart-only patch');
    await _run('bash',
        ['$scriptsDir/verify_dart_only_patch.sh', baseApk.path, apk.path, abi]);
    final baseOutputDir = Directory('${outputDir.path}/base')
      ..createSync(recursive: true);
    stdout.writeln('==> Extracting the shipped base libapp.so');
    await _run('bash', [
      '$scriptsDir/extract_artifacts.sh',
      baseApk.path,
      abi,
      baseOutputDir.path
    ]);
    baseLibappSo = File('${baseOutputDir.path}/libapp.so');
  }

  stdout.writeln('==> Reading compatibility metadata');
  final versionJson = jsonDecode((await _capture(
      'flutter', ['--version', '--machine'],
      cwd: projectDir.path)));
  final engineRevision = versionJson['engineRevision'] as String;
  final dartVersion = versionJson['dartSdkVersion'] as String;
  final release = _readPubspecVersion(projectDir);
  const buildMode = 'release';

  final libappSo = File('${outputDir.path}/libapp.so');
  final hash = sha256.convert(libappSo.readAsBytesSync()).toString();

  File uploadedArtifact;
  if (artifactKind == 'binary_diff') {
    stdout.writeln('==> Computing a binary diff against the base artifact');
    final diffPath = '${outputDir.path}/libapp.so.diff';
    await _run('bash', [
      '$scriptsDir/generate_binary_diff.sh',
      baseLibappSo!.path,
      libappSo.path,
      diffPath
    ]);
    uploadedArtifact = File(diffPath);
  } else {
    uploadedArtifact = libappSo;
  }
  final artifactSize = uploadedArtifact.lengthSync();

  stdout.writeln('==> Signing the manifest');
  final payloadFile = File('${outputDir.path}/patch_payload.txt');
  await _run('bash', [
    '$scriptsDir/write_manifest_payload.sh',
    payloadFile.path,
    '1',
    release,
    '$patchNumber',
    artifactKind,
    engineRevision,
    dartVersion,
    abi,
    buildMode,
    hash,
    keyId,
    algorithm,
  ]);
  final signature = await _sign(payloadFile, privateKey, algorithm);
  payloadFile.deleteSync();

  final manifest = {
    'schema_version': 1,
    'release': release,
    'patch_number': patchNumber,
    'artifact_kind': artifactKind,
    'engine_revision': engineRevision,
    'dart_version': dartVersion,
    'abi': abi,
    'build_mode': buildMode,
    'sha256': hash,
    'artifact_size': artifactSize,
    'signature_key_id': keyId,
    'signature_algorithm': algorithm,
    'signature': signature,
  };
  final manifestFile = File('${outputDir.path}/patch_manifest.json')
    ..writeAsStringSync(jsonEncode(manifest));

  stdout.writeln('==> Uploading to $backendUrl');
  final uri = Uri.parse('$backendUrl/admin/apps/$appSlug/patches');
  final request = http.MultipartRequest('POST', uri)
    ..headers['X-Api-Key'] = apiKey
    ..files.add(await http.MultipartFile.fromPath('manifest', manifestFile.path,
        contentType: MediaType('application', 'json')))
    ..files.add(await http.MultipartFile.fromPath(
        'artifact', uploadedArtifact.path,
        contentType: MediaType('application', 'octet-stream')));
  final response = await http.Response.fromStream(await request.send());
  if (response.statusCode != 201) {
    throw 'Upload failed (${response.statusCode}): ${response.body}';
  }

  stdout.writeln();
  stdout.writeln(
      'Published $appSlug patch $patchNumber ($artifactKind, $artifactSize bytes).');
}

Future<int> _nextPatchNumber(
    String backendUrl, String appSlug, String apiKey) async {
  final uri = Uri.parse('$backendUrl/admin/apps/$appSlug/patches');
  final response = await http.get(uri, headers: {'X-Api-Key': apiKey});
  if (response.statusCode != 200) {
    throw 'Could not list existing patches (${response.statusCode}): ${response.body}';
  }
  final patches = jsonDecode(response.body) as List;
  if (patches.isEmpty) return 1;
  final highest = patches
      .map((p) => p['patch_number'] as int)
      .reduce((a, b) => a > b ? a : b);
  return highest + 1;
}

String _readPubspecVersion(Directory projectDir) {
  final pubspec =
      loadYaml(File('${projectDir.path}/pubspec.yaml').readAsStringSync())
          as YamlMap;
  final version = pubspec['version'] as String?;
  if (version == null) throw 'No version: in ${projectDir.path}/pubspec.yaml';
  return version;
}

Future<String> _sign(
    File payloadFile, File privateKey, String algorithm) async {
  final List<int> raw;
  if (algorithm == 'ed25519') {
    raw = await _captureBytes('openssl', [
      'pkeyutl',
      '-sign',
      '-rawin',
      '-inkey',
      privateKey.path,
      '-in',
      payloadFile.path
    ]);
  } else {
    raw = await _captureBytes('openssl', [
      'dgst',
      '-sha256',
      '-sign',
      privateKey.path,
      '-binary',
      payloadFile.path
    ]);
  }
  return base64Url.encode(raw).replaceAll('=', '');
}

Future<void> _run(String executable, List<String> args, {String? cwd}) async {
  final process = await Process.start(executable, args,
      workingDirectory: cwd, mode: ProcessStartMode.inheritStdio);
  final code = await process.exitCode;
  if (code != 0) throw '$executable ${args.join(' ')} exited with $code';
}

Future<String> _capture(String executable, List<String> args,
    {String? cwd}) async {
  final result = await Process.run(executable, args, workingDirectory: cwd);
  if (result.exitCode != 0)
    throw '$executable ${args.join(' ')} exited with ${result.exitCode}: ${result.stderr}';
  return result.stdout as String;
}

Future<List<int>> _captureBytes(String executable, List<String> args) async {
  final result = await Process.run(executable, args,
      stdoutEncoding: null, stderrEncoding: utf8);
  if (result.exitCode != 0)
    throw '$executable ${args.join(' ')} exited with ${result.exitCode}: ${result.stderr}';
  return result.stdout as List<int>;
}
