"use strict";

const state = { entry: null, revision: "", allowed: [], selectedId: "", dirty: false };
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

function node(tag, className = "", text = "") {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text) element.textContent = text;
  return element;
}

function control(labelText, className, value = "", options = {}) {
  const label = node("label");
  label.append(node("span", "", labelText));
  let input;
  if (options.choices) {
    input = node("select", className);
    for (const choice of options.choices) {
      const option = node("option", "", choice);
      option.value = choice;
      input.append(option);
    }
  } else if (options.multiline) {
    input = node("textarea", className);
  } else {
    input = node("input", className);
    input.type = options.type || "text";
  }
  input.value = value ?? "";
  if (options.readonly) input.readOnly = true;
  if (options.placeholder) input.placeholder = options.placeholder;
  label.append(input);
  return label;
}

function checkbox(labelText, className, checked) {
  const label = node("label");
  label.append(node("span", "", labelText));
  const input = node("input", className);
  input.type = "checkbox";
  input.checked = Boolean(checked);
  label.append(input);
  return label;
}

function removeButton(callback) {
  const button = node("button", "secondary danger remove", "移除");
  button.type = "button";
  button.addEventListener("click", callback);
  return button;
}

async function request(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
  });
  let payload;
  try { payload = await response.json(); } catch { payload = {}; }
  if (!response.ok) {
    const error = new Error(payload.error?.message || `HTTP ${response.status}`);
    error.payload = payload;
    error.status = response.status;
    throw error;
  }
  return payload;
}

async function loadEntries(query = "") {
  try {
    const payload = await request(`/api/entries?q=${encodeURIComponent(query)}`);
    $("#connection").textContent = "本機 working copy";
    $("#result-count").textContent = `${payload.entries.length} 筆結果`;
    const list = $("#entry-list");
    list.replaceChildren();
    for (const item of payload.entries) {
      const button = node("button", `entry-button${item.entry_id === state.selectedId ? " active" : ""}`);
      button.type = "button";
      button.append(node("strong", "", item.headword));
      button.append(node("small", "", `${item.reading || "—"} · ${item.edit_status}`));
      button.append(node("small", "", item.entry_id));
      button.addEventListener("click", () => selectEntry(item.entry_id));
      list.append(button);
    }
  } catch (error) {
    $("#connection").textContent = "無法連線";
    toast(error.message);
  }
}

async function selectEntry(entryId) {
  if (state.dirty && !window.confirm("尚有未儲存變更，確定要切換詞條嗎？")) return;
  try {
    const payload = await request(`/api/entries/${encodeURIComponent(entryId)}`);
    state.entry = payload.entry;
    state.revision = payload.revision;
    state.allowed = payload.allowed_transitions;
    state.selectedId = entryId;
    state.dirty = false;
    renderEditor();
    loadEntries($("#search").value);
  } catch (error) { toast(error.message); }
}

function renderEditor() {
  const entry = state.entry;
  $("#empty-state").classList.add("hidden");
  $("#entry-form").classList.remove("hidden");
  $("#entry-id").textContent = entry.entry_id;
  $("#entry-title").textContent = entry.headword;
  $("#status-badge").textContent = entry.edit_status;
  $("#ai-warning").classList.toggle("hidden", entry.edit_status !== "ai_draft");

  const basic = $("#basic-fields");
  basic.replaceChildren(
    control("詞目", "headword", entry.headword),
    control("詞性（逗號分隔）", "parts", entry.parts_of_speech.join(", ")),
    control("頻率排名", "frequency", entry.frequency_rank ?? "", { type: "number" }),
    control("編輯層級", "editorial-level", entry.editorial_level, { choices: ["imported", "curated", "featured"] }),
    control("來源 ID（逗號分隔）", "source-ids", entry.source_ids.join(", ")),
    control("資料版本", "data-version", entry.data_version),
  );
  renderForms(entry.forms);
  renderReadings(entry.readings);
  const senses = $("#senses");
  senses.replaceChildren();
  entry.senses.forEach((sense) => senses.append(renderSense(sense)));
  renderTransitions();
  hideIssues();
  $("#save-state").textContent = "已載入最新版本";
  $("#entry-form").oninput = () => {
    state.dirty = true;
    $("#save-state").textContent = "有未儲存變更";
    updatePreview();
  };
  updatePreview();
}

function sectionHeader(title, buttonText, callback) {
  const heading = node("div", "section-heading");
  heading.append(node("h3", "", title));
  const button = node("button", "secondary", buttonText);
  button.type = "button";
  button.addEventListener("click", callback);
  heading.append(button);
  return heading;
}

