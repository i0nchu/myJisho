# myJisho content editor UI

The UI is served by `python -m services.editor_api`; no build step or JavaScript
package install is required. It provides:

- headword/form/reading search and entry selection;
- structured editing for entry fields, forms, readings, senses, examples,
  relations, image metadata, and audio metadata;
- live app-like learner preview;
- schema and semantic validation with JSON paths;
- optimistic-concurrency saves to the server working copy;
- explicit review-state actions with AI-draft and human-review gates.

The UI intentionally has no arbitrary JSON-file picker and no publish bypass.
Transition actions operate on the last saved revision, so unsaved content must
be saved before a state change.

## Editorial presentation contract

The default form is organized around an editor's work: headword and readings,
senses, examples and related entries, then human review. Canonical enum values
are presented with Traditional Chinese labels. Stable IDs, raw status codes,
versions and timestamps are read-only under **系統資訊**; provenance and media
metadata are under **進階設定**.

The browser always starts from the complete entry returned by the API and
patches editable values into that snapshot. Hidden fields are never reconstructed
from an abbreviated form. The server remains authoritative for child IDs,
`updated_at`, entry/review/sense status alignment, and workflow transitions.
Related entries are selected by headword or reading while the canonical
`entry_id` remains the stored reference. Human validation text is shown first;
the stable JSON path, code and original message remain available under
**技術資訊** for diagnosis and audit evidence.
