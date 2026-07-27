from __future__ import annotations

import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[3]
EDITOR_ROOT = PROJECT_ROOT / "apps" / "content_editor"


class EditorUITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.html = (EDITOR_ROOT / "index.html").read_text(encoding="utf-8")
        cls.script = (EDITOR_ROOT / "app.js").read_text(encoding="utf-8")

    def test_default_information_architecture_uses_editor_language(self) -> None:
        for label in ("見出與讀音", "詞義、例句與關聯", "人工審核流程"):
            self.assertIn(label, self.html)
        for disclosure in ("進階設定", "系統資訊"):
            self.assertIn(f"<summary>{disclosure}</summary>", self.html)
        self.assertNotIn("needs_review", self.html)
        self.assertNotIn("reviewed/approved/published", self.html)

    def test_raw_codes_have_friendly_presentation_maps(self) -> None:
        for code, label in (
            ("ai_draft", "AI 草稿"),
            ("needs_review", "待人工審核"),
            ("near_synonym", "近義詞"),
            ("orthographic_variant", "表記差異"),
            ("system_tts", "裝置語音"),
        ):
            self.assertIn(f'{code}: "{label}"', self.script)
        self.assertIn("STATUS_ACTIONS", self.script)
        self.assertIn("labelFor(STATUS_LABELS, item.edit_status)", self.script)

    def test_pos_subtypes_render_as_families_without_rewriting_canonical_codes(self) -> None:
        self.assertIn('code.startsWith(`${prefix}-`)', self.script)
        self.assertIn("function mergePartsOfSpeech(original, selectedFamilies, otherParts)", self.script)
        self.assertIn("original.filter((code)", self.script)
        self.assertIn("section.dataset.originalParts = JSON.stringify(parts)", self.script)
        self.assertIn("parts_of_speech: mergePartsOfSpeech(", self.script)
        self.assertIn("partDisplayLabel(part)", self.script)
        self.assertIn('control("目前 canonical 詞性代碼"', self.script)
        self.assertNotIn("parts_of_speech: selectedFamilies", self.script)

    def test_editor_merges_changes_into_a_canonical_snapshot(self) -> None:
        self.assertIn("const draft = clone(original);", self.script)
        self.assertIn("function mergeEditableEntry(original, values)", self.script)
        self.assertNotIn("draft.updated_at =", self.script)
        self.assertIn("review_status: original.edit_status", self.script)
        self.assertIn("sense_id: card.dataset.senseId", self.script)
        self.assertNotIn('control("義項 ID"', self.script)
        self.assertNotIn('control("例句 ID"', self.script)

    def test_validation_keeps_raw_evidence_behind_technical_details(self) -> None:
        self.assertIn('node("summary", "", "技術資訊")', self.script)
        self.assertIn("${issue.path} · ${issue.code} · ${issue.message}", self.script)
        self.assertIn("friendlyIssue(issue)", self.script)


if __name__ == "__main__":
    unittest.main()
