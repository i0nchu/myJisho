class SearchHistoryItem {
  const SearchHistoryItem({required this.query, required this.searchedAt});

  final String query;
  final DateTime searchedAt;
}

class UserLibrary {
  const UserLibrary({required this.favoriteEntryIds, required this.history});

  const UserLibrary.empty() : favoriteEntryIds = const {}, history = const [];

  final Set<String> favoriteEntryIds;
  final List<SearchHistoryItem> history;
}
