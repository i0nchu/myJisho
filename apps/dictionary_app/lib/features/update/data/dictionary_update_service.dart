import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/release_manifest.dart';
import '../domain/update_models.dart';

/// Compatibility boundary for existing in-memory tests and developer sources.
///
/// Production remote updates additionally implement
/// [CompleteDictionaryPackageSource], which prevents a database-only source
/// from being presented as a complete release package.
abstract interface class DictionaryPackageSource {
  Future<Map<String, Object?>> fetchManifest();
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest);
}

abstract interface class CompleteDictionaryPackageSource {
  Future<CompletePackageMetadata> fetchCompletePackageMetadata(
    UpdateCancellationToken cancellationToken,
  );

  Future<DictionaryDownload> openDatabaseDownload(
    ReleaseManifest manifest,
    UpdateCancellationToken cancellationToken,
  );
}

abstract interface class DictionaryUpdateStorage {
  Future<String> stage(Uint8List databaseBytes);
  Future<bool> isHealthy(String stagedHandle);
  Future<void> activate(String stagedHandle);
  Future<void> commit();
  Future<void> rollback();
  Future<void> discard(String stagedHandle);
}

abstract interface class StreamingDictionaryUpdateStorage {
  Future<void> ensureCapacity(int requiredBytes);

  Future<StagedDictionary> stageStream(
    Stream<List<int>> databaseBytes, {
    required int expectedSize,
    required UpdateCancellationToken cancellationToken,
    DictionaryUpdateProgressCallback? onProgress,
  });
}

abstract interface class ManifestValidatingUpdateStorage {
  Future<bool> matchesManifest(String stagedHandle, ReleaseManifest manifest);
}

