import 'dictionary_entry.dart';

enum MatchKind {
  primaryExact('見出し完全一致'),
  alternativeExact('別表記完全一致'),
  readingExact('読み完全一致'),
  normalizedExact('正規化一致'),
  inflection('活用形から推測'),
  headwordPrefix('見出し前方一致'),
  readingPrefix('読み前方一致'),
  romaji('ローマ字一致'),
  contains('部分一致');

  const MatchKind(this.debugLabel);
  final String debugLabel;
}

class SearchHit {
  const SearchHit({
    required this.entry,
    required this.kind,
    required this.baseScore,
    required this.score,
    this.derivedFrom,
  });

  final DictionaryEntry entry;
  final MatchKind kind;
  final int baseScore;
  final int score;
  final String? derivedFrom;
}
