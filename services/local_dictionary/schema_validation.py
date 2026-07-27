"""Small dependency-free JSON Schema validator for local entry payloads."""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any


SCHEMA_PATH = Path(__file__).with_name("schema.json")


def load_schema() -> dict[str, Any]:
    with SCHEMA_PATH.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def validate_schema(value: Any) -> list[dict[str, str]]:
    schema = load_schema()
    issues: list[dict[str, str]] = []
    _walk(value, schema, schema, "$", issues)
    return issues


def _walk(
    value: Any,
    rule: dict[str, Any],
    root: dict[str, Any],
    path: str,
    issues: list[dict[str, str]],
) -> None:
    if "$ref" in rule:
        node: Any = root
        for part in rule["$ref"][2:].split("/"):
            node = node[part.replace("~1", "/").replace("~0", "~")]
        _walk(value, node, root, path, issues)
        return

    if "enum" in rule and value not in rule["enum"]:
        issues.append(_issue(path, "enum", f"must be one of {rule['enum']}"))
    if "const" in rule and value != rule["const"]:
        issues.append(_issue(path, "const", f"must equal {rule['const']!r}"))

    expected = rule.get("type")
    expected_types = expected if isinstance(expected, list) else [expected] if expected else []
    if expected_types and not any(_matches_type(value, item) for item in expected_types):
        issues.append(_issue(path, "type", f"must be {' or '.join(expected_types)}"))
        return

    if isinstance(value, dict):
        properties = rule.get("properties", {})
        for required in rule.get("required", []):
            if required not in value:
                issues.append(_issue(f"{path}.{required}", "required", "property is required"))
        if rule.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    issues.append(_issue(f"{path}.{key}", "additional_property", "property is not allowed"))
        for key, child_rule in properties.items():
            if key in value:
                _walk(value[key], child_rule, root, f"{path}.{key}", issues)
        return

    if isinstance(value, list):
        if len(value) < rule.get("minItems", 0):
            issues.append(_issue(path, "min_items", f"needs at least {rule['minItems']} item(s)"))
        if "maxItems" in rule and len(value) > rule["maxItems"]:
            issues.append(_issue(path, "max_items", f"must contain at most {rule['maxItems']} item(s)"))
        item_rule = rule.get("items")
        if item_rule:
            for index, item in enumerate(value):
                _walk(item, item_rule, root, f"{path}[{index}]", issues)
        return

    if isinstance(value, str):
        if len(value) < rule.get("minLength", 0):
            issues.append(_issue(path, "min_length", "must not be empty"))
        if "pattern" in rule and re.fullmatch(rule["pattern"], value) is None:
            issues.append(_issue(path, "pattern", f"must match {rule['pattern']}"))
        if rule.get("format") == "date-time":
            try:
                datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                issues.append(_issue(path, "date_time", "must be an ISO-8601 date-time"))
        return

    if isinstance(value, int) and not isinstance(value, bool):
        if "minimum" in rule and value < rule["minimum"]:
            issues.append(_issue(path, "minimum", f"must be at least {rule['minimum']}"))


def _matches_type(value: Any, expected: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }.get(expected, True)


def _issue(path: str, code: str, message: str) -> dict[str, str]:
    return {"path": path, "code": code, "message": message, "severity": "error"}
