"use strict";

const STATUS_LABELS = {
  imported: "已匯入",
  draft: "草稿",
  ai_draft: "AI 草稿",
  needs_review: "待人工審核",
  reviewed: "已完成校閱",
  approved: "已核准",
  published: "已發佈",
  rejected: "已退回",
  deprecated: "已停止使用",
};
const STATUS_ACTIONS = {
  draft: "退回草稿",
  ai_draft: "改為 AI 草稿",
  needs_review: "送交人工審核",
  reviewed: "完成校閱",
  approved: "核准內容",
  published: "正式發佈",
  rejected: "退回修改",
  deprecated: "停止使用",
};
const FORM_TYPE_LABELS = {
  primary: "主要表記",
  alternate: "其他表記",
  kana: "假名表記",
  variant: "表記差異",
  rare: "少見表記",
};
const EDITORIAL_LABELS = { imported: "匯入資料", curated: "已人工整理", featured: "重點詞條" };
const IMPORTANCE_LABELS = { primary: "主要詞義", secondary: "次要詞義", rare: "少見詞義" };
const RELATION_LABELS = {
  synonym: "同義詞",
  near_synonym: "近義詞",
  antonym: "反義詞",
  hypernym: "上位詞",
  hyponym: "下位詞",
  easily_confused: "容易混淆的詞",
  related: "相關詞",
  orthographic_variant: "表記差異",
};
const AUDIO_TYPE_LABELS = { system_tts: "裝置語音", synthetic: "合成語音", human: "真人錄音" };
const REGISTER_LABELS = {
  neutral: "一般",
  formal: "正式",
  casual: "口語",
  literary: "書面",
  technical: "專業用語",
  archaic: "古語",
};
const PART_LABELS = {
  noun: "名詞",
  verb: "動詞",
  adjective: "形容詞",
  adverb: "副詞",
  particle: "助詞",
  counter: "量詞",
  expression: "慣用表現",
  prefix: "接頭詞",
  suffix: "接尾詞",
};

const state = {
  entry: null,
  revision: "",
  allowed: [],
  selectedId: "",
  dirty: false,
  sources: [],
};
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const clone = (value) => (
  typeof structuredClone === "function"
    ? structuredClone(value)
    : JSON.parse(JSON.stringify(value))
);

function labelFor(labels, value, fallback = "其他") {
  return labels[value] || fallback;
}

function node(tag, className = "", text = "") {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text) element.textContent = text;
  return element;
}

function control(labelText, className, value = "", options = {}) {
  const label = node("label", options.labelClass || "");
  label.append(node("span", "", labelText));
  let input;
  if (options.choices) {
    input = node("select", className);
    for (const choice of options.choices) {
      const item = typeof choice === "string" ? { value: choice, label: choice } : choice;
      const option = node("option", "", item.label);
      option.value = item.value;
      input.append(option);
    }
  } else if (options.multiline) {
    input = node("textarea", className);
  } else {
    input = node("input", className);
    input.type = options.type || "text";
  }
  input.value = value ?? "";
  if (options.readonly) {
    input.readOnly = true;
    input.setAttribute("aria-readonly", "true");
  }
  if (options.placeholder) input.placeholder = options.placeholder;
  if (options.autocomplete) input.autocomplete = options.autocomplete;
  label.append(input);
  return label;
}

function choices(labels) {
  return Object.entries(labels).map(([value, label]) => ({ value, label }));
}

function checkbox(labelText, className, checked, value = "") {
  const label = node("label", "checkbox-control");
  const input = node("input", className);
  input.type = "checkbox";
  input.checked = Boolean(checked);
  input.value = value;
  label.append(input, node("span", "", labelText));
  return label;
}

function removeButton(callback, label = "移除") {
  const button = node("button", "secondary danger remove", label);
  button.type = "button";
  button.addEventListener("click", callback);
  return button;
}

