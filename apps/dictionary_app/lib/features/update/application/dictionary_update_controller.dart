import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myjisho_dictionary_app/app_metadata.dart';

import '../../dictionary/application/dictionary_providers.dart';
import '../../dictionary/data/dictionary_repository.dart';
import '../data/dictionary_update_service.dart';
import '../data/file_update_storage.dart';
import '../data/local_directory_package_source.dart';
import '../data/remote_dictionary_package_source.dart';
import '../data/sqlite_dictionary_inspector.dart';
import '../domain/update_models.dart';

enum DictionaryUpdatePhase { idle, running, succeeded, failed, unsupported }

class DictionaryUpdateState {
  const DictionaryUpdateState({
    required this.phase,
    required this.message,
    this.currentVersion,
    this.progress,
    this.canCancel = false,
    this.remoteConfigured = false,
  });

  const DictionaryUpdateState.idle()
    : phase = DictionaryUpdatePhase.idle,
      message = '更新サーバーを確認できます。',
      currentVersion = null,
      progress = null,
      canCancel = false,
      remoteConfigured = false;

  final DictionaryUpdatePhase phase;
  final String message;
  final String? currentVersion;
  final double? progress;
  final bool canCancel;
  final bool remoteConfigured;

  bool get isRunning => phase == DictionaryUpdatePhase.running;
}

class DictionaryUpdateController extends Notifier<DictionaryUpdateState> {
  static const _schemaVersion = 1;
  static const _remoteBaseUrl = String.fromEnvironment(
    'MYJISHO_DICTIONARY_BASE_URL',
  );

  UpdateCancellationToken? _cancellationToken;

  bool get _isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  bool get _remoteConfigured => _remoteBaseUrl.trim().isNotEmpty;

  @override
  DictionaryUpdateState build() {
    ref.onDispose(() => _cancellationToken?.cancel());
    if (!_isSupportedPlatform) {
      return const DictionaryUpdateState(
        phase: DictionaryUpdatePhase.unsupported,
        message: 'このプラットフォームでは辞書更新を利用できません。',
      );
    }
    unawaited(_refreshCurrentVersion());
    return DictionaryUpdateState(
      phase: DictionaryUpdatePhase.idle,
      message: _remoteConfigured ? '更新サーバーを確認できます。' : '更新サーバーがこのビルドに設定されていません。',
      remoteConfigured: _remoteConfigured,
    );
  }

  Future<String> _activeDatabasePath() {
    return ref.read(activeDictionaryDatabasePathProvider.future);
  }

  Future<void> _refreshCurrentVersion() async {
    final version = await readDictionaryVersion(await _activeDatabasePath());
    state = DictionaryUpdateState(
      phase: DictionaryUpdatePhase.idle,
      message: _remoteConfigured ? '更新サーバーを確認できます。' : '更新サーバーがこのビルドに設定されていません。',
      currentVersion: version,
      remoteConfigured: _remoteConfigured,
    );
  }

  Future<void> checkForRemoteUpdate() async {
    if (!_isSupportedPlatform || state.isRunning) return;
    if (!_remoteConfigured) {
      state = DictionaryUpdateState(
        phase: DictionaryUpdatePhase.failed,
        message: '更新サーバーがこのビルドに設定されていません。',
        currentVersion: state.currentVersion,
      );
      return;
    }
    final baseUri = Uri.tryParse(_remoteBaseUrl);
    if (baseUri == null) {
      state = DictionaryUpdateState(
        phase: DictionaryUpdatePhase.failed,
        message: '更新サーバーの設定が正しくありません。',
        currentVersion: state.currentVersion,
      );
      return;
    }
    DictionaryPackageSource source;
    try {
      source = createRemoteDictionaryPackageSource(
        baseUri,
        allowInsecureLoopback: kDebugMode,
      );
    } on ArgumentError {
      state = DictionaryUpdateState(
        phase: DictionaryUpdatePhase.failed,
        message: '安全なHTTPS更新サーバーが設定されていません。',
        currentVersion: state.currentVersion,
      );
      return;
    }
    await _install(source);
  }

