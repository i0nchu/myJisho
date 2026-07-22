import 'dart:io';
import 'dart:typed_data';

import 'dictionary_update_service.dart';

DictionaryUpdateStorage createFileUpdateStorage({
  required String activeDatabasePath,
  required Future<bool> Function(String path) healthCheck,
}) {
  return FileDictionaryUpdateStorage(
    activeDatabasePath: activeDatabasePath,
    healthCheck: healthCheck,
  );
}

class FileDictionaryUpdateStorage implements DictionaryUpdateStorage {
  FileDictionaryUpdateStorage({
    required this.activeDatabasePath,
    required this.healthCheck,
  });

  final String activeDatabasePath;
  final Future<bool> Function(String path) healthCheck;

  String get _stagedPath => '$activeDatabasePath.staged';
  String get _backupPath => '$activeDatabasePath.backup';
  String get _markerPath => '$activeDatabasePath.update-in-progress';

  Future<void> _recoverInterruptedUpdate() async {
    final marker = File(_markerPath);
    final backup = File(_backupPath);
    if (!await marker.exists()) return;
    if (await backup.exists()) {
      final active = File(activeDatabasePath);
      if (await active.exists()) await active.delete();
      await backup.rename(active.path);
    }
    await marker.delete();
  }

  @override
  Future<String> stage(Uint8List databaseBytes) async {
    await _recoverInterruptedUpdate();
    final staged = File(_stagedPath);
    if (await staged.exists()) await staged.delete();
    await staged.writeAsBytes(databaseBytes, flush: true);
    return staged.path;
  }

  @override
  Future<bool> isHealthy(String stagedHandle) => healthCheck(stagedHandle);

  @override
  Future<void> activate(String stagedHandle) async {
    final active = File(activeDatabasePath);
    final backup = File(_backupPath);
    final staged = File(stagedHandle);
    if (await backup.exists()) await backup.delete();
    await File(_markerPath).writeAsString('replace');
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
    if (await backup.exists()) await backup.delete();
    if (await marker.exists()) await marker.delete();
  }

  @override
  Future<void> rollback() async {
    final active = File(activeDatabasePath);
    final backup = File(_backupPath);
    if (!await backup.exists()) return;
    if (await active.exists()) await active.delete();
    await backup.rename(active.path);
    final marker = File(_markerPath);
    if (await marker.exists()) await marker.delete();
  }

  @override
  Future<void> discard(String stagedHandle) async {
    final file = File(stagedHandle);
    if (await file.exists()) await file.delete();
  }
}
