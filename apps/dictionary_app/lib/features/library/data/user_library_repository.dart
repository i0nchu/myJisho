import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/user_library.dart';

/// Read/write contract for the user-owned database.
///
/// This must remain separate from the replaceable dictionary data package so a
/// dictionary update can never erase favorites or history.
abstract interface class UserLibraryRepository {
  Future<UserLibrary> load();

  Future<UserLibrary> toggleFavorite(String entryId);

  Future<UserLibrary> addHistory(String query);

  Future<UserLibrary> clearHistory();
}

class InMemoryUserLibraryRepository implements UserLibraryRepository {
  UserLibrary _value = const UserLibrary.empty();

  @override
  Future<UserLibrary> load() async => _value;

  @override
  Future<UserLibrary> toggleFavorite(String entryId) async {
    final next = {..._value.favoriteEntryIds};
    if (!next.add(entryId)) next.remove(entryId);
    _value = UserLibrary(favoriteEntryIds: next, history: _value.history);
    return _value;
  }

  @override
  Future<UserLibrary> addHistory(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return _value;
    final next = [
      SearchHistoryItem(query: trimmed, searchedAt: DateTime.now()),
      ..._value.history.where((item) => item.query != trimmed),
    ].take(30).toList(growable: false);
    _value = UserLibrary(
      favoriteEntryIds: _value.favoriteEntryIds,
      history: next,
    );
    return _value;
  }

  @override
  Future<UserLibrary> clearHistory() async {
    _value = UserLibrary(
      favoriteEntryIds: _value.favoriteEntryIds,
      history: const [],
    );
    return _value;
  }
}

class SharedPreferencesUserLibraryRepository implements UserLibraryRepository {
  SharedPreferencesUserLibraryRepository([
    Future<SharedPreferences>? preferences,
  ]) : _preferences = preferences ?? SharedPreferences.getInstance();

  static const _favoritesKey = 'myjisho.user.favorite_entry_ids.v1';
  static const _historyKey = 'myjisho.user.search_history.v1';

  final Future<SharedPreferences> _preferences;

  @override
  Future<UserLibrary> load() async {
    final preferences = await _preferences;
    final favoriteIds = preferences.getStringList(_favoritesKey) ?? const [];
    final encodedHistory = preferences.getStringList(_historyKey) ?? const [];
    final history = <SearchHistoryItem>[];
    for (final encoded in encodedHistory) {
      try {
        final value = jsonDecode(encoded) as Map<String, Object?>;
        history.add(
          SearchHistoryItem(
            query: value['query']! as String,
            searchedAt: DateTime.parse(value['searchedAt']! as String),
          ),
        );
      } on FormatException {
        // Ignore a single damaged history row and preserve the remaining data.
      }
    }
    return UserLibrary(favoriteEntryIds: favoriteIds.toSet(), history: history);
  }

  @override
  Future<UserLibrary> toggleFavorite(String entryId) async {
    final current = await load();
    final next = {...current.favoriteEntryIds};
    if (!next.add(entryId)) next.remove(entryId);
    await (await _preferences).setStringList(
      _favoritesKey,
      next.toList()..sort(),
    );
    return UserLibrary(favoriteEntryIds: next, history: current.history);
  }

  @override
  Future<UserLibrary> addHistory(String query) async {
    final trimmed = query.trim();
    final current = await load();
    if (trimmed.isEmpty) return current;
    final history = [
      SearchHistoryItem(query: trimmed, searchedAt: DateTime.now()),
      ...current.history.where((item) => item.query != trimmed),
    ].take(30).toList(growable: false);
    await (await _preferences).setStringList(
      _historyKey,
      history
          .map(
            (item) => jsonEncode({
              'query': item.query,
              'searchedAt': item.searchedAt.toUtc().toIso8601String(),
            }),
          )
          .toList(growable: false),
    );
    return UserLibrary(
      favoriteEntryIds: current.favoriteEntryIds,
      history: history,
    );
  }

  @override
  Future<UserLibrary> clearHistory() async {
    final current = await load();
    await (await _preferences).remove(_historyKey);
    return UserLibrary(
      favoriteEntryIds: current.favoriteEntryIds,
      history: const [],
    );
  }
}
