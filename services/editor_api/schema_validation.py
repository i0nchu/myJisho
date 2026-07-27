"""Small dependency-free validator for the JSON Schema features myJisho uses."""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

from packages.dictionary_schema import validate_dictionary


SCHEMA_PATH = Path(__file__).resolve().parents[2] / "packages" / "dictionary_schema" / "schema.json"


def load_schema() -> dict[str, Any]:
    with SCHEMA_PATH.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def _type_matches(value: Any, expected: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }.get(expected, True)


def _resolve_ref(root: dict[str, Any], ref: str) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise ValueError(f"unsupported schema reference: {ref}")
    node: Any = root
    for part in ref[2:].split("/"):
        node = node[part.replace("~1", "/").replace("~0", "~")]
    return node


def _walk(value: Any, rule: dict[str, Any], root: dict[str, Any], path: str, issues: list[dict[str, str]]) -> None:
    if "$ref" in rule:
        _walk(value, _resolve_ref(root, rule["$ref"]), root, path, issues)
        return
    if "const" in rule and value != rule["const"]:
        issues.append(_issue(path, "const", f"must equal {rule['const']!r}"))
    if "enum" in rule and value not in rule["enum"]:
        issues.append(_issue(path, "enum", f"must be one of {rule['enum']}"))

    expected = rule.get("type")
    expected_types = expected if isinstance(expected, list) else [expected] if expected else []
    if expected_types and not any(_type_matches(value, item) for item in expected_types):
        issues.append(_issue(path, "type", f"must be {' or '.join(expected_types)}"))
        return

    if isinstance(value, dict):
        required = rule.get("required", [])
        for key in required:
            if key not in value:
                issues.append(_issue(f"{path}.{key}", "required", "property is required"))
        properties = rule.get("properties", {})
        if rule.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    issues.append(_issue(f"{path}.{key}", "additional_property", "property is not allowed"))
        for key, child in properties.items():
            if key in value:
                _walk(value[key], child, root, f"{path}.{key}", issues)
    elif isinstance(value, list):
        if len(value) < rule.get("minItems", 0):
            issues.append(_issue(path, "min_items", f"needs at least {rule['minItems']} item(s)"))
        item_rule = rule.get("items")
        if item_rule:
            for index, item in enumerate(value):
                _walk(item, item_rule, root, f"{path}[{index}]", issues)
    elif isinstance(value, str):
        if len(value) < rule.get("minLength", 0):
            issues.append(_issue(path, "min_length", "must not be empty"))
        if "pattern" in rule and re.fullmatch(rule["pattern"], value) is None:
            issues.append(_issue(path, "pattern", f"must match {rule['pattern']}"))
        if rule.get("format") == "date-time":
            try:
                datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                issues.append(_issue(path, "date_time", "must be an ISO-8601 date-time"))
    elif isinstance(value, int) and not isinstance(value, bool):
        if "minimum" in rule and value < rule["minimum"]:
            issues.append(_issue(path, "minimum", f"must be at least {rule['minimum']}"))


def _issue(path: str, code: str, message: str) -> dict[str, str]:
    return {"path": path, "code": code, "message": message, "severity": "error"}


def validate_document(document: Any) -> list[dict[str, str]]:
    """Validate structural schema and semantic cross-document rules."""

    schema = load_schema()
    issues: list[dict[str, str]] = []
    _walk(document, schema, schema, "$", issues)
    semantic = [
        {"path": issue.path, "code": issue.code, "message": issue.message, "severity": issue.severity}
        for issue in validate_dictionary(document)
    ]
    seen = {(item["path"], item["code"], item["message"]) for item in issues}
    issues.extend(item for item in semantic if (item["path"], item["code"], item["message"]) not in seen)
    return issues