  /// Debug-only complete-package sideload for release engineering.
  Future<void> installFromDirectory(String directoryPath) async {
    if (!_isSupportedPlatform || state.isRunning) return;
    if (!kDebugMode) {
      state = DictionaryUpdateState(
        phase: DictionaryUpdatePhase.unsupported,
        message: '本機パッケージの読み込みはデバッグビルド専用です。',
        currentVersion: state.currentVersion,
        remoteConfigured: _remoteConfigured,
      );
      return;
    }
    final path = directoryPath.trim();
    if (path.isEmpty) {
      state = DictionaryUpdateState(
        phase: DictionaryUpdatePhase.failed,
        message: 'releaseフォルダーのパスを入力してください。',
        currentVersion: state.currentVersion,
        remoteConfigured: _remoteConfigured,
      );
      return;
    }
    await _install(createLocalDirectoryPackageSource(path));
  }

  void cancel() {
    if (!state.canCancel) return;
    state = DictionaryUpdateState(
      phase: DictionaryUpdatePhase.running,
      message: '更新をキャンセルしています…',
      currentVersion: state.currentVersion,
      progress: state.progress,
      remoteConfigured: _remoteConfigured,
    );
    _cancellationToken?.cancel();
  }

  Future<void> _install(DictionaryPackageSource source) async {
    final cancellation = UpdateCancellationToken();
    _cancellationToken = cancellation;
    state = DictionaryUpdateState(
      phase: DictionaryUpdatePhase.running,
      message: 'パッケージ情報を確認しています…',
      currentVersion: state.currentVersion,
      canCancel: true,
      remoteConfigured: _remoteConfigured,
    );

    try {
      final activePath = await _activeDatabasePath();
      final currentVersion = await readDictionaryVersion(activePath);
      DictionaryRepository? liveRepository = ref.read(
        dictionaryRepositoryProvider,
      );

      Future<void> closeLiveRepository() async {
        final repository = liveRepository;
        liveRepository = null;
        if (repository is DictionaryRepositoryLifecycle) {
          await (repository as DictionaryRepositoryLifecycle).close();
        }
      }

      Future<void> reopenAndVerifyRepository() async {
        final repository = ref.refresh(dictionaryRepositoryProvider);
        liveRepository = repository;
        try {
          await _verifyRepositoryReady(repository);
        } on Object {
          await closeLiveRepository();
          rethrow;
        }
        _invalidateDictionaryConsumers();
      }

      final service = DictionaryUpdateService(
        source: source,
        storage: createFileUpdateStorage(
          activeDatabasePath: activePath,
          healthCheck: isHealthySqliteDictionary,
          manifestHealthCheck: sqliteDictionaryMatchesManifest,
        ),
        supportedSchemaVersion: _schemaVersion,
        currentDictionaryVersion: currentVersion,
        currentAppVersion: myJishoVersion,
        cancellationToken: cancellation,
        onProgress: _showProgress,
        beforeActivate: closeLiveRepository,
        afterActivate: reopenAndVerifyRepository,
        beforeRollback: closeLiveRepository,
        afterRollback: reopenAndVerifyRepository,
      );
      final result = await service.checkAndInstall();
      final nextVersion = await readDictionaryVersion(activePath);
      state = DictionaryUpdateState(
        phase:
            result == DictionaryUpdateResult.updated ||
                result == DictionaryUpdateResult.alreadyCurrent
            ? DictionaryUpdatePhase.succeeded
            : result == DictionaryUpdateResult.cancelled
            ? DictionaryUpdatePhase.idle
            : DictionaryUpdatePhase.failed,
        message: _messageFor(result),
        currentVersion: nextVersion,
        remoteConfigured: _remoteConfigured,
      );
    } on Object catch (error) {
      state = DictionaryUpdateState(
        phase: DictionaryUpdatePhase.failed,
        message: '更新できませんでした。以前の辞書はそのまま利用できます：$error',
        currentVersion: state.currentVersion,
        remoteConfigured: _remoteConfigured,
      );
    } finally {
      if (identical(_cancellationToken, cancellation)) {
        _cancellationToken = null;
      }
    }
  }

