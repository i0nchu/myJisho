"""Pure, dependency-free normalization used by build-time and search-time code."""

from __future__ import annotations

from dataclasses import dataclass
import re
import unicodedata


_JAPANESE_PUNCTUATION = str.maketrans("", "", "、。，．・：；？！『』「」【】（）［］｛｝〈〉《》〔〕…‥\"'“”‘’")
_SPACE_RE = re.compile(r"\s+")
_ROMAJI_RE = re.compile(r"^[A-Za-zāīūēōĀĪŪĒŌ' -]+$")


def normalize_text(text: str) -> str:
    """NFKC-normalize, case-fold, trim, and remove search punctuation/spaces."""

    if not isinstance(text, str):
        raise TypeError("text must be str")
    value = unicodedata.normalize("NFKC", text).casefold().strip()
    value = value.translate(_JAPANESE_PUNCTUATION)
    return _SPACE_RE.sub("", value)


def katakana_to_hiragana(text: str) -> str:
    """Convert modern katakana code points to hiragana; leave other text intact."""

    result: list[str] = []
    for char in unicodedata.normalize("NFKC", text):
        code = ord(char)
        if 0x30A1 <= code <= 0x30F6:
            result.append(chr(code - 0x60))
        else:
            result.append(char)
    return "".join(result)


def hiragana_to_katakana(text: str) -> str:
    result: list[str] = []
    for char in text:
        code = ord(char)
        if 0x3041 <= code <= 0x3096:
            result.append(chr(code + 0x60))
        else:
            result.append(char)
    return "".join(result)


_VOWEL_BY_KANA = {
    **{char: "あ" for char in "あかがさざただなはばぱまゃやらゎわ"},
    **{char: "い" for char in "いきぎしじちぢにひびぴみりゐ"},
    **{char: "う" for char in "うくぐすずつづぬふぶぷむゅゆるゔ"},
    **{char: "え" for char in "えけげせぜてでねへべぺめれゑ"},
    **{char: "お" for char in "おこごそぞとどのほぼぽもょよろを"},
}


def _expand_long_marks(text: str) -> str:
    out: list[str] = []
    for char in text:
        if char == "ー" and out:
            out.append(_VOWEL_BY_KANA.get(out[-1], char))
        else:
            out.append(char)
    return "".join(out)


def normalize_kana(text: str, *, expand_long_vowels: bool = True) -> str:
    """Normalize width/case/punctuation, kana script, and optionally ``ー``."""

    value = katakana_to_hiragana(normalize_text(text))
    return _expand_long_marks(value) if expand_long_vowels else value


_ROMAJI = {
    # Alternate and extended spellings must be considered before shorter keys.
    "ltsu": "っ", "xtsu": "っ", "tcha": "っちゃ", "tchu": "っちゅ", "tcho": "っちょ",
    "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ", "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
    "sha": "しゃ", "shu": "しゅ", "sho": "しょ", "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
    "ja": "じゃ", "ju": "じゅ", "jo": "じょ", "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
    "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ", "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
    "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ", "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
    "bya": "びゃ", "byu": "びゅ", "byo": "びょ", "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
    "mya": "みゃ", "myu": "みゅ", "myo": "みょ", "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
    "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ", "fya": "ふゃ", "fyu": "ふゅ", "fyo": "ふょ",
    "shi": "し", "chi": "ち", "tsu": "つ", "dzu": "づ", "fu": "ふ",
    "she": "しぇ", "je": "じぇ", "che": "ちぇ", "ti": "てぃ", "tu": "とぅ", "di": "でぃ", "du": "どぅ",
    "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ", "wi": "うぃ", "we": "うぇ", "wo": "を", "wu": "う",
    "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
    "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ",
    "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
    "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
    "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
    "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
    "za": "ざ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
    "ta": "た", "te": "て", "to": "と", "da": "だ", "de": "で", "do": "ど",
    "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
    "ha": "は", "hi": "ひ", "he": "へ", "ho": "ほ",
    "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
    "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
    "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
    "ya": "や", "yu": "ゆ", "yo": "よ", "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
    "wa": "わ", "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
}
_ROMAJI_KEYS = sorted(_ROMAJI, key=len, reverse=True)


