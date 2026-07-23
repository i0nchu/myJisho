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
    final inferredCandidates = candidates
        .where((candidate) => candidate.kind == QueryCandidateKind.inflection)
        .toList(growable: false);
    final inferredBases = inferredCandidates
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
      String? deinflectionReason;
      String matchedKey = '';

      if (query == entry.headword) {
        kind = MatchKind.primaryExact;
        baseScore = 1000;
        matchedKey = entry.headword;
      } else if (entry.forms.skip(1).contains(query)) {
        kind = MatchKind.alternativeExact;
        baseScore = 950;
        matchedKey = query;
      } else if (query == entry.reading) {
        kind = MatchKind.readingExact;
        baseScore = 900;
        matchedKey = entry.reading;
      } else if (normalizedQuery == normalizedHeadword ||
          normalizedForms.contains(normalizedQuery) ||
          kanaQuery == normalizedReading) {
        kind = MatchKind.normalizedExact;
        baseScore = 850;
        matchedKey = normalizedQuery == normalizedHeadword
            ? entry.headword
            : entry.reading;
      } else if (inferredBases.contains(normalizedHeadword) ||
          inferredBases.contains(normalizedReading)) {
        kind = MatchKind.inflection;
        baseScore = 800;
        matchedKey = inferredBases.contains(normalizedHeadword)
            ? entry.headword
            : entry.reading;
        derivedFrom = query;
        for (final candidate in inferredCandidates) {
          if (candidate.key == normalizedHeadword ||
              candidate.key == normalizedReading) {
            deinflectionReason = candidate.deinflectionReason;
            break;
          }
        }
      } else if (normalizedHeadword.startsWith(normalizedQuery)) {
        kind = MatchKind.headwordPrefix;
        baseScore = 650;
        matchedKey = entry.headword;
      } else if (normalizedReading.startsWith(kanaQuery)) {
        kind = MatchKind.readingPrefix;
        baseScore = 600;
        matchedKey = entry.reading;
      } else if (romajiReadings.contains(normalizedReading)) {
        kind = MatchKind.romaji;
        baseScore = 550;
        matchedKey = entry.reading;
      } else if (normalizedHeadword.contains(normalizedQuery) ||
          normalizedReading.contains(kanaQuery)) {
        kind = MatchKind.contains;
        baseScore = 450;
        matchedKey = normalizedHeadword.contains(normalizedQuery)
            ? entry.headword
            : entry.reading;
      }

      if (kind != null) {
        final modifiers = <SearchScoreModifier>[];
        final frequencyBoost = entry.frequencyRank <= 1000
            ? 120
            : entry.frequencyRank <= 5000
            ? 80
            : entry.frequencyRank <= 10000
            ? 40
            : 0;
        if (frequencyBoost > 0) {
          modifiers.add(SearchScoreModifier('frequency', frequencyBoost));
        }
        final editorialBoost = entry.editorialLevel.rankingBoost;
        if (editorialBoost > 0) {
          modifiers.add(
            SearchScoreModifier(
              'editorial_${entry.editorialLevel.name}',
              editorialBoost,
            ),
          );
        }
        final score =
            baseScore +
            modifiers.fold<int>(0, (total, modifier) => total + modifier.value);
        hits.add(
          SearchHit(
            entry: entry,
            kind: kind,
            baseScore: baseScore,
            score: score,
            matchedKey: matchedKey,
            modifiers: List.unmodifiable(modifiers),
            derivedFrom: derivedFrom,
            deinflectionReason: deinflectionReason,
          ),
        );
      }
    }

    hits.sort((a, b) {
      final scoreOrder = b.score.compareTo(a.score);
      if (scoreOrder != 0) return scoreOrder;
      final frequency = a.entry.frequencyRank.compareTo(b.entry.frequencyRank);
      if (frequency != 0) return frequency;
      final headword = a.entry.headword.compareTo(b.entry.headword);
      if (headword != 0) return headword;
      return a.entry.id.compareTo(b.entry.id);
    });
    return hits.take(limit).toList(growable: false);
  }
}
