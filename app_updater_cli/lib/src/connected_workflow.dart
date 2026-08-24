import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:yaml/yaml.dart';

class _Credentials {
  const _Credentials(this.backendUrl, this.token, this.email);
  final String backendUrl;
  final String token;
  final String email;

  static File get file {
    final override = Platform.environment['APP_UPDATER_CREDENTIALS_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) throw 'Cannot determine the user home directory.';
    return File('$home/.app_updater/credentials.json');
  }

  static _Credentials load() {
    if (!file.existsSync()) throw 'Not logged in. Run: app_updater login';
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return _Credentials(json['backend_url'] as String, json['token'] as String,
        json['email'] as String);
  }

  void save() {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(
        {'backend_url': backendUrl, 'token': token, 'email': email}));
    if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
  }
}

class _Client {
  _Client(this.credentials);
  final _Credentials credentials;

  Uri uri(String path) => Uri.parse(
      '${credentials.backendUrl.replaceAll(RegExp(r'/+$'), '')}$path');
  Map<String, String> get headers =>
      {'Authorization': 'Bearer ${credentials.token}'};

  Future<dynamic> getJson(String path) async {
    final response = await http.get(uri(path), headers: headers);
    return _decode(response);
  }

  Future<dynamic> postJson(String path, Map<String, dynamic> body) async {
    final response = await http.post(
      uri(path),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    final body =
        response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw 'Backend ${response.statusCode}: ${body is Map ? body['error'] ?? body : body}';
    }
    return body;
  }
}

class LoginCommand extends Command<void> {
  @override
  final name = 'login';
  @override
  final description = 'Log in once and store a revocable CLI session locally.';

  LoginCommand() {
    argParser
      ..addOption('backend-url', defaultsTo: 'http://localhost:8081')
      ..addOption('email')
      ..addOption('password',
          help:
              'Prefer the interactive hidden prompt; useful for automation only.');
  }

  @override
  Future<void> run() async {
    final backendUrl =
        (argResults!['backend-url'] as String).replaceAll(RegExp(r'/+$'), '');
    var email = argResults!['email'] as String?;
    if (email == null || email.isEmpty) {
      stdout.write('Email: ');
      email = stdin.readLineSync()?.trim();
    }
    var password = argResults!['password'] as String?;
    if (password == null) {
      stdout.write('Password: ');
      if (stdin.hasTerminal) stdin.echoMode = false;
      password = stdin.readLineSync();
      if (stdin.hasTerminal) stdin.echoMode = true;
      stdout.writeln();
    }
    if (email == null || email.isEmpty || password == null || password.isEmpty)
      throw 'Email and password are required.';
    final response = await http.post(
      Uri.parse('$backendUrl/v1/cli/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'password': password,
        'label': Platform.localHostname
      }),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200)
      throw 'Login failed: ${body['error'] ?? response.statusCode}';
    _Credentials(backendUrl, body['token'] as String, body['email'] as String)
        .save();
    stdout.writeln(
        'Logged in as ${body['email']}. Credentials saved with user-only permissions.');
  }
}

class LogoutCommand extends Command<void> {
  @override
  final name = 'logout';
  @override
  final description = 'Revoke the current CLI session and remove it locally.';

  @override
  Future<void> run() async {
    final credentials = _Credentials.load();
    final response = await http.delete(
      Uri.parse('${credentials.backendUrl}/v1/cli/session'),
      headers: {'Authorization': 'Bearer ${credentials.token}'},
    );
    if (response.statusCode != 204 && response.statusCode != 401) {
      throw 'Logout failed (${response.statusCode}): ${response.body}';
    }
    if (_Credentials.file.existsSync()) _Credentials.file.deleteSync();
    stdout.writeln('Logged out. The local CLI session was removed.');
  }
}

void addConnectedInitOptions(ArgParser parser) {
  parser
    ..addOption('app-slug',
        help: 'Existing app to connect, or slug for --create.')
    ..addOption('package-name', help: 'Required with --create.')
    ..addFlag('create',
        negatable: false, help: 'Create a managed-signing app from the CLI.');
}

Future<bool> writeConnectedConfig(ArgResults args, Directory projectDir) async {
  if (args.options.contains('yaml-file') && args['yaml-file'] != null)
    return false;
  final client = _Client(_Credentials.load());
  var slug = args['app-slug'] as String?;
  final create = args['create'] == true;
  dynamic response;
  if (create) {
    if (slug == null || slug.isEmpty || args['package-name'] == null) {
      throw '--create requires --app-slug and --package-name.';
    }
    response = await client.postJson('/v1/cli/apps', {
      'slug': slug,
      'package_name': args['package-name'],
    });
  } else {
    if (slug == null) {
      final apps = await client.getJson('/v1/cli/apps') as List;
      if (apps.length != 1) {
        final names = apps.map((app) => app['slug']).join(', ');
        throw 'Specify --app-slug. Available apps: ${names.isEmpty ? '(none; use --create)' : names}';
      }
      slug = apps.single['slug'] as String;
    }
    response = await client
        .getJson('/v1/cli/apps/${Uri.encodeComponent(slug)}/config');
  }
  File('${projectDir.path}/app_updater.yaml')
      .writeAsStringSync(response['yaml'] as String);
  stdout.writeln('==> Connected to $slug and wrote app_updater.yaml');
  return true;
}

