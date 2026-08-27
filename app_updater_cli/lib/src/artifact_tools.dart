import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const _supportedAbis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'};

String executableName(String executable, {bool? windows}) {
  final isWindows = windows ?? Platform.isWindows;
  if (isWindows && (executable == 'flutter' || executable == 'dart')) {
    return '$executable.bat';
  }
  return executable;
}

String javaClasspathSeparator({bool? windows}) =>
    (windows ?? Platform.isWindows) ? ';' : ':';

bool commandRequiresShell(String executable, {bool? windows}) {
  if (!(windows ?? Platform.isWindows)) return false;
  final lower = executable.toLowerCase();
  return lower.endsWith('.bat') || lower.endsWith('.cmd');
}

Directory artifactCacheDirectory({
  Map<String, String>? environment,
  bool? windows,
}) {
  final env = environment ?? Platform.environment;
  final override =
      env['APP_UPDATER_BSDIFF_CACHE_DIR'] ?? env['OTA_BSDIFF_CACHE_DIR'];
  if (override != null && override.isNotEmpty) return Directory(override);
  final isWindows = windows ?? Platform.isWindows;
  final localAppData = isWindows ? env['LOCALAPPDATA'] : null;
  final root = localAppData ?? (isWindows ? env['USERPROFILE'] : env['HOME']);
  if (root == null || root.isEmpty) {
    throw 'Cannot determine a user cache directory. Set '
        'APP_UPDATER_BSDIFF_CACHE_DIR.';
  }
  final context = isWindows ? p.windows : p.posix;
  return Directory(
    context.join(
      root,
      localAppData == null ? '.app_updater' : 'app_updater',
      'cache',
      'jbsdiff',
    ),
  );
}

Future<void> runInherited(
  String executable,
  List<String> arguments, {
  String? cwd,
}) async {
  final command = executableName(executable);
  try {
    final process = await Process.start(
      command,
      arguments,
      workingDirectory: cwd,
      mode: ProcessStartMode.inheritStdio,
      runInShell: commandRequiresShell(command),
    );
    final code = await process.exitCode;
    if (code != 0) {
      throw '$command ${arguments.join(' ')} exited with $code';
    }
  } on ProcessException catch (error) {
    throw 'Could not run $command. Ensure it is installed and on PATH. '
        '(${error.message})';
  }
}

Future<String> captureText(
  String executable,
  List<String> arguments, {
  String? cwd,
}) async {
  final result = await _runCaptured(executable, arguments, cwd: cwd);
  return result.stdout as String;
}

Future<List<int>> captureBinary(
  String executable,
  List<String> arguments, {
  String? cwd,
}) async {
  final result = await _runCaptured(
    executable,
    arguments,
    cwd: cwd,
    binaryStdout: true,
  );
  return result.stdout as List<int>;
}

Future<ProcessResult> _runCaptured(
  String executable,
  List<String> arguments, {
  String? cwd,
  bool binaryStdout = false,
}) async {
  final command = executableName(executable);
  try {
    final result = await Process.run(
      command,
      arguments,
      workingDirectory: cwd,
      runInShell: commandRequiresShell(command),
      stdoutEncoding: binaryStdout ? null : systemEncoding,
      stderrEncoding: systemEncoding,
    );
    if (result.exitCode != 0) {
      throw '$command ${arguments.join(' ')} exited with ${result.exitCode}: '
          '${result.stderr}';
    }
    return result;
  } on ProcessException catch (error) {
    throw 'Could not run $command. Ensure it is installed and on PATH. '
        '(${error.message})';
  }
}

