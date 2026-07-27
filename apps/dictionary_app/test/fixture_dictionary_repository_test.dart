import 'package:flutter_test/flutter_test.dart';
import 'package:myjisho_dictionary_app/features/dictionary/data/fixture_dictionary_repository.dart';
import 'package:myjisho_dictionary_app/features/dictionary/domain/search_hit.dart';

import 'test_data.dart';

void main() {
  final repository = FixtureDictionaryRepository.fromEntries([
    testEntry(),
    testEntry(id: 'entry_tabemono_001', headword: '食べる物', reading: 'たべるもの'),
    testEntry(id: 'entry_gakkou_001', headword: '学校', reading: 'がっこう'),
  ]);

  test('ranks an exact headword ahead of a prefix', () async {
    final hits = await repository.search('食べる');
    expect(hits.first.entry.headword, '食べる');
    expect(hits.first.kind, MatchKind.primaryExact);
    expect(hits.first.score, greaterThan(hits.last.score));
  });

  test('normalizes katakana readings', () async {
    final hits = await repository.search('ガッコウ');
    expect(hits.first.entry.headword, '学校');
    expect(hits.first.kind, MatchKind.normalizedExact);
  });

  test('supports common romaji and inflection queries', () async {
    final romaji = await repository.search('taberu');
    final inflection = await repository.search('食べました');
    expect(romaji.first.entry.headword, '食べる');
    expect(romaji.first.kind, MatchKind.romaji);
    expect(inflection.first.kind, MatchKind.inflection);
    expect(inflection.first.derivedFrom, '食べました');
  });
}