enum DictionaryUpdateResult {
  updated,
  alreadyCurrent,
  cancelled,
  downloadFailed,
  insufficientStorage,
  invalidManifest,
  invalidPackageContract,
  invalidReleaseChannel,
  unreviewedContent,
  unclearedLicense,
  invalidDatabaseFile,
  incompatibleSchema,
  incompatibleApp,
  packageTooLarge,
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
    this.beforeRollback,
    this.afterRollback,
    this.cancellationToken,
    this.onProgress,
    this.maxDatabaseSizeBytes = 150 * 1024 * 1024,
  });

  final DictionaryPackageSource source;
  final DictionaryUpdateStorage storage;
  final int supportedSchemaVersion;
  final String currentDictionaryVersion;
  final String currentAppVersion;
  final Future<void> Function()? beforeActivate;
  final Future<void> Function()? afterActivate;
  final Future<void> Function()? beforeRollback;
  final Future<void> Function()? afterRollback;
  final UpdateCancellationToken? cancellationToken;
  final DictionaryUpdateProgressCallback? onProgress;
  final int maxDatabaseSizeBytes;

  Future<DictionaryUpdateResult> checkAndInstall() async {
    final cancellation = cancellationToken ?? UpdateCancellationToken();
    onProgress?.call(
      const DictionaryUpdateProgress(
        phase: DictionaryUpdateProgressPhase.checkingMetadata,
      ),
    );

    final completeSource = source is CompleteDictionaryPackageSource
        ? source as CompleteDictionaryPackageSource
        : null;
    late ReleaseManifest manifest;
    if (completeSource != null) {
      try {
        cancellation.throwIfCancelled();
        final metadata = await completeSource.fetchCompletePackageMetadata(
          cancellation,
        );
        manifest = ReleasePackageContract.parseAndValidate(metadata);
      } on UpdateCancelledException {
        return DictionaryUpdateResult.cancelled;
      } on DictionaryDownloadException {
        return DictionaryUpdateResult.downloadFailed;
      } on FormatException {
        return DictionaryUpdateResult.invalidPackageContract;
      }
    } else {
      try {
        manifest = ReleaseManifest.fromJson(await source.fetchManifest());
      } on FormatException {
        return DictionaryUpdateResult.invalidManifest;
      } on Object {
        return DictionaryUpdateResult.downloadFailed;
      }
    }

    final preflight = _validateManifest(manifest);
    if (preflight != null) return preflight;

    if (completeSource != null) {
      return _installStreamed(completeSource, manifest, cancellation);
    }
    return _installLegacy(manifest);
  }

  DictionaryUpdateResult? _validateManifest(ReleaseManifest manifest) {
    if (manifest.channel != 'release') {
      return DictionaryUpdateResult.invalidReleaseChannel;
    }
    if (manifest.contentStatus != 'reviewed') {
      return DictionaryUpdateResult.unreviewedContent;
    }
    if (manifest.licenseStatus != 'cleared') {
      return DictionaryUpdateResult.unclearedLicense;
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
    if (manifest.databaseSize > maxDatabaseSizeBytes) {
      return DictionaryUpdateResult.packageTooLarge;
    }
    if (_compareVersions(
          currentDictionaryVersion,
          manifest.dictionaryVersion,
        ) >=
        0) {
      return DictionaryUpdateResult.alreadyCurrent;
    }
    return null;
  }

  Future<DictionaryUpdateResult> _installStreamed(
    CompleteDictionaryPackageSource completeSource,
    ReleaseManifest manifest,
    UpdateCancellationToken cancellation,
  ) async {
    final streamingStorage = storage is StreamingDictionaryUpdateStorage
        ? storage as StreamingDictionaryUpdateStorage
        : null;
    if (streamingStorage == null) {
      throw StateError(
        'Complete remote packages require streaming update storage.',
      );
    }

    onProgress?.call(
      DictionaryUpdateProgress(
        phase: DictionaryUpdateProgressPhase.preparingStorage,
        totalBytes: manifest.databaseSize,
      ),
    );
    try {
      cancellation.throwIfCancelled();
      await streamingStorage.ensureCapacity(manifest.databaseSize);
    } on UpdateCancelledException {
      return DictionaryUpdateResult.cancelled;
    } on InsufficientStorageException {
      return DictionaryUpdateResult.insufficientStorage;
    }

    late DictionaryDownload download;
    try {
      download = await completeSource.openDatabaseDownload(
        manifest,
        cancellation,
      );
    } on UpdateCancelledException {
      return DictionaryUpdateResult.cancelled;
    } on DictionaryDownloadException {
      return DictionaryUpdateResult.downloadFailed;
    } on Object {
      return DictionaryUpdateResult.downloadFailed;
    }
    if (download.contentLength != null &&
        download.contentLength != manifest.databaseSize) {
      await download.dispose();
      return DictionaryUpdateResult.invalidSize;
    }

    late StagedDictionary staged;
    try {
      staged = await streamingStorage.stageStream(
        download.bytes,
        expectedSize: manifest.databaseSize,
        cancellationToken: cancellation,
        onProgress: onProgress,
      );
    } on UpdateCancelledException {
      return DictionaryUpdateResult.cancelled;
    } on InsufficientStorageException {
      return DictionaryUpdateResult.insufficientStorage;
    } on DictionaryDownloadException {
      return DictionaryUpdateResult.downloadFailed;
    } on Object {
      return DictionaryUpdateResult.downloadFailed;
    } finally {
      await download.dispose();
    }
    if (staged.size != manifest.databaseSize) {
      await storage.discard(staged.handle);
      return DictionaryUpdateResult.invalidSize;
    }
    if (!_constantTimeEquals(
      staged.sha256,
      manifest.databaseSha256.toLowerCase(),
    )) {
      await storage.discard(staged.handle);
      return DictionaryUpdateResult.invalidChecksum;
    }
    return _verifyAndActivate(
      staged.handle,
      manifest,
      requireManifestMatch: true,
      cancellation: cancellation,
    );
  }

  Future<DictionaryUpdateResult> _installLegacy(
    ReleaseManifest manifest,
  ) async {
    late Uint8List bytes;
    try {
      bytes = await source.fetchDatabase(manifest);
    } on Object {
      return DictionaryUpdateResult.downloadFailed;
    }
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
    return _verifyAndActivate(
      staged,
      manifest,
      requireManifestMatch: false,
      cancellation: UpdateCancellationToken(),
    );
  }

  Future<DictionaryUpdateResult> _verifyAndActivate(
    String staged,
    ReleaseManifest manifest, {
    required bool requireManifestMatch,
    required UpdateCancellationToken cancellation,
  }) async {
    try {
      onProgress?.call(
        DictionaryUpdateProgress(
          phase: DictionaryUpdateProgressPhase.verifying,
          receivedBytes: manifest.databaseSize,
          totalBytes: manifest.databaseSize,
        ),
      );
      if (!await storage.isHealthy(staged)) {
        await storage.discard(staged);
        return DictionaryUpdateResult.unhealthyDatabase;
      }
      if (requireManifestMatch) {
        final validatingStorage = storage is ManifestValidatingUpdateStorage
            ? storage as ManifestValidatingUpdateStorage
            : null;
        if (validatingStorage == null ||
            !await validatingStorage.matchesManifest(staged, manifest)) {
          await storage.discard(staged);
          return DictionaryUpdateResult.unhealthyDatabase;
        }
      }
      cancellation.throwIfCancelled();

      var handoffStarted = false;
      try {
        onProgress?.call(
          DictionaryUpdateProgress(
            phase: DictionaryUpdateProgressPhase.activating,
            receivedBytes: manifest.databaseSize,
            totalBytes: manifest.databaseSize,
          ),
        );
        await beforeActivate?.call();
        handoffStarted = true;
        try {
          await storage.activate(staged);
          onProgress?.call(
            DictionaryUpdateProgress(
              phase: DictionaryUpdateProgressPhase.reopening,
              receivedBytes: manifest.databaseSize,
              totalBytes: manifest.databaseSize,
            ),
          );
          await afterActivate?.call();
          await storage.commit();
        } on Object {
          await beforeRollback?.call();
          await storage.rollback();
          await (afterRollback ?? afterActivate)?.call();
          rethrow;
        }
        return DictionaryUpdateResult.updated;
      } finally {
        // A failed pre-activation callback leaves the active database untouched.
        if (!handoffStarted) await storage.discard(staged);
      }
    } on UpdateCancelledException {
      await storage.discard(staged);
      return DictionaryUpdateResult.cancelled;
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

class ReleasePackageContract {
  const ReleasePackageContract._();

  static final RegExp _sha256 = RegExp(r'^[a-f0-9]{64}$');

  static ReleaseManifest parseAndValidate(CompletePackageMetadata metadata) {
    final releaseJson = _decodeObject(
      metadata.releaseManifestBytes,
      'release-manifest.json',
    );
    final manifest = ReleaseManifest.fromJson(
      releaseJson,
      requireCompleteContract: true,
    );
    final assetsJson = _decodeObject(
      metadata.assetsManifestBytes,
      'assets-manifest.json',
    );
    final assets = _validateAssetsManifest(assetsJson, manifest);

    final checksums = _parseChecksums(metadata.checksumsBytes);
    final expected = <String>{
      'dictionary.sqlite',
      'assets-manifest.json',
      'release-manifest.json',
    };
    if (checksums.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(checksums.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'checksums.txt must cover exactly the three release files.',
      );
    }
    if (!_constantTimeEquals(
      checksums['dictionary.sqlite']!,
      manifest.databaseSha256,
    )) {
      throw const FormatException(
        'checksums.txt and release manifest disagree about the database.',
      );
    }
    _requireBytesHash(
      metadata.releaseManifestBytes,
      checksums['release-manifest.json']!,
      'release-manifest.json',
    );
    _requireBytesHash(
      metadata.assetsManifestBytes,
      checksums['assets-manifest.json']!,
      'assets-manifest.json',
    );
    return manifest.withAssets(assets);
  }

  static Map<String, Object?> _decodeObject(Uint8List bytes, String filename) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw FormatException('$filename must contain one JSON object.');
    }
    return decoded;
  }

  static List<ReleaseAssetRecord> _validateAssetsManifest(
    Map<String, Object?> json,
    ReleaseManifest manifest,
  ) {
    const fields = <String>{
      'schema_version',
      'dictionary_version',
      'released_at',
      'assets',
    };
    if (json.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(json.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'assets-manifest.json fields do not match the supported contract.',
      );
    }
    final assetsReleasedAt = json['released_at'];
    final parsedAssetsReleasedAt = assetsReleasedAt is String
        ? DateTime.tryParse(assetsReleasedAt)
        : null;
    if (json['schema_version'] != 1 ||
        json['dictionary_version'] != manifest.dictionaryVersion ||
        parsedAssetsReleasedAt == null ||
        !parsedAssetsReleasedAt.isAtSameMomentAs(manifest.releasedAt)) {
      throw const FormatException(
        'Assets manifest version metadata does not match the release manifest.',
      );
    }
    final assets = json['assets'];
    if (assets is! List<Object?>) {
      throw const FormatException('assets must be an array.');
    }
    final ids = <String>{};
    final paths = <String>{};
    final validated = <ReleaseAssetRecord>[];
    const assetFields = <String>{
      'asset_id',
      'kind',
      'path',
      'sha256',
      'source_id',
      'license_spdx',
    };
    for (final rawAsset in assets) {
      if (rawAsset is! Map<String, Object?> ||
          rawAsset.keys.toSet().difference(assetFields).isNotEmpty ||
          assetFields.difference(rawAsset.keys.toSet()).isNotEmpty) {
        throw const FormatException('Invalid asset manifest item.');
      }
      final id = rawAsset['asset_id'];
      final kind = rawAsset['kind'];
      final path = rawAsset['path'];
      final digest = rawAsset['sha256'];
      final sourceId = rawAsset['source_id'];
      final license = rawAsset['license_spdx'];
      if (id is! String ||
          id.isEmpty ||
          !ids.add(id) ||
          kind is! String ||
          (kind != 'image' && kind != 'audio') ||
          path is! String ||
          !_isSafeAssetPath(path) ||
          !paths.add(path) ||
          digest is! String ||
          !_sha256.hasMatch(digest) ||
          sourceId is! String ||
          sourceId.isEmpty ||
          license is! String ||
          license.isEmpty) {
        throw const FormatException('Invalid asset manifest item value.');
      }
      validated.add(
        ReleaseAssetRecord(
          assetId: id,
          kind: kind,
          path: path,
          sha256: digest,
          sourceId: sourceId,
          licenseSpdx: license,
        ),
      );
    }
    return validated;
  }

  static bool _isSafeAssetPath(String value) {
    if (value.isEmpty ||
        value.contains('\u0000') ||
        value.contains(r'\') ||
        value.startsWith('/') ||
        value.endsWith('/') ||
        value.contains('//') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      return false;
    }
    final segments = value.split('/');
    return !segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    );
  }

  static Map<String, String> _parseChecksums(Uint8List bytes) {
    final text = utf8.decode(bytes);
    final lines = text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final result = <String, String>{};
    for (final line in lines) {
      final separator = line.indexOf('  ');
      if (separator != 64 ||
          line.indexOf('  ', separator + 2) >= 0 ||
          line.contains('\r')) {
        throw const FormatException('Malformed checksums.txt line.');
      }
      final digest = line.substring(0, separator);
      final filename = line.substring(separator + 2);
      if (!_sha256.hasMatch(digest) ||
          !<String>{
            'dictionary.sqlite',
            'assets-manifest.json',
            'release-manifest.json',
          }.contains(filename) ||
          result.containsKey(filename)) {
        throw const FormatException('Malformed checksums.txt line.');
      }
      result[filename] = digest;
    }
    return result;
  }

  static void _requireBytesHash(
    Uint8List bytes,
    String expected,
    String filename,
  ) {
    final actual = sha256.convert(bytes).toString();
    if (!_constantTimeEquals(actual, expected)) {
      throw FormatException('$filename checksum mismatch.');
    }
  }

  static bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a);
    final right = utf8.encode(b);
    var difference = left.length ^ right.length;
    final count = left.length < right.length ? left.length : right.length;
    for (var index = 0; index < count; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
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