class ReleaseCommand extends Command<void> {
  @override
  final name = 'release';
  @override
  final description = 'Build and register an immutable store release.';
  ReleaseCommand() {
    addSubcommand(_ReleaseAndroidCommand());
  }
}

class PatchCommand extends Command<void> {
  @override
  final name = 'patch';
  @override
  final description =
      'Build and publish a Dart-only patch for a registered release.';
  PatchCommand() {
    addSubcommand(_PatchAndroidCommand());
  }
}

abstract class _AndroidCommand extends Command<void> {
  _AndroidCommand() {
    argParser
      ..addOption('project-dir', defaultsTo: '.')
      ..addOption('entrypoint', defaultsTo: 'lib/main.dart')
      ..addOption('target-platform',
          defaultsTo: 'android-arm64',
          allowed: ['android-arm64', 'android-arm', 'android-x64']);
  }

  Directory project(ArgResults args) {
    final directory = Directory(args['project-dir'] as String).absolute;
    if (!File('${directory.path}/app_updater.yaml').existsSync())
      throw 'Run app_updater init first.';
    return directory;
  }

  Map<String, dynamic> config(Directory project) {
    final yaml =
        loadYaml(File('${project.path}/app_updater.yaml').readAsStringSync())
            as YamlMap;
    return {'app_slug': yaml['app_slug'] as String};
  }

  String abi(ArgResults args) => const {
        'android-arm64': 'arm64-v8a',
        'android-arm': 'armeabi-v7a',
        'android-x64': 'x86_64',
      }[args['target-platform']]!;

  String releaseVersion(Directory project) {
    final yaml =
        loadYaml(File('${project.path}/pubspec.yaml').readAsStringSync())
            as YamlMap;
    return yaml['version'] as String? ?? (throw 'pubspec.yaml has no version.');
  }

  Future<Map<String, dynamic>> toolchain(Directory project) async =>
      jsonDecode(await _capture('flutter', ['--version', '--machine'],
          cwd: project.path)) as Map<String, dynamic>;

  String scriptsDir() =>
      '${File(Platform.script.toFilePath()).parent.parent.path}/scripts';
}

class _ReleaseAndroidCommand extends _AndroidCommand {
  @override
  final name = 'android';
  @override
  final description =
      'Build the Play AAB and register its immutable Dart base artifact.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final projectDir = project(args);
    final appSlug = config(projectDir)['app_slug'] as String;
    final release = releaseVersion(projectDir);
    final selectedAbi = abi(args);
    stdout.writeln('==> Building Play release AAB');
    await _run(
        'flutter',
        [
          'build',
          'appbundle',
          '--release',
          '--target',
          args['entrypoint'] as String,
          '--target-platform',
          args['target-platform'] as String
        ],
        cwd: projectDir.path);
    final aab = File(
        '${projectDir.path}/build/app/outputs/bundle/release/app-release.aab');
    if (!aab.existsSync()) throw 'Expected AAB not found: ${aab.path}';
    final validationDir = Directory(
        '${projectDir.path}/build/app_updater_release/$release/$selectedAbi')
      ..createSync(recursive: true);
    await _run('bash', [
      '${scriptsDir()}/extract_artifacts.sh',
      aab.path,
      selectedAbi,
      validationDir.path
    ]);
    final metadata = await toolchain(projectDir);
    final commit = await _captureOrEmpty('git', ['rev-parse', 'HEAD'],
        cwd: projectDir.path);
    final credentials = _Credentials.load();
    final request = http.MultipartRequest(
        'POST',
        Uri.parse(
            '${credentials.backendUrl}/v1/cli/apps/${Uri.encodeComponent(appSlug)}/releases'))
      ..headers['Authorization'] = 'Bearer ${credentials.token}'
      ..fields.addAll({
        'release_version': release,
        'engine_revision': metadata['engineRevision'] as String,
        'dart_version': metadata['dartSdkVersion'] as String,
        'abi': selectedAbi,
        'source_commit': commit.trim(),
      })
      ..files.add(await http.MultipartFile.fromPath('artifact', aab.path,
          contentType: MediaType('application', 'octet-stream')));
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != 201)
      throw 'Release registration failed (${response.statusCode}): ${response.body}';
    stdout.writeln('Registered $appSlug release $release ($selectedAbi).');
    stdout.writeln('Upload this exact artifact to Play: ${aab.path}');
  }
}

