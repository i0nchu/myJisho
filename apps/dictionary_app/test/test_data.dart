import 'package:kotoba_dictionary_app/features/dictionary/domain/dictionary_entry.dart';

DictionaryEntry testEntry({
  String id = 'entry_taberu_001',
  String headword = '食べる',
  String reading = 'たべる',
  String? imageAsset,
  String? audioAsset,
}) {
  return DictionaryEntry(
    id: id,
    headword: headword,
    reading: reading,
    partsOfSpeech: const ['動詞', '一段'],
    frequencyRank: 180,
    curated: true,
    forms: [headword, reading],
    senses: const [
      DictionarySense(
        id: 'sense_001',
        definition: '食べ物を口に入れて、飲み込む。',
        examples: ['朝ご飯を食べる。'],
        usageNote: '',
        collocations: ['ご飯を食べる'],
      ),
    ],
    relations: const [],
    sourceLabel: 'test-original',
    editStatus: 'approved',
    reviewStatus: 'approved',
    imageAsset: imageAsset,
    audioAsset: audioAsset,
  );
}
