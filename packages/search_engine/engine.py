"""Traceable rank-based offline search over a builder-produced SQLite file."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import re
import sqlite3
from typing import Iterable

from packages.japanese_normalizer import deinflect, normalize_kana, normalize_text, romaji_to_hiragana


_ASCII_ROMAJI = re.compile(r"^[A-Za-zāīūēōĀĪŪĒŌ' -]+$")


@dataclass(frozen=True)
class MatchEvidence:
    matched_key: str
    match_type: str
    base_score: int
    modifiers: tuple[tuple[str, int], ...]
    final_score: int
    deinflection_reason: str | None = None
    deinflection_confidence: float | None = None


@dataclass(frozen=True)
class SearchResult:
    entry_id: str
    headword: str
    reading: str
    parts_of_speech: tuple[str, ...]
    definition_ja_simple: str
    frequency_rank: int | None
    score: int
    match_type: str
    query_source: str
    deinflected_from: str | None = None
    evidence: tuple[MatchEvidence, ...] = field(default_factory=tuple)


class SearchEngine:
    """Read-only search service; one instance may be reused for many queries."""

    def __init__(self, database: str | Path | sqlite3.Connection):
        if isinstance(database, sqlite3.Connection):
            self.connection = database
            self._owns_connection = False
        else:
            uri = Path(database).resolve().as_uri() + "?mode=ro"
            self.connection = sqlite3.connect(uri, uri=True)
            self._owns_connection = True
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA query_only = ON")

    def close(self) -> None:
        if self._owns_connection:
            self.connection.close()

    def __enter__(self) -> "SearchEngine":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _entry_modifiers(self, row: sqlite3.Row, is_common: bool) -> tuple[tuple[str, int], ...]:
        modifiers: list[tuple[str, int]] = []
        rank = row["frequency_rank"]
        if rank is not None:
            if rank <= 1_000:
                modifiers.append(("frequency", 120))
            elif rank <= 5_000:
                modifiers.append(("frequency", 80))
            elif rank <= 10_000:
                modifiers.append(("frequency", 40))
        level = row["editorial_level"]
        if level == "featured":
            modifiers.append(("editorial_featured", 80))
        elif level == "curated":
            modifiers.append(("editorial_curated", 40))
        if is_common:
            modifiers.append(("common_form", 40))
        return tuple(modifiers)

    def _rows_exact(self, key: str) -> list[sqlite3.Row]:
        return self.connection.execute(
            """
            SELECT sk.*, e.headword, e.frequency_rank, e.editorial_level
            FROM search_keys sk JOIN entries e USING (entry_id)
            WHERE sk.search_key = ?
            ORDER BY sk.entry_id, sk.key_type
            """,
            (key,),
        ).fetchall()

    def _rows_prefix(self, key: str, candidate_limit: int) -> list[sqlite3.Row]:
        return self.connection.execute(
            """
            SELECT sk.*, e.headword, e.frequency_rank, e.editorial_level
            FROM search_keys sk JOIN entries e USING (entry_id)
            WHERE sk.search_key_prefix >= ? AND sk.search_key_prefix < ? AND sk.search_key != ?
            LIMIT ?
            """,
            (key, key + "\U0010ffff", key, candidate_limit),
        ).fetchall()

    def _rows_contains(self, key: str, candidate_limit: int) -> list[sqlite3.Row]:
        escaped = key.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        return self.connection.execute(
            """
            SELECT sk.*, e.headword, e.frequency_rank, e.editorial_level
            FROM search_keys sk JOIN entries e USING (entry_id)
            WHERE sk.search_key LIKE ? ESCAPE '\\' AND sk.search_key != ?
            LIMIT ?
            """,
            (f"%{escaped}%", key, candidate_limit),
        ).fetchall()

    def _make_evidence(
        self,
        row: sqlite3.Row,
        match_type: str,
        base_score: int,
        *,
        confidence: float | None = None,
        reason: str | None = None,
    ) -> MatchEvidence:
        modifiers = list(self._entry_modifiers(row, bool(row["is_common"])))
        if confidence is not None:
            penalty = -round((1.0 - confidence) * 100)
            if penalty:
                modifiers.append(("deinflection_uncertainty", penalty))
        final_score = base_score + sum(value for _, value in modifiers)
        return MatchEvidence(
            matched_key=row["display_key"],
            match_type=match_type,
            base_score=base_score,
            modifiers=tuple(modifiers),
            final_score=final_score,
            deinflection_reason=reason,
            deinflection_confidence=confidence,
        )

    def search(self, query: str, *, limit: int = 20, debug: bool = False) -> list[SearchResult]:
        """Search by exact form/reading, normalized kana, romaji, inflection, prefix, then substring."""

        if limit < 1:
            return []
        raw = query
        normalized = normalize_text(query)
        if not normalized:
            return []
        kana = normalize_kana(query)
        is_romaji = bool(_ASCII_ROMAJI.fullmatch(query.strip()))
        evidence_by_entry: dict[str, list[MatchEvidence]] = {}
        candidate_limit = min(max(limit * 4, 32), 200)

        def record(row: sqlite3.Row, evidence: MatchEvidence) -> None:
            values = evidence_by_entry.setdefault(row["entry_id"], [])
            identity = (evidence.matched_key, evidence.match_type, evidence.deinflection_reason)
            if not any((old.matched_key, old.match_type, old.deinflection_reason) == identity for old in values):
                values.append(evidence)

        # Exact form/reading. Script/width conversions are deliberately labeled normalized.
        if not is_romaji:
            exact_keys = [normalized]
            if kana != normalized:
                exact_keys.append(kana)
            for exact_key in dict.fromkeys(exact_keys):
                for row in self._rows_exact(exact_key):
                    key_type = row["key_type"]
                    display_normalized = normalize_text(row["display_key"])
                    transformed = exact_key != normalized or display_normalized != normalized
                    if transformed:
                        match_type, base = "normalized_exact", 850
                    elif key_type == "primary":
                        match_type, base = "primary_exact", 1000
                    elif key_type == "alternate":
                        match_type, base = "alternate_exact", 950
                    else:
                        match_type, base = "reading_exact", 900
                    record(row, self._make_evidence(row, match_type, base))

        # Romaji is intentionally lower than exact Japanese matches.
        if is_romaji:
            for converted in romaji_to_hiragana(query):
                key = normalize_kana(converted)
                for row in self._rows_exact(key):
                    record(row, self._make_evidence(row, "romaji", 550))

        # Deinflection candidates only become results if the candidate exists in the lexicon.
        if not is_romaji:
            deinflection_inputs = tuple(dict.fromkeys((normalized, kana)))
            for source in deinflection_inputs:
                for candidate in deinflect(source):
                    candidate_keys = tuple(dict.fromkeys((normalize_text(candidate.lemma), normalize_kana(candidate.lemma))))
                    for key in candidate_keys:
                        for row in self._rows_exact(key):
                            record(
                                row,
                                self._make_evidence(
                                    row,
                                    "deinflection",
                                    800,
                                    confidence=candidate.confidence,
                                    reason=candidate.reason,
                                ),
                            )

        # Prefix and substring fallback. For romaji the converted kana is used.
        fallback_keys: list[str]
        if is_romaji:
            fallback_keys = [normalize_kana(value) for value in romaji_to_hiragana(query)]
        else:
            fallback_keys = list(dict.fromkeys((normalized, kana)))
        for key in fallback_keys:
            for row in self._rows_prefix(key, candidate_limit):
                if row["key_type"] == "reading":
                    match_type, base = "reading_prefix", 600
                else:
                    match_type, base = "primary_prefix", 650
                if is_romaji:
                    match_type, base = "romaji_prefix", 500
                record(row, self._make_evidence(row, match_type, base))
            # Contains is the final fallback and must not impose a table scan on
            # queries already satisfied by a stronger stage.
            if len(key) >= 2 and not evidence_by_entry:
                for row in self._rows_contains(key, candidate_limit):
                    record(row, self._make_evidence(row, "contains", 450))

        if not evidence_by_entry:
            return []
        entry_ids = sorted(evidence_by_entry)
        placeholders = ",".join("?" for _ in entry_ids)
        # Fetch related display fields in batches. This intentionally avoids
        # correlated subqueries, which turn broad prefixes into O(candidates ×
        # dictionary-size) scans when reading/definition indexes are absent in
        # an older but schema-compatible database.
        rows = self.connection.execute(
            f"SELECT entry_id, headword, frequency_rank FROM entries WHERE entry_id IN ({placeholders})",
            entry_ids,
        ).fetchall()
        reading_rows = self.connection.execute(
            f"SELECT entry_id, kana, is_primary, reading_id FROM readings WHERE entry_id IN ({placeholders})",
            entry_ids,
        ).fetchall()
        readings: dict[str, tuple[int, str, str]] = {}
        for reading_row in reading_rows:
            value = (int(reading_row["is_primary"]), reading_row["reading_id"], reading_row["kana"])
            old = readings.get(reading_row["entry_id"])
            if old is None or (-value[0], value[1]) < (-old[0], old[1]):
                readings[reading_row["entry_id"]] = value
        pos_rows = self.connection.execute(
            f"SELECT entry_id, pos_code, sort_order FROM entry_parts_of_speech WHERE entry_id IN ({placeholders})",
            entry_ids,
        ).fetchall()
        parts: dict[str, list[tuple[int, str]]] = {}
        for pos_row in pos_rows:
            parts.setdefault(pos_row["entry_id"], []).append((pos_row["sort_order"], pos_row["pos_code"]))
        sense_rows = self.connection.execute(
            f"SELECT entry_id, sense_id, sort_order FROM senses WHERE entry_id IN ({placeholders})",
            entry_ids,
        ).fetchall()
        primary_senses: dict[str, tuple[int, str]] = {}
        for sense_row in sense_rows:
            value = (sense_row["sort_order"], sense_row["sense_id"])
            old = primary_senses.get(sense_row["entry_id"])
            if old is None or value < old:
                primary_senses[sense_row["entry_id"]] = value
        sense_ids = [value[1] for value in primary_senses.values()]
        definitions: dict[str, str] = {}
        if sense_ids:
            sense_placeholders = ",".join("?" for _ in sense_ids)
            definition_rows = self.connection.execute(
                f"SELECT sense_id, language, definition_text FROM definitions WHERE sense_id IN ({sense_placeholders})",
                sense_ids,
            ).fetchall()
            for definition_row in definition_rows:
                if definition_row["sense_id"] not in definitions or definition_row["language"] == "ja-simple":
                    definitions[definition_row["sense_id"]] = definition_row["definition_text"]
        results: list[SearchResult] = []
        for row in rows:
            evidence = sorted(
                evidence_by_entry[row["entry_id"]],
                key=lambda item: (-item.final_score, item.match_type, item.matched_key),
            )
            best = evidence[0]
            results.append(
                SearchResult(
                    entry_id=row["entry_id"],
                    headword=row["headword"],
                    reading=readings.get(row["entry_id"], (0, "", ""))[2],
                    parts_of_speech=tuple(value for _, value in sorted(parts.get(row["entry_id"], []))),
                    definition_ja_simple=definitions.get(primary_senses.get(row["entry_id"], (0, ""))[1], ""),
                    frequency_rank=row["frequency_rank"],
                    score=best.final_score,
                    match_type=best.match_type,
                    query_source=raw,
                    deinflected_from=raw if best.match_type == "deinflection" else None,
                    evidence=tuple(evidence) if debug else (),
                )
            )
        return sorted(
            results,
            key=lambda item: (-item.score, item.frequency_rank is None, item.frequency_rank or 2**31, item.headword, item.entry_id),
        )[:limit]