class _PatchAndroidCommand extends _AndroidCommand {
  @override
  final name = 'android';
  @override
  final description =
      'Download the registered base, verify Dart-only changes, diff, sign, and publish.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final projectDir = project(args);
    final appSlug = config(projectDir)['app_slug'] as String;
    final release = releaseVersion(projectDir);
    final selectedAbi = abi(args);
    final outputDir = Directory('${projectDir.path}/build/app_updater_patch')
      ..createSync(recursive: true);
    final credentials = _Credentials.load();
    final baseAab = File('${outputDir.path}/registered-base.aab');
    final downloadUri = Uri.parse(
        '${credentials.backendUrl}/v1/cli/apps/${Uri.encodeComponent(appSlug)}/releases/${Uri.encodeComponent(release)}/artifact?abi=${Uri.encodeQueryComponent(selectedAbi)}');
    final download = await http.get(downloadUri,
        headers: {'Authorization': 'Bearer ${credentials.token}'});
    if (download.statusCode != 200)
      throw 'No registered base for $release/$selectedAbi. Run app_updater release android first: ${download.body}';
    baseAab.writeAsBytesSync(download.bodyBytes);

    stdout.writeln('==> Building patch candidate AAB');
    await _run(
        'flutter',
        [
          'build',
          'appbundle',
          '--release',
          '--target',
          args['entrypoint'] as String,
          '--target-platform',
          args['target-platform'] as String
        ],
        cwd: projectDir.path);
    final patchAab = File(
        '${projectDir.path}/build/app/outputs/bundle/release/app-release.aab');
    final scripts = scriptsDir();
    await _run('bash', [
      '$scripts/verify_dart_only_patch.sh',
      baseAab.path,
      patchAab.path,
      selectedAbi
    ]);
    final baseDir = Directory('${outputDir.path}/base')
      ..createSync(recursive: true);
    final patchDir = Directory('${outputDir.path}/candidate')
      ..createSync(recursive: true);
    await _run('bash', [
      '$scripts/extract_artifacts.sh',
      baseAab.path,
      selectedAbi,
      baseDir.path
    ]);
    await _run('bash', [
      '$scripts/extract_artifacts.sh',
      patchAab.path,
      selectedAbi,
      patchDir.path
    ]);
    final diff = File('${outputDir.path}/libapp.so.diff');
    await _run('bash', [
      '$scripts/generate_binary_diff.sh',
      '${baseDir.path}/libapp.so',
      '${patchDir.path}/libapp.so',
      diff.path
    ]);
    final target = File('${patchDir.path}/libapp.so');
    final metadata = await toolchain(projectDir);
    final unsignedManifest = {
      'schema_version': 1,
      'release': release,
      'artifact_kind': 'binary_diff',
      'engine_revision': metadata['engineRevision'],
      'dart_version': metadata['dartSdkVersion'],
      'abi': selectedAbi,
      'build_mode': 'release',
      'sha256': sha256.convert(target.readAsBytesSync()).toString(),
      'artifact_size': diff.lengthSync(),
    };
    final request = http.MultipartRequest(
        'POST',
        Uri.parse(
            '${credentials.backendUrl}/v1/cli/apps/${Uri.encodeComponent(appSlug)}/patches'))
      ..headers['Authorization'] = 'Bearer ${credentials.token}'
      ..fields['manifest'] = jsonEncode(unsignedManifest)
      ..files.add(await http.MultipartFile.fromPath('artifact', diff.path,
          contentType: MediaType('application', 'octet-stream')));
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != 201)
      throw 'Patch publish failed (${response.statusCode}): ${response.body}';
    final patch = jsonDecode(response.body) as Map<String, dynamic>;
    stdout.writeln(
        'Published $appSlug $release patch ${patch['patch_number']} ($selectedAbi).');
  }
}

Future<void> _run(String executable, List<String> arguments,
    {String? cwd}) async {
  final process = await Process.start(executable, arguments,
      workingDirectory: cwd, mode: ProcessStartMode.inheritStdio);
  final code = await process.exitCode;
  if (code != 0) throw '$executable ${arguments.join(' ')} exited with $code';
}

Future<String> _capture(String executable, List<String> arguments,
    {String? cwd}) async {
  final result =
      await Process.run(executable, arguments, workingDirectory: cwd);
  if (result.exitCode != 0) throw '$executable failed: ${result.stderr}';
  return result.stdout as String;
}

Future<String> _captureOrEmpty(String executable, List<String> arguments,
    {String? cwd}) async {
  try {
    return await _capture(executable, arguments, cwd: cwd);
  } catch (_) {
    return '';
  }
}
