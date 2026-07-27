"""Dependency-free semantic validation for myJisho canonical JSON.

The JSON Schema is the interchange contract.  This module adds checks that JSON
Schema cannot conveniently express, such as stable-ID uniqueness, relation
integrity, provenance completeness, and the AI-review publishing gate.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import PurePosixPath
import re
from typing import Any, Iterable


ALLOWED_EDIT_STATUSES = {
    "imported",
    "draft",
    "ai_draft",
    "needs_review",
    "reviewed",
    "approved",
    "published",
    "rejected",
    "deprecated",
}
ALLOWED_RELATIONS = {
    "synonym",
    "near_synonym",
    "antonym",
    "hypernym",
    "hyponym",
    "easily_confused",
    "related",
    "orthographic_variant",
}
_SHA256 = re.compile(r"^[a-f0-9]{64}$")


@dataclass(frozen=True)
class ValidationIssue:
    path: str
    code: str
    message: str
    severity: str = "error"

    def __str__(self) -> str:
        return f"{self.severity.upper()} {self.code} at {self.path}: {self.message}"


def _is_non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _require_string(
    obj: dict[str, Any], key: str, path: str, issues: list[ValidationIssue]
) -> None:
    if not _is_non_empty_string(obj.get(key)):
        issues.append(ValidationIssue(f"{path}.{key}", "required_string", "must be a non-empty string"))


def _valid_timestamp(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return True
    except ValueError:
        return False


def is_safe_asset_path(value: Any) -> bool:
    """Return whether *value* is a normalized relative POSIX asset path."""

    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        return False
    if value.startswith("/") or value.endswith("/") or "//" in value:
        return False
    if re.match(r"^[A-Za-z]:", value):
        return False
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and path.as_posix() == value


def license_clearance_issues(document: Any) -> list[ValidationIssue]:
    """Return non-structural license risks for content referenced by entries.

    These are warnings during development, but the release builder promotes
    them to a hard gate unless explicitly producing a development package.
    """

    if not isinstance(document, dict) or not isinstance(document.get("entries"), list):
        return []
    sources = {
        source.get("source_id"): source
        for source in document.get("sources", [])
        if isinstance(source, dict) and isinstance(source.get("source_id"), str)
    }
    referenced: set[str] = set()
    assets: list[tuple[str, dict[str, Any]]] = []
    for i, entry in enumerate(document["entries"]):
        if not isinstance(entry, dict):
            continue
        referenced.update(value for value in entry.get("source_ids", []) if isinstance(value, str))
        for j, sense in enumerate(entry.get("senses", [])):
            if not isinstance(sense, dict):
                continue
            referenced.update(value for value in sense.get("source_ids", []) if isinstance(value, str))
            referenced.update(
                example.get("source_id")
                for example in sense.get("examples", [])
                if isinstance(example, dict) and isinstance(example.get("source_id"), str)
            )
            for field in ("image_assets", "audio_assets"):
                for k, asset in enumerate(sense.get(field, [])):
                    if isinstance(asset, dict):
                        source_id = asset.get("source_id")
                        if isinstance(source_id, str):
                            referenced.add(source_id)
                        assets.append((f"$.entries[{i}].senses[{j}].{field}[{k}]", asset))

    issues: list[ValidationIssue] = []
    unclear_values = {"", "noassertion", "none", "unknown", "unlicensed"}
    for source_id in sorted(referenced):
        source = sources.get(source_id)
        if source is None:
            continue  # Structural validation reports unknown references.
        source_path = f"$.sources[{source_id!r}]"
        license_value = str(source.get("license_spdx", "")).strip()
        if license_value.casefold() in unclear_values:
            issues.append(ValidationIssue(f"{source_path}.license_spdx", "uncleared_license", "referenced source needs an explicit license", "warning"))
        if source.get("redistribution_allowed") is not True:
            issues.append(ValidationIssue(f"{source_path}.redistribution_allowed", "redistribution_blocked", "referenced source must permit redistribution", "warning"))
        if source.get("source_type") != "original" or source.get("attribution_required") is True:
            for key in ("title", "author", "license_url", "original_url", "retrieved_at"):
                if not _is_non_empty_string(source.get(key)):
                    issues.append(ValidationIssue(f"{source_path}.{key}", "attribution_metadata", "required attribution/provenance metadata is missing", "warning"))

    for asset_path, asset in assets:
        license_value = str(asset.get("license_spdx", "")).strip()
        if license_value.casefold() in unclear_values:
            issues.append(ValidationIssue(f"{asset_path}.license_spdx", "uncleared_license", "packaged media needs an explicit license", "warning"))
        if asset.get("redistribution_allowed") is not True:
            issues.append(ValidationIssue(f"{asset_path}.redistribution_allowed", "redistribution_blocked", "packaged media must permit redistribution", "warning"))
    return issues


def validate_dictionary(document: Any) -> list[ValidationIssue]:
    """Return all validation issues without stopping at the first bad entry."""

    issues: list[ValidationIssue] = []
    if not isinstance(document, dict):
        return [ValidationIssue("$", "type", "document must be an object")]

    if document.get("schema_version") != 1:
        issues.append(ValidationIssue("$.schema_version", "schema_version", "supported value is 1"))
    _require_string(document, "dictionary_version", "$", issues)

    entries = document.get("entries")
    if not isinstance(entries, list):
        issues.append(ValidationIssue("$.entries", "type", "must be an array"))
        return issues

    entry_ids: set[str] = set()
    sense_ids: set[str] = set()
    example_ids: set[str] = set()
    asset_ids: set[str] = set()
    source_ids: set[str] = set()

    top_sources = document.get("sources", [])
    if not isinstance(top_sources, list):
        issues.append(ValidationIssue("$.sources", "type", "must be an array"))
        top_sources = []
    for i, source in enumerate(top_sources):
        path = f"$.sources[{i}]"
        if not isinstance(source, dict):
            issues.append(ValidationIssue(path, "type", "must be an object"))
            continue
        for key in ("source_id", "title", "source_type", "license_spdx"):
            _require_string(source, key, path, issues)
        source_id = source.get("source_id")
        if isinstance(source_id, str):
            if source_id in source_ids:
                issues.append(ValidationIssue(f"{path}.source_id", "duplicate_id", source_id))
            source_ids.add(source_id)
        if source.get("source_type") != "original":
            for key in (
                "license_url",
                "retrieved_at",
                "redistribution_allowed",
                "modification_allowed",
                "commercial_use_allowed",
                "attribution_required",
            ):
                if key not in source or source[key] in (None, ""):
                    issues.append(ValidationIssue(f"{path}.{key}", "external_provenance", "required for external data"))

    for i, entry in enumerate(entries):
        path = f"$.entries[{i}]"
        if not isinstance(entry, dict):
            issues.append(ValidationIssue(path, "type", "must be an object"))
            continue
        for key in ("entry_id", "headword", "created_at", "updated_at", "data_version"):
            _require_string(entry, key, path, issues)
        entry_id = entry.get("entry_id")
        if isinstance(entry_id, str):
            if entry_id in entry_ids:
                issues.append(ValidationIssue(f"{path}.entry_id", "duplicate_id", entry_id))
            entry_ids.add(entry_id)
        for key in ("created_at", "updated_at"):
            if key in entry and not _valid_timestamp(entry[key]):
                issues.append(ValidationIssue(f"{path}.{key}", "timestamp", "must be ISO-8601"))
        status = entry.get("edit_status")
        if status not in ALLOWED_EDIT_STATUSES:
            issues.append(ValidationIssue(f"{path}.edit_status", "enum", f"unknown status {status!r}"))

        forms = entry.get("forms")
        if not isinstance(forms, list) or not forms:
            issues.append(ValidationIssue(f"{path}.forms", "required", "at least one form is required"))
            forms = []
        primary_forms = 0
        for j, form in enumerate(forms):
            form_path = f"{path}.forms[{j}]"
            if not isinstance(form, dict):
                issues.append(ValidationIssue(form_path, "type", "must be an object"))
                continue
            _require_string(form, "text", form_path, issues)
            if form.get("type") == "primary":
                primary_forms += 1
        if primary_forms != 1:
            issues.append(ValidationIssue(f"{path}.forms", "primary_form", "exactly one primary form is required"))

        readings = entry.get("readings")
        if not isinstance(readings, list) or not readings:
            issues.append(ValidationIssue(f"{path}.readings", "required", "at least one reading is required"))

        parts = entry.get("parts_of_speech")
        if not isinstance(parts, list) or not parts or not all(_is_non_empty_string(p) for p in parts):
            issues.append(ValidationIssue(f"{path}.parts_of_speech", "required", "at least one part of speech is required"))

        entry_sources = entry.get("source_ids")
        if not isinstance(entry_sources, list) or not entry_sources:
            issues.append(ValidationIssue(f"{path}.source_ids", "missing_source", "entry must cite at least one source"))

        senses = entry.get("senses")
        if not isinstance(senses, list) or not senses:
            issues.append(ValidationIssue(f"{path}.senses", "required", "at least one sense is required"))
            senses = []
        orders: set[int] = set()
        for j, sense in enumerate(senses):
            sense_path = f"{path}.senses[{j}]"
            if not isinstance(sense, dict):
                issues.append(ValidationIssue(sense_path, "type", "must be an object"))
                continue
            for key in ("sense_id", "definition_ja_simple", "register", "importance", "review_status"):
                _require_string(sense, key, sense_path, issues)
            sense_id = sense.get("sense_id")
            if isinstance(sense_id, str):
                if sense_id in sense_ids:
                    issues.append(ValidationIssue(f"{sense_path}.sense_id", "duplicate_id", sense_id))
                sense_ids.add(sense_id)
            order = sense.get("order")
            if not isinstance(order, int) or order < 1:
                issues.append(ValidationIssue(f"{sense_path}.order", "order", "must be a positive integer"))
            elif order in orders:
                issues.append(ValidationIssue(f"{sense_path}.order", "duplicate_order", str(order)))
            else:
                orders.add(order)

            examples = sense.get("examples", [])
            if not isinstance(examples, list):
                issues.append(ValidationIssue(f"{sense_path}.examples", "type", "must be an array"))
                examples = []
            if sense.get("importance") == "primary" and not examples:
                issues.append(ValidationIssue(f"{sense_path}.examples", "primary_example", "primary sense needs an example"))
            for k, example in enumerate(examples):
                example_path = f"{sense_path}.examples[{k}]"
                if not isinstance(example, dict):
                    issues.append(ValidationIssue(example_path, "type", "must be an object"))
                    continue
                for key in ("example_id", "sentence", "source_id"):
                    _require_string(example, key, example_path, issues)
                example_id = example.get("example_id")
                if isinstance(example_id, str):
                    if example_id in example_ids:
                        issues.append(ValidationIssue(f"{example_path}.example_id", "duplicate_id", example_id))
                    example_ids.add(example_id)

            for asset_kind, assets in (("image", sense.get("image_assets", [])), ("audio", sense.get("audio_assets", []))):
                assets_path = f"{sense_path}.{asset_kind}_assets"
                if not isinstance(assets, list):
                    issues.append(ValidationIssue(assets_path, "type", "must be an array"))
                    continue
                for k, asset in enumerate(assets):
                    asset_path = f"{assets_path}[{k}]"
                    if not isinstance(asset, dict):
                        issues.append(ValidationIssue(asset_path, "type", "must be an object"))
                        continue
                    for key in ("asset_id", "source_id", "license_spdx", "sha256", "path", "kind"):
                        _require_string(asset, key, asset_path, issues)
                    asset_id = asset.get("asset_id")
                    if isinstance(asset_id, str):
                        if asset_id in asset_ids:
                            issues.append(ValidationIssue(f"{asset_path}.asset_id", "duplicate_id", asset_id))
                        asset_ids.add(asset_id)
                    if not isinstance(asset.get("sha256"), str) or not _SHA256.fullmatch(asset["sha256"]):
                        issues.append(ValidationIssue(f"{asset_path}.sha256", "checksum", "must be a lowercase SHA-256"))
                    if not is_safe_asset_path(asset.get("path")):
                        issues.append(ValidationIssue(f"{asset_path}.path", "unsafe_asset_path", "must be a normalized relative POSIX path without traversal, NUL, or backslashes"))
                    if asset.get("kind") != asset_kind:
                        issues.append(ValidationIssue(f"{asset_path}.kind", "asset_kind", f"must be {asset_kind}"))

    # Cross-reference checks run after all stable IDs have been collected.
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            continue
        path = f"$.entries[{i}]"
        for source_id in entry.get("source_ids", []):
            if source_id not in source_ids:
                issues.append(ValidationIssue(f"{path}.source_ids", "unknown_source", str(source_id)))
        cited_source_ids = set(entry.get("source_ids", []))
        for sense in entry.get("senses", []):
            if not isinstance(sense, dict):
                continue
            cited_source_ids.update(sense.get("source_ids", []))
            cited_source_ids.update(
                example.get("source_id")
                for example in sense.get("examples", [])
                if isinstance(example, dict)
            )
            for field in ("image_assets", "audio_assets"):
                cited_source_ids.update(
                    asset.get("source_id")
                    for asset in sense.get(field, [])
                    if isinstance(asset, dict)
                )
        ai_assisted = any(
            next(
                (source for source in top_sources if isinstance(source, dict) and source.get("source_id") == source_id),
                {},
            ).get("ai_assisted", False)
            for source_id in cited_source_ids
        )
        publishing_status = entry.get("edit_status")
        if publishing_status in {"approved", "published"}:
            review = entry.get("review", {})
            has_review_evidence = (
                isinstance(review, dict)
                and _is_non_empty_string(review.get("reviewed_by"))
                and _valid_timestamp(review.get("reviewed_at"))
            )
            if not has_review_evidence:
                issues.append(ValidationIssue(f"{path}.review", "review_evidence", "approved/published content requires reviewer and timestamp"))
            if ai_assisted:
                review_status_aligned = isinstance(review, dict) and review.get("status") == publishing_status
                senses_aligned = all(
                    isinstance(sense, dict) and sense.get("review_status") == publishing_status
                    for sense in entry.get("senses", [])
                )
                if not (has_review_evidence and review_status_aligned and senses_aligned):
                    issues.append(
                        ValidationIssue(
                            f"{path}.review",
                            "ai_review_gate",
                            "AI-assisted approved/published content requires human evidence and aligned entry, review, and sense statuses",
                        )
                    )
        for j, sense in enumerate(entry.get("senses", [])):
            if not isinstance(sense, dict):
                continue
            sense_path = f"{path}.senses[{j}]"
            for source_id in sense.get("source_ids", []):
                if source_id not in source_ids:
                    issues.append(ValidationIssue(f"{sense_path}.source_ids", "unknown_source", str(source_id)))
            for k, example in enumerate(sense.get("examples", [])):
                if isinstance(example, dict) and example.get("source_id") not in source_ids:
                    issues.append(ValidationIssue(f"{sense_path}.examples[{k}].source_id", "unknown_source", str(example.get("source_id"))))
            for field in ("image_assets", "audio_assets"):
                for k, asset in enumerate(sense.get(field, [])):
                    if isinstance(asset, dict) and asset.get("source_id") not in source_ids:
                        issues.append(ValidationIssue(f"{sense_path}.{field}[{k}].source_id", "unknown_source", str(asset.get("source_id"))))
            for k, relation in enumerate(sense.get("relations", [])):
                relation_path = f"{sense_path}.relations[{k}]"
                if not isinstance(relation, dict):
                    issues.append(ValidationIssue(relation_path, "type", "must be an object"))
                    continue
                if relation.get("entry_id") not in entry_ids:
                    issues.append(ValidationIssue(f"{relation_path}.entry_id", "unknown_entry", str(relation.get("entry_id"))))
                if relation.get("relation_type") not in ALLOWED_RELATIONS:
                    issues.append(ValidationIssue(f"{relation_path}.relation_type", "enum", str(relation.get("relation_type"))))

    issues.extend(license_clearance_issues(document))
    return issues


def assert_valid_dictionary(document: Any) -> None:
    """Raise ``ValueError`` containing every error in *document*."""

    issues = validate_dictionary(document)
    errors = [issue for issue in issues if issue.severity == "error"]
    if errors:
        raise ValueError("Canonical dictionary validation failed:\n" + "\n".join(map(str, errors)))