def romaji_to_hiragana(text: str) -> tuple[str, ...]:
    """Return deterministic Hepburn-style candidates (empty for non-romaji)."""

    if not isinstance(text, str) or not _ROMAJI_RE.fullmatch(text.strip()):
        return ()
    value = unicodedata.normalize("NFKC", text).casefold().strip()
    value = value.translate(str.maketrans({"ā": "aa", "ī": "ii", "ū": "uu", "ē": "ee", "ō": "ou"}))
    value = re.sub(r"[ -]", "", value)
    # Both shinbun and the traditional Hepburn spelling shimbun are accepted.
    value = re.sub(r"m(?=[bmp])", "n", value)
    out: list[str] = []
    i = 0
    while i < len(value):
        if value[i] == "'":
            i += 1
            continue
        if i + 1 < len(value) and value[i] == value[i + 1] and value[i] not in "aeioun":
            out.append("っ")
            i += 1
            continue
        if value[i] == "n":
            next_char = value[i + 1] if i + 1 < len(value) else ""
            if not next_char or next_char == "'" or next_char not in "aeiouy":
                out.append("ん")
                i += 1
                continue
        matched = False
        for key in _ROMAJI_KEYS:
            if value.startswith(key, i):
                out.append(_ROMAJI[key])
                i += len(key)
                matched = True
                break
        if not matched:
            return ()
    primary = "".join(out)
    candidates = [primary]
    # `ou` may represent おう or おお in real names/lexemes; retain both.
    if "おう" in primary:
        candidates.append(primary.replace("おう", "おお"))
    return tuple(dict.fromkeys(candidates))


@dataclass(frozen=True)
class DeinflectionCandidate:
    lemma: str
    reason: str
    confidence: float


_POLITE_STEM = {"い": ("う", "く", "ぐ"), "き": ("く",), "ぎ": ("ぐ",), "し": ("す",), "ち": ("つ",), "に": ("ぬ",), "び": ("ぶ",), "み": ("む",), "り": ("る",)}
_A_ROW = {"わ": "う", "か": "く", "が": "ぐ", "さ": "す", "た": "つ", "な": "ぬ", "ば": "ぶ", "ま": "む", "ら": "る"}
_E_ROW = {"え": "う", "け": "く", "げ": "ぐ", "せ": "す", "て": "つ", "ね": "ぬ", "べ": "ぶ", "め": "む", "れ": "る"}
_O_ROW = {"お": "う", "こ": "く", "ご": "ぐ", "そ": "す", "と": "つ", "の": "ぬ", "ぼ": "ぶ", "も": "む", "ろ": "る"}


