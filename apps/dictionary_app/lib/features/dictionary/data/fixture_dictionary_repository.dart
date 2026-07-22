import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/dictionary_entry.dart';
import '../domain/japanese_query_normalizer.dart';
import '../domain/search_hit.dart';
import 'dictionary_repository.dart';

class FixtureDictionaryRepository implements DictionaryRepository {
  FixtureDictionaryRepository(
    this._bundle, {
    this.assetPath = 'assets/fixtures/dictionary.json',
  });

  FixtureDictionaryRepository.fromEntries(List<DictionaryEntry> entries)
    : _bundle = null,
      assetPath = '',
      _entries = List.unmodifiable(entries);

  final AssetBundle? _bundle;
  final String assetPath;
  List<DictionaryEntry>? _entries;
  static const _normalizer = JapaneseQueryNormalizer();

  Future<void> _ensureLoaded() async {
    if (_entries != null) return;
    final jsonText = await _bundle!.loadString(assetPath);
    final decoded = jsonDecode(jsonText);
    final values = decoded is List<Object?>
        ? decoded
        : (decoded! as Map<String, Object?>)['entries']! as List<Object?>;
    _entries = _resolveRelations(
      values
          .map(
            (value) => DictionaryEntry.fromJson(value! as Map<String, Object?>),
          )
          .toList(growable: false),
    );
  }

  static List<DictionaryEntry> _resolveRelations(
    List<DictionaryEntry> entries,
  ) {
    final byId = {for (final entry in entries) entry.id: entry};
    return List.unmodifiable(
      entries.map(
        (entry) => entry.copyWith(
          relations: entry.relations
              .map(
                (relation) => relation.copyWith(
                  headword: relation.targetEntryId == null
                      ? relation.headword
                      : byId[relation.targetEntryId]?.headword ??
                            relation.headword,
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }

  @override
  Future<List<DictionaryEntry>> allEntries() async {
    await _ensureLoaded();
    return _entries!;
  }

  @override
  Future<DictionaryEntry?> findById(String entryId) async {
    await _ensureLoaded();
    for (final entry in _entries!) {
      if (entry.id == entryId) return entry;
    }
    return null;
  }

  @override
  Future<List<DictionaryEntry>> findByIds(Iterable<String> entryIds) async {
    await _ensureLoaded();
    final wanted = entryIds.toSet();
    return _entries!
        .where((entry) => wanted.contains(entry.id))
        .toList(growable: false);
  }

  @override
  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) async {
    await _ensureLoaded();
    final query = rawQuery.trim();
    if (query.isEmpty) return const [];

    final normalizedQuery = _normalizer.normalizeText(query);
    final kanaQuery = _normalizer.normalizeKana(query);
    final candidates = _normalizer.queryCandidates(query);
    final romajiReadings = candidates
        .where((candidate) => candidate.kind == QueryCandidateKind.romaji)
        .map((candidate) => candidate.key)
        .toSet();
    final inferredBases = candidates
        .where((candidate) => candidate.kind == QueryCandidateKind.inflection)
        .map((candidate) => candidate.key)
        .toSet();
    final hits = <SearchHit>[];

    for (final entry in _entries!) {
      final normalizedHeadword = _normalizer.normalizeText(entry.headword);
      final normalizedReading = _normalizer.normalizeKana(entry.reading);
      final normalizedForms = entry.forms
          .map(_normalizer.normalizeText)
          .toList();
      MatchKind? kind;
      int baseScore = 0;
      String? derivedFrom;

      if (query == entry.headword) {
        kind = MatchKind.primaryExact;
        baseScore = 1000;
      } else if (entry.forms.skip(1).contains(query)) {
        kind = MatchKind.alternativeExact;
        baseScore = 950;
      } else if (query == entry.reading) {
        kind = MatchKind.readingExact;
        baseScore = 900;
      } else if (normalizedQuery == normalizedHeadword ||
          normalizedForms.contains(normalizedQuery) ||
          kanaQuery == normalizedReading) {
        kind = MatchKind.normalizedExact;
        baseScore = 850;
      } else if (inferredBases.contains(normalizedHeadword) ||
          inferredBases.contains(normalizedReading)) {
        kind = MatchKind.inflection;
        baseScore = 800;
        derivedFrom = query;
      } else if (normalizedHeadword.startsWith(normalizedQuery)) {
        kind = MatchKind.headwordPrefix;
        baseScore = 650;
      } else if (normalizedReading.startsWith(kanaQuery)) {
        kind = MatchKind.readingPrefix;
        baseScore = 600;
      } else if (romajiReadings.contains(normalizedReading)) {
        kind = MatchKind.romaji;
        baseScore = 550;
      } else if (normalizedHeadword.contains(normalizedQuery) ||
          normalizedReading.contains(kanaQuery)) {
        kind = MatchKind.contains;
        baseScore = 450;
      }

      if (kind != null) {
        final frequencyBoost = entry.frequencyRank <= 1000
            ? 120
            : entry.frequencyRank <= 5000
            ? 80
            : 30;
        hits.add(
          SearchHit(
            entry: entry,
            kind: kind,
            baseScore: baseScore,
            score: baseScore + frequencyBoost + (entry.curated ? 80 : 0),
            derivedFrom: derivedFrom,
          ),
        );
      }
    }

    hits.sort((a, b) {
      final scoreOrder = b.score.compareTo(a.score);
      if (scoreOrder != 0) return scoreOrder;
      return a.entry.frequencyRank.compareTo(b.entry.frequencyRank);
    });
    return hits.take(limit).toList(growable: false);
  }
}