  Future<void> _verifyRepositoryReady(DictionaryRepository repository) async {
    if (repository is DictionaryRepositoryReadiness) {
      await (repository as DictionaryRepositoryReadiness).verifyReady();
      return;
    }
    final entries = await repository.allEntries();
    if (entries.isEmpty) {
      throw StateError('Dictionary repository returned no entries.');
    }
  }

  void _invalidateDictionaryConsumers() {
    ref.invalidate(searchResultsProvider);
    ref.invalidate(entryProvider);
    ref.invalidate(allEntriesProvider);
    ref.invalidate(entriesByIdsProvider);
  }

  void _showProgress(DictionaryUpdateProgress progress) {
    if (!state.isRunning) return;
    final canCancel =
        progress.phase != DictionaryUpdateProgressPhase.activating &&
        progress.phase != DictionaryUpdateProgressPhase.reopening;
    state = DictionaryUpdateState(
      phase: DictionaryUpdatePhase.running,
      message: _progressMessage(progress),
      currentVersion: state.currentVersion,
      progress: progress.fraction,
      canCancel: canCancel,
      remoteConfigured: _remoteConfigured,
    );
  }

  String _progressMessage(DictionaryUpdateProgress progress) {
    return switch (progress.phase) {
      DictionaryUpdateProgressPhase.checkingMetadata => 'パッケージ情報を確認しています…',
      DictionaryUpdateProgressPhase.preparingStorage => '保存領域を確認しています…',
      DictionaryUpdateProgressPhase.downloading =>
        '辞書をダウンロードしています… '
            '${_formatBytes(progress.receivedBytes)} / '
            '${_formatBytes(progress.totalBytes ?? 0)}',
      DictionaryUpdateProgressPhase.verifying => 'サイズ・署名値・データベースを検証しています…',
      DictionaryUpdateProgressPhase.activating => '辞書を安全に入れ替えています…',
      DictionaryUpdateProgressPhase.reopening => '新しい辞書を開いて確認しています…',
    };
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _messageFor(DictionaryUpdateResult result) => switch (result) {
    DictionaryUpdateResult.updated => '辞書データを更新しました。',
    DictionaryUpdateResult.alreadyCurrent => '同じか新しい辞書が入っています。',
    DictionaryUpdateResult.cancelled => '更新をキャンセルしました。以前の辞書を利用できます。',
    DictionaryUpdateResult.downloadFailed =>
      'ダウンロードを完了できませんでした。通信を確認して再試行してください。',
    DictionaryUpdateResult.insufficientStorage =>
      '空き容量が足りません。容量を確保してから再試行してください。',
    DictionaryUpdateResult.invalidManifest => '更新情報の形式が正しくありません。',
    DictionaryUpdateResult.invalidPackageContract =>
      '更新パッケージのmanifestまたはchecksumsが一致しません。',
    DictionaryUpdateResult.invalidReleaseChannel =>
      'releaseチャンネルのパッケージではありません。',
    DictionaryUpdateResult.unreviewedContent => 'レビュー済みの内容ではないため、更新を拒否しました。',
    DictionaryUpdateResult.unclearedLicense => '利用許諾を確認できない内容があるため、更新を拒否しました。',
    DictionaryUpdateResult.invalidDatabaseFile => '辞書ファイル名が正しくないため、更新を拒否しました。',
    DictionaryUpdateResult.incompatibleSchema => 'この辞書形式には対応していません。',
    DictionaryUpdateResult.incompatibleApp => '先にアプリを更新してください。',
    DictionaryUpdateResult.packageTooLarge => '更新パッケージが許容サイズを超えています。',
    DictionaryUpdateResult.invalidSize => '辞書ファイルの大きさが一致しません。',
    DictionaryUpdateResult.invalidChecksum => '辞書ファイルのSHA-256検証に失敗しました。',
    DictionaryUpdateResult.unhealthyDatabase => '辞書データを開けないため、更新を中止しました。',
  };
}

final dictionaryUpdateControllerProvider =
    NotifierProvider<DictionaryUpdateController, DictionaryUpdateState>(
      DictionaryUpdateController.new,
    );