function renderForms(forms) {
  const section = $("#forms-section");
  const list = node("div", "repeat-list forms-list");
  section.replaceChildren(sectionHeader("表記", "＋ 新增表記", () => {
    list.append(formRow({ text: "", type: "alternate", common: false })); markDirty();
  }), list);
  forms.forEach((form) => list.append(formRow(form)));
}

function formRow(form) {
  const row = node("div", "repeat-row form-row");
  row.append(control("文字", "form-text", form.text));
  row.append(control("類型", "form-type", form.type, { choices: ["primary", "alternate", "kana", "variant", "rare"] }));
  row.append(checkbox("常用", "form-common", form.common));
  row.append(removeButton(() => { row.remove(); markDirty(); }));
  return row;
}

function renderReadings(readings) {
  const section = $("#readings-section");
  const list = node("div", "repeat-list readings-list");
  section.replaceChildren(sectionHeader("讀音", "＋ 新增讀音", () => {
    list.append(readingRow({ kana: "", primary: false })); markDirty();
  }), list);
  readings.forEach((reading) => list.append(readingRow(reading)));
}

function readingRow(reading) {
  const row = node("div", "repeat-row reading-row");
  row.append(control("假名", "reading-kana", reading.kana));
  row.append(checkbox("主要讀音", "reading-primary", reading.primary));
  row.append(removeButton(() => { row.remove(); markDirty(); }));
  return row;
}

function renderSense(sense) {
  const card = node("article", "sense-card");
  const heading = node("div", "sense-heading");
  heading.append(node("h4", "sense-label", `義項 ${sense.order}`));
  heading.append(removeButton(() => { card.remove(); renumberSenses(); markDirty(); }));
  card.append(heading);
  const basics = node("div", "field-grid sense-basics");
  basics.append(
    control("義項 ID", "sense-id", sense.sense_id),
    control("順序", "sense-order", sense.order, { type: "number" }),
    control("重要性", "sense-importance", sense.importance, { choices: ["primary", "secondary", "rare"] }),
    control("語域", "sense-register", sense.register),
    control("簡明日文定義", "sense-definition definition", sense.definition_ja_simple, { multiline: true }),
    control("使用說明", "sense-usage definition", sense.usage_note_ja, { multiline: true }),
    control("義項來源 ID（逗號分隔）", "sense-sources", sense.source_ids.join(", ")),
    control("義項審核狀態", "sense-review", sense.review_status),
  );
  card.append(basics);
  card.append(nestedExamples(sense.examples || []));
  card.append(nestedRelations(sense.relations || []));
  card.append(nestedAssets("圖片 metadata", "image-list", sense.image_assets || [], "image"));
  card.append(nestedAssets("音訊 metadata", "audio-list", sense.audio_assets || [], "audio"));
  return card;
}

function nested(title, addText, className, add) {
  const wrapper = node("section", `nested ${className}-section`);
  const list = node("div", `repeat-list ${className}`);
  const heading = node("div", "section-heading");
  heading.append(node("h5", "", title));
  const button = node("button", "secondary", addText);
  button.type = "button";
  button.addEventListener("click", () => { list.append(add()); markDirty(); });
  heading.append(button);
  wrapper.append(heading, list);
  return { wrapper, list };
}

function nestedExamples(examples) {
  const part = nested("例句", "＋ 例句", "examples-list", () => exampleRow({ example_id: "", sentence: "", source_id: "", audio_asset_id: null }));
  examples.forEach((example) => part.list.append(exampleRow(example)));
  return part.wrapper;
}

function exampleRow(example) {
  const row = node("div", "repeat-row example-row");
  row.append(control("例句 ID", "example-id", example.example_id));
  row.append(control("日文例句", "example-sentence", example.sentence));
  row.append(control("來源 ID", "example-source", example.source_id));
  row.append(control("音訊 asset ID", "example-audio", example.audio_asset_id || ""));
  row.append(removeButton(() => { row.remove(); markDirty(); }));
  return row;
}

function nestedRelations(relations) {
  const blank = { entry_id: "", relation_type: "related", note_ja: "" };
  const part = nested("詞條關係", "＋ 關係", "relations-list", () => relationRow(blank));
  relations.forEach((relation) => part.list.append(relationRow(relation)));
  return part.wrapper;
}

function relationRow(relation) {
  const row = node("div", "repeat-row relation-row");
  row.append(control("目標 entry ID", "relation-entry", relation.entry_id));
  row.append(control("關係", "relation-type", relation.relation_type, { choices: ["synonym", "near_synonym", "antonym", "hypernym", "hyponym", "easily_confused", "related", "orthographic_variant"] }));
  row.append(control("日文說明", "relation-note", relation.note_ja));
  row.append(removeButton(() => { row.remove(); markDirty(); }));
  return row;
}