def deinflect(text: str) -> tuple[DeinflectionCandidate, ...]:
    """Generate plausible verb/adjective lemmas; callers must verify in lexicon."""

    value = normalize_text(text)
    found: dict[tuple[str, str], DeinflectionCandidate] = {}

    def add(lemma: str, reason: str, confidence: float) -> None:
        if lemma and lemma != value:
            key = (lemma, reason)
            candidate = DeinflectionCandidate(lemma, reason, confidence)
            if key not in found or found[key].confidence < confidence:
                found[key] = candidate

    # Progressive forms are reduced recursively to their て-form.
    for suffix in ("ている", "でいる", "ています", "でいます", "ていた", "でいた"):
        if value.endswith(suffix):
            te_form = value[: -len(suffix)] + suffix[0]
            for candidate in deinflect(te_form):
                add(candidate.lemma, f"progressive/{candidate.reason}", candidate.confidence * 0.94)

    polite_suffixes = ("ませんでした", "ました", "ません", "ます")
    for suffix in polite_suffixes:
        if value.endswith(suffix) and len(value) > len(suffix):
            stem = value[: -len(suffix)]
            add(stem + "る", f"polite:{suffix}", 0.96)
            if stem and stem[-1] in _POLITE_STEM:
                for ending in _POLITE_STEM[stem[-1]]:
                    add(stem[:-1] + ending, f"polite:{suffix}", 0.92)

    for suffix, endings in (("って", ("う", "つ", "る")), ("った", ("う", "つ", "る")), ("んで", ("む", "ぶ", "ぬ")), ("んだ", ("む", "ぶ", "ぬ")), ("いて", ("く",)), ("いた", ("く",)), ("いで", ("ぐ",)), ("いだ", ("ぐ",)), ("して", ("す",)), ("した", ("す",))):
        if value.endswith(suffix) and len(value) > len(suffix):
            root = value[: -len(suffix)]
            add(root + "る", f"te/past:{suffix}", 0.88)
            for ending in endings:
                add(root + ending, f"te/past:{suffix}", 0.95)
            if value == "行って" or value == "行った":
                add("行く", f"irregular:{suffix}", 0.99)

    for suffix in ("なくて", "なかった", "ない"):
        if value.endswith(suffix) and len(value) > len(suffix):
            stem = value[: -len(suffix)]
            add(stem + "る", f"negative:{suffix}", 0.91)
            if stem and stem[-1] in _A_ROW:
                add(stem[:-1] + _A_ROW[stem[-1]], f"negative:{suffix}", 0.96)

    # Ichidan passive/potential and causative, including negative variants.
    for suffix, reason, confidence in (
        ("られなかった", "ichidan:potential/passive-negative-past", 0.94),
        ("られない", "ichidan:potential/passive-negative", 0.96),
        ("られた", "ichidan:potential/passive-past", 0.93),
        ("られる", "ichidan:potential/passive", 0.95),
        ("させられる", "ichidan:causative-passive", 0.90),
        ("させる", "ichidan:causative", 0.94),
    ):
        if value.endswith(suffix) and len(value) > len(suffix):
            add(value[: -len(suffix)] + "る", reason, confidence)

    # Godan passive/causative and negative variants use the a-row stem.
    for suffix, reason, confidence in (
        ("せられる", "godan:causative-passive", 0.88),
        ("せる", "godan:causative", 0.93),
        ("れる", "godan:passive", 0.92),
    ):
        if value.endswith(suffix) and len(value) > len(suffix):
            stem = value[: -len(suffix)]
            if stem and stem[-1] in _A_ROW:
                add(stem[:-1] + _A_ROW[stem[-1]], reason, confidence)

    # Godan potential/imperative/conditional and volitional.
    for suffix, reason in (("れば", "conditional"), ("る", "potential")):
        if value.endswith(suffix) and len(value) > len(suffix):
            stem = value[: -len(suffix)]
            if stem and stem[-1] in _E_ROW:
                add(stem[:-1] + _E_ROW[stem[-1]], f"godan:{reason}", 0.91)
    if value and value[-1] in _E_ROW:
        add(value[:-1] + _E_ROW[value[-1]], "godan:imperative", 0.82)
    if value.endswith("う") and len(value) > 1 and value[-2] in _O_ROW:
        add(value[:-2] + _O_ROW[value[-2]], "godan:volitional", 0.91)

    # I-adjectives. Longer endings are checked first to avoid bad truncation.
    for suffix, replacement, reason, confidence in (
        ("くなかった", "い", "i-adjective:negative-past", 0.98),
        ("くありませんでした", "い", "i-adjective:polite-negative-past", 0.97),
        ("かった", "い", "i-adjective:past", 0.98),
        ("くない", "い", "i-adjective:negative", 0.98),
        ("くありません", "い", "i-adjective:polite-negative", 0.97),
        ("くて", "い", "i-adjective:connective", 0.95),
        ("く", "い", "i-adjective:adverbial", 0.90),
    ):
        if value.endswith(suffix) and len(value) > len(suffix):
            add(value[: -len(suffix)] + replacement, reason, confidence)

    # Common na-adjective copular/connective forms.
    for suffix, reason, confidence in (
        ("ではありませんでした", "na-adjective:polite-negative-past", 0.96),
        ("ではない", "na-adjective:negative", 0.95),
        ("じゃない", "na-adjective:negative-casual", 0.93),
        ("だった", "na-adjective:past", 0.96),
        ("なら", "na-adjective:conditional", 0.90),
        ("で", "na-adjective:connective", 0.82),
        ("に", "na-adjective:adverbial", 0.80),
        ("な", "na-adjective:attributive", 0.80),
        ("だ", "na-adjective:copula", 0.88),
    ):
        if value.endswith(suffix) and len(value) > len(suffix):
            add(value[: -len(suffix)], reason, confidence)

    return tuple(sorted(found.values(), key=lambda item: (-item.confidence, item.lemma, item.reason)))


def query_variants(text: str) -> dict[str, tuple[str, ...]]:
    """Expose every deterministic query representation while retaining raw input."""

    normalized = normalize_text(text)
    kana = normalize_kana(text)
    romaji = romaji_to_hiragana(text)
    return {
        "raw": (text,),
        "normalized": (normalized,),
        "kana": (kana,),
        "romaji": tuple(normalize_kana(item) for item in romaji),
    }
