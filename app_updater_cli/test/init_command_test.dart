import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('init edits a Flutter project with portable paths and the main branch',
      () async {
    final temporary = Directory.systemTemp.createTempSync('app_updater_init_');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final project = Directory(p.join(temporary.path, 'flutter app'))
      ..createSync(recursive: true);
    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync(
      'name: windows_fixture\nversion: 1.0.0+1\ndependencies:\n  flutter:\n    sdk: flutter\n',
    );
    final mainActivity = File(
      p.join(
        project.path,
        'android',
        'app',
        'src',
        'main',
        'kotlin',
        'com',
        'example',
        'windows_fixture',
        'MainActivity.kt',
      ),
    );
    mainActivity.parent.createSync(recursive: true);
    mainActivity.writeAsStringSync(
      'package com.example.windows_fixture\n\n'
      'import io.flutter.embedding.android.FlutterActivity\n\n'
      'class MainActivity : FlutterActivity()\n',
    );
    final mainDart = File(p.join(project.path, 'lib', 'main.dart'));
    mainDart.parent.createSync(recursive: true);
    mainDart.writeAsStringSync(
      "import 'package:flutter/widgets.dart';\n"
      'void main() {\n'
      '  WidgetsFlutterBinding.ensureInitialized();\n'
      '}\n',
    );
    final config = File(p.join(temporary.path, 'app_updater.yaml'))
      ..writeAsStringSync(
        'app_slug: windows-fixture\nbackend_url: https://updates.example.com\n',
      );

    Future<ProcessResult> runInit() => Process.run(
          Platform.resolvedExecutable,
          [
            'run',
            'bin/app_updater.dart',
            'init',
            '--project-dir',
            project.path,
            '--yaml-file',
            config.path,
          ],
          workingDirectory: Directory.current.path,
        );

    final first = await runInit();
    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    final pubspec =
        File(p.join(project.path, 'pubspec.yaml')).readAsStringSync();
    expect(pubspec, contains('ref: main'));
    expect(pubspec, isNot(contains('ref: master')));
    expect(mainActivity.readAsStringSync(), contains('FlutterOtaActivity'));
    expect(mainDart.readAsStringSync(),
        contains('AppUpdater.instance.autoUpdate()'));
    expect(File(p.join(project.path, 'app_updater.yaml')).existsSync(), isTrue);

    final second = await runInit();
    expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
    expect(
      'ref: main'.allMatches(
        File(p.join(project.path, 'pubspec.yaml')).readAsStringSync(),
      ),
      hasLength(1),
    );
  });

  test('init create discovers launcher icon and uploads it once', () async {
    final temporary = Directory.systemTemp.createTempSync('app_updater_logo_');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final project = Directory(p.join(temporary.path, 'project'))
      ..createSync(recursive: true);
    final icon = File(p.join(project.path, 'assets', 'icon', 'brand.png'));
    icon.parent.createSync(recursive: true);
    icon.writeAsBytesSync(List<int>.generate(256, (index) => index));
    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync(
      'name: logo_fixture\n'
      'version: 1.0.0+1\n'
      'dependencies:\n'
      '  flutter:\n'
      '    sdk: flutter\n'
      'flutter_launcher_icons:\n'
      '  image_path: assets/icon/brand.png\n',
    );

    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST' && request.uri.path == '/v1/cli/apps') {
        request.response.statusCode = 201;
        request.response.write(jsonEncode({
          'app': {'slug': 'logo-fixture'},
          'yaml': 'app_slug: logo-fixture\nbackend_url: http://localhost\n',
        }));
      } else if (request.method == 'PUT' &&
          request.uri.path == '/v1/cli/apps/logo-fixture/logo') {
        request.response
            .write(jsonEncode({'sha256': List.filled(64, 'a').join()}));
      } else {
        request.response.statusCode = 404;
        request.response.write(jsonEncode({'error': 'unexpected request'}));
      }
      await request.response.close();
    });

    final credentials = File(p.join(temporary.path, 'credentials.json'))
      ..writeAsStringSync(jsonEncode({
        'backend_url': 'http://127.0.0.1:${server.port}',
        'token': 'test-token',
        'email': 'owner@example.com',
      }));
    final environment = {
      ...Platform.environment,
      'APP_UPDATER_CREDENTIALS_FILE': credentials.path,
    };

    final first = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/app_updater.dart',
        'init',
        '--project-dir',
        project.path,
        '--create',
        '--app-slug',
        'logo-fixture',
        '--package-name',
        'com.example.logo_fixture',
      ],
      workingDirectory: Directory.current.path,
      environment: environment,
    );

    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    expect(first.stdout, contains('Uploaded app logo'));
    expect(requests, [
      'POST /v1/cli/apps',
      'PUT /v1/cli/apps/logo-fixture/logo',
    ]);

    // Idempotent reruns must not overwrite a logo that may have been changed in the portal.
    requests.clear();
    final second = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/app_updater.dart',
        'init',
        '--project-dir',
        project.path,
      ],
      workingDirectory: Directory.current.path,
      environment: environment,
    );
    expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
    expect(requests, isEmpty);

    final explicit = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/app_updater.dart',
        'init',
        '--project-dir',
        project.path,
        '--icon',
        'assets/icon/brand.png',
      ],
      workingDirectory: Directory.current.path,
      environment: environment,
    );
    expect(explicit.exitCode, 0,
        reason: '${explicit.stdout}\n${explicit.stderr}');
    expect(requests, ['PUT /v1/cli/apps/logo-fixture/logo']);
  });
}