function nestedAssets(title, className, assets, kind) {
  const blank = { asset_id: "", source_id: "", license_spdx: "", redistribution_allowed: false, sha256: "", path: "", kind, audio_type: "system_tts" };
  const part = nested(title, "＋ Asset", className, () => assetRow(blank, kind));
  assets.forEach((asset) => part.list.append(assetRow(asset, kind)));
  return part.wrapper;
}

function assetRow(asset, kind) {
  const row = node("div", "repeat-row asset-row");
  row.append(control("Asset ID", "asset-id", asset.asset_id));
  row.append(control("來源 ID", "asset-source", asset.source_id));
  row.append(control("SPDX 授權", "asset-license", asset.license_spdx));
  row.append(control("SHA-256", "asset-hash", asset.sha256));
  row.append(control("相對資產路徑", "asset-path", asset.path || ""));
  row.append(checkbox("允許再散布", "asset-redistribution", asset.redistribution_allowed));
  if (kind === "audio") row.append(control("音訊類型", "asset-audio-type", asset.audio_type || "system_tts", { choices: ["system_tts", "synthetic", "human"] }));
  row.append(removeButton(() => { row.remove(); markDirty(); }));
  return row;
}

function splitList(value) {
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}

function collectDraft() {
  const original = state.entry;
  const draft = structuredClone(original);
  draft.headword = $(".headword").value.trim();
  draft.parts_of_speech = splitList($(".parts").value);
  draft.frequency_rank = $(".frequency").value ? Number($(".frequency").value) : null;
  draft.editorial_level = $(".editorial-level").value;
  draft.source_ids = splitList($(".source-ids").value);
  draft.data_version = $(".data-version").value.trim();
  draft.updated_at = new Date().toISOString();
  draft.forms = $$(".form-row").map((row) => ({
    text: $(".form-text", row).value.trim(), type: $(".form-type", row).value, common: $(".form-common", row).checked,
  }));
  draft.readings = $$(".reading-row").map((row) => ({
    kana: $(".reading-kana", row).value.trim(), primary: $(".reading-primary", row).checked,
  }));
  draft.senses = $$(".sense-card").map((card, index) => collectSense(card, index));
  return draft;
}

function collectSense(card, index) {
  return {
    sense_id: $(".sense-id", card).value.trim(),
    order: Number($(".sense-order", card).value) || index + 1,
    definition_ja_simple: $(".sense-definition", card).value.trim(),
    usage_note_ja: $(".sense-usage", card).value,
    register: $(".sense-register", card).value.trim(),
    importance: $(".sense-importance", card).value,
    examples: $$(".example-row", card).map((row) => ({
      example_id: $(".example-id", row).value.trim(),
      sentence: $(".example-sentence", row).value.trim(),
      source_id: $(".example-source", row).value.trim(),
      audio_asset_id: $(".example-audio", row).value.trim() || null,
    })),
    relations: $$(".relation-row", card).map((row) => ({
      entry_id: $(".relation-entry", row).value.trim(),
      relation_type: $(".relation-type", row).value,
      note_ja: $(".relation-note", row).value,
    })),
    image_assets: collectAssets(card, ".image-list", "image"),
    audio_assets: collectAssets(card, ".audio-list", "audio"),
    source_ids: splitList($(".sense-sources", card).value),
    review_status: $(".sense-review", card).value.trim(),
  };
}

function collectAssets(card, listSelector, kind) {
  return $$(`${listSelector} .asset-row`, card).map((row) => {
    const asset = {
      asset_id: $(".asset-id", row).value.trim(),
      source_id: $(".asset-source", row).value.trim(),
      license_spdx: $(".asset-license", row).value.trim(),
      redistribution_allowed: $(".asset-redistribution", row).checked,
      sha256: $(".asset-hash", row).value.trim(),
      path: $(".asset-path", row).value.trim(),
      kind,
    };
    if (kind === "audio") asset.audio_type = $(".asset-audio-type", row).value;
    return asset;
  });
}

