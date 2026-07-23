enum QueryCandidateKind { normalized, kana, romaji, inflection }

class QueryCandidate {
  const QueryCandidate({
    required this.key,
    required this.kind,
    this.derivedFrom,
    this.deinflectionReason,
  });

  final String key;
  final QueryCandidateKind kind;
  final String? derivedFrom;
  final String? deinflectionReason;
}

class DeinflectionCandidate {
  const DeinflectionCandidate(this.lemma, this.reason);

  final String lemma;
  final String reason;
}

class JapaneseQueryNormalizer {
  const JapaneseQueryNormalizer();

  static const _punctuation = '、。，．・：；？！『』「」【】（）［］｛｝〈〉《》〔〕…‥"\'“”‘’';
  static const _halfwidthKana =
      '｡｢｣､･ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ';
  static const _fullwidthKana =
      '。「」、・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン';
  static const _voiced = <String, String>{
    'ウ': 'ヴ',
    'カ': 'ガ',
    'キ': 'ギ',
    'ク': 'グ',
    'ケ': 'ゲ',
    'コ': 'ゴ',
    'サ': 'ザ',
    'シ': 'ジ',
    'ス': 'ズ',
    'セ': 'ゼ',
    'ソ': 'ゾ',
    'タ': 'ダ',
    'チ': 'ヂ',
    'ツ': 'ヅ',
    'テ': 'デ',
    'ト': 'ド',
    'ハ': 'バ',
    'ヒ': 'ビ',
    'フ': 'ブ',
    'ヘ': 'ベ',
    'ホ': 'ボ',
  };
  static const _semiVoiced = <String, String>{
    'ハ': 'パ',
    'ヒ': 'ピ',
    'フ': 'プ',
    'ヘ': 'ペ',
    'ホ': 'ポ',
  };

  String normalizeText(String text) {
    final widthNormalized = _normalizeWidth(text).trim().toLowerCase();
    final buffer = StringBuffer();
    for (final rune in widthNormalized.runes) {
      final character = String.fromCharCode(rune);
      if (RegExp(r'\s').hasMatch(character) ||
          _punctuation.contains(character)) {
        continue;
      }
      buffer.write(character);
    }
    return buffer.toString();
  }

  String normalizeKana(String text, {bool expandLongVowels = true}) {
    final hiragana = katakanaToHiragana(normalizeText(text));
    return expandLongVowels ? _expandLongMarks(hiragana) : hiragana;
  }

