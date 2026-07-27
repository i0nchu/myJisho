"""Deterministic Japanese query normalization and deinflection."""

from .normalizer import (
    DeinflectionCandidate,
    deinflect,
    hiragana_to_katakana,
    katakana_to_hiragana,
    normalize_kana,
    normalize_text,
    query_variants,
    romaji_to_hiragana,
)

__all__ = [
    "DeinflectionCandidate",
    "deinflect",
    "hiragana_to_katakana",
    "katakana_to_hiragana",
    "normalize_kana",
    "normalize_text",
    "query_variants",
    "romaji_to_hiragana",
]
