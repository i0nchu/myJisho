import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/release_manifest.dart';

abstract interface class DictionaryPackageSource {
  Future<Map<String, Object?>> fetchManifest();
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest);
}

abstract interface class DictionaryUpdateStorage {
  Future<String> stage(Uint8List databaseBytes);
  Future<bool> isHealthy(String stagedHandle);
  Future<void> activate(String stagedHandle);
  Future<void> commit();
  Future<void> rollback();
  Future<void> discard(String stagedHandle);
}

enum DictionaryUpdateResult {
  updated,
  alreadyCurrent,
  invalidReleaseChannel,
  unreviewedContent,
  invalidDatabaseFile,
  incompatibleSchema,
  incompatibleApp,
  invalidSize,
  invalidChecksum,
  unhealthyDatabase,
}

class DictionaryUpdateService {
  const DictionaryUpdateService({
    required this.source,
    required this.storage,
    required this.supportedSchemaVersion,
    required this.currentDictionaryVersion,
    required this.currentAppVersion,
    this.beforeActivate,
    this.afterActivate,
  });

  final DictionaryPackageSource source;
  final DictionaryUpdateStorage storage;
  final int supportedSchemaVersion;
  final String currentDictionaryVersion;
  final String currentAppVersion;
  final Future<void> Function()? beforeActivate;
  final Future<void> Function()? afterActivate;

  Future<DictionaryUpdateResult> checkAndInstall() async {
    final manifest = ReleaseManifest.fromJson(await source.fetchManifest());
    if (manifest.channel != 'release') {
      return DictionaryUpdateResult.invalidReleaseChannel;
    }
    if (manifest.contentStatus != 'reviewed') {
      return DictionaryUpdateResult.unreviewedContent;
    }
    if (manifest.databaseFile != 'dictionary.sqlite') {
      return DictionaryUpdateResult.invalidDatabaseFile;
    }
    if (manifest.schemaVersion != supportedSchemaVersion) {
      return DictionaryUpdateResult.incompatibleSchema;
    }
    if (_compareVersions(currentAppVersion, manifest.minimumAppVersion) < 0) {
      return DictionaryUpdateResult.incompatibleApp;
    }
    if (_compareVersions(
          currentDictionaryVersion,
          manifest.dictionaryVersion,
        ) >=
        0) {
      return DictionaryUpdateResult.alreadyCurrent;
    }

    final bytes = await source.fetchDatabase(manifest);
    if (bytes.length != manifest.databaseSize) {
      return DictionaryUpdateResult.invalidSize;
    }
    final actualHash = sha256.convert(bytes).toString();
    if (!_constantTimeEquals(
      actualHash,
      manifest.databaseSha256.toLowerCase(),
    )) {
      return DictionaryUpdateResult.invalidChecksum;
    }

    final staged = await storage.stage(bytes);
    try {
      if (!await storage.isHealthy(staged)) {
        await storage.discard(staged);
        return DictionaryUpdateResult.unhealthyDatabase;
      }
      var handoffStarted = false;
      try {
        await beforeActivate?.call();
        handoffStarted = true;
        try {
          await storage.activate(staged);
          await afterActivate?.call();
          await storage.commit();
        } on Object {
          await storage.rollback();
          await afterActivate?.call();
          rethrow;
        }
        return DictionaryUpdateResult.updated;
      } finally {
        // A failed pre-activation callback leaves the active database untouched.
        if (!handoffStarted) await storage.discard(staged);
      }
    } on Object {
      await storage.discard(staged);
      rethrow;
    }
  }

  bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a);
    final right = utf8.encode(b);
    var difference = left.length ^ right.length;
    final count = left.length < right.length ? left.length : right.length;
    for (var index = 0; index < count; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  int _compareVersions(String left, String right) {
    return _SemanticVersion.parse(
      left,
    ).compareTo(_SemanticVersion.parse(right));
  }
}

class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.core, this.preRelease);

  factory _SemanticVersion.parse(String input) {
    final withoutBuild = input.split('+').first;
    final separator = withoutBuild.indexOf('-');
    final coreText = separator < 0
        ? withoutBuild
        : withoutBuild.substring(0, separator);
    final preRelease = separator < 0
        ? const <String>[]
        : withoutBuild.substring(separator + 1).split('.');
    final core = coreText
        .split('.')
        .map((part) {
          final match = RegExp(r'^\d+').firstMatch(part);
          return match == null ? 0 : int.parse(match.group(0)!);
        })
        .toList(growable: false);
    return _SemanticVersion(core, preRelease);
  }

  final List<int> core;
  final List<String> preRelease;

  @override
  int compareTo(_SemanticVersion other) {
    final count = core.length > other.core.length
        ? core.length
        : other.core.length;
    for (var index = 0; index < count; index++) {
      final left = index < core.length ? core[index] : 0;
      final right = index < other.core.length ? other.core[index] : 0;
      if (left != right) return left.compareTo(right);
    }
    if (preRelease.isEmpty && other.preRelease.isNotEmpty) return 1;
    if (preRelease.isNotEmpty && other.preRelease.isEmpty) return -1;
    for (
      var index = 0;
      index < preRelease.length && index < other.preRelease.length;
      index++
    ) {
      final left = preRelease[index];
      final right = other.preRelease[index];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      if (leftNumber != null &&
          rightNumber != null &&
          leftNumber != rightNumber) {
        return leftNumber.compareTo(rightNumber);
      }
      if (leftNumber != null && rightNumber == null) return -1;
      if (leftNumber == null && rightNumber != null) return 1;
      final lexical = left.compareTo(right);
      if (lexical != 0) return lexical;
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }
}
