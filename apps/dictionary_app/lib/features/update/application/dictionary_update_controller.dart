import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dictionary/application/dictionary_providers.dart';
import '../../dictionary/data/bundled_database_path.dart';
import '../../dictionary/data/dictionary_repository.dart';
import '../data/dictionary_update_service.dart';
import '../data/file_update_storage.dart';
import '../data/local_directory_package_source.dart';
import '../data/sqlite_dictionary_inspector.dart';

enum DictionaryUpdatePhase { idle, running, succeeded, failed, unsupported }

class DictionaryUpdateState {
  const DictionaryUpdateState({
    required this.phase,
    required this.message,
    this.currentVersion,
  });

  const DictionaryUpdateState.idle()
    : phase = DictionaryUpdatePhase.idle,
      message = '本機のreleaseフォルダーから更新できます。',
      currentVersion = null;

  final DictionaryUpdatePhase phase;
  final String message;
  final String? currentVersion;

  bool get isRunning => phase == DictionaryUpdatePhase.running;
}

class DictionaryUpdateController extends Notifier<DictionaryUpdateState> {
  static const _appVersion = '0.1.0';
  static const _schemaVersion = 1;

  @override
  DictionaryUpdateState build() {
    if (kIsWeb) {
      return const DictionaryUpdateState(
        phase: DictionaryUpdatePhase.unsupported,
        message: 'Web版では本機辞書の更新を利用できません。',
      );
    }
    unawaited(_refreshCurrentVersion());
    return const DictionaryUpdateState.idle();
  }

  Future<String> _activeDatabasePath() => prepareBundledDictionaryDatabase(
    rootBundle,
    'assets/database/dictionary.sqlite',
  );

  Future<void> _refreshCurrentVersion() async {
    final version = await readDictionaryVersion(await _activeDatabasePath());
    state = DictionaryUpdateState(
      phase: DictionaryUpdatePhase.idle,
      message: '本機のreleaseフォルダーから更新できます。',
      currentVersion: version,
    );
  }

  Future<void> installFromDirectory(String directoryPath) async {
    if (kIsWeb) return;
    if (state.isRunning) return;
    final path = directoryPath.trim();
    if (path.isEmpty) {
      state = DictionaryUpdateState(
        phase: DictionaryUpdatePhase.failed,
        message: 'releaseフォルダーのパスを入力してください。',
        currentVersion: state.currentVersion,
      );
      return;
    }

    state = DictionaryUpdateState(
      phase: DictionaryUpdatePhase.running,
      message: 'パッケージを検証しています…',
      currentVersion: state.currentVersion,
    );

    try {
      final activePath = await _activeDatabasePath();
      final currentVersion = await readDictionaryVersion(activePath);
      final repository = ref.read(dictionaryRepositoryProvider);
      final service = DictionaryUpdateService(
        source: createLocalDirectoryPackageSource(path),
        storage: createFileUpdateStorage(
          activeDatabasePath: activePath,
          healthCheck: isHealthySqliteDictionary,
        ),
        supportedSchemaVersion: _schemaVersion,
        currentDictionaryVersion: currentVersion,
        currentAppVersion: _appVersion,
        beforeActivate: () async {
          if (repository is DictionaryRepositoryLifecycle) {
            await (repository as DictionaryRepositoryLifecycle).close();
          }
        },
        afterActivate: () async {
          ref.invalidate(dictionaryRepositoryProvider);
          ref.invalidate(searchResultsProvider);
          ref.invalidate(entryProvider);
          ref.invalidate(allEntriesProvider);
        },
      );
      final result = await service.checkAndInstall();
      final nextVersion = await readDictionaryVersion(activePath);
      state = DictionaryUpdateState(
        phase:
            result == DictionaryUpdateResult.updated ||
                result == DictionaryUpdateResult.alreadyCurrent
            ? DictionaryUpdatePhase.succeeded
            : DictionaryUpdatePhase.failed,
        message: _messageFor(result),
        currentVersion: nextVersion,
      );
    } on Object catch (error) {
      state = DictionaryUpdateState(
        phase: DictionaryUpdatePhase.failed,
        message: '更新できませんでした：$error',
        currentVersion: state.currentVersion,
      );
    }
  }

  String _messageFor(DictionaryUpdateResult result) => switch (result) {
    DictionaryUpdateResult.updated => '辞書データを更新しました。',
    DictionaryUpdateResult.alreadyCurrent => '同じか新しい辞書が入っています。',
    DictionaryUpdateResult.invalidReleaseChannel =>
      'releaseチャンネルのパッケージではありません。',
    DictionaryUpdateResult.unreviewedContent => 'レビュー済みの内容ではないため、更新を拒否しました。',
    DictionaryUpdateResult.invalidDatabaseFile => '辞書ファイル名が正しくないため、更新を拒否しました。',
    DictionaryUpdateResult.incompatibleSchema => 'この辞書形式には対応していません。',
    DictionaryUpdateResult.incompatibleApp => '先にアプリを更新してください。',
    DictionaryUpdateResult.invalidSize => '辞書ファイルの大きさが一致しません。',
    DictionaryUpdateResult.invalidChecksum => '辞書ファイルの検証に失敗しました。',
    DictionaryUpdateResult.unhealthyDatabase => '辞書データを開けないため、更新を中止しました。',
  };
}

final dictionaryUpdateControllerProvider =
    NotifierProvider<DictionaryUpdateController, DictionaryUpdateState>(
      DictionaryUpdateController.new,
    );