function updatePreview() {
  if (!state.entry) return;
  const draft = collectDraft();
  const preview = $("#preview");
  preview.replaceChildren();
  preview.append(node("p", "preview-meta", draft.parts_of_speech.join(" · ")));
  preview.append(node("h3", "preview-headword", draft.headword || "—"));
  preview.append(node("p", "preview-reading", draft.readings.find((item) => item.primary)?.kana || draft.readings[0]?.kana || ""));
  preview.append(node("p", "preview-meta", `頻率 ${draft.frequency_rank ?? "—"} · ${draft.editorial_level}`));
  draft.senses.forEach((sense, index) => {
    const block = node("section", "preview-sense");
    block.append(node("h4", "", `${index + 1} · ${sense.register} · ${sense.importance}`));
    block.append(node("p", "", sense.definition_ja_simple || "未填寫定義"));
    if (sense.usage_note_ja) block.append(node("p", "preview-meta", sense.usage_note_ja));
    if (sense.examples[0]?.sentence) block.append(node("p", "preview-example", sense.examples[0].sentence));
    preview.append(block);
  });
  $("#entry-title").textContent = draft.headword || state.entry.entry_id;
}

function renderTransitions() {
  const holder = $("#transition-buttons");
  holder.replaceChildren();
  if (!state.allowed.length) holder.append(node("span", "muted", "目前沒有可用的狀態轉換"));
  for (const status of state.allowed) {
    const button = node("button", "secondary", `轉為 ${status}`);
    button.type = "button";
    button.addEventListener("click", () => runTransition(status));
    holder.append(button);
  }
}

async function runTransition(status) {
  if (state.dirty) { toast("請先儲存或重新載入目前變更，再執行狀態轉換"); return; }
  try {
    const payload = await request(`/api/entries/${encodeURIComponent(state.selectedId)}/transition`, {
      method: "POST",
      body: JSON.stringify({
        status,
        reviewer: $("#reviewer").value,
        notes: $("#review-notes").value,
        base_revision: state.revision,
      }),
    });
    state.entry = payload.entry; state.revision = payload.revision; state.allowed = payload.allowed_transitions;
    state.dirty = false; renderEditor(); loadEntries($("#search").value); toast(`已轉為 ${status}`);
  } catch (error) { showApiError(error); }
}

async function validateDraft() {
  try {
    const payload = await request(`/api/entries/${encodeURIComponent(state.selectedId)}/validate`, {
      method: "POST", body: JSON.stringify({ entry: collectDraft() }),
    });
    showIssues(payload.issues);
    toast(payload.valid ? "Schema 與語意驗證通過" : `發現 ${payload.issues.length} 個問題`);
  } catch (error) { showApiError(error); }
}

async function saveDraft(event) {
  event.preventDefault();
  try {
    const payload = await request(`/api/entries/${encodeURIComponent(state.selectedId)}`, {
      method: "PUT", body: JSON.stringify({ entry: collectDraft(), base_revision: state.revision }),
    });
    state.entry = payload.entry; state.revision = payload.revision; state.allowed = payload.allowed_transitions;
    state.dirty = false; renderEditor(); loadEntries($("#search").value); toast("已安全寫入 working copy");
  } catch (error) { showApiError(error); }
}

function showApiError(error) {
  if (error.payload?.issues) showIssues(error.payload.issues);
  toast(error.status === 409 ? `${error.message}（請重新選取詞條）` : error.message);
}

function showIssues(issues) {
  const panel = $("#issues-panel");
  const list = $("#issues");
  list.replaceChildren();
  if (!issues.length) list.append(node("li", "", "全部驗證通過"));
  for (const issue of issues) list.append(node("li", "", `${issue.path} · ${issue.code} · ${issue.message}`));
  panel.classList.remove("hidden");
}

function hideIssues() { $("#issues-panel").classList.add("hidden"); $("#issues").replaceChildren(); }
function markDirty() { state.dirty = true; $("#save-state").textContent = "有未儲存變更"; updatePreview(); }
function renumberSenses() { $$(".sense-card").forEach((card, index) => { $(".sense-order", card).value = index + 1; $(".sense-label", card).textContent = `義項 ${index + 1}`; }); }
function toast(message) { const box = $("#toast"); box.textContent = message; box.classList.remove("hidden"); window.clearTimeout(toast.timer); toast.timer = window.setTimeout(() => box.classList.add("hidden"), 4000); }

let searchTimer;
$("#search").addEventListener("input", (event) => { window.clearTimeout(searchTimer); searchTimer = window.setTimeout(() => loadEntries(event.target.value), 180); });
$("#entry-form").addEventListener("submit", saveDraft);
$("#validate").addEventListener("click", validateDraft);
$("#add-sense").addEventListener("click", () => {
  const index = $$(".sense-card").length + 1;
  $("#senses").append(renderSense({
    sense_id: `${state.entry.entry_id}-s${index}`, order: index, definition_ja_simple: "", usage_note_ja: "",
    register: "neutral", importance: index === 1 ? "primary" : "secondary", examples: [], relations: [],
    image_assets: [], audio_assets: [], source_ids: [...state.entry.source_ids], review_status: "draft",
  }));
  markDirty();
});

loadEntries();
