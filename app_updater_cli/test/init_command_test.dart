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
}