function splitList(value) {
  return value.split(",").map((item) => item.trim()).filter(Boolean);
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

async function loadSources() {
  const payload = await request("/api/sources");
  state.sources = payload.sources;
}

async function loadEntries(query = "") {
  try {
    const payload = await request(`/api/entries?q=${encodeURIComponent(query)}`);
    $("#connection").textContent = "本機工作副本";
    $("#result-count").textContent = `${payload.entries.length} 筆結果`;
    const list = $("#entry-list");
    list.replaceChildren();
    for (const item of payload.entries) {
      const button = node("button", `entry-button${item.entry_id === state.selectedId ? " active" : ""}`);
      button.type = "button";
      button.append(node("strong", "", item.headword));
      button.append(node("small", "", `${item.reading || "無主要讀音"} · ${labelFor(STATUS_LABELS, item.edit_status)}`));
      button.addEventListener("click", () => selectEntry(item.entry_id));
      list.append(button);
    }
  } catch (error) {
    $("#connection").textContent = "連線失敗";
    toast(humanApiMessage(error));
  }
}

async function selectEntry(entryId) {
  if (state.dirty && !window.confirm("目前有尚未儲存的內容，確定要離開這筆詞條嗎？")) return;
  try {
    const payload = await request(`/api/entries/${encodeURIComponent(entryId)}`);
    state.entry = payload.entry;
    state.revision = payload.revision;
    state.allowed = payload.allowed_transitions;
    state.selectedId = entryId;
    state.dirty = false;
    renderEditor();
    loadEntries($("#search").value);
  } catch (error) {
    toast(humanApiMessage(error));
  }
}

function renderEditor() {
  const entry = state.entry;
  $("#empty-state").classList.add("hidden");
  $("#entry-form").classList.remove("hidden");
  $("#entry-title").textContent = entry.headword;
  $("#status-badge").textContent = labelFor(STATUS_LABELS, entry.edit_status);
  $("#ai-warning").classList.toggle("hidden", entry.edit_status !== "ai_draft");

  $("#basic-fields").replaceChildren(control("詞目", "headword", entry.headword));
  renderParts(entry.parts_of_speech);
  renderForms(entry.forms);
  renderReadings(entry.readings);
  renderAdvanced(entry);

  const senses = $("#senses");
  senses.replaceChildren();
  entry.senses.forEach((sense) => senses.append(renderSense(sense)));
  renderSystemInfo(entry);
  renderTransitions();
  hideIssues();
  $("#save-state").textContent = "已載入最新版本";
  $("#entry-form").oninput = (event) => {
    if (event.target.closest(".workflow-panel")) return;
    markDirty();
  };
  updatePreview();
}

function sectionHeader(title, buttonText, callback) {
  const heading = node("div", "section-heading");
  heading.append(node("h4", "", title));
  const button = node("button", "secondary compact", buttonText);
  button.type = "button";
  button.addEventListener("click", callback);
  heading.append(button);
  return heading;
}

function renderParts(parts) {
  const section = $("#parts-section");
  const known = new Set(Object.keys(PART_LABELS));
  const options = node("div", "choice-grid parts-options");
  for (const [value, label] of Object.entries(PART_LABELS)) {
    options.append(checkbox(label, "part-option", parts.includes(value), value));
  }
  const unknown = parts.filter((part) => !known.has(part));
  section.replaceChildren(node("h4", "", "詞性"), options);
  section.dataset.unknownParts = JSON.stringify(unknown);
}

function renderForms(forms) {
  const section = $("#forms-section");
  const list = node("div", "repeat-list forms-list");
  section.replaceChildren(sectionHeader("表記", "＋ 新增表記", () => {
    list.append(formRow({ text: "", type: "alternate", common: false }));
    markDirty();
  }), list);
  forms.forEach((form) => list.append(formRow(form)));
}

function formRow(form) {
  const row = node("div", "repeat-row form-row");
  row.append(
    control("表記", "form-text", form.text),
    control("用途", "form-type", form.type, { choices: choices(FORM_TYPE_LABELS) }),
    checkbox("常用", "form-common", form.common),
    removeButton(() => { row.remove(); markDirty(); }),
  );
  return row;
}

function renderReadings(readings) {
  const section = $("#readings-section");
  const list = node("div", "repeat-list readings-list");
  section.replaceChildren(sectionHeader("讀音", "＋ 新增讀音", () => {
    list.append(readingRow({ kana: "", primary: false }));
    markDirty();
  }), list);
  readings.forEach((reading) => list.append(readingRow(reading)));
}

function readingRow(reading) {
  const row = node("div", "repeat-row reading-row");
  row.append(
    control("假名", "reading-kana", reading.kana),
    checkbox("主要讀音", "reading-primary", reading.primary),
    removeButton(() => { row.remove(); markDirty(); }),
  );
  return row;
}

function sourceChecklist(selected, className) {
  const wrapper = node("fieldset", `source-picker ${className}`);
  wrapper.dataset.originalSources = JSON.stringify(selected);
  wrapper.append(node("legend", "", "出典"));
  if (!state.sources.length) {
    wrapper.append(node("p", "muted", "目前無法載入出典名稱；既有出典會保持不變。"));
    return wrapper;
  }
  for (const source of state.sources) {
    const detail = `${source.title} · ${source.author} · ${source.license_spdx}`;
    wrapper.append(checkbox(detail, "source-option", selected.includes(source.source_id), source.source_id));
  }
  return wrapper;
}

function selectedSources(root) {
  const inputs = $$(".source-option", root);
  if (!inputs.length) return JSON.parse(root.dataset.originalSources || "[]");
  return inputs.filter((input) => input.checked).map((input) => input.value);
}

function sourceSelect(label, className, value) {
  const options = state.sources.map((source) => ({
    value: source.source_id,
    label: `${source.title}（${source.author}）`,
  }));
  if (!options.some((option) => option.value === value)) {
    options.unshift({ value, label: value ? "既有出典" : "請選擇出典" });
  }
  return control(label, className, value, { choices: options });
}

function renderAdvanced(entry) {
  const holder = $("#advanced-fields");
  const fields = node("div", "field-grid");
  fields.append(
    control("使用頻率排名", "frequency", entry.frequency_rank ?? "", { type: "number" }),
    control("編輯優先度", "editorial-level", entry.editorial_level, { choices: choices(EDITORIAL_LABELS) }),
  );
  const unknownParts = entry.parts_of_speech.filter((part) => !(part in PART_LABELS));
  fields.append(control("其他詞性代碼（逗號分隔）", "parts-unknown", unknownParts.join(", ")));
  holder.replaceChildren(fields, sourceChecklist(entry.source_ids, "entry-sources"));
}

function renderSense(sense) {
  const card = node("article", "sense-card");
  card.dataset.senseId = sense.sense_id || "";
  const heading = node("div", "sense-heading");
  const title = node("h4", "sense-label", `詞義 ${sense.order}`);
  const actions = node("div", "sense-actions");
  const up = node("button", "secondary compact", "上移");
  const down = node("button", "secondary compact", "下移");
  up.type = down.type = "button";
  up.addEventListener("click", () => moveSense(card, -1));
  down.addEventListener("click", () => moveSense(card, 1));
  actions.append(up, down, removeButton(() => {
    card.remove();
    renumberSenses();
    markDirty();
  }));
  heading.append(title, actions);
  card.append(heading);

  const registerKnown = sense.register in REGISTER_LABELS;
  const registerValue = registerKnown ? sense.register : "__custom__";
  const registerChoices = [...choices(REGISTER_LABELS), { value: "__custom__", label: "其他（於進階設定輸入）" }];
  const basics = node("div", "field-grid sense-basics");
  basics.append(
    control("詞義重要度", "sense-importance", sense.importance, { choices: choices(IMPORTANCE_LABELS) }),
    control("使用情境／語域", "sense-register", registerValue, { choices: registerChoices }),
    control("簡明日文定義", "sense-definition definition", sense.definition_ja_simple, { multiline: true }),
    control("使用說明", "sense-usage definition", sense.usage_note_ja, { multiline: true }),
  );
  card.append(basics);
  card.append(nestedExamples(sense));
  card.append(nestedRelations(sense.relations || []));

  const advanced = node("details", "nested disclosure sense-advanced");
  advanced.append(node("summary", "", "詞義進階設定"));
  advanced.append(
    control("自訂語域", "sense-register-custom", registerKnown ? "" : sense.register, {
      placeholder: "只有選擇「其他」時才使用",
    }),
    sourceChecklist(sense.source_ids, "sense-sources"),
    nestedAssets("圖片資料", "image-list", sense.image_assets || [], "image"),
    nestedAssets("音訊資料", "audio-list", sense.audio_assets || [], "audio"),
  );
  card.append(advanced);
  return card;
}

function moveSense(card, delta) {
  const sibling = delta < 0 ? card.previousElementSibling : card.nextElementSibling;
  if (!sibling) return;
  if (delta < 0) card.parentElement.insertBefore(card, sibling);
  else card.parentElement.insertBefore(sibling, card);
  renumberSenses();
  markDirty();
}

function nested(title, addText, className, add) {
  const wrapper = node("section", `nested ${className}-section`);
  const list = node("div", `repeat-list ${className}`);
  const heading = node("div", "section-heading");
  heading.append(node("h5", "", title));
  const button = node("button", "secondary compact", addText);
  button.type = "button";
  button.addEventListener("click", () => {
    list.append(add());
    markDirty();
  });
  heading.append(button);
  wrapper.append(heading, list);
  return { wrapper, list };
}

function nestedExamples(sense) {
  const defaultSource = sense.source_ids?.[0] || state.entry.source_ids[0] || "";
  const part = nested("例句", "＋ 新增例句", "examples-list", () => exampleRow({
    example_id: "",
    sentence: "",
    source_id: defaultSource,
    audio_asset_id: null,
  }));
  (sense.examples || []).forEach((example) => part.list.append(exampleRow(example)));
  return part.wrapper;
}

function exampleRow(example) {
  const row = node("div", "repeat-row example-row");
  row.dataset.exampleId = example.example_id || "";
  const detail = node("details", "row-details disclosure");
  detail.append(
    node("summary", "", "例句出典與音訊"),
    sourceSelect("出典", "example-source", example.source_id),
    control("連結的音訊識別碼", "example-audio", example.audio_asset_id || "", { readonly: true }),
  );
  row.append(
    control("日文例句", "example-sentence", example.sentence),
    detail,
    removeButton(() => { row.remove(); markDirty(); }),
  );
  return row;
}

function nestedRelations(relations) {
  const part = nested("關聯詞", "＋ 新增關聯", "relations-list", () => relationRow({
    entry_id: "",
    relation_type: "related",
    note_ja: "",
  }));
  relations.forEach((relation) => part.list.append(relationRow(relation)));
  return part.wrapper;
}

function relationRow(relation) {
  const row = node("div", "repeat-row relation-row");
  const picker = control("關聯詞目", "relation-query", "", {
    placeholder: "輸入詞目或讀音後選擇",
    autocomplete: "off",
  });
  const input = $(".relation-query", picker);
  input.dataset.entryId = relation.entry_id || "";
  input.setAttribute("role", "combobox");
  input.setAttribute("aria-autocomplete", "list");
  input.setAttribute("aria-expanded", "false");
  const suggestions = node("div", "relation-suggestions");
  suggestions.setAttribute("role", "listbox");
  let timer;
  input.addEventListener("input", () => {
    input.dataset.entryId = "";
    window.clearTimeout(timer);
    timer = window.setTimeout(() => searchRelation(input, suggestions), 180);
  });
  row.append(
    picker,
    control("關係", "relation-type", relation.relation_type, { choices: choices(RELATION_LABELS) }),
    control("差異說明", "relation-note", relation.note_ja),
    removeButton(() => { row.remove(); markDirty(); }),
    suggestions,
  );
  if (relation.entry_id) hydrateRelationLabel(input, relation.entry_id);
  return row;
}

async function hydrateRelationLabel(input, entryId) {
  input.value = "正在載入關聯詞目…";
  try {
    const payload = await request(`/api/entries?q=${encodeURIComponent(entryId)}`);
    const match = payload.entries.find((entry) => entry.entry_id === entryId);
    input.value = match ? referenceLabel(match) : "找不到既有關聯詞目";
  } catch {
    input.value = "無法載入既有關聯詞目";
  }
}

function referenceLabel(entry) {
  return entry.reading ? `${entry.headword}（${entry.reading}）` : entry.headword;
}

async function searchRelation(input, suggestions) {
  const query = input.value.trim();
  suggestions.replaceChildren();
  input.setAttribute("aria-expanded", "false");
  if (!query) return;
  try {
    const payload = await request(`/api/entries?q=${encodeURIComponent(query)}`);
    for (const entry of payload.entries.slice(0, 8)) {
      if (entry.entry_id === state.selectedId) continue;
      const option = node("button", "relation-option", referenceLabel(entry));
      option.type = "button";
      option.setAttribute("role", "option");
      option.addEventListener("click", () => {
        input.value = referenceLabel(entry);
        input.dataset.entryId = entry.entry_id;
        suggestions.replaceChildren();
        input.setAttribute("aria-expanded", "false");
        markDirty();
      });
      suggestions.append(option);
    }
    input.setAttribute("aria-expanded", suggestions.childElementCount ? "true" : "false");
  } catch {
    suggestions.append(node("p", "muted", "無法搜尋關聯詞目"));
  }
}

function nestedAssets(title, className, assets, kind) {
  const blank = {
    asset_id: "",
    source_id: state.entry.source_ids[0] || "",
    license_spdx: "",
    redistribution_allowed: false,
    sha256: "",
    path: "",
    kind,
    audio_type: "system_tts",
  };
  const part = nested(title, "＋ 新增媒體", className, () => assetRow(blank, kind));
  assets.forEach((asset) => part.list.append(assetRow(asset, kind)));
  return part.wrapper;
}

function assetRow(asset, kind) {
  const row = node("div", "repeat-row asset-row");
  row.dataset.assetId = asset.asset_id || "";
  row.append(
    sourceSelect("出典", "asset-source", asset.source_id),
    control("SPDX 授權代碼", "asset-license", asset.license_spdx),
    control("SHA-256 雜湊", "asset-hash", asset.sha256),
    control("相對資產路徑", "asset-path", asset.path || ""),
    checkbox("允許再散布", "asset-redistribution", asset.redistribution_allowed),
  );
  if (kind === "audio") {
    row.append(control("音訊類型", "asset-audio-type", asset.audio_type || "system_tts", {
      choices: choices(AUDIO_TYPE_LABELS),
    }));
  }
  row.append(removeButton(() => { row.remove(); markDirty(); }));
  return row;
}

function collectEditableValues() {
  const knownParts = $$(".part-option").filter((input) => input.checked).map((input) => input.value);
  const entrySources = selectedSources($(".entry-sources"));
  return {
    headword: $(".headword").value.trim(),
    parts_of_speech: [...knownParts, ...splitList($(".parts-unknown").value)],
    frequency_rank: $(".frequency").value ? Number($(".frequency").value) : null,
    editorial_level: $(".editorial-level").value,
    source_ids: entrySources,
    forms: $$(".form-row").map((row) => ({
      text: $(".form-text", row).value.trim(),
      type: $(".form-type", row).value,
      common: $(".form-common", row).checked,
    })),
    readings: $$(".reading-row").map((row) => ({
      kana: $(".reading-kana", row).value.trim(),
      primary: $(".reading-primary", row).checked,
    })),
    senses: $$(".sense-card").map((card) => collectSenseValues(card)),
  };
}

function collectSenseValues(card) {
  const registerChoice = $(".sense-register", card).value;
  const customRegister = $(".sense-register-custom", card).value.trim();
  return {
    sense_id: card.dataset.senseId || "",
    definition_ja_simple: $(".sense-definition", card).value.trim(),
    usage_note_ja: $(".sense-usage", card).value,
    register: registerChoice === "__custom__" ? customRegister : registerChoice,
    importance: $(".sense-importance", card).value,
    examples: $$(".example-row", card).map((row) => ({
      example_id: row.dataset.exampleId || "",
      sentence: $(".example-sentence", row).value.trim(),
      source_id: $(".example-source", row).value,
      audio_asset_id: $(".example-audio", row).value || null,
    })),
    relations: $$(".relation-row", card).map((row) => ({
      entry_id: $(".relation-query", row).dataset.entryId || "",
      relation_type: $(".relation-type", row).value,
      note_ja: $(".relation-note", row).value,
    })),
    image_assets: collectAssets(card, ".image-list", "image"),
    audio_assets: collectAssets(card, ".audio-list", "audio"),
    source_ids: selectedSources($(".sense-sources", card)),
  };
}

function collectAssets(card, listSelector, kind) {
  return $$(`${listSelector} .asset-row`, card).map((row) => {
    const asset = {
      asset_id: row.dataset.assetId || "",
      source_id: $(".asset-source", row).value,
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

function mergeEditableEntry(original, values) {
  const draft = clone(original);
  for (const key of (
    ["headword", "parts_of_speech", "frequency_rank", "editorial_level", "source_ids", "forms", "readings"]
  )) {
    draft[key] = clone(values[key]);
  }
  const originalSenses = new Map(original.senses.map((sense) => [sense.sense_id, sense]));
  draft.senses = values.senses.map((valuesSense, index) => {
    const prior = originalSenses.get(valuesSense.sense_id);
    const sense = prior ? clone(prior) : {
      sense_id: "",
      order: index + 1,
      definition_ja_simple: "",
      usage_note_ja: "",
      register: "neutral",
      importance: "secondary",
      examples: [],
      relations: [],
      image_assets: [],
      audio_assets: [],
      source_ids: clone(original.source_ids),
      review_status: original.edit_status,
    };
    const originalExamples = new Map((prior?.examples || []).map((item) => [item.example_id, item]));
    const originalAssets = new Map(
      [...(prior?.image_assets || []), ...(prior?.audio_assets || [])].map((item) => [item.asset_id, item]),
    );
    for (const key of ["definition_ja_simple", "usage_note_ja", "register", "importance", "relations", "source_ids"]) {
      sense[key] = clone(valuesSense[key]);
    }
    sense.order = index + 1;
    sense.examples = valuesSense.examples.map((item) => ({
      ...(originalExamples.has(item.example_id) ? clone(originalExamples.get(item.example_id)) : { example_id: "" }),
      sentence: item.sentence,
      source_id: item.source_id,
      audio_asset_id: item.audio_asset_id,
    }));
    for (const field of ["image_assets", "audio_assets"]) {
      sense[field] = valuesSense[field].map((item) => ({
        ...(originalAssets.has(item.asset_id) ? clone(originalAssets.get(item.asset_id)) : { asset_id: "" }),
        ...clone(item),
      }));
    }
    return sense;
  });
  return draft;
}

function collectDraft() {
  return mergeEditableEntry(state.entry, collectEditableValues());
}

function updatePreview() {
  if (!state.entry) return;
  const draft = collectDraft();
  const preview = $("#preview");
  preview.replaceChildren();
  preview.append(node("p", "preview-meta", draft.parts_of_speech.map((part) => labelFor(PART_LABELS, part)).join(" · ")));
  preview.append(node("h3", "preview-headword", draft.headword || "—"));
  preview.append(node("p", "preview-reading", draft.readings.find((item) => item.primary)?.kana || draft.readings[0]?.kana || ""));
  preview.append(node("p", "preview-meta", `頻率 ${draft.frequency_rank ?? "—"} · ${labelFor(EDITORIAL_LABELS, draft.editorial_level)}`));
  draft.senses.forEach((sense, index) => {
    const block = node("section", "preview-sense");
    block.append(node("h4", "", `詞義 ${index + 1} · ${labelFor(REGISTER_LABELS, sense.register)} · ${labelFor(IMPORTANCE_LABELS, sense.importance)}`));
    block.append(node("p", "", sense.definition_ja_simple || "尚未填寫定義"));
    if (sense.usage_note_ja) block.append(node("p", "preview-meta", sense.usage_note_ja));
    if (sense.examples[0]?.sentence) block.append(node("p", "preview-example", sense.examples[0].sentence));
    preview.append(block);
  });
  $("#entry-title").textContent = draft.headword || state.entry.headword;
}

function renderSystemInfo(entry) {
  const info = node("dl", "system-grid");
  const add = (term, value) => {
    info.append(node("dt", "", term), node("dd", "", value ?? "—"));
  };
  add("詞條識別碼", entry.entry_id);
  add("原始狀態代碼", entry.edit_status);
  add("資料版本", entry.data_version);
  add("建立時間", entry.created_at);
  add("更新時間", entry.updated_at);
  add("審核者", entry.review?.reviewed_by);
  add("審核時間", entry.review?.reviewed_at);
  const child = node("div", "system-children");
  child.append(node("h4", "", "子項目識別碼"));
  entry.senses.forEach((sense, index) => {
    const values = [
      `詞義 ${index + 1}: ${sense.sense_id}`,
      ...sense.examples.map((example, i) => `例句 ${i + 1}: ${example.example_id}`),
      ...sense.image_assets.map((asset, i) => `圖片 ${i + 1}: ${asset.asset_id}`),
      ...sense.audio_assets.map((asset, i) => `音訊 ${i + 1}: ${asset.asset_id}`),
    ];
    values.forEach((value) => child.append(node("code", "", value)));
  });
  $("#system-info").replaceChildren(info, child);
}

function renderTransitions() {
  const holder = $("#transition-buttons");
  holder.replaceChildren();
  const needsReviewer = state.allowed.some((status) => ["reviewed", "approved", "published"].includes(status));
  $("#reviewer-label").classList.toggle("hidden", !needsReviewer);
  if (!state.allowed.length) holder.append(node("span", "muted", "目前沒有可用的審核動作"));
  for (const status of state.allowed) {
    const button = node("button", "secondary", STATUS_ACTIONS[status] || "變更狀態");
    button.type = "button";
    button.addEventListener("click", () => runTransition(status));
    holder.append(button);
  }
}

async function runTransition(status) {
  if (state.dirty) {
    toast("請先儲存或重新載入目前內容，再執行審核動作");
    return;
  }
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
    state.entry = payload.entry;
    state.revision = payload.revision;
    state.allowed = payload.allowed_transitions;
    state.dirty = false;
    renderEditor();
    loadEntries($("#search").value);
    toast(`已完成：${STATUS_ACTIONS[status] || labelFor(STATUS_LABELS, status)}`);
  } catch (error) {
    showApiError(error);
  }
}

async function validateDraft() {
  try {
    const payload = await request(`/api/entries/${encodeURIComponent(state.selectedId)}/validate`, {
      method: "POST",
      body: JSON.stringify({ entry: collectDraft() }),
    });
    showIssues(payload.issues);
    toast(payload.valid ? "資料驗證通過" : `發現 ${payload.issues.length} 個需要處理的問題`);
  } catch (error) {
    showApiError(error);
  }
}

async function saveDraft(event) {
  event.preventDefault();
  try {
    const payload = await request(`/api/entries/${encodeURIComponent(state.selectedId)}`, {
      method: "PUT",
      body: JSON.stringify({ entry: collectDraft(), base_revision: state.revision }),
    });
    state.entry = payload.entry;
    state.revision = payload.revision;
    state.allowed = payload.allowed_transitions;
    state.dirty = false;
    renderEditor();
    loadEntries($("#search").value);
    toast("已安全儲存至本機工作副本");
  } catch (error) {
    showApiError(error);
  }
}

function humanApiMessage(error) {
  const code = error.payload?.error?.code;
  if (code === "revision_conflict") return "這筆資料已被更新，請重新選取詞條後再編輯。";
  if (code === "workflow_error") return "此審核動作不符合目前流程，內容未被變更。";
  if (code === "validation_failed") return "資料尚有未通過驗證的欄位。";
  if (code === "not_found") return "找不到指定的詞條。";
  if (code === "bad_request") return "送出的資料格式不正確，內容未被變更。";
  return "操作失敗，請稍後重試。";
}

function showApiError(error) {
  if (error.payload?.issues) showIssues(error.payload.issues);
  toast(humanApiMessage(error));
}

const FIELD_LABELS = {
  headword: "詞目",
  parts_of_speech: "詞性",
  forms: "表記",
  readings: "讀音",
  senses: "詞義",
  definition_ja_simple: "簡明日文定義",
  usage_note_ja: "使用說明",
  register: "使用情境／語域",
  importance: "詞義重要度",
  examples: "例句",
  sentence: "日文例句",
  source_ids: "出典",
  source_id: "出典",
  relations: "關聯詞",
  entry_id: "關聯詞目",
  relation_type: "關係",
  sha256: "SHA-256 雜湊",
  path: "資產路徑",
  license_spdx: "媒體授權",
};

function issueLocation(issue) {
  const senseMatch = issue.path.match(/\.senses\[(\d+)\]/);
  const exampleMatch = issue.path.match(/\.examples\[(\d+)\]/);
  const field = Object.keys(FIELD_LABELS).find((key) => issue.path.endsWith(`.${key}`))
    || Object.keys(FIELD_LABELS).find((key) => issue.path.includes(`.${key}`))
    || "";
  const parts = [];
  if (senseMatch) parts.push(`詞義 ${Number(senseMatch[1]) + 1}`);
  if (exampleMatch) parts.push(`例句 ${Number(exampleMatch[1]) + 1}`);
  parts.push(FIELD_LABELS[field] || "這筆資料");
  return parts.join("的");
}

function friendlyIssue(issue) {
  const location = issueLocation(issue);
  if (["required", "required_string", "min_length", "min_items"].includes(issue.code)) {
    return `請完整填寫${location}。`;
  }
  if (issue.code === "primary_form") return "請指定且只指定一個主要表記。";
  if (issue.code === "primary_example") return "主要詞義至少需要一個例句。";
  if (issue.code === "unknown_source" || issue.code === "missing_source") return `${location}必須選擇有效的出典。`;
  if (issue.code === "unknown_entry") return "請從搜尋結果選擇有效的關聯詞目。";
  if (issue.code.startsWith("duplicate")) return `${location}與其他項目重複。`;
  if (["pattern", "checksum", "unsafe_asset_path"].includes(issue.code)) return `${location}的格式不正確。`;
  if (issue.code === "review_evidence" || issue.code === "ai_review_gate") return "此內容仍缺少必要的人工審核證據。";
  return `請檢查${location}。`;
}

function issueTarget(path) {
  const senseMatch = path.match(/\.senses\[(\d+)\]/);
  const exampleMatch = path.match(/\.examples\[(\d+)\]/);
  let root = document;
  if (senseMatch) root = $$(".sense-card")[Number(senseMatch[1])] || document;
  if (exampleMatch && root !== document) root = $$(".example-row", root)[Number(exampleMatch[1])] || root;
  const mappings = {
    headword: ".headword",
    parts_of_speech: ".part-option",
    forms: ".form-text",
    readings: ".reading-kana",
    definition_ja_simple: ".sense-definition",
    usage_note_ja: ".sense-usage",
    register: ".sense-register",
    importance: ".sense-importance",
    sentence: ".example-sentence",
    source_id: ".example-source",
    entry_id: ".relation-query",
    relation_type: ".relation-type",
    sha256: ".asset-hash",
    path: ".asset-path",
    license_spdx: ".asset-license",
  };
  const key = Object.keys(mappings).find((name) => path.endsWith(`.${name}`))
    || Object.keys(mappings).find((name) => path.includes(`.${name}`));
  return key ? $(mappings[key], root) : null;
}

function showIssues(issues) {
  const panel = $("#issues-panel");
  const list = $("#issues");
  list.replaceChildren();
  const errors = issues.filter((issue) => issue.severity !== "warning").length;
  const warnings = issues.length - errors;
  $("#issue-summary").textContent = issues.length ? `${errors} 個錯誤 · ${warnings} 個提醒` : "全部通過";
  if (!issues.length) list.append(node("li", "issue-pass", "全部驗證通過"));
  for (const issue of issues) {
    const item = node("li", `issue-item ${issue.severity || "error"}`);
    const link = node("button", "issue-link", friendlyIssue(issue));
    link.type = "button";
    const target = issueTarget(issue.path);
    link.disabled = !target;
    link.addEventListener("click", () => {
      target?.closest("details")?.setAttribute("open", "");
      target?.focus();
    });
    const technical = node("details", "technical-issue");
    technical.append(node("summary", "", "技術資訊"));
    const code = node("code", "");
    code.textContent = `${issue.path} · ${issue.code} · ${issue.message}`;
    technical.append(code);
    item.append(link, technical);
    list.append(item);
  }
  panel.classList.remove("hidden");
}

function hideIssues() {
  $("#issues-panel").classList.add("hidden");
  $("#issues").replaceChildren();
  $("#issue-summary").textContent = "";
}

function markDirty() {
  state.dirty = true;
  $("#save-state").textContent = "有尚未儲存的變更";
  updatePreview();
}

function renumberSenses() {
  $$(".sense-card").forEach((card, index) => {
    $(".sense-label", card).textContent = `詞義 ${index + 1}`;
  });
}

function toast(message) {
  const box = $("#toast");
  box.textContent = message;
  box.classList.remove("hidden");
  window.clearTimeout(toast.timer);
  toast.timer = window.setTimeout(() => box.classList.add("hidden"), 4000);
}

function bindEditor() {
  let searchTimer;
  $("#search").addEventListener("input", (event) => {
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(() => loadEntries(event.target.value), 180);
  });
  $("#entry-form").addEventListener("submit", saveDraft);
  $("#validate").addEventListener("click", validateDraft);
  $("#add-sense").addEventListener("click", () => {
    const index = $$(".sense-card").length + 1;
    $("#senses").append(renderSense({
      sense_id: "",
      order: index,
      definition_ja_simple: "",
      usage_note_ja: "",
      register: "neutral",
      importance: index === 1 ? "primary" : "secondary",
      examples: [],
      relations: [],
      image_assets: [],
      audio_assets: [],
      source_ids: [...state.entry.source_ids],
      review_status: state.entry.edit_status,
    }));
    markDirty();
  });
}

async function initialize() {
  bindEditor();
  try {
    await loadSources();
  } catch (error) {
    state.sources = [];
    toast(humanApiMessage(error));
  }
  await loadEntries();
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    STATUS_LABELS,
    FORM_TYPE_LABELS,
    RELATION_LABELS,
    labelFor,
    mergeEditableEntry,
  };
}

if (typeof document !== "undefined") initialize();
