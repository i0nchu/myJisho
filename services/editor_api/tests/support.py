from __future__ import annotations


def valid_document(status: str = "draft") -> dict:
    return {
        "schema_version": 1,
        "dictionary_version": "test-1",
        "sources": [
            {
                "source_id": "kotoba.original",
                "title": "Kotoba original",
                "source_type": "original",
                "author": "Kotoba editorial team",
                "license_spdx": "CC-BY-4.0",
                "license_url": "https://creativecommons.org/licenses/by/4.0/",
                "original_url": "https://kotoba.invalid/source/test",
                "retrieved_at": "2026-07-22T00:00:00Z",
                "redistribution_allowed": True,
                "modification_allowed": True,
                "commercial_use_allowed": True,
                "attribution_required": True,
                "ai_assisted": False,
            }
        ],
        "entries": [valid_entry(status)],
    }


def valid_entry(status: str = "draft") -> dict:
    return {
        "entry_id": "entry-taberu",
        "headword": "食べる",
        "forms": [{"text": "食べる", "type": "primary", "common": True}],
        "readings": [{"kana": "たべる", "primary": True}],
        "parts_of_speech": ["verb"],
        "frequency_rank": 120,
        "editorial_level": "curated",
        "edit_status": status,
        "senses": [
            {
                "sense_id": "sense-taberu-1",
                "order": 1,
                "definition_ja_simple": "食物を口に入れる。",
                "usage_note_ja": "",
                "register": "neutral",
                "importance": "primary",
                "examples": [
                    {
                        "example_id": "example-taberu-1",
                        "sentence": "朝ご飯を食べる。",
                        "source_id": "kotoba.original",
                        "audio_asset_id": None,
                    }
                ],
                "relations": [],
                "image_assets": [],
                "audio_assets": [],
                "source_ids": ["kotoba.original"],
                "review_status": status,
            }
        ],
        "source_ids": ["kotoba.original"],
        "review": {"status": status, "reviewed_by": None, "reviewed_at": None, "notes": ""},
        "created_at": "2026-07-22T00:00:00Z",
        "updated_at": "2026-07-22T00:00:00Z",
        "data_version": "1",
    }
