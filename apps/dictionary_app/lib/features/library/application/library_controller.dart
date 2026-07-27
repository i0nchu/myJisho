import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/user_library_repository.dart';
import '../domain/user_library.dart';

final userLibraryRepositoryProvider = Provider<UserLibraryRepository>((ref) {
  return SharedPreferencesUserLibraryRepository();
});

class LibraryController extends AsyncNotifier<UserLibrary> {
  @override
  Future<UserLibrary> build() => ref.read(userLibraryRepositoryProvider).load();

  Future<void> toggleFavorite(String entryId) async {
    state = await AsyncValue.guard(
      () => ref.read(userLibraryRepositoryProvider).toggleFavorite(entryId),
    );
  }

  Future<void> recordSearch(String query) async {
    final value = await ref
        .read(userLibraryRepositoryProvider)
        .addHistory(query);
    state = AsyncData(value);
  }

  Future<void> clearHistory() async {
    state = AsyncData(
      await ref.read(userLibraryRepositoryProvider).clearHistory(),
    );
  }
}

final libraryControllerProvider =
    AsyncNotifierProvider<LibraryController, UserLibrary>(
      LibraryController.new,
    );
