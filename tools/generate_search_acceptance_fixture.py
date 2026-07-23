"""Generate the versioned Kotoba search-acceptance corpus.

The source lists in this file are deliberately reviewed, finite, and
deterministic.  The generated JSON is committed so CI consumers do not need to
run this generator; tests regenerate it in memory to detect accidental drift.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "data" / "fixtures" / "search_acceptance_v1.json"


# 100 distinct, high-frequency learner vocabulary items.  These are search
# probes, not release definitions or a claim of an authoritative frequency
# list.
COMMON_WORDS = (
    ("私", "わたし"), ("今日", "きょう"), ("明日", "あした"), ("昨日", "きのう"),
    ("人", "ひと"), ("時間", "じかん"), ("日本", "にほん"), ("学校", "がっこう"),
    ("先生", "せんせい"), ("学生", "がくせい"), ("友達", "ともだち"), ("家", "いえ"),
    ("会社", "かいしゃ"), ("駅", "えき"), ("電車", "でんしゃ"), ("車", "くるま"),
    ("本", "ほん"), ("新聞", "しんぶん"), ("水", "みず"), ("お茶", "おちゃ"),
    ("ご飯", "ごはん"), ("朝", "あさ"), ("昼", "ひる"), ("夜", "よる"),
    ("名前", "なまえ"), ("言葉", "ことば"), ("天気", "てんき"), ("雨", "あめ"),
    ("雪", "ゆき"), ("山", "やま"), ("川", "かわ"), ("海", "うみ"),
    ("道", "みち"), ("店", "みせ"), ("病院", "びょういん"), ("電話", "でんわ"),
    ("仕事", "しごと"), ("休み", "やすみ"), ("部屋", "へや"), ("窓", "まど"),
    ("机", "つくえ"), ("椅子", "いす"), ("犬", "いぬ"), ("猫", "ねこ"),
    ("魚", "さかな"), ("鳥", "とり"), ("花", "はな"), ("木", "き"),
    ("空", "そら"), ("町", "まち"), ("国", "くに"), ("問題", "もんだい"),
    ("質問", "しつもん"), ("答え", "こたえ"), ("音楽", "おんがく"), ("映画", "えいが"),
    ("写真", "しゃしん"), ("料理", "りょうり"), ("旅行", "りょこう"), ("生活", "せいかつ"),
    ("文化", "ぶんか"), ("意味", "いみ"), ("例", "れい"), ("前", "まえ"),
    ("後ろ", "うしろ"), ("上", "うえ"), ("下", "した"), ("中", "なか"),
    ("外", "そと"), ("右", "みぎ"), ("左", "ひだり"), ("東", "ひがし"),
    ("西", "にし"), ("南", "みなみ"), ("北", "きた"), ("春", "はる"),
    ("夏", "なつ"), ("秋", "あき"), ("冬", "ふゆ"), ("一", "いち"),
    ("二", "に"), ("三", "さん"), ("百", "ひゃく"), ("千", "せん"),
    ("円", "えん"), ("子供", "こども"), ("大人", "おとな"), ("男", "おとこ"),
    ("女", "おんな"), ("父", "ちち"), ("母", "はは"), ("兄", "あに"),
    ("姉", "あね"), ("弟", "おとうと"), ("妹", "いもうと"), ("体", "からだ"),
    ("手", "て"), ("足", "あし"), ("目", "め"), ("口", "くち"),
)


# Each row is a different lemma and an authentic inflected surface form that
# the P0 rule set promises to recover.
VERB_INFLECTIONS = (
    ("食べる", "たべる", "verb-ichidan", "食べました"),
    ("見る", "みる", "verb-ichidan", "見ました"),
    ("起きる", "おきる", "verb-ichidan", "起きました"),
    ("寝る", "ねる", "verb-ichidan", "寝ました"),
    ("教える", "おしえる", "verb-ichidan", "教えました"),
    ("覚える", "おぼえる", "verb-ichidan", "覚えました"),
    ("忘れる", "わすれる", "verb-ichidan", "忘れました"),
    ("開ける", "あける", "verb-ichidan", "開けました"),
    ("閉める", "しめる", "verb-ichidan", "閉めました"),
    ("借りる", "かりる", "verb-ichidan", "借りました"),
    ("いる", "いる", "verb-ichidan", "いました"),
    ("着る", "きる", "verb-ichidan", "着ました"),
    ("出る", "でる", "verb-ichidan", "出ました"),
    ("降りる", "おりる", "verb-ichidan", "降りました"),
    ("始める", "はじめる", "verb-ichidan", "始めました"),
    ("考える", "かんがえる", "verb-ichidan", "考えました"),
    ("調べる", "しらべる", "verb-ichidan", "調べました"),
    ("続ける", "つづける", "verb-ichidan", "続けました"),
    ("止める", "とめる", "verb-ichidan", "止めました"),
    ("生きる", "いきる", "verb-ichidan", "生きました"),
    ("書く", "かく", "verb-godan", "書いて"),
    ("聞く", "きく", "verb-godan", "聞いた"),
    ("歩く", "あるく", "verb-godan", "歩きました"),
    ("泳ぐ", "およぐ", "verb-godan", "泳いで"),
    ("話す", "はなす", "verb-godan", "話した"),
    ("待つ", "まつ", "verb-godan", "待って"),
    ("持つ", "もつ", "verb-godan", "持った"),
    ("立つ", "たつ", "verb-godan", "立たない"),
    ("買う", "かう", "verb-godan", "買って"),
    ("会う", "あう", "verb-godan", "会った"),
    ("使う", "つかう", "verb-godan", "使いました"),
    ("読む", "よむ", "verb-godan", "読んで"),
    ("飲む", "のむ", "verb-godan", "飲んだ"),
    ("休む", "やすむ", "verb-godan", "休みました"),
    ("遊ぶ", "あそぶ", "verb-godan", "遊んで"),
    ("呼ぶ", "よぶ", "verb-godan", "呼んだ"),
    ("死ぬ", "しぬ", "verb-godan", "死んだ"),
    ("取る", "とる", "verb-godan", "取って"),
    ("帰る", "かえる", "verb-godan", "帰った"),
    ("走る", "はしる", "verb-godan", "走りました"),
    ("入る", "はいる", "verb-godan", "入らない"),
    ("作る", "つくる", "verb-godan", "作って"),
    ("売る", "うる", "verb-godan", "売りました"),
    ("送る", "おくる", "verb-godan", "送った"),
    ("切る", "きる", "verb-godan", "切って"),
    ("急ぐ", "いそぐ", "verb-godan", "急いだ"),
    ("消す", "けす", "verb-godan", "消した"),
    ("行く", "いく", "verb-godan", "行かなかった"),
    ("働く", "はたらく", "verb-godan", "働きません"),
    ("習う", "ならう", "verb-godan", "習いませんでした"),
)


ADJECTIVE_INFLECTIONS = (
    ("高い", "たかい", "adjective-i", "高かった"),
    ("安い", "やすい", "adjective-i", "安くない"),
    ("大きい", "おおきい", "adjective-i", "大きかった"),
    ("小さい", "ちいさい", "adjective-i", "小さくない"),
    ("新しい", "あたらしい", "adjective-i", "新しくて"),
    ("古い", "ふるい", "adjective-i", "古かった"),
    ("良い", "よい", "adjective-i", "良くない"),
    ("悪い", "わるい", "adjective-i", "悪かった"),
    ("暑い", "あつい", "adjective-i", "暑くない"),
    ("寒い", "さむい", "adjective-i", "寒かった"),
    ("難しい", "むずかしい", "adjective-i", "難しくて"),
    ("易しい", "やさしい", "adjective-i", "易しかった"),
    ("面白い", "おもしろい", "adjective-i", "面白くない"),
    ("忙しい", "いそがしい", "adjective-i", "忙しかった"),
    ("楽しい", "たのしい", "adjective-i", "楽しくて"),
    ("長い", "ながい", "adjective-i", "長かった"),
    ("短い", "みじかい", "adjective-i", "短くない"),
    ("近い", "ちかい", "adjective-i", "近かった"),
    ("遠い", "とおい", "adjective-i", "遠くない"),
    ("静か", "しずか", "adjective-na", "静かだった"),
)


KATAKANA_CASES = (
    ("コーヒー", "コーヒー"), ("テレビ", "ﾃﾚﾋﾞ"), ("ラジオ", "ラジオ"),
    ("コンピューター", "ｺﾝﾋﾟｭｰﾀｰ"), ("スマートフォン", "ｽﾏｰﾄﾌｫﾝ"),
    ("インターネット", "ｲﾝﾀｰﾈｯﾄ"), ("ホテル", "ホテル"),
    ("レストラン", "ﾚｽﾄﾗﾝ"), ("タクシー", "ﾀｸｼｰ"), ("バス", "バス"),
    ("スーパー", "スーパー"), ("コンビニ", "ｺﾝﾋﾞﾆ"), ("カメラ", "カメラ"),
    ("ピアノ", "ﾋﾟｱﾉ"), ("ギター", "ｷﾞﾀｰ"), ("サッカー", "ｻｯｶｰ"),
    ("テニス", "テニス"), ("パン", "パン"), ("ジュース", "ジュース"),
    ("アイスクリーム", "アイスクリーム"),
)


ROMAJI_CASES = (
    ("食べる", "たべる", "taberu"), ("見る", "みる", "miru"),
    ("書く", "かく", "kaku"), ("読む", "よむ", "yomu"),
    ("飲む", "のむ", "nomu"), ("行く", "いく", "iku"),
    ("来る", "くる", "kuru"), ("する", "する", "suru"),
    ("学校", "がっこう", "gakkou"), ("先生", "せんせい", "sensei"),
    ("友達", "ともだち", "tomodachi"), ("新聞", "しんぶん", "shimbun"),
    ("電車", "でんしゃ", "densha"), ("病院", "びょういん", "byouin"),
    ("旅行", "りょこう", "ryokou"), ("音楽", "おんがく", "ongaku"),
    ("コンピューター", "コンピューター", "konpyuutaa"),
    ("コーヒー", "コーヒー", "koohii"), ("ジュース", "ジュース", "juusu"),
    ("サッカー", "サッカー", "sakkaa"),
)


# Ordered by intended frequency within each shared reading.  The first spelling
# is the expected top result; all alternatives must remain visible and ordered.
AMBIGUITY_GROUPS = (
    ("あう", (("会う", "verb-godan"), ("合う", "verb-godan"), ("遭う", "verb-godan"))),
    ("かえる", (("帰る", "verb-godan"), ("変える", "verb-ichidan"), ("替える", "verb-ichidan"))),
    ("きく", (("聞く", "verb-godan"), ("聴く", "verb-godan"), ("効く", "verb-godan"))),
    ("とる", (("取る", "verb-godan"), ("撮る", "verb-godan"), ("採る", "verb-godan"))),
    ("はし", (("橋", "noun"), ("箸", "noun"), ("端", "noun"))),
    ("かみ", (("紙", "noun"), ("髪", "noun"), ("神", "noun"))),
    ("あめ", (("雨", "noun"), ("飴", "noun"))),
    ("あつい", (("暑い", "adjective-i"), ("熱い", "adjective-i"), ("厚い", "adjective-i"))),
    ("はやい", (("早い", "adjective-i"), ("速い", "adjective-i"))),
    ("なおす", (("直す", "verb-godan"), ("治す", "verb-godan"))),
    ("うつす", (("写す", "verb-godan"), ("移す", "verb-godan"))),
    ("なく", (("泣く", "verb-godan"), ("鳴く", "verb-godan"))),
    ("あける", (("開ける", "verb-ichidan"), ("明ける", "verb-ichidan"))),
    ("かく", (("書く", "verb-godan"), ("描く", "verb-godan"), ("掻く", "verb-godan"))),
    ("さす", (("指す", "verb-godan"), ("刺す", "verb-godan"), ("差す", "verb-godan"))),
    ("つく", (("着く", "verb-godan"), ("付く", "verb-godan"), ("点く", "verb-godan"))),
    ("みる", (("見る", "verb-ichidan"), ("観る", "verb-ichidan"), ("診る", "verb-ichidan"))),
    ("のる", (("乗る", "verb-godan"), ("載る", "verb-godan"))),
    ("はかる", (("測る", "verb-godan"), ("計る", "verb-godan"), ("量る", "verb-godan"))),
    ("あがる", (("上がる", "verb-godan"), ("挙がる", "verb-godan"))),
)


NEGATIVE_CASES = (
    ("存在しない語", "unregistered Japanese phrase"),
    ("未登録語彙甲", "unregistered marker A"),
    ("未登録語彙乙", "unregistered marker B"),
    ("架空辞書語", "invented compound"),
    ("仮想単語丙", "unregistered marker C"),
    ("食べるる", "malformed doubled dictionary ending"),
    ("行くました", "malformed polite attachment"),
    ("高いかった", "malformed adjective past"),
    ("静かいだった", "malformed adjective copula"),
    ("学校校", "duplicated final kanji"),
    ("新聞聞", "duplicated final kanji"),
    ("コヒヒー", "misspelled katakana"),
    ("とうきょううう", "overlong kana"),
    ("かんじじじ", "repeated kana tail"),
    ("スーパーーー", "extra long-vowel marks"),
    ("zzzznotword", "non-convertible romaji"),
    ("qqqq", "non-convertible romaji"),
    ("xyzabc", "non-convertible romaji"),
    ("123不存在", "mixed digit negative"),
    ("無無無無", "repeated unattested form"),
)


def _entry_id(headword: str, reading: str) -> str:
    digest = hashlib.sha256(f"{headword}\0{reading}".encode("utf-8")).hexdigest()[:16]
    return f"golden_{digest}"


def _case(
    category: str,
    index: int,
    query: str,
    expected_ids: list[str],
    *,
    match_kind: str | None = None,
    analysis_lemma: str | None = None,
    note: str,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "case_id": f"{category}-{index:03d}",
        "raw_query": query,
        "input_context": "ja-JP offline dictionary search",
        "expected_entry_ids": expected_ids,
        "forbidden_entry_ids": [],
        "note": note,
    }
    if match_kind is not None:
        result["expected_match_kind"] = match_kind
    if analysis_lemma is not None:
        result["expected_analysis_lemma"] = analysis_lemma
    return result


def fixture_payload() -> dict[str, Any]:
    entries: dict[tuple[str, str], dict[str, Any]] = {}

    def add_entry(
        headword: str,
        reading: str,
        part_of_speech: str,
        frequency_rank: int,
        editorial_level: str,
        *,
        replace_editorial_level: bool = False,
        replace_frequency_rank: bool = False,
    ) -> str:
        key = (headword, reading)
        entry = entries.get(key)
        if entry is None:
            entry = {
                "entry_id": _entry_id(headword, reading),
                "headword": headword,
                "reading": reading,
                "part_of_speech": part_of_speech,
                "frequency_rank": frequency_rank,
                "editorial_level": editorial_level,
            }
            entries[key] = entry
        else:
            entry["frequency_rank"] = (
                frequency_rank
                if replace_frequency_rank
                else min(entry["frequency_rank"], frequency_rank)
            )
            if replace_editorial_level:
                entry["editorial_level"] = editorial_level
        return entry["entry_id"]

    categories: dict[str, list[dict[str, Any]]] = {
        "common_words": [],
        "verb_inflections": [],
        "adjective_inflections": [],
        "katakana": [],
        "romaji": [],
        "ambiguity": [],
        "negative": [],
    }

    for index, (headword, reading) in enumerate(COMMON_WORDS, 1):
        editorial_level = ("featured", "curated", "imported")[(index - 1) % 3]
        entry_id = add_entry(
            headword, reading, "noun", index, editorial_level
        )
        categories["common_words"].append(
            _case(
                "common",
                index,
                headword,
                [entry_id],
                match_kind="primary_exact",
                note=f"distinct common learner word: {headword}／{reading}",
            )
        )

    for index, (headword, reading, part_of_speech, surface) in enumerate(VERB_INFLECTIONS, 1):
        editorial_level = ("featured", "curated", "imported")[(index - 1) % 3]
        entry_id = add_entry(
            headword,
            reading,
            part_of_speech,
            500 + index,
            editorial_level,
        )
        categories["verb_inflections"].append(
            _case(
                "verb",
                index,
                surface,
                [entry_id],
                match_kind="deinflection",
                analysis_lemma=headword,
                note=f"recover {part_of_speech} lemma {headword} from {surface}",
            )
        )

    for index, (headword, reading, part_of_speech, surface) in enumerate(ADJECTIVE_INFLECTIONS, 1):
        editorial_level = ("featured", "curated", "imported")[(index - 1) % 3]
        entry_id = add_entry(
            headword,
            reading,
            part_of_speech,
            700 + index,
            editorial_level,
        )
        categories["adjective_inflections"].append(
            _case(
                "adjective",
                index,
                surface,
                [entry_id],
                match_kind="deinflection",
                analysis_lemma=headword,
                note=f"recover {part_of_speech} lemma {headword} from {surface}",
            )
        )

    for index, (headword, query) in enumerate(KATAKANA_CASES, 1):
        editorial_level = ("featured", "curated", "imported")[(index - 1) % 3]
        entry_id = add_entry(
            headword, headword, "noun", 1_500 + index, editorial_level
        )
        categories["katakana"].append(
            _case(
                "katakana",
                index,
                query,
                [entry_id],
                note=f"katakana/width normalization for {headword}",
            )
        )

    for index, (headword, reading, query) in enumerate(ROMAJI_CASES, 1):
        part = "verb-irregular" if headword in {"来る", "する"} else "noun"
        editorial_level = ("featured", "curated", "imported")[(index - 1) % 3]
        entry_id = add_entry(
            headword, reading, part, 1_800 + index, editorial_level
        )
        categories["romaji"].append(
            _case(
                "romaji",
                index,
                query,
                [entry_id],
                match_kind="romaji",
                note=f"common Hepburn input {query} → {reading}",
            )
        )

    for index, (reading, alternatives) in enumerate(AMBIGUITY_GROUPS, 1):
        ordered_ids: list[str] = []
        for alternative_index, (headword, part_of_speech) in enumerate(alternatives, 1):
            # Every alternative has the same frequency rank so the expected
            # featured → curated → imported order is caused by the canonical
            # editorial modifier, not hidden by frequency.
            rank = 2_000 + index * 100
            editorial_level = ("featured", "curated", "imported")[
                alternative_index - 1
            ]
            ordered_ids.append(
                add_entry(
                    headword,
                    reading,
                    part_of_speech,
                    rank,
                    editorial_level,
                    replace_editorial_level=True,
                    replace_frequency_rank=True,
                )
            )
        categories["ambiguity"].append(
            _case(
                "ambiguity",
                index,
                reading,
                ordered_ids,
                note=f"same-reading alternatives remain visible in frequency order: {reading}",
            )
        )

    for index, (query, reason) in enumerate(NEGATIVE_CASES, 1):
        categories["negative"].append(
            _case("negative", index, query, [], note=reason)
        )

    lexical_rows = sorted(entries.values(), key=lambda item: item["entry_id"])
    content = {"lexicon": lexical_rows, "categories": categories}
    checksum = hashlib.sha256(
        json.dumps(
            content,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return {
        "schema_version": 1,
        "corpus_id": "kotoba-search-acceptance-v1",
        "search_rules_version": 1,
        "normalizer_version": 1,
        "fixture_license": "CC0-1.0",
        "purpose": (
            "Machine-verifiable search contract; examples are QA probes and "
            "are not release dictionary content or a frequency authority."
        ),
        "content_sha256": checksum,
        **content,
    }


def render_fixture() -> str:
    return json.dumps(
        fixture_payload(), ensure_ascii=False, indent=2, sort_keys=True
    ) + "\n"


def main() -> int:
    DEFAULT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    DEFAULT_OUTPUT.write_text(render_fixture(), encoding="utf-8", newline="\n")
    print(DEFAULT_OUTPUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