Future<File> extractLibapp(
  File archive,
  String abi,
  Directory outputDirectory,
) async {
  _validateArchiveAndAbi(archive, abi);
  final entries = await _archiveEntries(archive);
  final entry = _libappEntry(entries, abi, archive.path);
  final temporary =
      await Directory.systemTemp.createTemp('app_updater_extract_');
  try {
    await _extractArchive(archive, temporary, [entry]);
    final extracted = File(p.joinAll([temporary.path, ...entry.split('/')]));
    if (!extracted.existsSync()) {
      throw 'Failed to extract $entry from ${archive.path}.';
    }
    outputDirectory.createSync(recursive: true);
    final output = File(p.join(outputDirectory.path, 'libapp.so'));
    extracted.copySync(output.path);
    final hash = sha256.convert(output.readAsBytesSync()).toString();
    File('${output.path}.sha256').writeAsStringSync('$hash  libapp.so\n');
    stdout.writeln('$entry -> ${output.path}');
    stdout.writeln('sha256: $hash');
    return output;
  } finally {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}

Future<void> verifyDartOnlyPatch(
  File baseArchive,
  File patchArchive,
  String abi,
) async {
  _validateArchiveAndAbi(baseArchive, abi);
  _validateArchiveAndAbi(patchArchive, abi);
  final baseEntries = await _archiveEntries(baseArchive);
  final targetEntry = _libappEntry(baseEntries, abi, baseArchive.path);
  final patchEntries = await _archiveEntries(patchArchive);
  if (!patchEntries.contains(targetEntry)) {
    throw '$targetEntry is not present in ${patchArchive.path}. Use artifacts '
        'built for the same target ABI.';
  }

  final temporary =
      await Directory.systemTemp.createTemp('app_updater_verify_');
  final baseDirectory = Directory(p.join(temporary.path, 'base'))..createSync();
  final patchDirectory = Directory(p.join(temporary.path, 'patch'))
    ..createSync();
  try {
    await _extractArchive(baseArchive, baseDirectory);
    await _extractArchive(patchArchive, patchDirectory);
    final baseFiles = _comparableFiles(baseDirectory, targetEntry, abi);
    final patchFiles = _comparableFiles(patchDirectory, targetEntry, abi);
    final allPaths = {...baseFiles.keys, ...patchFiles.keys}.toList()..sort();
    final differences = <String>[];
    for (final relativePath in allPaths) {
      final baseFile = baseFiles[relativePath];
      final patchFile = patchFiles[relativePath];
      if (baseFile == null) {
        differences.add('Only in patch: $relativePath');
      } else if (patchFile == null) {
        differences.add('Only in base: $relativePath');
      } else if (baseFile.lengthSync() != patchFile.lengthSync() ||
          await _fileHash(baseFile) != await _fileHash(patchFile)) {
        differences.add('Files differ: $relativePath');
      }
      if (differences.length >= 80) break;
    }
    if (differences.isNotEmpty) {
      throw 'Patch is not Dart-only. Archive content outside $targetEntry '
          'changed:\n${differences.join('\n')}\nPublish these native, asset, or '
          'resource changes through a new Play Store release.';
    }
    stdout.writeln(
      'Dart-only archive guard passed: only $targetEntry '
      '(and signing/debug metadata) changed',
    );
  } finally {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}

Future<File> generateBinaryDiff(
  File baseArtifact,
  File patchedArtifact,
  File output,
) async {
  if (!baseArtifact.existsSync()) {
    throw 'Base artifact not found: ${baseArtifact.path}';
  }
  if (!patchedArtifact.existsSync()) {
    throw 'Patched artifact not found: ${patchedArtifact.path}';
  }
  const jbsdiffVersion = '1.0';
  const commonsCompressVersion = '1.21';
  final cache = artifactCacheDirectory()..createSync(recursive: true);
  final jbsdiff = File(p.join(cache.path, 'jbsdiff-$jbsdiffVersion.jar'));
  final commons = File(
    p.join(cache.path, 'commons-compress-$commonsCompressVersion.jar'),
  );
  await _downloadIfMissing(
    jbsdiff,
    Uri.parse(
      'https://repo1.maven.org/maven2/io/sigpipe/jbsdiff/'
      '$jbsdiffVersion/jbsdiff-$jbsdiffVersion.jar',
    ),
  );
  await _downloadIfMissing(
    commons,
    Uri.parse(
      'https://repo1.maven.org/maven2/org/apache/commons/commons-compress/'
      '$commonsCompressVersion/commons-compress-$commonsCompressVersion.jar',
    ),
  );
  output.parent.createSync(recursive: true);
  if (output.existsSync()) output.deleteSync();
  final classpath = [jbsdiff.path, commons.path].join(javaClasspathSeparator());
  await runInherited(_javaTool('java'), [
    '-cp',
    classpath,
    'io.sigpipe.jbsdiff.ui.CLI',
    'diff',
    baseArtifact.path,
    patchedArtifact.path,
    output.path,
  ]);
  if (!output.existsSync()) throw 'Binary diff was not created: ${output.path}';
  stdout.writeln('Binary diff: ${output.path} (${output.lengthSync()} bytes)');
  return output;
}

void writeManifestPayload(
  File output, {
  required int schemaVersion,
  required int otaProtocolVersion,
  required String release,
  required int patchNumber,
  required String artifactKind,
  required String engineRevision,
  required String dartVersion,
  required String abi,
  required String buildMode,
  required String baseSha256,
  required String buildFingerprint,
  required String sha256Hash,
  required String signatureKeyId,
  required String signatureAlgorithm,
}) {
  if (schemaVersion != 2) throw 'Unsupported schema version.';
  if (otaProtocolVersion != 2) throw 'Unsupported OTA protocol version.';
  if (patchNumber < 0) throw 'Invalid patch number.';
  if (!{'full_aot_library', 'binary_diff'}.contains(artifactKind)) {
    throw 'Invalid artifact kind.';
  }
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(engineRevision)) {
    throw 'Invalid engine revision.';
  }
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256Hash)) {
    throw 'Invalid sha256.';
  }
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(baseSha256) ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(buildFingerprint)) {
    throw 'Invalid base SHA-256 or build fingerprint.';
  }
  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(signatureKeyId)) {
    throw 'Invalid signature key id.';
  }
  if (!{'ed25519', 'rsa_pkcs1_sha256'}.contains(signatureAlgorithm)) {
    throw 'Invalid signature algorithm.';
  }
  for (final value in [release, dartVersion, abi, buildMode]) {
    if (value.contains('\n') || value.contains('\r')) {
      throw 'Manifest values must fit on one line.';
    }
  }
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    'schema_version=$schemaVersion\n'
    'ota_protocol_version=$otaProtocolVersion\n'
    'release=$release\n'
    'patch_number=$patchNumber\n'
    'artifact_kind=$artifactKind\n'
    'engine_revision=$engineRevision\n'
    'dart_version=$dartVersion\n'
    'abi=$abi\n'
    'build_mode=$buildMode\n'
    'base_sha256=$baseSha256\n'
    'build_fingerprint=$buildFingerprint\n'
    'sha256=$sha256Hash\n'
    'signature_key_id=$signatureKeyId\n'
    'signature_algorithm=$signatureAlgorithm\n',
  );
}

