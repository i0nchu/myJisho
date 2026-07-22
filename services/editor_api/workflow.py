"""Editorial state machine and human-review gates."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any


TRANSITIONS: dict[str, set[str]] = {
    "imported": {"draft", "ai_draft", "deprecated"},
    "draft": {"needs_review", "rejected"},
    "ai_draft": {"needs_review", "rejected"},
    "needs_review": {"reviewed", "draft", "rejected"},
    "reviewed": {"approved", "needs_review", "rejected"},
    "approved": {"published", "needs_review", "deprecated"},
    "published": {"needs_review", "deprecated"},
    "rejected": {"draft", "ai_draft"},
    "deprecated": {"draft"},
}


class WorkflowError(ValueError):
    pass


def allowed_transitions(status: str) -> list[str]:
    return sorted(TRANSITIONS.get(status, set()))


def check_transition(before: dict[str, Any], after: dict[str, Any]) -> None:
    old = before.get("edit_status")
    new = after.get("edit_status")
    if old == new:
        return
    if new not in TRANSITIONS.get(old, set()):
        raise WorkflowError(f"illegal status transition: {old!r} -> {new!r}")
    review = after.get("review", {})
    if new in {"reviewed", "approved", "published"}:
        if not str(review.get("reviewed_by") or "").strip() or not review.get("reviewed_at"):
            raise WorkflowError(f"{new} requires human reviewer and review time")
    if old == "ai_draft" and new in {"approved", "published"}:
        raise WorkflowError("AI draft must pass needs_review and reviewed before approval")
    if new == "published" and old != "approved":
        raise WorkflowError("published content must come from approved")


def check_replacement(before: dict[str, Any], after: dict[str, Any]) -> None:
    """Check transition rules and prevent silent edits to signed-off content."""

    check_transition(before, after)
    if before.get("edit_status") == after.get("edit_status") and before.get("edit_status") in {
        "reviewed",
        "approved",
        "published",
    }:
        ignored = {"updated_at", "review"}
        before_content = {key: value for key, value in before.items() if key not in ignored}
        after_content = {key: value for key, value in after.items() if key not in ignored}
        if before_content != after_content:
            raise WorkflowError("signed-off content must move to needs_review before editing")


def transition(entry: dict[str, Any], status: str, reviewer: str = "", notes: str = "") -> dict[str, Any]:
    import copy

    result = copy.deepcopy(entry)
    if status in {"reviewed", "approved", "published"}:
        if not reviewer.strip():
            raise WorkflowError(f"{status} requires a named human reviewer")
        result["review"] = {
            "status": status,
            "reviewed_by": reviewer.strip(),
            "reviewed_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "notes": notes,
        }
    else:
        review = result.setdefault("review", {})
        review["status"] = status
        if notes:
            review["notes"] = notes
    result["edit_status"] = status
    for sense in result.get("senses", []):
        sense["review_status"] = status
    result["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    check_transition(entry, result)
    return result
