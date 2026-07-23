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
  romajiPrefix('ローマ字前方一致'),
  contains('部分一致');

  const MatchKind(this.debugLabel);
  final String debugLabel;
}

class SearchScoreModifier {
  const SearchScoreModifier(this.name, this.value);

  final String name;
  final int value;
}

class SearchEvidence {
  const SearchEvidence({
    required this.matchedKey,
    required this.matchKind,
    required this.rawScore,
    required this.modifiers,
    required this.finalScore,
    this.derivedFrom,
    this.deinflectionReason,
    this.deinflectionConfidence,
  });

  final String matchedKey;
  final MatchKind matchKind;
  final int rawScore;
  final List<SearchScoreModifier> modifiers;
  final int finalScore;
  final String? derivedFrom;
  final String? deinflectionReason;
  final double? deinflectionConfidence;

  int get calculatedFinalScore =>
      rawScore +
      modifiers.fold<int>(0, (total, modifier) => total + modifier.value);
  bool get isScoreConsistent => calculatedFinalScore == finalScore;
}

class SearchHit {
  const SearchHit({
    required this.entry,
    required this.kind,
    required this.baseScore,
    required this.score,
    required this.matchedKey,
    required this.modifiers,
    this.derivedFrom,
    this.deinflectionReason,
    this.deinflectionConfidence,
  });

  final DictionaryEntry entry;
  final MatchKind kind;
  final int baseScore;
  final int score;
  final String matchedKey;
  final List<SearchScoreModifier> modifiers;
  final String? derivedFrom;
  final String? deinflectionReason;
  final double? deinflectionConfidence;

  SearchEvidence get evidence => SearchEvidence(
    matchedKey: matchedKey,
    matchKind: kind,
    rawScore: baseScore,
    modifiers: modifiers,
    finalScore: score,
    derivedFrom: derivedFrom,
    deinflectionReason: deinflectionReason,
    deinflectionConfidence: deinflectionConfidence,
  );
}
