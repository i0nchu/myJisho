import 'dart:typed_data';

/// A cooperative cancellation signal shared by the UI, network source, and
/// staging writer. Cancellation is honored only before activation begins.
class UpdateCancellationToken {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const UpdateCancelledException();
  }

  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

class UpdateCancelledException implements Exception {
  const UpdateCancelledException();

  @override
  String toString() => 'Dictionary update cancelled.';
}

class DictionaryDownloadException implements Exception {
  const DictionaryDownloadException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class InsufficientStorageException implements Exception {
  const InsufficientStorageException({
    required this.requiredBytes,
    this.availableBytes,
    this.cause,
  });

  final int requiredBytes;
  final int? availableBytes;
  final Object? cause;

  @override
  String toString() {
    final available = availableBytes == null
        ? ''
        : ' (available: $availableBytes bytes)';
    return 'Insufficient storage for $requiredBytes bytes$available.';
  }
}

enum DictionaryUpdateProgressPhase {
  checkingMetadata,
  preparingStorage,
  downloading,
  verifying,
  activating,
  reopening,
}

class DictionaryUpdateProgress {
  const DictionaryUpdateProgress({
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes,
  });

  final DictionaryUpdateProgressPhase phase;
  final int receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0, 1);
  }
}

typedef DictionaryUpdateProgressCallback =
    void Function(DictionaryUpdateProgress progress);

/// Raw trusted metadata files. Their exact bytes are required because
/// checksums.txt hashes the files, not a re-serialized JSON representation.
class CompletePackageMetadata {
  const CompletePackageMetadata({
    required this.releaseManifestBytes,
    required this.assetsManifestBytes,
    required this.checksumsBytes,
  });

  final Uint8List releaseManifestBytes;
  final Uint8List assetsManifestBytes;
  final Uint8List checksumsBytes;
}

class DictionaryDownload {
  const DictionaryDownload({
    required this.bytes,
    this.contentLength,
    this.onDispose,
  });

  final Stream<List<int>> bytes;
  final int? contentLength;
  final Future<void> Function()? onDispose;

  Future<void> dispose() async {
    await onDispose?.call();
  }
}

class StagedDictionary {
  const StagedDictionary({
    required this.handle,
    required this.size,
    required this.sha256,
  });

  final String handle;
  final int size;
  final String sha256;
}
