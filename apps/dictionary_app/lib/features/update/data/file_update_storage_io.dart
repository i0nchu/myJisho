import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/release_manifest.dart';
import '../domain/update_models.dart';
import 'dictionary_update_service.dart';

DictionaryUpdateStorage createFileUpdateStorage({
  required String activeDatabasePath,
  required Future<bool> Function(String path) healthCheck,
  Future<bool> Function(String path, ReleaseManifest manifest)?
  manifestHealthCheck,
  Future<int?> Function(String path)? availableBytes,
}) {
  return FileDictionaryUpdateStorage(
    activeDatabasePath: activeDatabasePath,
    healthCheck: healthCheck,
    manifestHealthCheck: manifestHealthCheck,
    availableBytes: availableBytes,
  );
}

class FileDictionaryUpdateStorage
    implements
        DictionaryUpdateStorage,
        StreamingDictionaryUpdateStorage,
        ManifestValidatingUpdateStorage {
  FileDictionaryUpdateStorage({
    required this.activeDatabasePath,
    required this.healthCheck,
    this.manifestHealthCheck,
    this.availableBytes,
  });

  final String activeDatabasePath;
  final Future<bool> Function(String path) healthCheck;
  final Future<bool> Function(String path, ReleaseManifest manifest)?
  manifestHealthCheck;
  final Future<int?> Function(String path)? availableBytes;

  String get _stagedPath => '$activeDatabasePath.staged';
  String get _backupPath => '$activeDatabasePath.backup';
  String get _markerPath => '$activeDatabasePath.update-in-progress';
  String get _lockPath => '$activeDatabasePath.update-lock';

  RandomAccessFile? _updateLock;

  Future<void> _recoverInterruptedUpdate() async {
    final marker = File(_markerPath);
    final backup = File(_backupPath);
    if (!await marker.exists()) return;
    if (await backup.exists()) {
      await _restoreBackup();
    }
    await marker.delete();
  }

  Future<void> _acquireUpdateLock() async {
    if (_updateLock != null) {
      throw StateError('This update storage already owns the update lock.');
    }
    final handle = await File(_lockPath).open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.blockingExclusive);
      _updateLock = handle;
    } on Object {
      await handle.close();
      rethrow;
    }
  }

  Future<void> _releaseUpdateLock() async {
    final handle = _updateLock;
    if (handle == null) return;
    _updateLock = null;
    try {
      await handle.unlock();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<String> stage(Uint8List databaseBytes) async {
    final result = await stageStream(
      Stream<List<int>>.value(databaseBytes),
      expectedSize: databaseBytes.length,
      cancellationToken: UpdateCancellationToken(),
    );
    return result.handle;
  }

  @override
  Future<void> ensureCapacity(int requiredBytes) async {
    final probe = availableBytes;
    if (probe == null) return;
    final available = await probe(activeDatabasePath);
    if (available == null) return;
    // Leave room for filesystem metadata and the transaction marker. The old
    // active database is renamed, not copied, so only the staging file needs
    // new allocation.
    final reserve = requiredBytes ~/ 20 + 1024 * 1024;
    final totalRequired = requiredBytes + reserve;
    if (available < totalRequired) {
      throw InsufficientStorageException(
        requiredBytes: totalRequired,
        availableBytes: available,
      );
    }
  }

  @override
  Future<StagedDictionary> stageStream(
    Stream<List<int>> databaseBytes, {
    required int expectedSize,
    required UpdateCancellationToken cancellationToken,
    DictionaryUpdateProgressCallback? onProgress,
  }) async {
    await _acquireUpdateLock();
    final staged = File(_stagedPath);
    RandomAccessFile? output;
    final digestOutput = _DigestOutput();
    final digestSink = sha256.startChunkedConversion(digestOutput);
    var received = 0;
    try {
      await _recoverInterruptedUpdate();
      await ensureCapacity(expectedSize);
      if (await staged.exists()) await staged.delete();
      output = await staged.open(mode: FileMode.write);
      await for (final chunk in databaseBytes) {
        cancellationToken.throwIfCancelled();
        received += chunk.length;
        if (received > expectedSize) {
          throw const DictionaryDownloadException(
            'Dictionary download exceeded its declared size.',
          );
        }
        digestSink.add(chunk);
        await output.writeFrom(chunk);
        onProgress?.call(
          DictionaryUpdateProgress(
            phase: DictionaryUpdateProgressPhase.downloading,
            receivedBytes: received,
            totalBytes: expectedSize,
          ),
        );
      }
      cancellationToken.throwIfCancelled();
      await output.flush();
      await output.close();
      output = null;
      digestSink.close();
      return StagedDictionary(
        handle: staged.path,
        size: received,
        sha256: digestOutput.value.toString(),
      );
    } on FileSystemException catch (error) {
      await _closeIgnoringErrors(output);
      if (await staged.exists()) await staged.delete();
      await _releaseUpdateLock();
      if (_isDiskFull(error)) {
        throw InsufficientStorageException(
          requiredBytes: expectedSize,
          cause: error,
        );
      }
      throw DictionaryDownloadException(
        'Could not write the staged dictionary.',
        error,
      );
    } on Object {
      await _closeIgnoringErrors(output);
      if (await staged.exists()) await staged.delete();
      await _releaseUpdateLock();
      rethrow;
    }
  }

  @override
  Future<bool> isHealthy(String stagedHandle) => healthCheck(stagedHandle);

  @override
  Future<bool> matchesManifest(String stagedHandle, ReleaseManifest manifest) {
    final check = manifestHealthCheck;
    if (check == null) return Future<bool>.value(false);
    return check(stagedHandle, manifest);
  }

  @override
  Future<void> activate(String stagedHandle) async {
    final active = File(activeDatabasePath);
    final backup = File(_backupPath);
    final staged = File(stagedHandle);
    if (await backup.exists()) await backup.delete();
    await File(_markerPath).writeAsString('replace', flush: true);
    if (await active.exists()) await active.rename(backup.path);
    try {
      await staged.rename(active.path);
    } on Object {
      if (await backup.exists() && !await active.exists()) {
        await backup.rename(active.path);
      }
      rethrow;
    }
  }

  @override
  Future<void> commit() async {
    final backup = File(_backupPath);
    final marker = File(_markerPath);
    try {
      // Removing the marker commits the already reopened active database.
      // A leftover backup is harmless and is cleaned on the next transaction.
      if (await marker.exists()) await marker.delete();
      try {
        if (await backup.exists()) await backup.delete();
      } on FileSystemException {
        // Do not roll back a healthy reopened database for cleanup failure.
      }
    } finally {
      await _releaseUpdateLock();
    }
  }

  @override
  Future<void> rollback() async {
    final backup = File(_backupPath);
    try {
      if (await backup.exists()) {
        await _restoreBackup();
      }
      final marker = File(_markerPath);
      if (await marker.exists()) await marker.delete();
    } finally {
      await _releaseUpdateLock();
    }
  }

  @override
  Future<void> discard(String stagedHandle) async {
    try {
      final file = File(stagedHandle);
      if (await file.exists()) await file.delete();
    } finally {
      await _releaseUpdateLock();
    }
  }

  Future<void> _restoreBackup() async {
    final active = File(activeDatabasePath);
    final backup = File(_backupPath);
    final displaced = File('$activeDatabasePath.failed-update');
    if (await displaced.exists()) await displaced.delete();
    if (await active.exists()) await active.rename(displaced.path);
    try {
      await backup.rename(active.path);
      if (await displaced.exists()) await displaced.delete();
    } on Object {
      if (!await active.exists() && await displaced.exists()) {
        await displaced.rename(active.path);
      }
      rethrow;
    }
  }

  Future<void> _closeIgnoringErrors(RandomAccessFile? file) async {
    if (file == null) return;
    try {
      await file.close();
    } on FileSystemException {
      // Preserve the original staging error.
    }
  }

  bool _isDiskFull(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == 28 || code == 39 || code == 112) return true;
    final message = '${error.message} ${error.osError?.message}'.toLowerCase();
    return message.contains('no space left') ||
        message.contains('disk full') ||
        message.contains('not enough space');
  }
}

class _DigestOutput implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final result = _value;
    if (result == null) throw StateError('Digest is not complete.');
    return result;
  }

  @override
  void add(Digest data) {
    if (_value != null) throw StateError('Digest was emitted more than once.');
    _value = data;
  }

  @override
  void close() {}
}
