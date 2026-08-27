import 'dart:io';

import 'package:app_updater_cli/src/artifact_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('uses Windows executable and classpath conventions', () {
    expect(executableName('flutter', windows: true), 'flutter.bat');
    expect(executableName('dart', windows: true), 'dart.bat');
    expect(executableName('git', windows: true), 'git');
    expect(javaClasspathSeparator(windows: true), ';');
    expect(javaClasspathSeparator(windows: false), ':');
    expect(commandRequiresShell('flutter.bat', windows: true), isTrue);
    expect(commandRequiresShell('java.exe', windows: true), isFalse);
    expect(commandRequiresShell('flutter', windows: false), isFalse);
  });

  test('uses LOCALAPPDATA for the Windows artifact cache', () {
    final directory = artifactCacheDirectory(
      environment: {'LOCALAPPDATA': r'C:\Users\dev\AppData\Local'},
      windows: true,
    );
    expect(
      directory.path,
      r'C:\Users\dev\AppData\Local\app_updater\cache\jbsdiff',
    );
  });

  test('writes the canonical manifest payload with LF newlines', () {
    final temporary = Directory.systemTemp.createTempSync('manifest_payload_');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final output = File('${temporary.path}/payload.txt');
    writeManifestPayload(
      output,
      schemaVersion: 2,
      otaProtocolVersion: 2,
      release: '1.0.0+1',
      patchNumber: 2,
      artifactKind: 'binary_diff',
      engineRevision: 'a' * 40,
      dartVersion: '3.4.0',
      abi: 'arm64-v8a',
      buildMode: 'release',
      baseSha256: 'c' * 64,
      buildFingerprint: 'd' * 64,
      sha256Hash: 'b' * 64,
      signatureKeyId: 'release-2026',
      signatureAlgorithm: 'rsa_pkcs1_sha256',
    );
    final payload = output.readAsStringSync();
    expect(payload, contains('patch_number=2\n'));
    expect(payload, endsWith('signature_algorithm=rsa_pkcs1_sha256\n'));
    expect(payload, isNot(contains('\r\n')));
  });

  test('rejects multiline manifest values on every platform', () {
    final temporary = Directory.systemTemp.createTempSync('manifest_payload_');
    addTearDown(() => temporary.deleteSync(recursive: true));
    expect(
      () => writeManifestPayload(
        File('${temporary.path}/payload.txt'),
        schemaVersion: 2,
        otaProtocolVersion: 2,
        release: '1.0.0+1\nmalicious=true',
        patchNumber: 2,
        artifactKind: 'binary_diff',
        engineRevision: 'a' * 40,
        dartVersion: '3.4.0',
        abi: 'arm64-v8a',
        buildMode: 'release',
        baseSha256: 'c' * 64,
        buildFingerprint: 'd' * 64,
        sha256Hash: 'b' * 64,
        signatureKeyId: 'release-2026',
        signatureAlgorithm: 'rsa_pkcs1_sha256',
      ),
      throwsA(anything),
    );
  });

  test('build fingerprint matches shell, backend, and Android contract', () {
    expect(
      computeBuildFingerprint(
        otaProtocolVersion: 2,
        release: '1.0.0+1',
        engineRevision: '83675ed27633283e7fc296c8bca22e841224c096',
        dartVersion: '3.12.2',
        abi: 'arm64-v8a',
        buildMode: 'release',
        baseSha256: 'a' * 64,
      ),
      '46612b3568f1b3220765c4138063d6940fdb87bc5dd5197555bd3c188e0be766',
    );
  });

  test('extracts libapp and enforces Dart-only archive changes', () async {
    final temporary = Directory.systemTemp.createTempSync('artifact_tools_');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final base = await _createArchive(
      temporary,
      'base.aab',
      libappContents: 'dart-v1',
      resourceContents: 'unchanged',
    );
    final dartPatch = await _createArchive(
      temporary,
      'dart-patch.aab',
      libappContents: 'dart-v2',
      resourceContents: 'unchanged',
    );
    final nativePatch = await _createArchive(
      temporary,
      'native-patch.aab',
      libappContents: 'dart-v2',
      resourceContents: 'changed',
    );

    final output = Directory(p.join(temporary.path, 'output'));
    final extracted = await extractLibapp(dartPatch, 'arm64-v8a', output);
    expect(extracted.readAsStringSync(), 'dart-v2');
    expect(File('${extracted.path}.sha256').existsSync(), isTrue);
    await verifyDartOnlyPatch(base, dartPatch, 'arm64-v8a');
    await expectLater(
      verifyDartOnlyPatch(base, nativePatch, 'arm64-v8a'),
      throwsA(contains('Patch is not Dart-only')),
    );
  });
}

Future<File> _createArchive(
  Directory root,
  String name, {
  required String libappContents,
  required String resourceContents,
}) async {
  final source = Directory(p.join(root.path, '$name-source'))
    ..createSync(recursive: true);
  final library = File(
    p.join(source.path, 'base', 'lib', 'arm64-v8a', 'libapp.so'),
  );
  library.parent.createSync(recursive: true);
  library.writeAsStringSync(libappContents);
  File(p.join(source.path, 'resources.pb')).writeAsStringSync(resourceContents);
  final archive = File(p.join(root.path, name));
  await runInherited(
    Platform.isWindows ? 'jar.exe' : 'jar',
    ['cf', archive.absolute.path, '.'],
    cwd: source.path,
  );
  return archive;
}
