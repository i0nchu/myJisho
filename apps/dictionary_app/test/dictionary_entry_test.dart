import 'package:flutter_test/flutter_test.dart';
import 'package:myjisho_dictionary_app/features/dictionary/domain/dictionary_entry.dart';

void main() {
  test('parses the canonical dictionary contract including media', () {
    final entry = DictionaryEntry.fromJson({
      'entry_id': 'entry_hirou_001',
      'headword': '拾う',
      'forms': [
        {'text': '拾う', 'type': 'primary', 'common': true},
        {'text': 'ひろう', 'type': 'kana', 'common': true},
      ],
      'readings': [
        {'kana': 'ひろう', 'primary': true},
      ],
      'parts_of_speech': ['動詞', '五段'],
      'frequency_rank': 1420,
      'editorial_level': 'curated',
      'edit_status': 'ai_draft',
      'senses': [
        {
          'sense_id': 'sense_hirou_001',
          'definition_ja_simple': '地面などに落ちているものを、手で取る。',
          'usage_note_ja': '落ちているものに使う。',
          'examples': [
            {'sentence': '道で財布を拾った。'},
          ],
          'relations': [
            {
              'entry_id': 'entry_toru_001',
              'relation_type': 'easily_confused',
              'note_ja': '「取る」は広い意味で使う。',
            },
          ],
          'image_assets': [
            {'path': 'assets/images/hirou.png'},
          ],
          'audio_assets': [
            {'path': 'assets/audio/hirou.wav'},
          ],
        },
      ],
      'source_ids': ['source_original'],
      'review': {'status': 'ai_draft'},
    });

    expect(entry.id, 'entry_hirou_001');
    expect(entry.reading, 'ひろう');
    expect(entry.forms, ['拾う', 'ひろう']);
    expect(entry.primarySense.examples, ['道で財布を拾った。']);
    expect(entry.relations.single.relation, 'easily_confused');
    expect(entry.relations.single.displayRelationLabel, '間違えやすい言葉');
    expect(entry.imageAsset, 'assets/images/hirou.png');
    expect(entry.audioAsset, 'assets/audio/hirou.wav');
    expect(entry.sourceLabel, 'source_original');
    expect(entry.status, 'ready');
    expect(entry.versionOrigin, 'imported');
    expect(entry.partOfSpeechLabel, '動詞・五段');
  });

  test('rejects traversal in canonical media paths', () {
    expect(
      () => DictionaryEntry.fromJson({
        'entry_id': 'entry_unsafe',
        'headword': '危険',
        'forms': [
          {'text': '危険', 'type': 'primary', 'common': true},
        ],
        'readings': [
          {'kana': 'きけん', 'primary': true},
        ],
        'parts_of_speech': ['noun'],
        'frequency_rank': 1,
        'editorial_level': 'curated',
        'edit_status': 'reviewed',
        'senses': [
          {
            'sense_id': 'sense_unsafe',
            'definition_ja_simple': '安全ではないこと。',
            'usage_note_ja': '',
            'examples': <Object?>[],
            'relations': <Object?>[],
            'image_assets': [
              {'path': '../secret.png'},
            ],
            'audio_assets': <Object?>[],
          },
        ],
        'source_ids': ['source_original'],
        'review': {'status': 'reviewed'},
      }),
      throwsFormatException,
    );
  });

  test('parses self-hosted generation metadata without review state', () {
    final entry = DictionaryEntry.fromJson({
      'entry_id': 'entry_generated_test',
      'headword': '新語',
      'forms': [
        {'text': '新語', 'type': 'primary', 'common': true},
      ],
      'readings': [
        {'kana': 'しんご', 'primary': true},
      ],
      'parts_of_speech': ['noun'],
      'frequency_rank': null,
      'editorial_level': 'curated',
      'status': 'ready',
      'version_origin': 'generated',
      'locked': false,
      'senses': [
        {
          'sense_id': 'sense_generated_test',
          'definition_ja_simple': '新しく作られた言葉。',
          'usage_note_ja': '',
          'examples': [
            {
              'example_id': 'example_generated_test',
              'sentence': 'この新語を辞書に加える。',
              'source_id': null,
            },
          ],
          'relations': <Object?>[],
          'image_assets': <Object?>[],
          'audio_assets': <Object?>[],
        },
      ],
      'source_ids': <Object?>[],
      'generation': {
        'model': 'Qwen3 8B',
        'generated_at': '2026-07-27T13:16:00Z',
        'generator_version': 'myjisho-local-1',
        'source_count': 0,
        'knowledge_only': true,
        'sources': <Object?>[],
      },
      'created_at': '2026-07-27T13:16:00Z',
      'updated_at': '2026-07-27T13:16:00Z',
      'data_version': 'myjisho-local-1',
    });

    expect(entry.status, 'ready');
    expect(entry.versionOrigin, 'generated');
    expect(entry.isGeneratedLocally, isTrue);
    expect(entry.isKnowledgeOnly, isTrue);
    expect(entry.frequencyRank, 999999);
    expect(entry.generationInfo?.model, 'Qwen3 8B');
  });
}
