enum EditorialLevel {
  imported,
  curated,
  featured;

  static EditorialLevel parse(Object? value) => switch (value) {
    'imported' => EditorialLevel.imported,
    'curated' => EditorialLevel.curated,
    'featured' => EditorialLevel.featured,
    _ => throw FormatException('Unknown editorial level: $value'),
  };

  int get rankingBoost => switch (this) {
    EditorialLevel.imported => 0,
    EditorialLevel.curated => 40,
    EditorialLevel.featured => 80,
  };
}

class DictionaryEntry {
  const DictionaryEntry({
    required this.id,
    required this.headword,
    required this.reading,
    required this.partsOfSpeech,
    required this.frequencyRank,
    EditorialLevel? editorialLevel,
    bool curated = false,
    required this.forms,
    required this.senses,
    required this.relations,
    required this.sourceLabel,
    required this.editStatus,
    required this.reviewStatus,
    this.imageAsset,
    this.audioAsset,
  }) : editorialLevel =
           editorialLevel ??
           (curated ? EditorialLevel.curated : EditorialLevel.imported);

  factory DictionaryEntry.fromJson(Map<String, Object?> json) {
    final isCanonical = json.containsKey('entry_id');
    final canonicalForms = isCanonical
        ? (json['forms'] as List<Object?>? ?? const [])
              .map(
                (value) => (value! as Map<String, Object?>)['text']! as String,
              )
              .toList(growable: false)
        : (json['forms']! as List<Object?>).cast<String>();
    final canonicalReadings = (json['readings'] as List<Object?>? ?? const [])
        .cast<Object?>();
    String canonicalReading = '';
    for (final value in canonicalReadings) {
      final reading = value! as Map<String, Object?>;
      if (reading['primary'] == true) {
        canonicalReading = reading['kana']! as String;
        break;
      }
    }
    if (canonicalReading.isEmpty && canonicalReadings.isNotEmpty) {
      canonicalReading =
          (canonicalReadings.first! as Map<String, Object?>)['kana']! as String;
    }
    final rawSenses = (json['senses']! as List<Object?>)
        .map((value) => value! as Map<String, Object?>)
        .toList(growable: false);
    final firstSense = rawSenses.first;
    final rawRelations = isCanonical
        ? (firstSense['relations'] as List<Object?>? ?? const [])
        : (json['relations'] as List<Object?>? ?? const []);
    final rawSourceIds = json['source_ids'] as List<Object?>? ?? const [];
    final legacySources = json['sources'] as List<Object?>? ?? const [];
    final firstImages =
        firstSense['image_assets'] as List<Object?>? ?? const [];
    final firstAudio = firstSense['audio_assets'] as List<Object?>? ?? const [];
    return DictionaryEntry(
      id: (json[isCanonical ? 'entry_id' : 'id'])! as String,
      headword: json['headword']! as String,
      reading: isCanonical ? canonicalReading : json['reading']! as String,
      partsOfSpeech:
          (json[isCanonical ? 'parts_of_speech' : 'partsOfSpeech']!
                  as List<Object?>)
              .cast<String>()
              .map(_partOfSpeechLabel)
              .toList(growable: false),
      frequencyRank:
          json[isCanonical ? 'frequency_rank' : 'frequencyRank']! as int,
      editorialLevel: isCanonical
          ? EditorialLevel.parse(json['editorial_level'])
          : json['editorialLevel'] != null
          ? EditorialLevel.parse(json['editorialLevel'])
          : (json['curated'] == true
                ? EditorialLevel.curated
                : EditorialLevel.imported),
      forms: canonicalForms,
      senses: rawSenses.map(DictionarySense.fromJson).toList(growable: false),
      relations: rawRelations
          .map((value) => RelatedEntry.fromJson(value! as Map<String, Object?>))
          .toList(growable: false),
      sourceLabel: isCanonical
          ? rawSourceIds.isNotEmpty
                ? rawSourceIds.cast<String>().join('・')
                : legacySources.isNotEmpty
                ? ((legacySources.first! as Map<String, Object?>)['source_id']
                          as String? ??
                      '出典情報あり')
                : '出典情報なし'
          : json['sourceLabel']! as String,
      editStatus: isCanonical
          ? (json['edit_status'] as String? ?? 'imported')
          : (json['editStatus'] as String? ?? 'approved'),
      reviewStatus: isCanonical
          ? ((json['review'] as Map<String, Object?>?)?['status'] as String? ??
                'needs_review')
          : (json['reviewStatus'] as String? ?? 'approved'),
      imageAsset: isCanonical
          ? _canonicalMediaPath(firstImages)
          : json['imageAsset'] as String? ?? json['imageDataUri'] as String?,
      audioAsset: isCanonical
          ? _canonicalMediaPath(firstAudio)
          : json['audioAsset'] as String?,
    );
  }

