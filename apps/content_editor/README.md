# Kotoba content editor UI

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