String computeBuildFingerprint({
  required int otaProtocolVersion,
  required String release,
  required String engineRevision,
  required String dartVersion,
  required String abi,
  required String buildMode,
  required String baseSha256,
}) {
  final payload = 'ota_protocol_version=$otaProtocolVersion\n'
      'release=$release\n'
      'engine_revision=$engineRevision\n'
      'dart_version=$dartVersion\n'
      'abi=$abi\n'
      'build_mode=$buildMode\n'
      'base_sha256=$baseSha256\n';
  return sha256.convert(utf8.encode(payload)).toString();
}

void _validateArchiveAndAbi(File archive, String abi) {
  if (!archive.existsSync()) throw 'Archive not found: ${archive.path}';
  if (!_supportedAbis.contains(abi)) throw 'Unsupported Android ABI: $abi';
}

Future<Set<String>> _archiveEntries(File archive) async {
  final listing = await captureText(_javaTool('jar'), ['tf', archive.path]);
  return const LineSplitter()
      .convert(listing)
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toSet();
}

String _libappEntry(Set<String> entries, String abi, String archivePath) {
  final apkEntry = 'lib/$abi/libapp.so';
  final bundleEntry = 'base/$apkEntry';
  if (entries.contains(apkEntry)) return apkEntry;
  if (entries.contains(bundleEntry)) return bundleEntry;
  throw 'Neither $apkEntry nor $bundleEntry is present in $archivePath.';
}

Future<void> _extractArchive(
  File archive,
  Directory destination, [
  List<String> entries = const [],
]) async {
  await runInherited(
    _javaTool('jar'),
    ['xf', archive.absolute.path, ...entries],
    cwd: destination.path,
  );
}

Map<String, File> _comparableFiles(
  Directory root,
  String targetEntry,
  String abi,
) {
  final symbolEntry =
      'BUNDLE-METADATA/com.android.tools.build.debugsymbols/$abi/libapp.so.sym';
  final files = <String, File>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative =
        p.relative(entity.path, from: root.path).replaceAll('\\', '/');
    if (relative == targetEntry || relative == symbolEntry) continue;
    if (_isSigningEntry(relative)) continue;
    files[relative] = entity;
  }
  return files;
}

bool _isSigningEntry(String relativePath) {
  if (!relativePath.startsWith('META-INF/')) return false;
  final name = relativePath.split('/').last.toUpperCase();
  return name == 'MANIFEST.MF' ||
      name.endsWith('.SF') ||
      name.endsWith('.RSA') ||
      name.endsWith('.DSA') ||
      name.endsWith('.EC');
}

Future<String> _fileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _downloadIfMissing(File destination, Uri uri) async {
  if (destination.existsSync()) return;
  stdout.writeln('Downloading ${p.basename(destination.path)}');
  final response = await http.get(uri);
  if (response.statusCode != 200) {
    throw 'Download failed (${response.statusCode}): $uri';
  }
  final temporary = File('${destination.path}.tmp');
  temporary.writeAsBytesSync(response.bodyBytes, flush: true);
  temporary.renameSync(destination.path);
}

String _javaTool(String name) {
  final javaHome = Platform.environment['JAVA_HOME'];
  if (javaHome != null && javaHome.isNotEmpty) {
    final candidate = p.join(
      javaHome,
      'bin',
      Platform.isWindows ? '$name.exe' : name,
    );
    if (File(candidate).existsSync()) return candidate;
  }
  return Platform.isWindows ? '$name.exe' : name;
}
