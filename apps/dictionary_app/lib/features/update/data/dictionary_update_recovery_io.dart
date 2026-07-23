import 'dart:io';

Future<void> recoverInterruptedDictionaryUpdateBeforeOpen(
  String activeDatabasePath,
) async {
  final lock = await File(
    '$activeDatabasePath.update-lock',
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.blockingExclusive);
    final marker = File('$activeDatabasePath.update-in-progress');
    if (!await marker.exists()) return;

    final active = File(activeDatabasePath);
    final backup = File('$activeDatabasePath.backup');
    final staged = File('$activeDatabasePath.staged');
    final displaced = File('$activeDatabasePath.failed-update');
    if (await backup.exists()) {
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
    if (await staged.exists()) await staged.delete();
    await marker.delete();
  } finally {
    try {
      await lock.unlock();
    } finally {
      await lock.close();
    }
  }
}