  String katakanaToHiragana(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      buffer.writeCharCode(
        rune >= 0x30a1 && rune <= 0x30f6 ? rune - 0x60 : rune,
      );
    }
    return buffer.toString();
  }

  List<String> romajiToHiragana(String text) {
    final raw = text.trim();
    if (!RegExp(r"^[A-Za-zāīūēōĀĪŪĒŌ' -]+$").hasMatch(raw)) return const [];
    final value = raw
        .toLowerCase()
        .replaceAll('ā', 'aa')
        .replaceAll('ī', 'ii')
        .replaceAll('ū', 'uu')
        .replaceAll('ē', 'ee')
        .replaceAll('ō', 'ou')
        .replaceAll(RegExp(r'[ -]'), '')
        .replaceAllMapped(RegExp(r'm(?=[bmp])'), (_) => 'n');
    final output = StringBuffer();
    var index = 0;
    while (index < value.length) {
      if (value[index] == "'") {
        index++;
        continue;
      }
      if (index + 1 < value.length &&
          value[index] == value[index + 1] &&
          !'aeioun'.contains(value[index])) {
        output.write('っ');
        index++;
        continue;
      }
      if (value[index] == 'n') {
        final next = index + 1 < value.length ? value[index + 1] : '';
        if (next.isEmpty || !'aeiouy'.contains(next)) {
          output.write('ん');
          index++;
          continue;
        }
      }
      String? matched;
      for (final key in _romajiKeys) {
        if (value.startsWith(key, index)) {
          matched = key;
          break;
        }
      }
      if (matched == null) return const [];
      output.write(_romaji[matched]);
      index += matched.length;
    }
    final primary = output.toString();
    return {
      primary,
      if (primary.contains('おう')) primary.replaceAll('おう', 'おお'),
    }.toList(growable: false);
  }

  List<DeinflectionCandidate> deinflect(String text) {
    final value = normalizeText(text);
    final found = <String, DeinflectionCandidate>{};
    void add(String lemma, String reason) {
      if (lemma.isNotEmpty && lemma != value) {
        found.putIfAbsent(lemma, () => DeinflectionCandidate(lemma, reason));
      }
    }

    for (final suffix in ['ませんでした', 'ました', 'ません', 'ます']) {
      if (value.endsWith(suffix) && value.length > suffix.length) {
        final stem = value.substring(0, value.length - suffix.length);
        add('$stemる', 'polite:$suffix');
        if (stem.isNotEmpty) {
          final endings =
              _politeStem[stem.substring(stem.length - 1)] ?? const [];
          for (final ending in endings) {
            add(
              '${stem.substring(0, stem.length - 1)}$ending',
              'polite:$suffix',
            );
          }
        }
      }
    }
    for (final rule in _tePastRules.entries) {
      if (value.endsWith(rule.key) && value.length > rule.key.length) {
        final root = value.substring(0, value.length - rule.key.length);
        add('$rootる', 'te/past:${rule.key}');
        for (final ending in rule.value) {
          add('$root$ending', 'te/past:${rule.key}');
        }
        if ((value == '行って' || value == '行った')) add('行く', 'irregular');
      }
    }
    for (final suffix in ['なくて', 'なかった', 'ない']) {
      if (value.endsWith(suffix) && value.length > suffix.length) {
        final stem = value.substring(0, value.length - suffix.length);
        add('$stemる', 'negative:$suffix');
        if (stem.isNotEmpty) {
          final ending = _aRow[stem.substring(stem.length - 1)];
          if (ending != null) {
            add(
              '${stem.substring(0, stem.length - 1)}$ending',
              'negative:$suffix',
            );
          }
        }
      }
    }
    for (final rule in _adjectiveRules.entries) {
      if (value.endsWith(rule.key) && value.length > rule.key.length) {
        add(
          '${value.substring(0, value.length - rule.key.length)}${rule.value}',
          'adjective:${rule.key}',
        );
      }
    }
    for (final suffix in ['だった', 'ではない', 'じゃない', 'なら', 'で', 'に', 'な', 'だ']) {
      if (value.endsWith(suffix) && value.length > suffix.length) {
        add(value.substring(0, value.length - suffix.length), 'na:$suffix');
      }
    }
    return found.values.toList(growable: false);
  }

  List<QueryCandidate> queryCandidates(String rawQuery) {
    final candidates = <QueryCandidate>[];
    final seen = <String>{};
    void add(
      String key,
      QueryCandidateKind kind, [
      String? derivedFrom,
      String? deinflectionReason,
    ]) {
      if (key.isNotEmpty && seen.add('$kind\u0000$key')) {
        candidates.add(
          QueryCandidate(
            key: key,
            kind: kind,
            derivedFrom: derivedFrom,
            deinflectionReason: deinflectionReason,
          ),
        );
      }
    }

    final normalized = normalizeText(rawQuery);
    add(normalized, QueryCandidateKind.normalized);
    add(normalizeKana(rawQuery), QueryCandidateKind.kana);
    for (final reading in romajiToHiragana(rawQuery)) {
      add(normalizeKana(reading), QueryCandidateKind.romaji);
    }
    for (final candidate in deinflect(rawQuery)) {
      add(
        normalizeText(candidate.lemma),
        QueryCandidateKind.inflection,
        rawQuery,
        candidate.reason,
      );
      add(
        normalizeKana(candidate.lemma),
        QueryCandidateKind.inflection,
        rawQuery,
        candidate.reason,
      );
    }
    return candidates;
  }

  String _normalizeWidth(String input) {
    final output = <String>[];
    for (var index = 0; index < input.length; index++) {
      final rune = input.codeUnitAt(index);
      if (rune >= 0xff01 && rune <= 0xff5e) {
        output.add(String.fromCharCode(rune - 0xfee0));
      } else if (rune == 0x3000) {
        output.add(' ');
      } else {
        final character = input[index];
        final kanaIndex = _halfwidthKana.indexOf(character);
        if (kanaIndex >= 0) {
          var full = _fullwidthKana[kanaIndex];
          if (index + 1 < input.length && input[index + 1] == 'ﾞ') {
            full = _voiced[full] ?? full;
            index++;
          } else if (index + 1 < input.length && input[index + 1] == 'ﾟ') {
            full = _semiVoiced[full] ?? full;
            index++;
          }
          output.add(full);
        } else {
          output.add(character);
        }
      }
    }
    return output.join();
  }

  String _expandLongMarks(String input) {
    final output = <String>[];
    for (final rune in input.runes) {
      final character = String.fromCharCode(rune);
      if (character == 'ー' && output.isNotEmpty) {
        output.add(_vowelByKana[output.last] ?? character);
      } else {
        output.add(character);
      }
    }
    return output.join();
  }

  static final _vowelByKana = <String, String>{
    for (final value in [
      'あ',
      'か',
      'が',
      'さ',
      'ざ',
      'た',
      'だ',
      'な',
      'は',
      'ば',
      'ぱ',
      'ま',
      'ゃ',
      'や',
      'ら',
      'ゎ',
      'わ',
    ])
      value: 'あ',
    for (final value in [
      'い',
      'き',
      'ぎ',
      'し',
      'じ',
      'ち',
      'ぢ',
      'に',
      'ひ',
      'び',
      'ぴ',
      'み',
      'り',
    ])
      value: 'い',
    for (final value in [
      'う',
      'く',
      'ぐ',
      'す',
      'ず',
      'つ',
      'づ',
      'ぬ',
      'ふ',
      'ぶ',
      'ぷ',
      'む',
      'ゅ',
      'ゆ',
      'る',
      'ゔ',
    ])
      value: 'う',
    for (final value in [
      'え',
      'け',
      'げ',
      'せ',
      'ぜ',
      'て',
      'で',
      'ね',
      'へ',
      'べ',
      'ぺ',
      'め',
      'れ',
    ])
      value: 'え',
    for (final value in [
      'お',
      'こ',
      'ご',
      'そ',
      'ぞ',
      'と',
      'ど',
      'の',
      'ほ',
      'ぼ',
      'ぽ',
      'も',
      'ょ',
      'よ',
      'ろ',
      'を',
    ])
      value: 'お',
  };
  static const _politeStem = <String, List<String>>{
    'い': ['う'],
    'き': ['く'],
    'ぎ': ['ぐ'],
    'し': ['す'],
    'ち': ['つ'],
    'に': ['ぬ'],
    'び': ['ぶ'],
    'み': ['む'],
    'り': ['る'],
  };
  static const _aRow = <String, String>{
    'わ': 'う',
    'か': 'く',
    'が': 'ぐ',
    'さ': 'す',
    'た': 'つ',
    'な': 'ぬ',
    'ば': 'ぶ',
    'ま': 'む',
    'ら': 'る',
  };
  static const _tePastRules = <String, List<String>>{
    'って': ['う', 'つ', 'る'],
    'った': ['う', 'つ', 'る'],
    'んで': ['む', 'ぶ', 'ぬ'],
    'んだ': ['む', 'ぶ', 'ぬ'],
    'いて': ['く'],
    'いた': ['く'],
    'いで': ['ぐ'],
    'いだ': ['ぐ'],
    'して': ['す'],
    'した': ['す'],
  };
  static const _adjectiveRules = <String, String>{
    'くなかった': 'い',
    'かった': 'い',
    'くない': 'い',
    'くて': 'い',
    'く': 'い',
  };
  static const _romaji = <String, String>{
    'ltsu': 'っ',
    'xtsu': 'っ',
    'tcha': 'っちゃ',
    'tchu': 'っちゅ',
    'tcho': 'っちょ',
    'kya': 'きゃ',
    'kyu': 'きゅ',
    'kyo': 'きょ',
    'gya': 'ぎゃ',
    'gyu': 'ぎゅ',
    'gyo': 'ぎょ',
    'sha': 'しゃ',
    'shu': 'しゅ',
    'sho': 'しょ',
    'sya': 'しゃ',
    'syu': 'しゅ',
    'syo': 'しょ',
    'jya': 'じゃ',
    'jyu': 'じゅ',
    'jyo': 'じょ',
    'cha': 'ちゃ',
    'chu': 'ちゅ',
    'cho': 'ちょ',
    'tya': 'ちゃ',
    'tyu': 'ちゅ',
    'tyo': 'ちょ',
    'nya': 'にゃ',
    'nyu': 'にゅ',
    'nyo': 'にょ',
    'hya': 'ひゃ',
    'hyu': 'ひゅ',
    'hyo': 'ひょ',
    'bya': 'びゃ',
    'byu': 'びゅ',
    'byo': 'びょ',
    'pya': 'ぴゃ',
    'pyu': 'ぴゅ',
    'pyo': 'ぴょ',
    'mya': 'みゃ',
    'myu': 'みゅ',
    'myo': 'みょ',
    'rya': 'りゃ',
    'ryu': 'りゅ',
    'ryo': 'りょ',
    'shi': 'し',
    'chi': 'ち',
    'tsu': 'つ',
    'she': 'しぇ',
    'je': 'じぇ',
    'che': 'ちぇ',
    'ja': 'じゃ',
    'ju': 'じゅ',
    'jo': 'じょ',
    'fa': 'ふぁ',
    'fi': 'ふぃ',
    'fe': 'ふぇ',
    'fo': 'ふぉ',
    'fu': 'ふ',
    'wi': 'うぃ',
    'we': 'うぇ',
    'wo': 'を',
    'wu': 'う',
    'ka': 'か',
    'ki': 'き',
    'ku': 'く',
    'ke': 'け',
    'ko': 'こ',
    'ga': 'が',
    'gi': 'ぎ',
    'gu': 'ぐ',
    'ge': 'げ',
    'go': 'ご',
    'sa': 'さ',
    'si': 'し',
    'su': 'す',
    'se': 'せ',
    'so': 'そ',
    'za': 'ざ',
    'zi': 'じ',
    'zu': 'ず',
    'ze': 'ぜ',
    'zo': 'ぞ',
    'ta': 'た',
    'te': 'て',
    'to': 'と',
    'da': 'だ',
    'de': 'で',
    'do': 'ど',
    'na': 'な',
    'ni': 'に',
    'nu': 'ぬ',
    'ne': 'ね',
    'no': 'の',
    'ha': 'は',
    'hi': 'ひ',
    'he': 'へ',
    'ho': 'ほ',
    'ba': 'ば',
    'bi': 'び',
    'bu': 'ぶ',
    'be': 'べ',
    'bo': 'ぼ',
    'pa': 'ぱ',
    'pi': 'ぴ',
    'pu': 'ぷ',
    'pe': 'ぺ',
    'po': 'ぽ',
    'ma': 'ま',
    'mi': 'み',
    'mu': 'む',
    'me': 'め',
    'mo': 'も',
    'ya': 'や',
    'yu': 'ゆ',
    'yo': 'よ',
    'ra': 'ら',
    'ri': 'り',
    'ru': 'る',
    're': 'れ',
    'ro': 'ろ',
    'wa': 'わ',
    'a': 'あ',
    'i': 'い',
    'u': 'う',
    'e': 'え',
    'o': 'お',
  };
  static final _romajiKeys = _romaji.keys.toList()
    ..sort((left, right) => right.length.compareTo(left.length));
}