  final String id;
  final String headword;
  final String reading;
  final List<String> partsOfSpeech;
  final int frequencyRank;
  final EditorialLevel editorialLevel;
  final List<String> forms;
  final List<DictionarySense> senses;
  final List<RelatedEntry> relations;
  final String sourceLabel;
  final String editStatus;
  final String reviewStatus;
  final String? imageAsset;
  final String? audioAsset;

  DictionarySense get primarySense => senses.first;
  String get partOfSpeechLabel => partsOfSpeech.join('・');
  bool get isReviewPending =>
      editStatus == 'ai_draft' ||
      editStatus == 'draft' ||
      editStatus == 'needs_review' ||
      reviewStatus == 'ai_draft' ||
      reviewStatus == 'needs_review';
  @Deprecated('Use editorialLevel so featured and curated remain distinct.')
  bool get curated => editorialLevel != EditorialLevel.imported;

  DictionaryEntry copyWith({List<RelatedEntry>? relations}) => DictionaryEntry(
    id: id,
    headword: headword,
    reading: reading,
    partsOfSpeech: partsOfSpeech,
    frequencyRank: frequencyRank,
    editorialLevel: editorialLevel,
    forms: forms,
    senses: senses,
    relations: relations ?? this.relations,
    sourceLabel: sourceLabel,
    editStatus: editStatus,
    reviewStatus: reviewStatus,
    imageAsset: imageAsset,
    audioAsset: audioAsset,
  );

  static String _partOfSpeechLabel(String value) => switch (value) {
    'noun' => '名詞',
    'verb-godan' => '動詞・五段',
    'verb-godan-irregular-te' => '動詞・五段',
    'verb-ichidan' => '動詞・一段',
    'adjective-i' => 'い形容詞',
    'adjective-na' => 'な形容詞',
    _ => value,
  };

  static String? _canonicalMediaPath(List<Object?> assets) {
    if (assets.isEmpty) return null;
    final path = (assets.first! as Map<String, Object?>)['path'] as String?;
    if (path == null || path.isEmpty) return null;
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    final safe =
        !normalized.startsWith('/') &&
        !normalized.contains('://') &&
        normalized.startsWith('assets/') &&
        !segments.any(
          (segment) => segment.isEmpty || segment == '..' || segment == '.',
        );
    if (!safe) throw FormatException('Unsafe media path: $path');
    return normalized;
  }
}

class DictionarySense {
  const DictionarySense({
    required this.id,
    required this.definition,
    required this.examples,
    required this.usageNote,
    required this.collocations,
  });

  factory DictionarySense.fromJson(Map<String, Object?> json) {
    final isCanonical = json.containsKey('sense_id');
    final rawExamples = json['examples']! as List<Object?>;
    return DictionarySense(
      id: json[isCanonical ? 'sense_id' : 'id']! as String,
      definition:
          json[isCanonical ? 'definition_ja_simple' : 'definition']! as String,
      examples: isCanonical
          ? rawExamples
                .map(
                  (value) =>
                      (value! as Map<String, Object?>)['sentence']! as String,
                )
                .toList(growable: false)
          : rawExamples.cast<String>(),
      usageNote:
          json[isCanonical ? 'usage_note_ja' : 'usageNote'] as String? ?? '',
      collocations: (json['collocations'] as List<Object?>? ?? const [])
          .map((value) {
            if (value is String) return value;
            final map = value! as Map<String, Object?>;
            return (map['text'] ?? map['phrase'])! as String;
          })
          .toList(growable: false),
    );
  }

  final String id;
  final String definition;
  final List<String> examples;
  final String usageNote;
  final List<String> collocations;
}

class RelatedEntry {
  const RelatedEntry({
    required this.headword,
    required this.relation,
    required this.note,
    this.targetEntryId,
  });

  factory RelatedEntry.fromJson(Map<String, Object?> json) => RelatedEntry(
    headword:
        (json['headword'] ?? json['target_headword'] ?? json['entry_id'])!
            as String,
    relation: (json['relation'] ?? json['relation_type'])! as String,
    note: (json['note'] ?? json['note_ja'] ?? '') as String,
    targetEntryId: json['entry_id'] as String?,
  );

  final String headword;
  final String relation;
  final String note;
  final String? targetEntryId;

  /// Human-facing Japanese label for the canonical relation code.
  ///
  /// Relation codes are part of the data contract and must never leak into
  /// the learner-facing dictionary UI.
  String get displayRelationLabel => switch (relation) {
    'near_synonym' => '似ている言葉',
    'antonym' => '反対語',
    'hypernym' => 'より広い言葉',
    'hyponym' => 'より具体的な言葉',
    'easily_confused' => '間違えやすい言葉',
    'related' => '関連する言葉',
    'orthographic_variant' => '表記の違い',
    _ => '関連する言葉',
  };

  RelatedEntry copyWith({String? headword}) => RelatedEntry(
    headword: headword ?? this.headword,
    relation: relation,
    note: note,
    targetEntryId: targetEntryId,
  );
}
