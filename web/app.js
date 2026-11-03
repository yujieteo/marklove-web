// src/core.ts
import createModule from "./marklove.mjs";

// src/dom.ts
function must(value, what) {
  if (value === null || value === undefined)
    throw new Error("Missing " + what);
  return value;
}
function byId(id, kind) {
  const el = document.getElementById(id);
  if (!(el instanceof kind))
    throw new Error("Missing element #" + id + " of type " + kind.name);
  return el;
}
function query(root, selector, kind) {
  const el = root.querySelector(selector);
  if (!(el instanceof kind))
    throw new Error("Missing element " + selector + " of type " + kind.name);
  return el;
}
function queryAll(root, selector, kind) {
  return [...root.querySelectorAll(selector)].filter((el) => el instanceof kind);
}
function isRecord(v) {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// src/core.ts
var encoder = new TextEncoder;
var decoder = new TextDecoder;
var O_TAKAHASHI = 1;
var O_TOC = 2;
var O_NARRATION = 4;
var O_PUBLIC_NOTES = 8;
var PAGE_SLIDES = 0;
var PAGE_ARTICLE = 1;
var TEXT_ARTICLE_MD = 0;
var TEXT_REVISED_MD = 1;
var TEXT_NARRATION = 2;
var TEXT_TRANSCRIPT = 3;
var TEXT_VTT = 4;
var TEXT_SRT = 5;
var LIST_LISTENER_MD = 0;
var LIST_PUBLIC_ASSETS = 1;
var LIST_PRIVATE_ASSETS = 2;
var LIST_REVISION_PROMPT = 3;
var MAX_SOURCE_BYTES = 512 * 1024;

class TooLarge extends Error {
}
function field(o, key) {
  return o[key];
}
function asRecord(v, what) {
  if (!isRecord(v))
    throw new Error("The core gave no object for " + what);
  return v;
}
function asString(v, what) {
  if (typeof v !== "string")
    throw new Error("The core gave no string for " + what);
  return v;
}
function asNumber(v, what) {
  if (typeof v !== "number")
    throw new Error("The core gave no number for " + what);
  return v;
}
function asBool(v, what) {
  if (typeof v !== "boolean")
    throw new Error("The core gave no boolean for " + what);
  return v;
}
function asArray(v, what) {
  if (!Array.isArray(v))
    throw new Error("The core gave no array for " + what);
  return v;
}
function asStrings(v, what) {
  return asArray(v, what).map((x) => asString(x, what));
}
function asSpan(v, what) {
  const a = asArray(v, what);
  return [asNumber(a[0], what), asNumber(a[1], what)];
}
function strField(o, key) {
  return asString(field(o, key), key);
}
function numField(o, key) {
  return asNumber(field(o, key), key);
}
function boolField(o, key) {
  return asBool(field(o, key), key);
}
function stringMap(v, what) {
  const out = {};
  for (const [k, x] of Object.entries(asRecord(v, what)))
    out[k] = asString(x, what);
  return out;
}
function parseJSON(s) {
  return JSON.parse(s);
}
var M = null;
var lenPtr = 0;
function mod() {
  return must(M, "loaded core. Call load() first");
}
function exportOf(m, name) {
  const key = `_${name}`;
  return must(m[key], "core export " + name);
}
async function load() {
  if (M)
    return;
  M = await createModule();
  M._goose_init(0, 0);
  lenPtr = M._malloc(8);
}
function put(inputs, m) {
  const all = inputs.map((v) => {
    if (typeof v !== "string")
      return v;
    const b = encoder.encode(v);
    if (b.length > MAX_SOURCE_BYTES)
      throw new TooLarge("The text is larger than 512 KB.");
    return b;
  });
  all.forEach((b, i) => {
    const p = m._ml_in_alloc(i, b.length);
    m.HEAPU8.set(b, p);
  });
}
function readLength(m, len) {
  return Number(must(new BigInt64Array(m.HEAPU8.buffer, len, 1)[0], "result length"));
}
function result(m, p, len) {
  const n = readLength(m, len);
  return m.HEAPU8.slice(p, p + n);
}
function callBytes(m, len, name, inputs, ints) {
  put(inputs, m);
  return result(m, exportOf(m, name)(...ints, len), len);
}
function bytes(name, inputs, ...ints) {
  return callBytes(mod(), lenPtr, name, inputs, ints);
}
async function instance(hooks) {
  const m = await createModule(hooks);
  m._goose_init(0, 0);
  const len = m._malloc(8);
  return (name, inputs, ...ints) => callBytes(m, len, name, inputs, ints);
}
var text = (name, inputs, ...ints) => decoder.decode(bytes(name, inputs, ...ints));
var json = (name, inputs, ...ints) => parseJSON(text(name, inputs, ...ints));
function plain(name, inputs, ...ints) {
  const m = mod();
  put(inputs, m);
  return exportOf(m, name)(...ints);
}
function docArgs(d) {
  if (encoder.encode(d.source).length > MAX_SOURCE_BYTES)
    throw new TooLarge("The Markdown file is larger than 512 KB. Split it into more projects.");
  const assets = Object.entries(d.assets || {}).map(([k, v]) => k + "\t" + v + `
`).join("");
  const part = (t) => encoder.encode(t || "");
  return [d.source, assets, part(d.fonts), part(d.style), part(d.script), d.appearance || ""];
}
var meta = (source, key) => text("ml_meta", [...docArgs({ source }), key]);
var page = (d, kind, opts) => text("ml_page", docArgs(d), kind, opts);
var textOutput = (d, kind, opts) => text("ml_text", docArgs(d), kind, opts);
function parseOutline(v) {
  return asArray(v, "outline").map((x) => {
    const o = asRecord(x, "outline entry");
    return {
      id: strField(o, "id"),
      frame: numField(o, "frame"),
      kind: numField(o, "kind"),
      s0: numField(o, "s0"),
      s1: numField(o, "s1"),
      steps: numField(o, "steps"),
      notes: strField(o, "notes")
    };
  });
}
var outline = (d, opts) => parseOutline(json("ml_outline", docArgs(d), opts));
function parseLint(v) {
  return asArray(v, "lint").map((x) => {
    const o = asRecord(x, "lint issue");
    const issue = {
      code: strField(o, "code"),
      severity: strField(o, "severity"),
      message: strField(o, "message"),
      detail: strField(o, "detail"),
      start: numField(o, "start"),
      end: numField(o, "end"),
      formats: asStrings(field(o, "formats"), "formats")
    };
    const style = field(o, "style");
    if (typeof style === "string")
      issue.style = style;
    return issue;
  });
}
var lint = (source, assets) => parseLint(json("ml_lint", docArgs({ source, assets })));
var epub = (d, date, opts) => text("ml_epub", docArgs(d), date, opts).split(`
`).filter(Boolean);
function listener(source, kind) {
  const t = text("ml_listener", docArgs({ source }), kind);
  return kind === LIST_PUBLIC_ASSETS || kind === LIST_PRIVATE_ASSETS ? asStrings(parseJSON(t), "listener assets") : t;
}
var authoringPrompt = (draft) => text("ml_authoring_prompt", [draft]);
function tour() {
  const o = asRecord(json("ml_tour", []), "tour");
  return { name: strField(o, "name"), markdown: strField(o, "markdown"), assets: stringMap(field(o, "assets"), "tour assets") };
}
function mathAt(t, offset) {
  const v = json("ml_math_at", [t], offset);
  if (v === null)
    return null;
  const o = asRecord(v, "math");
  return { latex: strField(o, "latex"), display: boolField(o, "display"), start: numField(o, "start"), end: numField(o, "end") };
}
var mathSpeech = (latex) => text("ml_math_speech", [latex]);
var math = (latex, display) => text("ml_math", [latex], display ? 1 : 0);
var mathCheck = (latex) => text("ml_math_check", [latex]);
function parseColors(v, what) {
  const o = asRecord(v, what);
  return {
    name: strField(o, "name"),
    isDark: boolField(o, "isDark"),
    background: strField(o, "background"),
    surface: strField(o, "surface"),
    border: strField(o, "border"),
    dim: strField(o, "dim"),
    text: strField(o, "text"),
    strong: strField(o, "strong"),
    accent: strField(o, "accent"),
    red: strField(o, "red"),
    green: strField(o, "green"),
    yellow: strField(o, "yellow"),
    blue: strField(o, "blue"),
    magenta: strField(o, "magenta"),
    cyan: strField(o, "cyan"),
    orange: strField(o, "orange"),
    violet: strField(o, "violet"),
    series: asStrings(field(o, "series"), "series")
  };
}
function themes() {
  return asArray(json("ml_theme_list", []), "themes").map((x) => {
    const o = asRecord(x, "theme");
    return {
      id: strField(o, "id"),
      name: strField(o, "name"),
      credit: strField(o, "credit"),
      darkOnly: boolField(o, "darkOnly"),
      light: parseColors(field(o, "light"), "light"),
      dark: parseColors(field(o, "dark"), "dark")
    };
  });
}
function themeResolve(theme, accent) {
  const o = asRecord(json("ml_theme_resolve", [theme, accent]), "theme choice");
  const prefers = field(o, "prefersDark");
  return {
    id: strField(o, "id"),
    name: strField(o, "name"),
    darkOnly: boolField(o, "darkOnly"),
    prefersDark: prefers === null ? null : asBool(prefers, "prefersDark")
  };
}
function themePalette(theme, accent, dark, moreContrast) {
  const v = json("ml_theme_palette", [theme, accent], dark ? 1 : 0, moreContrast ? 1 : 0);
  return { ...parseColors(v, "palette"), roles: stringMap(field(asRecord(v, "palette"), "roles"), "roles") };
}
function typography() {
  const all = asRecord(json("ml_typography", []), "typography");
  const o = asRecord(field(all, "editor"), "editor typography");
  return {
    ...all,
    editor: {
      font: strField(o, "font"),
      pointSize: numField(o, "pointSize"),
      pointSizeIOS: numField(o, "pointSizeIOS"),
      lineHeight: numField(o, "lineHeight"),
      maxLineCharacters: numField(o, "maxLineCharacters"),
      bold: asStrings(field(o, "bold"), "bold"),
      italic: asStrings(field(o, "italic"), "italic")
    }
  };
}
function highlightMarkdown(source) {
  return asArray(json("ml_highlight_md", [source]), "highlight").map((x) => {
    const a = asArray(x, "highlight span");
    return [asNumber(a[0], "start"), asNumber(a[1], "end"), asString(a[2], "role")];
  });
}
var SYNTAX = { sam: 0, plain: 1, vim: 2 };
function failure(o) {
  const e = field(o, "error");
  return typeof e === "string" ? { error: e } : null;
}
function find(t, pattern, syntax, ignoreCase) {
  const o = asRecord(json("ml_find", [t, pattern], SYNTAX[syntax], ignoreCase ? 1 : 0), "find");
  return failure(o) ?? { matches: asArray(field(o, "matches"), "matches").map((x) => asSpan(x, "match")) };
}
function replace(t, pattern, replacement, syntax, ignoreCase, selS, selE, all) {
  const o = asRecord(json("ml_replace", [t, pattern, replacement], SYNTAX[syntax], ignoreCase ? 1 : 0, selS, selE, all ? 1 : 0), "replace");
  const bad = failure(o);
  if (bad)
    return bad;
  const replaced = { count: numField(o, "count") };
  const body = field(o, "text");
  if (typeof body === "string")
    replaced.text = body;
  const sel = field(o, "selection");
  if (sel !== undefined)
    replaced.selection = asSpan(sel, "selection");
  return replaced;
}
function sam(command, t, selS, selE, ignoreCase) {
  const o = asRecord(json("ml_sam", [command, t], selS, selE, ignoreCase ? 1 : 0), "sam");
  const bad = failure(o);
  if (bad)
    return bad;
  const body = field(o, "text");
  return {
    text: body === null ? null : asString(body, "text"),
    selection: asSpan(field(o, "selection"), "selection"),
    printed: asStrings(field(o, "printed"), "printed"),
    summary: strField(o, "summary")
  };
}
function asDiffOp(v) {
  if (v === "same" || v === "add" || v === "remove")
    return v;
  throw new Error("The core gave an unknown diff operation");
}
function diff(a, b) {
  return asArray(json("ml_diff", [a, b]), "diff").map((x) => {
    const o = asRecord(x, "diff line");
    const line = { op: asDiffOp(field(o, "op")), text: strField(o, "text") };
    const old = field(o, "old");
    const created = field(o, "new");
    if (typeof old === "number")
      line.old = old;
    if (typeof created === "number")
      line.new = created;
    return line;
  });
}
var commitMessage = (a, b) => text("ml_commit_message", [a, b]);
var vimReset = () => plain("ml_vim_reset", []);
var vimClipboard = (t) => plain("ml_vim_clipboard", [t]);
function asVimMode(v) {
  if (v === "normal" || v === "insert" || v === "visual" || v === "visual-line" || v === "command")
    return v;
  throw new Error("The core gave an unknown Vim mode");
}
function asVimAction(v) {
  if (v === "" || v === "save" || v === "discard" || v === "copy")
    return v;
  throw new Error("The core gave an unknown Vim action");
}
function vimKey(t, selS, selE, key) {
  const o = asRecord(json("ml_vim_key", [t, key], selS, selE), "vim key");
  const body = field(o, "text");
  const r = {
    handled: boolField(o, "handled"),
    text: body === null ? null : asString(body, "text"),
    cursor: numField(o, "cursor"),
    sel: asSpan(field(o, "sel"), "sel"),
    mode: asVimMode(field(o, "mode")),
    status: strField(o, "status"),
    action: asVimAction(field(o, "action"))
  };
  const clip = field(o, "clip");
  if (typeof clip === "string")
    r.clip = clip;
  return r;
}
var zipBegin = () => plain("ml_zip_begin", []);
var zipAdd = (name, data, mtime) => plain("ml_zip_add", [name, data], mtime);
var zipTake = () => bytes("ml_zip_take", []);
var zipFinish = () => bytes("ml_zip_finish", []);
var CHUNK = 1 << 20;
async function crc32(blob) {
  let crc = 0;
  for (let i = 0;i < blob.size; i += CHUNK) {
    const part = new Uint8Array(await blob.slice(i, i + CHUNK).arrayBuffer());
    crc = plain("ml_crc32", [part], crc);
  }
  return crc;
}
async function zipAddBlob(name, blob, mtime) {
  const crc = await crc32(blob);
  const head = bytes("ml_zip_add_ref", [name], blob.size, crc, mtime);
  return head.length ? [head, blob] : null;
}
function parsePackAsset(v) {
  const o = asRecord(v, "pack asset");
  return {
    path: strField(o, "path"),
    method: numField(o, "method"),
    offset: numField(o, "offset"),
    csize: numField(o, "csize"),
    usize: numField(o, "usize"),
    crc: numField(o, "crc")
  };
}
var DEFLATE_METHOD = 8;
async function packImport(zipBlob) {
  const m = mod();
  const z = new Uint8Array(await zipBlob.arrayBuffer());
  const p = m._ml_in_alloc(0, z.length);
  m.HEAPU8.set(z, p);
  const r = m._ml_pack_import_arg(lenPtr);
  const n = readLength(m, lenPtr);
  const raw = asRecord(parseJSON(decoder.decode(m.HEAPU8.slice(r, r + n))), "pack");
  m._ml_in_alloc(0, 0);
  const bad = failure(raw);
  if (bad)
    return bad;
  const warnings = asStrings(field(raw, "warnings"), "warnings");
  const assets = {};
  for (const a of asArray(field(raw, "assets"), "assets").map(parsePackAsset)) {
    let data = zipBlob.slice(a.offset, a.offset + a.csize);
    if (a.method === DEFLATE_METHOD)
      data = await new Response(data.stream().pipeThrough(new DecompressionStream("deflate-raw"))).blob();
    if (data.size !== a.usize || await crc32(data) >>> 0 !== a.crc >>> 0) {
      warnings.push("Skipped " + a.path + ": the file is damaged.");
      continue;
    }
    assets[a.path] = data;
  }
  return { markdownName: strField(raw, "markdownName"), markdown: strField(raw, "markdown"), assets, warnings };
}
var gitBegin = (name, email, mtime) => plain("ml_git_begin", [name, email], mtime);
var gitFile = (path, data) => plain("ml_git_file", [path, data]) !== 0;
var gitCommit = (message, time, tzMinutes) => text("ml_git_commit", [message], time, tzMinutes);
var gitFinish = (mtime) => plain("ml_git_finish", [], mtime);
async function gitFileBlob(path, blob, mtime, seen) {
  const head = encoder.encode("blob " + blob.size + "\x00");
  const raw = new Blob([head, blob]);
  const sha = [...new Uint8Array(await crypto.subtle.digest("SHA-1", await raw.arrayBuffer()))].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (plain("ml_git_file_ref", [path, sha], blob.size) === 0)
    return null;
  if (seen.has(sha))
    return null;
  seen.add(sha);
  const z = await new Response(raw.stream().pipeThrough(new CompressionStream("deflate"))).blob();
  return zipAddBlob(".git/objects/" + sha.slice(0, 2) + "/" + sha.slice(2), z, mtime);
}
function utf8Offset(s, u16) {
  return encoder.encode(s.slice(0, u16)).length;
}
function utf16Offset(s, u8) {
  const b = encoder.encode(s);
  return decoder.decode(b.subarray(0, u8)).length;
}

// src/store.ts
var DB_NAME = "marklove";
var DB_VERSION = 1;
var SETTINGS_KEY = "marklove.settings";
var EDITOR_STATE_KEY = "marklove.editorState";
var db = null;
function req(r) {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
async function open() {
  if (db)
    return;
  const r = indexedDB.open(DB_NAME, DB_VERSION);
  r.onupgradeneeded = () => {
    const d = r.result;
    d.createObjectStore("projects", { keyPath: "id" });
    const a = d.createObjectStore("assets", { keyPath: ["project", "path"] });
    a.createIndex("project", "project");
    const v = d.createObjectStore("versions", { keyPath: "id", autoIncrement: true });
    v.createIndex("project", "project");
  };
  const opened = await req(r);
  if (!(opened instanceof IDBDatabase))
    throw new Error("The database did not open.");
  db = opened;
}
function tx(stores, mode = "readonly") {
  const t = must(db, "open database").transaction(stores, mode);
  const done = new Promise((resolve, reject) => {
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error || new Error("The change was not saved."));
  });
  return { t, done, s: (n) => t.objectStore(n) };
}
function isProject(v) {
  return isRecord(v) && typeof v["id"] === "string" && typeof v["name"] === "string" && typeof v["markdown"] === "string" && typeof v["modified"] === "number" && typeof v["isDemo"] === "boolean" && typeof v["isListener"] === "boolean";
}
function isVersion(v) {
  return isRecord(v) && typeof v["id"] === "number" && typeof v["project"] === "string" && typeof v["time"] === "number" && typeof v["message"] === "string" && typeof v["markdown"] === "string" && Array.isArray(v["assets"]) && v["assets"].every((x) => typeof x === "string");
}
function isAssetRow(v) {
  return isRecord(v) && typeof v["project"] === "string" && typeof v["path"] === "string" && v["blob"] instanceof Blob;
}
function rows(v, guard) {
  if (!Array.isArray(v))
    throw new Error("The database gave no list.");
  return v.map((x) => {
    if (!guard(x))
      throw new Error("The database gave a damaged row.");
    return x;
  });
}
async function projects() {
  const { s } = tx(["projects"]);
  const all = rows(await req(s("projects").getAll()), isProject);
  return all.sort((a, b) => b.modified - a.modified);
}
async function project(id) {
  const { s } = tx(["projects"]);
  const row = await req(s("projects").get(id));
  if (row === undefined)
    return;
  if (!isProject(row))
    throw new Error("The database gave a damaged project.");
  return row;
}
function safeFileName(title) {
  const cleaned = String(title).replace(/[\/\\:*?"<>|\n\r\t]/g, "-").trim().slice(0, 80);
  return !cleaned || cleaned.startsWith(".") ? "Marklove" : cleaned;
}
async function uniqueName(base) {
  const clean = safeFileName(base);
  const names = new Set((await projects()).map((p) => p.name.toLowerCase()));
  let name = clean, n = 2;
  while (names.has(name.toLowerCase()))
    name = clean + " " + n++;
  return name;
}
async function createProject({ name, markdown = "", assets = {}, demo = false, listener = false }) {
  const unique = await uniqueName(name || "Untitled");
  const p = { id: crypto.randomUUID(), name: unique, markdown, modified: Date.now(), isDemo: demo, isListener: listener };
  const { s, done } = tx(["projects", "assets"], "readwrite");
  s("projects").put(p);
  for (const [path, blob] of Object.entries(assets)) {
    const clean = normalizePath(path);
    if (clean)
      s("assets").put({ project: p.id, path: clean, blob });
  }
  await done;
  return p;
}
async function saveProject(p) {
  p.modified = Date.now();
  const { s, done } = tx(["projects"], "readwrite");
  s("projects").put(p);
  await done;
}
async function deleteProject(id) {
  const { s, done } = tx(["projects", "assets", "versions"], "readwrite");
  s("projects").delete(id);
  for (const store of ["assets", "versions"]) {
    const keys = await req(s(store).index("project").getAllKeys(id));
    if (!Array.isArray(keys))
      throw new Error("The database gave no list.");
    for (const k of keys)
      s(store).delete(k);
  }
  await done;
}
async function duplicateProject(p) {
  const assets = await assetBlobs(p.id);
  return createProject({ name: p.name + " copy", markdown: p.markdown, assets });
}
function normalizePath(path) {
  const parts = String(path).replace(/\\/g, "/").split("/").filter((x) => x && x !== ".");
  if (!parts.length || parts.some((x) => x === ".." || x.startsWith(".")))
    return null;
  return parts.join("/");
}
async function assetBlobs(projectId) {
  const { s } = tx(["assets"]);
  const found = rows(await req(s("assets").index("project").getAll(projectId)), isAssetRow);
  const out = {};
  for (const r of found)
    out[r.path] = r.blob;
  return out;
}
async function addAsset(projectId, path, blob) {
  const { s, done } = tx(["assets"], "readwrite");
  s("assets").put({ project: projectId, path, blob });
  await done;
}
function assetName(existing, folder, fileName, ext) {
  const base = fileName.replace(/\.[^.]*$/, "").replace(/ /g, "-").replace(/[^\p{L}\p{N}_-]/gu, "") || "file";
  let name = folder + "/" + base + "." + ext, n = 2;
  while (existing[name])
    name = folder + "/" + base + "-" + n++ + "." + ext;
  return name;
}
async function versions(projectId) {
  const { s } = tx(["versions"]);
  const found = rows(await req(s("versions").index("project").getAll(projectId)), isVersion);
  return found.sort((a, b) => b.time - a.time || b.id - a.id);
}
async function addVersion(v) {
  const { s, done } = tx(["versions"], "readwrite");
  s("versions").add(v);
  await done;
}
var DEFAULTS = {
  themeID: "selenized",
  appearance: "system",
  editorTextScale: 1,
  editorLineSpacing: 1.4,
  vimEnabled: false,
  slideStyle: "normal",
  showLineCount: true,
  wrapLines: true,
  gitEnabled: true,
  gitName: "",
  gitEmail: "",
  findSyntax: "sam",
  onboardingSeen: false,
  lastProject: "",
  increaseContrast: false
};
function readStorage(key) {
  try {
    const raw = localStorage.getItem(key);
    return raw === null ? {} : JSON.parse(raw);
  } catch {
    return {};
  }
}
function pickString(o, key, fallback) {
  const v = o[key];
  return typeof v === "string" ? v : fallback;
}
function pickNumber(o, key, fallback) {
  const v = o[key];
  return typeof v === "number" ? v : fallback;
}
function pickBool(o, key, fallback) {
  const v = o[key];
  return typeof v === "boolean" ? v : fallback;
}
function readSettings() {
  const stored = readStorage(SETTINGS_KEY);
  const o = isRecord(stored) ? stored : {};
  const appearance = o["appearance"];
  const slideStyle = o["slideStyle"];
  const findSyntax = o["findSyntax"];
  return {
    themeID: pickString(o, "themeID", DEFAULTS.themeID),
    appearance: appearance === "system" || appearance === "light" || appearance === "dark" ? appearance : DEFAULTS.appearance,
    editorTextScale: pickNumber(o, "editorTextScale", DEFAULTS.editorTextScale),
    editorLineSpacing: pickNumber(o, "editorLineSpacing", DEFAULTS.editorLineSpacing),
    vimEnabled: pickBool(o, "vimEnabled", DEFAULTS.vimEnabled),
    slideStyle: slideStyle === "normal" || slideStyle === "takahashi" ? slideStyle : DEFAULTS.slideStyle,
    showLineCount: pickBool(o, "showLineCount", DEFAULTS.showLineCount),
    wrapLines: pickBool(o, "wrapLines", DEFAULTS.wrapLines),
    gitEnabled: pickBool(o, "gitEnabled", DEFAULTS.gitEnabled),
    gitName: pickString(o, "gitName", DEFAULTS.gitName),
    gitEmail: pickString(o, "gitEmail", DEFAULTS.gitEmail),
    findSyntax: findSyntax === "sam" || findSyntax === "vim" || findSyntax === "plain" ? findSyntax : DEFAULTS.findSyntax,
    onboardingSeen: pickBool(o, "onboardingSeen", DEFAULTS.onboardingSeen),
    lastProject: pickString(o, "lastProject", DEFAULTS.lastProject),
    increaseContrast: pickBool(o, "increaseContrast", DEFAULTS.increaseContrast)
  };
}
var settings = readSettings();
function setSetting(key, value) {
  settings[key] = value;
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  } catch {
    return;
  }
}
function isEditorState(v) {
  return isRecord(v) && typeof v["s"] === "number" && typeof v["e"] === "number" && typeof v["top"] === "number";
}
function editorState(id) {
  const all = readStorage(EDITOR_STATE_KEY);
  if (!isRecord(all))
    return null;
  const v = all[id];
  return isEditorState(v) ? v : null;
}
function setEditorState(id, value) {
  try {
    const stored = readStorage(EDITOR_STATE_KEY);
    const all = isRecord(stored) ? stored : {};
    if (value)
      all[id] = value;
    else
      delete all[id];
    localStorage.setItem(EDITOR_STATE_KEY, JSON.stringify(all));
  } catch {
    return;
  }
}

// src/ui.ts
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false)
      continue;
    if (k === "class")
      el.className = String(v);
    else if (k === "text")
      el.textContent = String(v);
    else if (k === "html")
      el.innerHTML = String(v);
    else if (k.startsWith("on") && typeof v === "function")
      el.addEventListener(k.slice(2), v);
    else if (k === "style" && typeof v === "object")
      Object.assign(el.style, v);
    else if (v === true)
      el.setAttribute(k, "");
    else
      el.setAttribute(k, String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false)
      continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}
var ANNOUNCE_DELAY_MS = 30;
function announce(text) {
  const live = document.getElementById("live");
  if (!live || !text)
    return;
  live.textContent = "";
  setTimeout(() => {
    live.textContent = text;
  }, ANNOUNCE_DELAY_MS);
}
var openMenuEl = null;
function closeMenu() {
  if (!openMenuEl)
    return;
  const { el, button } = openMenuEl;
  openMenuEl = null;
  el.remove();
  button.setAttribute("aria-expanded", "false");
}
var ENABLED_ITEMS = ".menu-item:not([disabled])";
function attachMenu(button, items, { align = "start" } = {}) {
  button.setAttribute("aria-haspopup", "menu");
  button.setAttribute("aria-expanded", "false");
  const show = (focusLast) => {
    if (openMenuEl && openMenuEl.button === button) {
      closeMenu();
      return;
    }
    closeMenu();
    const list = typeof items === "function" ? items() : items;
    const el = h("div", { class: "menu", role: "menu", "aria-label": button.getAttribute("aria-label") || button.textContent });
    for (const it of list) {
      if (it.separator) {
        el.append(h("div", { class: "menu-sep", role: "separator" }));
        continue;
      }
      if (it.header) {
        el.append(h("div", { class: "menu-header", role: "presentation", text: it.header }));
        continue;
      }
      const role = it.checked === undefined ? "menuitem" : "menuitemcheckbox";
      const item = h("button", {
        type: "button",
        role,
        class: "menu-item" + (it.danger ? " danger" : ""),
        tabindex: "-1",
        "aria-checked": it.checked === undefined ? null : String(!!it.checked),
        disabled: it.disabled,
        title: it.hint,
        onclick: () => {
          closeMenu();
          button.focus();
          if (it.action)
            it.action();
        }
      }, h("span", { class: "menu-check", "aria-hidden": "true", text: it.checked ? "✓" : "" }), h("span", { text: it.label }), it.shortcut ? h("span", { class: "menu-key", "aria-hidden": "true", text: it.shortcut }) : null);
      el.append(item);
    }
    document.body.append(el);
    const r = button.getBoundingClientRect();
    const { offsetWidth: w, offsetHeight: hgt } = el;
    let left = align === "end" ? r.right - w : r.left;
    left = Math.max(8, Math.min(left, innerWidth - w - 8));
    let top = r.bottom + 4;
    if (top + hgt > innerHeight - 8)
      top = Math.max(8, innerHeight - hgt - 8);
    el.style.left = left + "px";
    el.style.top = top + "px";
    openMenuEl = { el, button };
    button.setAttribute("aria-expanded", "true");
    const enabled = queryAll(el, ENABLED_ITEMS, HTMLElement);
    (focusLast ? enabled[enabled.length - 1] : enabled[0])?.focus();
    el.addEventListener("keydown", (e) => {
      const all = queryAll(el, ENABLED_ITEMS, HTMLElement);
      const i = all.findIndex((x) => x === document.activeElement);
      if (e.key === "ArrowDown") {
        all[(i + 1) % all.length]?.focus();
        e.preventDefault();
      } else if (e.key === "ArrowUp") {
        all[(i - 1 + all.length) % all.length]?.focus();
        e.preventDefault();
      } else if (e.key === "Home") {
        all[0]?.focus();
        e.preventDefault();
      } else if (e.key === "End") {
        all[all.length - 1]?.focus();
        e.preventDefault();
      } else if (e.key === "Escape") {
        closeMenu();
        button.focus();
        e.preventDefault();
        e.stopPropagation();
      } else if (e.key === "Tab") {
        closeMenu();
      } else if (e.key.length === 1 && /\S/.test(e.key)) {
        const k = e.key.toLowerCase();
        const next = all.slice(i + 1).concat(all.slice(0, i + 1)).find((b) => (b.textContent ?? "").trim().toLowerCase().startsWith(k));
        next?.focus();
      }
    });
  };
  button.addEventListener("click", () => show(false));
  button.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      show(false);
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      show(true);
    }
  });
}
document.addEventListener("pointerdown", (e) => {
  const target = e.target;
  if (openMenuEl && target instanceof Node && !openMenuEl.el.contains(target) && !openMenuEl.button.contains(target))
    closeMenu();
});
window.addEventListener("resize", closeMenu);
function dialog({ title, body, buttons = [{ label: "Done", primary: true }], wide = false, onClose }) {
  const titleId = "dlg-" + Math.random().toString(36).slice(2);
  const bar = h("div", { class: "sheet-bar" });
  const left = h("div", { class: "sheet-bar-side" });
  const right = h("div", { class: "sheet-bar-side end" });
  const dlg = h("dialog", { class: "sheet" + (wide ? " wide" : ""), "aria-labelledby": titleId });
  const close = () => {
    if (dlg.open)
      dlg.close();
  };
  const made = [];
  for (const b of buttons) {
    const el = h("button", {
      type: "button",
      class: "button" + (b.primary ? " primary" : "") + (b.danger ? " danger" : ""),
      disabled: b.disabled,
      onclick: async () => {
        const r = b.action ? await b.action() : undefined;
        if (r !== false)
          close();
      }
    }, b.label);
    made.push(el);
    (b.cancel ? left : right).append(el);
  }
  bar.append(left, h("h2", { id: titleId, class: "sheet-title", text: title }), right);
  const content = h("div", { class: "sheet-body" });
  if (body)
    content.append(body);
  dlg.append(bar, content);
  dlg.addEventListener("close", () => {
    dlg.remove();
    if (onClose)
      onClose();
  });
  dlg.addEventListener("click", (e) => {
    if (e.target === dlg)
      close();
  });
  document.body.append(dlg);
  dlg.showModal();
  const first = content.querySelector("input, textarea, select, button, [tabindex='0']");
  if (first instanceof HTMLElement && first.tagName !== "BUTTON")
    first.focus();
  return { dlg, body: content, close, buttons: made, setTitle: (t) => {
    query(dlg, ".sheet-title", HTMLElement).textContent = t;
  } };
}
function alertBox(message, title = "Marklove") {
  return new Promise((resolve) => {
    dialog({ title, body: h("p", { class: "alert-text", text: message }), buttons: [{ label: "OK", primary: true }], onClose: () => resolve() });
  });
}
function confirmBox({ title, message, choices }) {
  return new Promise((resolve) => {
    let value = null;
    const body = h("div", {}, h("p", { class: "alert-text", text: message }));
    const row = h("div", { class: "confirm-row" });
    for (const c of choices) {
      row.append(h("button", {
        type: "button",
        class: "button" + (c.danger ? " danger" : "") + (c.primary ? " primary" : ""),
        onclick: () => {
          value = c.value;
          d.close();
        }
      }, c.label));
    }
    row.append(h("button", { type: "button", class: "button", onclick: () => d.close() }, "Cancel"));
    body.append(row);
    const d = dialog({ title, body, buttons: [], onClose: () => resolve(value) });
    row.querySelector("button")?.focus();
  });
}
function section(title, ...children) {
  const id = "sec-" + Math.random().toString(36).slice(2);
  return h("section", { class: "form-section", "aria-labelledby": title ? id : null }, title ? h("h3", { id, class: "form-section-title", text: title }) : null, ...children);
}
function footnote(text) {
  return h("p", { class: "footnote", text });
}
function toggleRow(label, checked, onchange, hint) {
  const id = "t-" + Math.random().toString(36).slice(2);
  const input = h("input", {
    type: "checkbox",
    id,
    role: "switch",
    checked,
    onchange: (e) => {
      if (e.target instanceof HTMLInputElement)
        onchange(e.target.checked);
    }
  });
  return h("div", { class: "row" }, h("label", { for: id, class: "row-label" }, label, hint ? h("span", { class: "row-hint", text: hint }) : null), input);
}
function selectRow(label, options, value, onchange) {
  const id = "s-" + Math.random().toString(36).slice(2);
  const sel = h("select", { id, onchange: (e) => {
    if (e.target instanceof HTMLSelectElement)
      onchange(e.target.value);
  } }, options.map(([v, t]) => h("option", { value: v, selected: v === value }, t)));
  return h("div", { class: "row" }, h("label", { for: id, class: "row-label", text: label }), sel);
}
function segmented(label, options, value, onchange) {
  const group = h("div", { class: "segmented", role: "radiogroup", "aria-label": label });
  const set = (v) => {
    for (const b of queryAll(group, "button", HTMLElement)) {
      const on = b.dataset["value"] === v;
      b.setAttribute("aria-checked", String(on));
      b.dataset["active"] = String(on);
      b.tabIndex = on ? 0 : -1;
    }
  };
  for (const [v, t] of options) {
    group.append(h("button", { type: "button", class: "button", role: "radio", "data-value": v, onclick: () => {
      set(v);
      onchange(v);
    } }, t));
  }
  group.addEventListener("keydown", (e) => {
    const all = queryAll(group, "button", HTMLElement);
    const i = all.findIndex((x) => x === document.activeElement);
    if (i < 0)
      return;
    let j = -1;
    if (e.key === "ArrowRight" || e.key === "ArrowDown")
      j = (i + 1) % all.length;
    if (e.key === "ArrowLeft" || e.key === "ArrowUp")
      j = (i - 1 + all.length) % all.length;
    const target = all[j];
    if (target) {
      e.preventDefault();
      target.focus();
      target.click();
    }
  });
  set(value);
  return Object.assign(group, { setValue: set });
}
var REVOKE_DELAY_MS = 60000;
function download(blob, name) {
  const url = URL.createObjectURL(blob);
  const a = h("a", { href: url, download: name, hidden: true });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), REVOKE_DELAY_MS);
}
function pickFile(accept, multiple = false) {
  return new Promise((resolve) => {
    const input = h("input", { type: "file", accept, multiple, hidden: true });
    input.addEventListener("change", () => {
      resolve([...input.files ?? []]);
      input.remove();
    });
    input.addEventListener("cancel", () => {
      resolve([]);
      input.remove();
    });
    document.body.append(input);
    input.click();
  });
}
async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const t = h("textarea", { style: { position: "fixed", opacity: "0" } });
    t.value = text;
    document.body.append(t);
    t.select();
    const ok = document.execCommand("copy");
    t.remove();
    return ok;
  }
}
function blobToDataURL(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader;
    r.onload = () => {
      if (typeof r.result === "string")
        resolve(r.result);
      else
        reject(new Error("The file did not read as text."));
    };
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}
var isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
var cmdKey = isMac ? "⌘" : "Ctrl+";

// src/editor.ts
var enc = new TextEncoder;
var elements = null;
function els() {
  if (elements === null)
    throw new Error("The editor is not initialised.");
  return elements;
}
var editor = {
  get ta() {
    return els().ta;
  },
  get pre() {
    return els().pre;
  },
  get box() {
    return els().box;
  },
  get placeholder() {
    return els().placeholder;
  },
  onChange: (_text) => {},
  onSelect: () => {},
  onVimAction: (_action, _clip) => {},
  onVimState: () => {},
  boldRoles: new Set,
  italicRoles: new Set,
  vim: false,
  vimMode: "normal",
  vimStatus: "",
  vimCursor: -1,
  vimPrevKey: "",
  vimClipReg: false,
  findHits: new Array,
  readOnly: false
};
function init({ textarea, highlight, box, placeholder }) {
  elements = { ta: textarea, pre: highlight, box, placeholder };
  const typo = typography().editor;
  editor.boldRoles = new Set(typo.bold);
  editor.italicRoles = new Set(typo.italic);
  textarea.addEventListener("input", () => {
    paint();
    editor.onChange(textarea.value);
  });
  textarea.addEventListener("scroll", syncScroll);
  document.addEventListener("selectionchange", () => {
    if (document.activeElement === textarea)
      editor.onSelect();
  });
  textarea.addEventListener("keydown", vimKeydown);
  new ResizeObserver(() => {
    applyMetrics();
    syncScroll();
  }).observe(box);
}
var metrics = { scale: 1, spacing: 1.4, wrap: true };
function setMetrics(m) {
  metrics = { ...metrics, ...m };
  applyMetrics();
}
var LINE_CHARACTERS = 76;
var NARROW_WIDTH = 600;
function applyMetrics() {
  const size = 15 * metrics.scale;
  const width = editor.box.clientWidth;
  const narrow = width < NARROW_WIDTH;
  const minSide = narrow ? 16 : 20;
  const side = Math.max(minSide, (width - size * 0.6 * LINE_CHARACTERS) / 2);
  const s = document.documentElement.style;
  s.setProperty("--editor-size", size + "px");
  s.setProperty("--editor-line", String(metrics.spacing));
  s.setProperty("--editor-side", side + "px");
  s.setProperty("--editor-top", (narrow ? 20 : 24) + "px");
  s.setProperty("--editor-bottom", (narrow ? 40 : 24) + "px");
  editor.box.classList.toggle("nowrap", !metrics.wrap);
  editor.ta.wrap = metrics.wrap ? "soft" : "off";
}
function syncScroll() {
  editor.pre.scrollTop = editor.ta.scrollTop;
  editor.pre.scrollLeft = editor.ta.scrollLeft;
}
var text2 = () => editor.ta.value;
function setText(t) {
  editor.ta.value = t;
  editor.ta.setSelectionRange(0, 0);
  editor.ta.scrollTop = 0;
  paint();
}
function selection() {
  return [editor.ta.selectionStart, editor.ta.selectionEnd];
}
function setSelection(s, e = s, reveal = true) {
  const n = editor.ta.value.length;
  const start = Math.max(0, Math.min(s, n));
  const end = Math.max(start, Math.min(e, n));
  editor.ta.setSelectionRange(start, end);
  if (reveal)
    revealSelection();
  editor.onSelect();
}
function focus() {
  editor.ta.focus({ preventScroll: true });
}
function revealSelection() {
  const [s] = selection();
  const y = offsetTop(s);
  const ta = editor.ta;
  if (y < ta.scrollTop + 20 || y > ta.scrollTop + ta.clientHeight - 60)
    ta.scrollTop = Math.max(0, y - ta.clientHeight / 3);
  syncScroll();
}
function offsetTop(offset) {
  const pre = editor.pre;
  const mark = document.createElement("span");
  const t = editor.ta.value;
  const saved = [...pre.childNodes];
  pre.textContent = t.slice(0, offset);
  pre.append(mark, t.slice(offset) + " ");
  const y = mark.offsetTop;
  pre.replaceChildren(...saved);
  return y;
}
function insertTextCommand(t) {
  try {
    return document.execCommand("insertText", false, t);
  } catch {
    return false;
  }
}
function replaceRange(s, e, t) {
  const ta = editor.ta;
  if (editor.readOnly)
    return;
  ta.focus({ preventScroll: true });
  ta.setSelectionRange(s, e);
  const ok = insertTextCommand(t);
  if (!ok || ta.value.slice(s, s + t.length) !== t) {
    ta.setRangeText(t, s, e, "end");
    paint();
    editor.onChange(ta.value);
  }
}
var isTrail = (c) => c >= 56320 && c <= 57343;
function replaceAll(next, { undoable = true } = {}) {
  const old = editor.ta.value;
  if (old === next)
    return;
  let p = 0;
  while (p < old.length && p < next.length && old.charCodeAt(p) === next.charCodeAt(p))
    p++;
  let q = 0;
  while (q < old.length - p && q < next.length - p && old.charCodeAt(old.length - 1 - q) === next.charCodeAt(next.length - 1 - q))
    q++;
  while (p > 0 && (isTrail(old.charCodeAt(p)) || isTrail(next.charCodeAt(p))))
    p--;
  while (q > 0 && (isTrail(old.charCodeAt(old.length - q)) || isTrail(next.charCodeAt(next.length - q))))
    q--;
  const middle = next.slice(p, next.length - q);
  if (undoable)
    replaceRange(p, old.length - q, middle);
  else {
    const top = editor.ta.scrollTop;
    editor.ta.setRangeText(middle, p, old.length - q, "preserve");
    editor.ta.scrollTop = top;
    paint();
    editor.onChange(editor.ta.value);
  }
}
function snippet(template, block = true) {
  const o = template.indexOf("⟦"), c = template.indexOf("⟧");
  if (o >= 0 && c > o) {
    return { text: template.slice(0, o) + template.slice(o + 1, c) + template.slice(c + 1), sel: [o, c - o - 1], block };
  }
  return { text: template, sel: [template.length, 0], block };
}
function insert(sn) {
  const t = text2();
  const [s, e] = selection();
  let prefix = "", suffix = "";
  if (sn.block) {
    const before = t.slice(0, s);
    if (before)
      prefix = before.endsWith(`

`) ? "" : before.endsWith(`
`) ? `
` : `

`;
    const after = t.slice(e);
    if (!after.startsWith(`
`))
      suffix = after ? `

` : `
`;
  }
  replaceRange(s, e, prefix + sn.text + suffix);
  const start = s + prefix.length + sn.sel[0];
  setSelection(start, start + sn.sel[1]);
  focus();
}
function frontMatterLines(date = new Date) {
  const lang = (navigator.language || "en").split("-")[0];
  return [
    "title: ⟦Title⟧",
    "subtitle: Subtitle",
    "author: Name",
    "institute: Institute",
    "date: " + date.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }),
    "lang: " + lang,
    "theme: selenized-light",
    "accent: blue",
    "voice: af_heart"
  ];
}
function insertFrontMatter() {
  const t = text2();
  const lines = frontMatterLines().map((l) => l.replace("⟦", "").replace("⟧", ""));
  const key = (l) => (l.split(":")[0] || "").trim().toLowerCase();
  if (t.startsWith(`---
`)) {
    const close = t.indexOf(`
---`, 3);
    if (close >= 0) {
      const body = t.slice(4, Math.max(4, close));
      const have = new Set(body.split(`
`).map(key));
      const missing = lines.filter((l) => !have.has(key(l)));
      if (missing.length)
        replaceRange(close, close, (close > 4 ? `
` : "") + missing.join(`
`));
      selectTitleValue();
      return;
    }
  }
  const block = `---
` + lines.join(`
`) + `
---
` + (t.length === 0 || t.startsWith(`
`) ? "" : `
`);
  replaceRange(0, 0, block);
  selectTitleValue();
}
function selectTitleValue() {
  const t = text2();
  const i = t.slice(0, 4000).indexOf(`
title:`);
  if (i >= 0) {
    let s = i + 7;
    while (t[s] === " ")
      s++;
    let e = t.indexOf(`
`, s);
    if (e < 0)
      e = t.length;
    setSelection(s, e);
  } else
    setSelection(0, 0);
  focus();
}
function wrapSelectionInLines(start, end) {
  const t = text2();
  const [s, e] = selection();
  if (s === e) {
    insert(snippet(start + `
⟦⟧
` + end));
    return;
  }
  const ls = t.lastIndexOf(`
`, s - 1) + 1;
  let le = t.indexOf(`
`, e > s && t[e - 1] === `
` ? e - 1 : e);
  le = le < 0 ? t.length : le + 1;
  let body = t.slice(ls, le);
  if (!body.endsWith(`
`))
    body += `
`;
  const rep = start + `
` + body + end + `
`;
  replaceRange(ls, le, rep);
  setSelection(ls, ls + rep.length);
}
function setPalette(roles) {
  let css = "";
  for (const [role, color] of Object.entries(roles))
    css += `.highlight .r-${role}{color:${color}}`;
  let st = document.getElementById("role-colors");
  if (!st) {
    st = document.createElement("style");
    st.id = "role-colors";
    document.head.append(st);
  }
  st.textContent = css;
  paint();
}
function byteMap(t) {
  const map = new Uint32Array(enc.encode(t).length + 1);
  let b = 0;
  for (let i = 0;i < t.length; i++) {
    const c = t.charCodeAt(i);
    let n;
    if (c < 128)
      n = 1;
    else if (c < 2048)
      n = 2;
    else if (c >= 55296 && c <= 56319) {
      n = 4;
      for (let k = 0;k < 4; k++)
        map[b + k] = i;
      b += 4;
      i++;
      continue;
    } else
      n = 3;
    for (let k = 0;k < n; k++)
      map[b + k] = i;
    b += n;
  }
  map[b] = t.length;
  return map;
}
var paintTimer = 0;
var LAZY_PAINT_LENGTH = 60000;
function paint() {
  const t = editor.ta.value;
  editor.placeholder.hidden = t.length > 0 || editor.readOnly;
  cancelAnimationFrame(paintTimer);
  if (t.length > LAZY_PAINT_LENGTH) {
    editor.pre.textContent = t + " ";
    paintTimer = requestAnimationFrame(() => paintNow(t));
  } else
    paintNow(t);
  syncScroll();
}
var ROLE_NAMES = [];
function roleIndex(name) {
  let i = ROLE_NAMES.indexOf(name);
  if (i < 0) {
    ROLE_NAMES.push(name);
    i = ROLE_NAMES.length - 1;
  }
  return i;
}
var FIND_MARK = 1;
var VIM_MARK = 2;
function highlightSpans(t) {
  try {
    return t.length ? highlightMarkdown(t) : [];
  } catch {
    return [];
  }
}
function vimCursorSpan() {
  const sp = document.createElement("span");
  sp.className = "vim-cursor";
  sp.textContent = " ";
  return sp;
}
function paintNow(t) {
  if (t !== editor.ta.value)
    return;
  const spans = highlightSpans(t);
  const n = t.length;
  const roles = new Int16Array(n).fill(-1);
  if (spans.length) {
    const map = byteMap(t);
    for (const [s, e, role] of spans) {
      const a = map[Math.min(s, map.length - 1)] ?? 0, b = map[Math.min(e, map.length - 1)] ?? 0;
      roles.fill(roleIndex(role), a, b);
    }
  }
  const marks = new Uint8Array(n);
  for (const [a, b] of editor.findHits)
    marks.fill(FIND_MARK, a, b);
  const c = editor.vim && editor.vimMode !== "insert" ? editor.vimCursor : -1;
  if (c >= 0 && c < n && t[c] !== `
`)
    marks[c] = VIM_MARK;
  const extra = c >= 0 && (c >= n || t[c] === `
`) ? c : -1;
  const frag = document.createDocumentFragment();
  let i = 0;
  while (i < n) {
    if (i === extra)
      frag.append(vimCursorSpan());
    let j = i + 1;
    while (j < n && j !== extra && roles[j] === roles[i] && marks[j] === marks[i])
      j++;
    const r = roles[i] ?? -1, m = marks[i] ?? 0;
    const chunk = t.slice(i, j);
    if (r < 0 && !m)
      frag.append(chunk);
    else {
      const sp = document.createElement("span");
      const name = r >= 0 ? ROLE_NAMES[r] ?? "" : "";
      let cls = name ? "r-" + name : "";
      if (editor.boldRoles.has(name))
        cls += " b";
      if (editor.italicRoles.has(name))
        cls += " i";
      if (m === FIND_MARK)
        cls += " find-hit";
      if (m === VIM_MARK)
        cls += " vim-cursor";
      sp.className = cls;
      sp.textContent = chunk;
      frag.append(sp);
    }
    i = j;
  }
  if (extra >= n)
    frag.append(vimCursorSpan());
  frag.append(" ");
  editor.pre.replaceChildren(frag);
}
function setFindHits(hits) {
  editor.findHits = hits;
  paint();
}
function lineStatus() {
  const t = editor.ta.value;
  const loc = editor.ta.selectionStart;
  let lines = 1, line = 1;
  for (let i = t.indexOf(`
`);i >= 0; i = t.indexOf(`
`, i + 1)) {
    lines++;
    if (i < loc)
      line++;
  }
  const words = (t.match(/[^\s]+/g) || []).length;
  return { line, lines, words };
}
var MODE_NAMES = { normal: "NORMAL", insert: "INSERT", visual: "VISUAL", "visual-line": "VISUAL LINE", command: "COMMAND" };
var MODE_SPOKEN = { normal: "Normal mode", insert: "Insert mode", visual: "Visual mode", "visual-line": "Visual line mode", command: "Command line" };
var vimModeName = (m) => MODE_NAMES[m] || "NORMAL";
function setVim(on) {
  editor.vim = on;
  if (on) {
    vimReset();
    editor.vimMode = "normal";
    editor.vimStatus = "";
    editor.vimCursor = editor.ta.selectionStart;
  }
  editor.box.classList.toggle("vim-normal", on && editor.vimMode !== "insert");
  paint();
  editor.onVimState();
}
var NAMED_KEYS = ["Escape", "Enter", "Backspace", "Tab", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"];
function keyName(e) {
  if (e.metaKey || e.altKey && e.key.length !== 1)
    return null;
  if (e.ctrlKey) {
    if (e.key === "[")
      return "Escape";
    if (e.key.length === 1)
      return "Ctrl-" + e.key.toLowerCase();
    return null;
  }
  if (NAMED_KEYS.includes(e.key))
    return e.key;
  if ([...e.key].length === 1)
    return e.key;
  return null;
}
function vimKeydown(e) {
  if (!editor.vim || editor.readOnly || e.isComposing)
    return;
  const key = keyName(e);
  if (!key)
    return;
  if (editor.vimMode === "insert" && key !== "Escape" && !key.startsWith("Ctrl-"))
    return;
  const prev = editor.vimPrevKey;
  editor.vimPrevKey = key;
  if (editor.vimMode === "command")
    editor.vimClipReg = false;
  else if (prev === '"' && (key === "+" || key === "*"))
    editor.vimClipReg = true;
  else if (editor.vimClipReg && (key === "p" || key === "P")) {
    editor.vimClipReg = false;
    e.preventDefault();
    e.stopPropagation();
    clipboardKey(key);
    return;
  } else if (!/^[0-9]$/.test(key))
    editor.vimClipReg = false;
  if (runVimKey(key)) {
    e.preventDefault();
    e.stopPropagation();
  }
}
async function readClipboardOrEmpty() {
  try {
    return await navigator.clipboard.readText();
  } catch {
    return "";
  }
}
function errorMessage(err) {
  return err instanceof Error ? err.message : String(err);
}
async function clipboardKey(key) {
  const clip = await readClipboardOrEmpty();
  try {
    vimClipboard(clip);
  } catch (err) {
    vimMessage(errorMessage(err));
    return;
  }
  runVimKey(key);
}
function runVimKey(key) {
  const t = editor.ta.value;
  const [s16, e16] = selection();
  let r;
  try {
    r = vimKey(t, utf8Offset(t, s16), utf8Offset(t, e16), key);
  } catch (err) {
    if (!(err instanceof TooLarge))
      throw err;
    vimMessage(err.message);
    vimInsert();
    return false;
  }
  if (!r.handled)
    return false;
  applyVim(r);
  return true;
}
function vimInsert() {
  if (!editor.vim || editor.vimMode === "insert")
    return;
  editor.vimMode = "insert";
  editor.box.classList.toggle("vim-normal", false);
  paint();
  editor.onVimState();
}
function vimMessage(m) {
  editor.vimStatus = m;
  editor.onVimState();
}
function applyVim(r) {
  const old = editor.ta.value;
  let t = old;
  if (r.text !== null && r.text !== undefined) {
    t = r.text;
    replaceAll(t, { undoable: false });
  }
  const a = utf16Offset(t, r.sel[0]), b = utf16Offset(t, r.sel[1]);
  const cursor = utf16Offset(t, r.cursor);
  const prev = editor.vimMode;
  editor.vimMode = r.mode;
  editor.vimStatus = r.status || "";
  editor.vimCursor = cursor;
  if (r.mode === "visual" || r.mode === "visual-line")
    editor.ta.setSelectionRange(Math.min(a, b), Math.max(a, b));
  else
    editor.ta.setSelectionRange(cursor, cursor);
  editor.box.classList.toggle("vim-normal", r.mode !== "insert");
  if (prev !== r.mode)
    announce(MODE_SPOKEN[r.mode] || "");
  paint();
  revealCaret();
  editor.onSelect();
  editor.onVimState();
  if (r.action)
    editor.onVimAction(r.action, r.clip);
}
function revealCaret() {
  const ta = editor.ta;
  const y = offsetTop(editor.vimCursor >= 0 ? editor.vimCursor : ta.selectionStart);
  if (y < ta.scrollTop + 10 || y > ta.scrollTop + ta.clientHeight - 40)
    ta.scrollTop = Math.max(0, y - ta.clientHeight / 3);
  syncScroll();
}
function syncVimCursor() {
  if (!editor.vim)
    return;
  const c = editor.ta.selectionStart;
  if (c !== editor.vimCursor && editor.vimMode !== "insert") {
    editor.vimCursor = c;
    paint();
  }
}

// src/preview.ts
var parts = { style: "", runtime: "", articleStyle: "", articleScript: "", fonts: "" };
var FACES = [
  ["Courier Prime", "CourierPrime-Regular.woff2", "normal", "400"],
  ["Courier Prime", "CourierPrime-Bold.woff2", "normal", "700"],
  ["Courier Prime", "CourierPrime-Italic.woff2", "italic", "400"],
  ["Courier Prime", "CourierPrime-BoldItalic.woff2", "italic", "700"],
  ["KpMath", "KpMath-Light.otf", "normal", "400"],
  ["Courier Prime Sans", "CourierPrimeSans-Regular.woff2", "normal", "400"],
  ["Courier Prime Sans", "CourierPrimeSans-Bold.woff2", "normal", "700"]
];
var PAGE_FACES = [
  ["Libre Baskerville", "LibreBaskerville-Variable.ttf", "normal", "400 700"],
  ["Libre Baskerville", "LibreBaskerville-Italic-Variable.ttf", "italic", "400 700"],
  ...FACES
];
function faceCSS(url, faces = FACES) {
  return faces.map(([family, file, style, weight]) => {
    const format = file.endsWith(".woff2") ? "woff2" : file.endsWith(".ttf") ? "truetype" : "opentype";
    return `@font-face{font-family:"${family}";src:url(${url(file)}) format("${format}");font-style:${style};font-weight:${weight};font-display:swap}
`;
  }).join("");
}
var fontURL = (f) => new URL("fonts/" + f, location.href).href;
function messageOf(e) {
  return e instanceof Error ? e.message : String(e);
}
async function loadParts() {
  const get = (p) => fetch(p).then((r) => {
    if (!r.ok)
      throw new Error(p);
    return r.text();
  });
  const [style, runtime, articleStyle, articleScript] = await Promise.all([get("style.css"), get("runtime.js"), get("article.css"), get("article.js")]);
  parts.style = style;
  parts.runtime = runtime;
  parts.articleStyle = articleStyle;
  parts.articleScript = articleScript;
  parts.fonts = faceCSS(fontURL);
}
function readDataURL(blob) {
  return new Promise((res) => {
    const r = new FileReader;
    r.onload = () => res(typeof r.result === "string" ? r.result : "");
    r.readAsDataURL(blob);
  });
}
var embedded = new Map;
async function embeddedFonts(faces = FACES) {
  const known = embedded.get(faces);
  if (known !== undefined)
    return known;
  const urls = new Map;
  for (const [, file] of faces) {
    const blob = await (await fetch("fonts/" + file)).blob();
    const mime = file.endsWith(".woff2") ? "font/woff2" : file.endsWith(".ttf") ? "font/ttf" : "font/otf";
    const b64 = (await readDataURL(blob)).split(",")[1] ?? "";
    urls.set(file, `data:${mime};base64,${b64}`);
  }
  const css = faceCSS((f) => urls.get(f) ?? "", faces);
  embedded.set(faces, css);
  return css;
}
function doc(source, assets, { kind = PAGE_SLIDES, appearance = "", fonts = parts.fonts } = {}) {
  const article = kind === PAGE_ARTICLE;
  return { source, assets, fonts, style: article ? parts.articleStyle : parts.style, script: article ? parts.articleScript : parts.runtime, appearance };
}
function slideOptions(takahashi) {
  return (takahashi ? O_TAKAHASHI : 0) | O_NARRATION | O_PUBLIC_NOTES;
}

class PageFrame {
  host;
  title;
  chrome;
  frame = null;
  url = null;
  html = "";
  onload = null;
  onkey = null;
  constructor(host, title, { chrome = true } = {}) {
    this.host = host;
    this.title = title;
    this.chrome = chrome;
  }
  show(html, hash = "", keepScroll = false) {
    this.html = html;
    const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
    const f = document.createElement("iframe");
    f.title = this.title;
    const old = this.frame, oldURL = this.url;
    let scroll = 0;
    if (keepScroll && old) {
      try {
        scroll = old.contentWindow?.scrollY ?? 0;
      } catch {
        scroll = 0;
      }
    }
    if (old) {
      f.style.position = "absolute";
      f.style.visibility = "hidden";
      f.style.inset = "0";
    }
    f.addEventListener("load", () => {
      try {
        const d = must(f.contentDocument, "frame document");
        if (!this.chrome) {
          const st = d.createElement("style");
          st.textContent = ".bar{display:none!important}.deck{padding:8px!important}.skip{display:none}";
          d.head.append(st);
        }
        if (scroll)
          must(f.contentWindow, "frame window").scrollTo(0, scroll);
        d.addEventListener("keydown", (e) => this.onkey?.(e));
      } catch {}
      if (old) {
        old.remove();
        f.style.position = "";
        f.style.visibility = "";
        f.style.inset = "";
      }
      if (oldURL)
        URL.revokeObjectURL(oldURL);
      this.onload?.(f);
    }, { once: true });
    f.src = url + (hash ? "#" + hash : "");
    this.host.append(f);
    this.frame = f;
    this.url = url;
  }
  currentId() {
    try {
      return decodeURIComponent(must(this.frame?.contentWindow, "frame window").location.hash.slice(1));
    } catch {
      return "";
    }
  }
  key(name, times = 1) {
    try {
      const d = must(this.frame?.contentDocument, "frame document");
      for (let i = 0;i < times; i++)
        d.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true }));
    } catch {}
  }
  clear() {
    if (this.frame)
      this.frame.remove();
    if (this.url)
      URL.revokeObjectURL(this.url);
    this.frame = null;
    this.url = null;
  }
}
function slideAt(outline, offset) {
  let best = outline[0];
  for (const s of outline) {
    if (s.s0 <= offset && offset < s.s1)
      return s;
    if (s.s0 <= offset)
      best = s;
  }
  return best;
}
var NO_SLIDES_MESSAGE = "No Slides. Add a slide title with ## to make a slide.";
function speakerReady({ source, assets, takahashi, appearance, startOffset }) {
  const d = doc(source, assets, { appearance });
  const opts = slideOptions(takahashi);
  let html;
  let outline2;
  try {
    html = page(d, PAGE_SLIDES, opts);
    outline2 = outline(d, opts);
  } catch (e) {
    return { error: messageOf(e) };
  }
  if (!outline2.length)
    return { error: NO_SLIDES_MESSAGE };
  const startSlide = slideAt(outline2, startOffset ?? 0);
  let index = Math.max(0, startSlide ? outline2.indexOf(startSlide) : -1);
  if (startOffset === null || startOffset === undefined)
    index = 0;
  let step = 0;
  const slideAtIndex = (i) => must(outline2[i], "slide " + i);
  const curHost = h("div", { style: { position: "relative" } });
  const nextHost = h("div", { style: { position: "relative" } });
  const cur = new PageFrame(curHost, "Current slide", { chrome: false });
  const nxt = new PageFrame(nextHost, "Next slide", { chrome: false });
  const counter = h("span", { class: "counter", role: "status" });
  const nextLabel = h("p", { class: "cap-label", text: "Next" });
  const last = h("p", { class: "footnote", text: "This is the last slide.", hidden: true });
  const notes = h("div", { class: "notes", tabindex: "0", "aria-label": "Private notes" });
  const time = h("span", { class: "time", role: "timer" }, "0:00:00");
  let audience = null;
  let started = 0, elapsed = 0;
  let timer;
  const fmt = (s) => `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
  const tick = () => {
    const s = Math.floor((elapsed + (started ? Date.now() - started : 0)) / 1000);
    time.textContent = fmt(s);
    time.setAttribute("aria-label", "Time: " + fmt(s));
  };
  const startBtn = h("button", { type: "button", class: "button primary", onclick: () => {
    if (started) {
      elapsed += Date.now() - started;
      started = 0;
      clearInterval(timer);
      startBtn.textContent = "Start";
    } else {
      started = Date.now();
      timer = setInterval(tick, 1000);
      startBtn.textContent = "Pause";
    }
    tick();
  } }, "Start");
  const resetBtn = h("button", { type: "button", class: "button", onclick: () => {
    elapsed = 0;
    if (started)
      started = Date.now();
    tick();
  } }, "Reset");
  const counterText = () => {
    const s = slideAtIndex(index);
    return `Slide ${index + 1} of ${outline2.length}` + (s.steps > 1 ? `, step ${step + 1} of ${s.steps}` : "");
  };
  function update() {
    const s = slideAtIndex(index);
    counter.textContent = counterText();
    notes.textContent = s.notes || "No notes for this slide.";
    const n = outline2[index + 1];
    nextLabel.hidden = nextHost.hidden = !n;
    last.hidden = !!n;
    if (n)
      nxt.show(html, n.id);
  }
  nxt.onload = () => {
    const n = outline2[index + 1];
    if (n && n.steps > 1)
      nxt.key("ArrowRight", n.steps - 1);
  };
  cur.onload = () => {
    cur.key("ArrowRight", step);
  };
  function go(delta, toCur = true, toAudience = true) {
    const s = slideAtIndex(index);
    let moved = false;
    if (delta > 0) {
      if (step < s.steps - 1) {
        step++;
        moved = true;
      } else if (index < outline2.length - 1) {
        index++;
        step = 0;
        moved = true;
        update();
      }
    } else {
      if (step > 0) {
        step--;
        moved = true;
      } else if (index > 0) {
        index--;
        step = slideAtIndex(index).steps - 1;
        moved = true;
        update();
      }
    }
    if (!moved)
      return;
    const k = delta > 0 ? "ArrowRight" : "ArrowLeft";
    if (toCur)
      cur.key(k);
    if (toAudience && audience && !audience.closed) {
      try {
        audience.document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true }));
      } catch {}
    }
    counter.textContent = counterText();
  }
  const forward = (k) => ["ArrowRight", " ", "PageDown"].includes(k);
  const back = (k) => ["ArrowLeft", "PageUp"].includes(k);
  const keys = (e) => {
    if (forward(e.key)) {
      e.preventDefault();
      go(1);
    } else if (back(e.key)) {
      e.preventDefault();
      go(-1);
    }
  };
  cur.onkey = (e) => {
    if (!e.isTrusted)
      return;
    if (forward(e.key))
      go(1, false, true);
    else if (back(e.key))
      go(-1, false, true);
  };
  const prevBtn = h("button", { type: "button", class: "button", "aria-label": "Previous Slide", title: "Previous slide", onclick: () => go(-1) }, "◀");
  const nextBtn = h("button", { type: "button", class: "button", "aria-label": "Next Slide", title: "Next slide", onclick: () => go(1) }, "▶");
  const body = h("div", { class: "speaker" }, h("div", { class: "col" }, curHost, h("div", { class: "ctl" }, prevBtn, counter, nextBtn)), h("div", { class: "col" }, h("div", { class: "timer" }, time, startBtn, resetBtn), nextLabel, nextHost, last, h("p", { class: "cap-label", text: "Notes" }), notes));
  function openAudience() {
    const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
    const win = window.open(url + "#" + encodeURIComponent(slideAtIndex(index).id), "marklove-audience");
    audience = win;
    if (!win) {
      announce("The browser blocked the audience window. Allow pop-ups for this page.");
      return;
    }
    win.addEventListener("load", () => {
      try {
        if (step)
          for (let i = 0;i < step; i++)
            win.document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
        win.document.addEventListener("keydown", (e) => {
          if (!e.isTrusted)
            return;
          if (forward(e.key))
            go(1, true, false);
          else if (back(e.key))
            go(-1, true, false);
        });
      } catch {}
      setTimeout(() => URL.revokeObjectURL(url), 5000);
    }, { once: true });
  }
  const dlg = dialog({
    title: "Speaker Ready",
    body,
    buttons: [
      { label: "End", cancel: true },
      { label: "Open Audience Window", action: () => {
        openAudience();
        return false;
      } }
    ],
    onClose: () => {
      clearInterval(timer);
      cur.clear();
      nxt.clear();
      if (audience && !audience.closed)
        audience.close();
    }
  });
  dlg.dlg.classList.add("full");
  must(dlg.buttons[1], "audience button").title = "Show the slides in a separate window. Move it to the projector and make it full screen.";
  dlg.dlg.addEventListener("keydown", (e) => {
    const onButton = e.target instanceof Element && e.target.tagName === "BUTTON";
    if (!onButton || e.key !== " ")
      keys(e);
  });
  cur.show(html, slideAtIndex(index).id);
  update();
  tick();
  prevBtn.focus();
  return { dlg };
}
function listenerPreview({ source, assets, takahashi, appearance }) {
  let md;
  let html;
  try {
    const listened = listener(source, LIST_LISTENER_MD);
    if (typeof listened !== "string")
      throw new Error("The listener output is not text.");
    md = listened;
    html = page(doc(md, assets, { appearance }), PAGE_SLIDES, (takahashi ? O_TAKAHASHI : 0) | O_PUBLIC_NOTES);
  } catch (e) {
    return { error: messageOf(e) };
  }
  const host = h("div", { style: { position: "relative", flex: "1", display: "flex" } });
  const frame = new PageFrame(host, "Listener slides");
  const text = h("pre", { class: "code", hidden: true, tabindex: "0", "aria-label": "Listener Markdown", text: md });
  const pick = segmented("Show", [["slides", "Slides"], ["text", "Text"]], "slides", (v) => {
    host.hidden = v !== "slides";
    host.style.display = v === "slides" ? "flex" : "none";
    text.hidden = v !== "text";
  });
  const body = h("div", { style: { display: "flex", flexDirection: "column", gap: "10px", flex: "1" } }, h("div", { class: "banner", style: { borderRadius: "8px" } }, h("span", { "aria-hidden": "true" }, "\uD83D\uDC65"), h("span", { class: "msg", text: "This is what a listener sees. Private notes are not in the Listener package. Select Reading view in the page to see the notes for listeners." })), pick, host, text);
  const d = dialog({ title: "Listener Preview", body, wide: true, onClose: () => frame.clear() });
  d.dlg.classList.add("full");
  frame.show(html);
  if (host.firstElementChild)
    host.firstElementChild.classList.add("listener-frame");
  frame.onload = (f) => f.classList.add("listener-frame");
  return d;
}

// src/find.ts
var find2 = {
  open: false,
  showsReplace: false,
  showsCommand: false,
  matchCase: false,
  query: "",
  replacement: "",
  command: "",
  matches: [],
  current: -1,
  error: "",
  lastCount: null,
  commandOutput: [],
  commandStatus: "",
  commandError: ""
};
var bar = null;
var app = null;
var els2 = {};
var REFRESH_DELAY_MS = 120;
var MAX_COMMAND_ROWS = 5;
var WHOLE_FILE_HINT = "No changes. Dot is empty. Put , before the command to use the whole file.";
var SYNTAXES = [["sam", "Sam (Plan 9)"], ["vim", "Vim"], ["plain", "Plain text"]];
var syntax = () => settings.findSyntax;
var syntaxName = () => SYNTAXES.find((s) => s[0] === syntax())?.[1] ?? "";
var usesSam = () => syntax() === "sam";
var barEl = () => must(bar, "find bar");
var appRef = () => must(app, "find app");
var messageOf2 = (e) => e instanceof Error ? e.message : String(e);
function initFind(el, appRefValue) {
  bar = el;
  app = appRefValue;
}
function toU16(t, pairs) {
  if (!pairs.length)
    return [];
  const map = byteMap(t);
  return pairs.map(([s, e]) => [map[s] ?? t.length, map[e] ?? t.length]);
}
function refresh(select = false) {
  find2.error = "";
  if (!find2.open || !find2.query) {
    find2.matches = [];
    find2.current = -1;
    setFindHits([]);
    render();
    return;
  }
  const t = text2();
  let r;
  try {
    r = find(t, find2.query, syntax(), !find2.matchCase);
  } catch (e) {
    r = { error: messageOf2(e) };
  }
  if ("error" in r) {
    find2.error = r.error;
    find2.matches = [];
  } else
    find2.matches = toU16(t, r.matches);
  const caret = selection()[0];
  find2.current = find2.matches.length ? Math.max(0, find2.matches.findIndex(([s]) => s >= caret)) : -1;
  setFindHits(find2.matches);
  if (select && find2.current >= 0)
    show(find2.current);
  render();
}
function show(i) {
  const m = find2.matches[i];
  if (!m)
    return;
  find2.current = i;
  setSelection(m[0], m[1]);
  render();
}
function next(forward = true) {
  refresh();
  if (!find2.matches.length)
    return;
  const [cs, ce] = selection();
  let i;
  if (forward) {
    i = find2.matches.findIndex(([s]) => s > cs || s === cs && cs === ce);
    if (i < 0)
      i = 0;
  } else {
    i = -1;
    find2.matches.forEach(([s], k) => {
      if (s < cs)
        i = k;
    });
    if (i < 0)
      i = find2.matches.length - 1;
  }
  show(i);
}
function replaceCurrent() {
  const t = text2();
  const [s, e] = selection();
  let r;
  try {
    r = replace(t, find2.query, find2.replacement, syntax(), !find2.matchCase, utf8Offset(t, s), utf8Offset(t, e), false);
  } catch (err) {
    r = { error: messageOf2(err) };
  }
  if ("error" in r) {
    find2.error = r.error;
    render();
    return;
  }
  if (!r.count || r.text === undefined || !r.selection) {
    next();
    return;
  }
  replaceAll(r.text);
  const caret = utf16Offset(r.text, r.selection[1]);
  setSelection(caret, caret);
  next();
}
function replaceAllMatches() {
  const t = text2();
  let r;
  try {
    r = replace(t, find2.query, find2.replacement, syntax(), !find2.matchCase, 0, 0, true);
  } catch (err) {
    r = { error: messageOf2(err) };
  }
  if ("error" in r) {
    find2.error = r.error;
    render();
    return;
  }
  if (r.count && r.text !== undefined)
    replaceAll(r.text);
  find2.lastCount = r.count || 0;
  announce(find2.lastCount + (find2.lastCount === 1 ? " replacement." : " replacements."));
  refresh();
}
function runCommand() {
  const t = text2();
  const [s, e] = selection();
  let r;
  try {
    r = sam(find2.command, t, utf8Offset(t, s), utf8Offset(t, e), !find2.matchCase);
  } catch (err) {
    r = { error: messageOf2(err) };
  }
  if ("error" in r) {
    find2.commandError = r.error;
    find2.commandStatus = "";
    find2.commandOutput = [];
    announce(r.error);
  } else {
    const nt = r.text === null ? t : r.text;
    if (r.text !== null)
      replaceAll(r.text);
    setSelection(utf16Offset(nt, r.selection[0]), utf16Offset(nt, r.selection[1]));
    find2.commandOutput = r.printed;
    find2.commandError = "";
    if (r.text === null && r.summary === "No changes." && s === e && !find2.command.trim().startsWith(","))
      find2.commandStatus = WHOLE_FILE_HINT;
    else
      find2.commandStatus = r.summary;
    announce(find2.commandStatus);
  }
  refresh();
}
function statusText() {
  if (find2.error)
    return find2.error;
  if (!find2.query)
    return "";
  if (!find2.matches.length)
    return "No matches";
  if (find2.current >= 0)
    return `${find2.current + 1} of ${find2.matches.length}`;
  return `Matches: ${find2.matches.length}`;
}
function openFind({ replace = false, command = false } = {}) {
  if (appRef().readOnly())
    return;
  find2.open = true;
  if (replace)
    find2.showsReplace = true;
  if (command && usesSam())
    find2.showsCommand = true;
  build();
  barEl().hidden = false;
  const query = must(els2.query, "find field");
  const target = command && find2.showsCommand ? must(els2.command, "command field") : replace ? must(els2.replace, "replace field") : query;
  const [from, to] = selection();
  const sel = text2().slice(from, to);
  if (!command && sel && !sel.includes(`
`) && !replace) {
    find2.query = sel;
    query.value = sel;
  }
  target.focus();
  target.select();
  refresh(true);
}
function closeFind() {
  find2.open = false;
  barEl().hidden = true;
  setFindHits([]);
  focus();
}
function build() {
  const box = barEl();
  box.replaceChildren();
  const q = h("input", {
    type: "text",
    value: find2.query,
    placeholder: { sam: "Find (Sam)", vim: "Find (Vim)", plain: "Find" }[syntax()],
    "aria-label": "Find",
    autocomplete: "off",
    autocapitalize: "off",
    spellcheck: "false",
    title: usesSam() ? "Sam (Plan 9) pattern" : "",
    oninput: (e) => {
      if (e.target instanceof HTMLInputElement) {
        find2.query = e.target.value;
        find2.lastCount = null;
        refresh(true);
      }
    },
    onkeydown: (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        next(!e.shiftKey);
      }
    }
  });
  const status = h("span", { class: "find-status", role: "status", "aria-live": "polite" });
  const prev = h("button", { type: "button", class: "iconbtn", "aria-label": "Previous Match", title: "Previous Match (⇧⌘G)", onclick: () => next(false) }, "▲");
  const nxt = h("button", { type: "button", class: "iconbtn", "aria-label": "Next Match", title: "Next Match (⌘G)", onclick: () => next(true) }, "▼");
  const opts = h("button", { type: "button", class: "iconbtn", "aria-label": "Find Options", title: "Replace, Match Case, and the sam command line" }, "⋯");
  attachMenu(opts, () => {
    const items = [
      { label: "Replace", checked: find2.showsReplace, action: () => {
        find2.showsReplace = !find2.showsReplace;
        build();
        if (find2.showsReplace)
          els2.replace?.focus();
        refresh();
      } },
      usesSam() ? { label: "Sam Command Line", checked: find2.showsCommand, action: () => {
        find2.showsCommand = !find2.showsCommand;
        build();
        if (find2.showsCommand)
          els2.command?.focus();
        refresh();
      } } : null,
      { label: "Match Case", checked: find2.matchCase, action: () => {
        find2.matchCase = !find2.matchCase;
        refresh(true);
      } },
      { separator: true },
      usesSam() ? { label: "Sam Tutorial…", action: () => samTutorial() } : null,
      { label: "Pattern Syntax: " + syntaxName() + "…", action: () => appRef().openSettings() }
    ];
    return items.filter((item) => item !== null);
  }, { align: "end" });
  const close = h("button", { type: "button", class: "iconbtn", "aria-label": "Close Find", title: "Close Find (Escape)", onclick: closeFind }, "✕");
  box.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "⌕"), q, status, prev, nxt, opts, close));
  Object.assign(els2, { query: q, status, prev, next: nxt });
  if (find2.showsReplace) {
    const r = h("input", {
      type: "text",
      value: find2.replacement,
      "aria-label": "Replace with",
      autocomplete: "off",
      spellcheck: "false",
      placeholder: { sam: "Replace (\\1, &, \\n)", vim: "Replace (\\1, &, \\u, \\r)", plain: "Replace" }[syntax()],
      oninput: (e) => {
        if (e.target instanceof HTMLInputElement)
          find2.replacement = e.target.value;
      },
      onkeydown: (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          replaceCurrent();
        }
      }
    });
    const one = h("button", { type: "button", class: "button", onclick: replaceCurrent }, "Replace");
    const all = h("button", { type: "button", class: "button", "aria-label": "Replace All", onclick: replaceAllMatches }, "All");
    const count = h("span", { class: "find-status" });
    box.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "⇄"), r, one, all), count);
    Object.assign(els2, { replace: r, replaceOne: one, replaceAll: all, count });
  } else
    els2.replace = q;
  if (usesSam() && find2.showsCommand) {
    const run = h("button", { type: "button", class: "button", title: "Run the sam command (⌘Return)", disabled: !find2.command.trim(), onclick: runCommand }, "Run");
    const c = h("textarea", {
      rows: "1",
      "aria-label": "Sam command",
      placeholder: "Sam command, for example ,x/teh/c/the/",
      spellcheck: "false",
      autocomplete: "off",
      autocapitalize: "off",
      title: "Runs on the selection. Put a comma first to use the whole file.",
      oninput: (e) => {
        if (!(e.target instanceof HTMLTextAreaElement))
          return;
        find2.command = e.target.value;
        e.target.rows = Math.min(MAX_COMMAND_ROWS, e.target.value.split(`
`).length);
        run.disabled = !find2.command.trim();
      },
      onkeydown: (e) => {
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
          e.preventDefault();
          if (find2.command.trim())
            runCommand();
        }
      }
    });
    c.value = find2.command;
    const cstatus = h("div", { class: "find-status", role: "status" });
    const out = h("pre", { class: "sam-output", "aria-label": "Command output", hidden: true });
    box.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "»"), c, run), cstatus, out);
    Object.assign(els2, { command: c, cstatus, out });
  } else
    els2.command = q;
  box.onkeydown = (e) => {
    if (e.key === "Escape") {
      e.preventDefault();
      closeFind();
    }
  };
  render();
}
function render() {
  if (!bar || bar.hidden && !find2.open)
    return;
  if (!els2.status || !els2.prev || !els2.next)
    return;
  els2.status.textContent = statusText();
  els2.status.classList.toggle("error", !!find2.error);
  els2.prev.disabled = els2.next.disabled = !find2.matches.length;
  if (find2.showsReplace && els2.replaceOne && els2.replaceAll && els2.count) {
    els2.replaceOne.disabled = els2.replaceAll.disabled = !find2.matches.length;
    els2.count.textContent = find2.lastCount === null ? "" : `${find2.lastCount} ${find2.lastCount === 1 ? "replacement" : "replacements"}.`;
  }
  if (els2.cstatus && els2.out) {
    els2.cstatus.textContent = find2.commandError || find2.commandStatus;
    els2.cstatus.classList.toggle("error", !!find2.commandError);
    els2.out.hidden = !find2.commandOutput.length;
    els2.out.textContent = find2.commandOutput.join(`
`);
  }
}
var refreshTimer;
function textChanged() {
  if (!find2.open || !find2.query)
    return;
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(() => refresh(false), REFRESH_DELAY_MS);
}
function syntaxChanged() {
  if (find2.open) {
    build();
    refresh(true);
  }
}
var NUMBERS = `Air 343 m/s
Water 1480 m/s
Steel 5960 m/s
`;
var LESSONS = [
  ["1. Dot and addresses", [
    "Dot is the selected text. Each command works on dot.",
    "An address selects new text. `2` is line 2. `,` is the whole file. `$` is the end.",
    "`/word/` is the next match after dot. `?word?` is the match before dot.",
    "Type `1,2` or `/Steel/` below. The highlight shows the new dot."
  ], NUMBERS, "2"],
  ["2. Plan 9 patterns", [
    "A pattern finds text. `.` is any character. `[0-9]` is one digit. `[^ ]` is any character but a space.",
    "`*` is zero or more. `+` is one or more. `?` is zero or one. `|` separates alternatives. `( )` makes a group.",
    "`^` is the start of a line. `$` is the end of a line. A `\\` before a character finds that character.",
    "Sam takes the longest match at the first position. So `/a|ab/` finds `ab`, not `a`."
  ], NUMBERS, "/[0-9]+/"],
  ["3. Change text", [
    "`c/text/` changes dot to the text. `a/text/` adds text after dot. `i/text/` adds text before dot. `d` deletes dot.",
    "An address can come before the command. `/Water/c/Sea water/` changes the next Water.",
    "In the text, `\\n` is a new line."
  ], NUMBERS, "/Water/c/Sea water/"],
  ["4. Loop with x", [
    "`x/pattern/ command` runs the command on each match in dot.",
    "`,x/teh/c/the/` corrects each teh in the file. The comma makes dot the whole file.",
    "This is the main idea of sam: first select, then change."
  ], `teh cat sat on teh mat
teh end
`, ",x/teh/c/the/"],
  ["5. Lines and guards", [
    "`x` without a pattern runs the command on each line.",
    "`g/pattern/ command` runs the command only when dot has a match. `v/pattern/ command` runs it when dot has no match.",
    "`,x g/Steel/d` deletes each line with Steel. `,x v/Air/d` keeps only the lines with Air."
  ], NUMBERS, ",x g/Steel/d"],
  ["6. Substitute with groups", [
    "`s/pattern/text/` replaces the first match in dot. Add `g` at the end to replace all matches.",
    "In the text, `&` is the full match. `\\1` to `\\9` are the groups in `( )`.",
    "This command puts each number before its name."
  ], NUMBERS, ",s/([A-Za-z]+) ([0-9]+)/\\2 \\1/g"],
  ["7. Between the matches with y", [
    "`y/pattern/ command` runs the command on the text between the matches.",
    "Here, `y` selects each item between the commas, and `c` changes it."
  ], "red, green, blue", ",y/, / c/color/"],
  ["8. Loops in loops, and braces", [
    "A loop can contain a loop. `,x/[A-Za-z]+ [0-9]+/ x/[0-9]+/ p` shows the numbers after a word.",
    "`{ }` runs several commands on the same dot. Put each command on its own line.",
    "Sam makes all changes at the end, together. Undo removes them in one step."
  ], NUMBERS, `,x/[0-9]+/ {
i/[/
a/]/
}`],
  ["9. Show results", [
    "`p` shows the text of dot. `=` shows the line numbers and the character positions of dot.",
    "Use `p` to check a loop before you change text."
  ], NUMBERS, ",x/[A-Z][a-z]+/ p"]
];
var REFERENCE = [
  [",", "The whole file"],
  ["n  #n", "Line n; the position after n characters"],
  ["/re/  ?re?", "The next match; the match before dot"],
  ["a,b  a;b", "From a to b; b starts at a"],
  [".  $  +  -", "Dot; the end; the next line; the line before"],
  ["x/re/ cmd", "Run cmd on each match"],
  ["y/re/ cmd", "Run cmd between the matches"],
  ["g/re/ cmd", "Run cmd if dot has a match"],
  ["v/re/ cmd", "Run cmd if dot has no match"],
  ["s/re/text/g", "Replace matches; & and \\1 to \\9"],
  ["c a i", "Change, append, insert: c/text/"],
  ["d", "Delete dot"],
  ["m addr  t addr", "Move or copy dot to after addr"],
  ["p  =", "Show the text; show the line numbers"],
  ["{ … }", "Several commands, one on each line"]
];
function richText(s) {
  const p = h("p", {});
  s.split("`").forEach((part, i) => p.append(i % 2 ? h("code", { text: part }) : part));
  return p;
}
function lesson([title, text, sample, command]) {
  const result = h("div", {});
  const input = h("textarea", { rows: "1", "aria-label": "Command for " + title, spellcheck: "false", autocapitalize: "off", class: "lesson-cmd" });
  input.value = command;
  const reset = h("button", { type: "button", class: "button", hidden: true, onclick: () => {
    input.value = command;
    update();
  } }, "Reset");
  function update() {
    reset.hidden = input.value === command;
    input.rows = Math.min(MAX_COMMAND_ROWS, input.value.split(`
`).length);
    result.replaceChildren();
    let r;
    try {
      r = sam(input.value, sample, 0, 0, false);
    } catch (e) {
      r = { error: messageOf2(e) };
    }
    if ("error" in r) {
      result.append(h("p", { class: "error-text", role: "status", text: "⚠ " + r.error }));
      return;
    }
    const t = r.text === null ? sample : r.text;
    const a = utf16Offset(t, r.selection[0]), b = utf16Offset(t, r.selection[1]);
    const code = h("pre", { class: "code", "aria-label": "Result" }, t.slice(0, a), b > a ? h("mark", { text: t.slice(a, b) }) : null, t.slice(b));
    result.append(h("p", { class: "cap-label", text: "Result" }), code);
    if (r.printed.length)
      result.append(h("pre", { class: "code", "aria-label": "Output", text: r.printed.join(`
`) }));
    result.append(footnote(r.summary));
  }
  input.addEventListener("input", update);
  update();
  return section(title, h("div", { class: "group" }, text.map(richText), h("p", { class: "cap-label", text: "Sample text" }), h("pre", { class: "code", "aria-label": "Sample text", text: sample }), h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "»"), input, reset), result));
}
function samTutorial() {
  const body = h("div", {}, section("Structural editing", h("div", { class: "group" }, h("p", { text: "Sam is the text editor of Plan 9. Its commands select text first, then change it. In Marklove, open Find and use the Sam pattern syntax (Settings). Type a command in the command line and select Run." }))), LESSONS.map(lesson), section("Reference", h("div", { class: "group" }, REFERENCE.map(([k, v]) => h("div", { class: "find-row" }, h("strong", { class: "code-key", style: { fontFamily: "var(--mono)", minWidth: "9em" }, text: k }), h("span", { class: "row-hint", text: v })))), footnote("Marklove does not have sam's file commands, such as w, e, and q. Marklove saves each change for you.")));
  dialog({
    title: "Sam Tutorial",
    body,
    wide: true,
    buttons: [
      { label: "Use Sam in Find", cancel: true, disabled: appRef().readOnly(), action: () => {
        setSetting("findSyntax", "sam");
        find2.showsCommand = true;
        setTimeout(() => openFind({ command: true }), 0);
      } },
      { label: "Done", primary: true }
    ]
  });
}

// src/pages.ts
var LAYOUT_SLIDES = 0;
var LAYOUT_VIDEO = 1;
var LAYOUT_ARTICLE = 2;
var LAYOUT_HANDOUT = 3;
var LAYOUT_POSTER = 4;
var LY_ALL = 0;
var LY_BASE = 1;
var LY_NEW = 2;
var LY_LEAVE = 3;
var LY_GROW = 4;
var POSTER_SIZES = ["a0", "a1", "in48x36", "in42x42"];
var decoder2 = new TextDecoder;
var core = null;
function record(v, what) {
  if (!isRecord(v))
    throw new Error("Bad " + what);
  return v;
}
function num(o, k) {
  const v = o[k];
  if (typeof v !== "number")
    throw new Error("Bad number " + k);
  return v;
}
function str(o, k) {
  const v = o[k];
  if (typeof v !== "string")
    throw new Error("Bad string " + k);
  return v;
}
function list(o, k) {
  const v = o[k];
  if (!Array.isArray(v))
    throw new Error("Bad list " + k);
  return v;
}
function parseTimeline(v) {
  const o = record(v, "timeline");
  return {
    voice: str(o, "voice"),
    segments: list(o, "segments").map((s) => {
      const r = record(s, "segment");
      return { page: num(r, "page"), step: num(r, "step"), start: num(r, "start"), duration: num(r, "duration") };
    }),
    cues: list(o, "cues").map((c) => {
      const r = record(c, "cue");
      return { start: num(r, "start"), end: num(r, "end"), text: str(r, "text") };
    })
  };
}
function parseLayout(v) {
  const o = record(v, "layout");
  return {
    pages: list(o, "pages").map((p) => {
      const r = record(p, "page");
      return { width: num(r, "width"), height: num(r, "height"), steps: num(r, "steps"), title: str(r, "title"), text: str(r, "text") };
    }),
    warnings: str(o, "warnings").split(`
`).filter(Boolean),
    timeline: o["timeline"] === undefined ? null : parseTimeline(o["timeline"])
  };
}
function parseRegions(v) {
  if (!Array.isArray(v))
    throw new Error("Bad regions");
  return v.map((x) => {
    const r = record(x, "region");
    return {
      x: num(r, "x"),
      y: num(r, "y"),
      scale: num(r, "scale"),
      width: num(r, "width"),
      height: num(r, "height"),
      colors: num(r, "colors"),
      minArea: num(r, "minArea"),
      tolerance: num(r, "tolerance"),
      label: str(r, "label")
    };
  });
}
var canvas2d = null;
function measure(text, font) {
  canvas2d ??= must(document.createElement("canvas").getContext("2d"), "2D canvas");
  canvas2d.font = font;
  return canvas2d.measureText(text).width;
}
var mathCache = new Map;
var mathHost = null;
function styleOf(el) {
  return "style" in el && el.style instanceof CSSStyleDeclaration ? el.style : null;
}
function mathMetric(latex, display, which) {
  const key = display + `
` + latex;
  let m = mathCache.get(key);
  if (!m) {
    if (!mathHost) {
      mathHost = document.createElement("div");
      mathHost.setAttribute("aria-hidden", "true");
      mathHost.style.cssText = "position:absolute;left:-10000px;top:0;visibility:hidden";
      document.body.append(mathHost);
    }
    const box = document.createElement("div");
    box.style.cssText = "font-family:KpMath,math;line-height:0;white-space:nowrap;width:max-content;font-size:100px";
    box.innerHTML = math(latex, display === 1);
    const base = document.createElement("span");
    base.style.cssText = "display:inline-block;width:0;height:0";
    box.append(base);
    mathHost.append(box);
    const el = box.querySelector("math") || box.firstElementChild;
    const elStyle = el ? styleOf(el) : null;
    if (elStyle && display === 1)
      elStyle.display = "inline math";
    const b = box.getBoundingClientRect(), r = el ? el.getBoundingClientRect() : b;
    const y = base.getBoundingClientRect().bottom;
    m = el ? [r.width / 100, (y - r.top) / 100, (r.bottom - y) / 100, (y - (display === 1 ? r.top : b.top)) / 100] : [-1, -1, -1, -1];
    box.remove();
    mathCache.set(key, m);
  }
  return m[which] ?? -1;
}
async function loadFonts() {
  const st = document.createElement("style");
  st.textContent = faceCSS(fontURL, PAGE_FACES);
  document.head.append(st);
  await Promise.all(PAGE_FACES.map(([family, , style, weight]) => Promise.all(weight.split(" ").map((w) => document.fonts.load(`${style} ${w} 16px "${family}"`).catch(() => null)))));
}
async function load2() {
  if (core)
    return;
  await loadFonts();
  core = await instance({ mlMeasure: measure, mlMath: mathMetric });
}
var callCore = (name, inputs, ...ints) => must(core, "page core")(name, inputs, ...ints);
var text3 = (name, inputs, ...ints) => decoder2.decode(callCore(name, inputs, ...ints));
var isVideo = (path) => /\.(mp4|m4v|mov|webm)$/i.test(path);
function videoElement(blob) {
  const v = document.createElement("video");
  v.muted = true;
  v.preload = "auto";
  v.src = URL.createObjectURL(blob);
  return new Promise((res) => {
    v.onloadeddata = () => res(v);
    v.onerror = () => res(null);
  });
}
async function media(ctx) {
  const paths = Object.keys(ctx.assetURLs);
  const sizes = [], urls = [];
  for (const path of paths) {
    const blob = ctx.assets[path];
    let url = "";
    if (!blob) {
      urls.push(url);
      continue;
    }
    try {
      if (isVideo(path)) {
        const v = await videoElement(blob);
        if (v) {
          const c = document.createElement("canvas");
          c.width = v.videoWidth;
          c.height = v.videoHeight;
          must(c.getContext("2d"), "2D canvas").drawImage(v, 0, 0);
          url = c.toDataURL("image/jpeg", 0.9);
          sizes.push(`${path}	${v.videoWidth}	${v.videoHeight}
`);
          URL.revokeObjectURL(v.src);
        }
      } else {
        const bm = await createImageBitmap(blob);
        sizes.push(`${path}	${bm.width}	${bm.height}
`);
        bm.close();
        url = await readDataURL(blob);
      }
    } catch {
      url = "";
    }
    urls.push(url);
  }
  return { sizes: sizes.join(""), urls };
}
function layout(ctx, m, kind, { takahashi = false, appearance = "", a = 0, b = 0, durations = "" } = {}) {
  const args = docArgs({ source: ctx.source, assets: ctx.assetURLs, appearance });
  const opts = (takahashi ? O_TAKAHASHI : 0) | O_NARRATION | O_PUBLIC_NOTES;
  return parseLayout(JSON.parse(text3("ml_layout", [...args, m.sizes, durations], kind, opts, a, b)));
}
function podcast(ctx, durations) {
  const args = docArgs({ source: ctx.source, assets: ctx.assetURLs });
  return parseTimeline(JSON.parse(text3("ml_podcast", [...args, "", durations], O_NARRATION)));
}
var pageSVG = (page, step, layer = LY_ALL, progress = 1, scale = 1) => text3("ml_page_svg", [], page, step, layer, progress, scale);
function resolve(svg, m, fonts) {
  return svg.replace("/*ml-fonts*/", fonts).replace(/href="(asset|poster):(-?\d+)"/g, (_, _kind, i) => `href="${m.urls[+i] || ""}"`);
}
async function raster(svg, w, h) {
  const img = new Image;
  img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
  await img.decode();
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  must(c.getContext("2d"), "2D canvas").drawImage(img, 0, 0, w, h);
  return c;
}
var toBlob = (c, type) => new Promise((res, rej) => {
  c.toBlob((b) => {
    if (b)
      res(b);
    else
      rej(new Error("The canvas has no image."));
  }, type);
});
var slideName = (i, n, ext) => `Slide ${String(i + 1).padStart(Math.max(2, String(n).length), "0")}.${ext}`;
function descriptions(pages, ext) {
  return pages.map((p, i) => slideName(i, pages.length, ext).replace(/\.\w+$/, "") + `
` + p.text).join(`

`) + `
`;
}
async function slidesPNG(ctx, opt, progress) {
  const m = await media(ctx);
  const fonts = await embeddedFonts(PAGE_FACES);
  const { pages, warnings } = layout(ctx, m, LAYOUT_SLIDES, opt);
  const files = [];
  for (const [i, page] of pages.entries()) {
    progress?.(i / pages.length);
    const s = 1920 / page.width;
    const w = 1920, hgt = Math.round(page.height * s);
    files.push([slideName(i, pages.length, "png"), await toBlob(await raster(resolve(pageSVG(i, -1, LY_ALL, 1, s), m, fonts), w, hgt), "image/png")]);
  }
  files.push(["Descriptions.txt", descriptions(pages, "png")]);
  return { files, notes: warnings };
}
async function slidesSVG(ctx, opt, progress) {
  const m = await media(ctx);
  const fonts = await embeddedFonts(PAGE_FACES);
  const { pages, warnings } = layout(ctx, m, LAYOUT_SLIDES, opt);
  const files = [];
  for (let i = 0;i < pages.length; i++) {
    progress?.(i / pages.length);
    let svg = text3("ml_export_svg", [], i);
    const regions = parseRegions(JSON.parse(text3("ml_regions", [])));
    const traced = [];
    for (const [k, r] of regions.entries()) {
      const c = await raster(resolve(text3("ml_region_svg", [], k), m, fonts), r.width, r.height);
      const px = must(c.getContext("2d"), "2D canvas").getImageData(0, 0, r.width, r.height).data;
      traced.push(text3("ml_trace_arg", [new Uint8Array(px.buffer), r.label], r.width, r.height, r.colors, r.minArea, r.tolerance, r.x, r.y, r.scale));
    }
    svg = svg.replace(/<!--ml-region (\d+)-->\n/g, (_, k) => traced[+k] || "");
    files.push([slideName(i, pages.length, "svg"), new Blob([svg], { type: "image/svg+xml" })]);
  }
  files.push(["Descriptions.txt", descriptions(pages, "svg")]);
  return { files, notes: warnings };
}
async function printHTML(ctx, kind, opt) {
  const m = await media(ctx);
  const urls = m.urls.slice();
  Object.entries(ctx.assetURLs).forEach(([path, u], i) => {
    if (!isVideo(path))
      urls[i] = u;
  });
  const { pages, warnings } = layout(ctx, m, kind, opt);
  const w = pages[0]?.width || 960, hgt = pages[0]?.height || 540;
  const body = pages.map((_, i) => resolve(pageSVG(i, -1), { urls }, "").replace(/^<svg /, `<svg class="page" `)).join("");
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${ctx.title.replace(/[<&]/g, "")}</title>
<style>${faceCSS(fontURL, PAGE_FACES)}@page{size:${w}pt ${hgt}pt;margin:0}html,body{margin:0;padding:0}
svg.page{display:block;width:${w}pt;height:${hgt}pt;break-after:page;page-break-after:always}
svg.page:last-child{break-after:auto;page-break-after:auto}</style></head><body>${body}</body></html>`;
  return { html, notes: warnings };
}
function captions(ctx, m, { takahashi = false, durations = "", srt = false } = {}) {
  const args = docArgs({ source: ctx.source, assets: ctx.assetURLs });
  return text3("ml_text", [...args, m.sizes, durations], srt ? TEXT_SRT : TEXT_VTT, takahashi ? O_TAKAHASHI : 0);
}
var mp4Head = (inputs, ...ints) => callCore("ml_mp4", inputs, ...ints);

// src/voice.ts
var KOKORO = "https://cdn.jsdelivr.net/npm/kokoro-js@1.2.1/dist/kokoro.web.js";
var MODEL = "onnx-community/Kokoro-82M-v1.0-ONNX";
var CACHE = "transformers-cache";
var QUANTIZED_MODEL_SUFFIX = "/onnx/model_quantized.onnx";
var DEFAULT_VOICE = "af_heart";
var SAMPLE_RATE = 24000;
var SIZE_TEXT = "about 90 MB";
var SAMPLE_TEXT = "This is the voice of your narration. It speaks the text of your slides.";
var MIX_TAIL_SECONDS = 0.5;
function method(owner, name) {
  const fn = owner[name];
  if (typeof fn !== "function")
    throw new Error("The voice library has no " + name + ".");
  return (...args) => Reflect.apply(fn, owner, args);
}
function toNarrator(v) {
  if (!isRecord(v) || !isRecord(v["voices"]))
    throw new Error("The voice library gave an unknown voice model.");
  const voices = v["voices"];
  const generate = method(v, "generate");
  return {
    voices,
    async generate(text, voice) {
      const out = await generate(text, { voice });
      if (!isRecord(out) || !(out["audio"] instanceof Float32Array))
        throw new Error("The voice gave no audio.");
      return Float32Array.from(out["audio"]);
    }
  };
}
var tts = null;
var loading = null;
function load3(progress) {
  if (tts)
    return Promise.resolve(tts);
  if (!loading) {
    loading = (async () => {
      const lib = await import(KOKORO);
      if (!isRecord(lib) || !isRecord(lib["KokoroTTS"]))
        throw new Error("The voice library did not load.");
      const files = new Map;
      const model = await method(lib["KokoroTTS"], "from_pretrained")(MODEL, {
        dtype: "q8",
        device: "wasm",
        progress_callback: (e) => {
          if (!isRecord(e) || e["status"] !== "progress")
            return;
          const { file, loaded, total } = e;
          if (typeof file !== "string" || typeof loaded !== "number" || typeof total !== "number" || !total)
            return;
          files.set(file, [loaded, total]);
          let a = 0, b = 0;
          for (const [l, t] of files.values()) {
            a += l;
            b += t;
          }
          if (progress)
            progress(a / b);
        }
      });
      tts = toNarrator(model);
      return tts;
    })().catch((e) => {
      loading = null;
      throw e;
    });
  }
  return loading;
}
async function installed() {
  if (tts)
    return true;
  try {
    const c = await caches.open(CACHE);
    return (await c.keys()).some((r) => r.url.includes(MODEL + "/") && r.url.endsWith(QUANTIZED_MODEL_SUFFIX));
  } catch {
    return false;
  }
}
async function remove() {
  tts = null;
  loading = null;
  try {
    await caches.delete(CACHE);
  } catch {
    return;
  }
}
function voiceFor(name) {
  return tts && name && tts.voices[name] ? name : DEFAULT_VOICE;
}
async function synthesize(text, voice) {
  const t = await load3();
  return t.generate(text, voiceFor(voice));
}
var spoken = new Map;
function forget() {
  spoken = new Map;
}
async function clips(sentences, voice, progress) {
  const out = new Map;
  const unique = [...new Set(sentences)];
  for (const [k, sentence] of unique.entries()) {
    const key = voiceFor(voice) + `
` + sentence;
    let audio = spoken.get(key);
    if (!audio) {
      audio = await synthesize(sentence, voice);
      spoken.set(key, audio);
    }
    out.set(sentence, audio);
    if (progress)
      progress((k + 1) / unique.length);
  }
  const durations = [...out].map(([s, a]) => `${s}	${(a.length / SAMPLE_RATE).toFixed(4)}
`).join("");
  return { clips: out, durations };
}
function mix(cues, clips, duration) {
  const out = new Float32Array(Math.floor((duration + MIX_TAIL_SECONDS) * SAMPLE_RATE));
  for (const c of cues) {
    const clip = clips.get(c.text);
    if (!clip)
      continue;
    const start = Math.max(0, Math.floor(c.start * SAMPLE_RATE));
    for (let i = 0;i < clip.length && start + i < out.length; i++)
      out[start + i] = (out[start + i] ?? 0) + (clip[i] ?? 0);
  }
  for (let i = 0;i < out.length; i++)
    out[i] = Math.max(-1, Math.min(1, out[i] ?? 0));
  return out;
}
async function playSample(voice) {
  const a = await synthesize(SAMPLE_TEXT, voice);
  const ctx = new AudioContext({ sampleRate: SAMPLE_RATE });
  const buf = ctx.createBuffer(1, a.length, SAMPLE_RATE);
  buf.copyToChannel(a, 0);
  const src = ctx.createBufferSource();
  src.buffer = buf;
  src.connect(ctx.destination);
  await new Promise((res) => {
    src.onended = () => res();
    src.start();
  });
  await ctx.close();
}

// src/video.ts
var W = 1920;
var H = 1080;
var FPS = 30;
var TRANSITION = 0.6;
var PLOT_DRAW = 1.4;
var BITRATE = 6000000;
var AUDIO_BITRATE = 64000;
var SCALE = 600;
var A_NONE = 0;
var A_AAC = 1;
var A_OPUS = 2;
var RATE = 48000;
function isFrameTrack(t) {
  return "requestFrame" in t && typeof t.requestFrame === "function";
}
function hold(frames, start, end, draw) {
  let t = start, last = -1;
  const final = end - 1 / 30;
  while (t < final - 0.001) {
    frames.push([t, draw]);
    last = t;
    t += 1;
  }
  if (final - last > 0.5 / 30)
    frames.push([Math.max(start, final), draw]);
}
function frameList(pages, timeline, animated, m, fonts) {
  const cache = new Map;
  const layer = (page, step, ly, progress = 1) => {
    const key = [page, step, ly, progress].join(" ");
    let drawn = cache.get(key);
    if (!drawn) {
      if (cache.size > 64)
        cache.clear();
      const info = must(pages[page], "page " + page);
      drawn = raster(resolve(pageSVG(page, step, ly, progress, W / info.width), m, fonts), W, H);
      cache.set(key, drawn);
    }
    return drawn;
  };
  const frames = [];
  const segs = timeline.segments;
  segs.forEach((seg, k) => {
    const end = seg.start + seg.duration;
    const all = async (ctx) => ctx.drawImage(await layer(seg.page, seg.step, LY_ALL), 0, 0);
    if (!animated) {
      hold(frames, seg.start, end, all);
      return;
    }
    const fade = seg.step > 0 || k === 0 || segs[k - 1]?.page !== seg.page;
    const hasPlot = pageSVG(seg.page, seg.step, LY_GROW).replace(/^[\s\S]*?<\/style>\n(<filter[\s\S]*?<\/filter>\n)?/, "") !== `</svg>
`;
    const n = Math.round(TRANSITION * FPS), drawN = hasPlot ? Math.round(PLOT_DRAW * FPS) : n;
    const total = Math.min(Math.max(n, drawN), Math.floor(seg.duration * FPS) - 1);
    for (let f = 0;f < Math.max(total, 0); f++) {
      const t = f / Math.max(n, 1), plotT = Math.min(f / Math.max(drawN, 1), 1);
      const ease = t < 1 ? 0.5 - Math.cos(Math.min(t, 1) * Math.PI) / 2 : 1;
      frames.push([seg.start + f / FPS, async (ctx) => {
        ctx.drawImage(await layer(seg.page, seg.step, LY_BASE), 0, 0);
        ctx.globalAlpha = fade ? ease : 1;
        ctx.drawImage(await layer(seg.page, seg.step, LY_NEW), 0, 0);
        if (plotT >= 1)
          ctx.drawImage(await layer(seg.page, seg.step, LY_GROW), 0, 0);
        ctx.globalAlpha = 1;
        if (plotT < 1)
          ctx.drawImage(await layer(seg.page, seg.step, LY_GROW, Math.round(plotT * 1000) / 1000), 0, 0);
        if (seg.step > 0 && ease < 1) {
          ctx.globalAlpha = 1 - ease;
          ctx.drawImage(await layer(seg.page, seg.step, LY_LEAVE), 0, 0);
          ctx.globalAlpha = 1;
        }
      }]);
    }
    hold(frames, seg.start + Math.max(total, 0) / FPS, end, all);
  });
  return frames;
}
var u32 = (values) => new Uint8Array(new Uint32Array(values).buffer);
function bytesOf(d) {
  return Uint8Array.from(ArrayBuffer.isView(d) ? new Uint8Array(d.buffer, d.byteOffset, d.byteLength) : new Uint8Array(d));
}
async function videoConfig() {
  if (typeof VideoEncoder === "undefined")
    return null;
  for (const codec of ["avc1.640028", "avc1.4d0028", "avc1.42e028"]) {
    const c = { codec, width: W, height: H, bitrate: BITRATE, framerate: FPS, avc: { format: "avc" } };
    try {
      if ((await VideoEncoder.isConfigSupported(c)).supported)
        return c;
    } catch {}
  }
  return null;
}
async function encodeVideo(config, frames, progress) {
  const chunks = [], sizes = [], keys = [], times = [];
  const state = { avcC: null, error: null };
  const enc = new VideoEncoder({
    output: (chunk, meta) => {
      const b = new Uint8Array(chunk.byteLength);
      chunk.copyTo(b);
      chunks.push(b);
      sizes.push(b.length);
      keys.push(chunk.type === "key" ? 1 : 0);
      times.push(chunk.timestamp);
      const description = meta?.decoderConfig?.description;
      if (description)
        state.avcC = bytesOf(description);
    },
    error: (e) => {
      state.error = e;
    }
  });
  enc.configure(config);
  const canvas = new OffscreenCanvas(W, H), ctx = must(canvas.getContext("2d"), "2D canvas");
  let last = -1, lastKey = -10;
  const used = [];
  for (const [i, [time, draw]] of frames.entries()) {
    if (time <= last + 0.001)
      continue;
    last = time;
    await draw(ctx);
    const frame = new VideoFrame(canvas, { timestamp: Math.round(time * 1e6) });
    const key = time - lastKey >= 2;
    if (key)
      lastKey = time;
    enc.encode(frame, { keyFrame: key });
    frame.close();
    used.push(time);
    while (enc.encodeQueueSize > 4)
      await new Promise((r) => enc.addEventListener("dequeue", () => r(), { once: true }));
    if (state.error)
      throw state.error;
    if (i % 10 === 0)
      progress?.(i / frames.length);
  }
  await enc.flush();
  enc.close();
  if (state.error)
    throw state.error;
  return { chunks, sizes, keys, times: used, avcC: state.avcC };
}
async function audioConfig() {
  if (typeof AudioEncoder === "undefined")
    return null;
  for (const [codec, id] of [["mp4a.40.2", A_AAC], ["opus", A_OPUS]]) {
    const c = { codec, sampleRate: RATE, numberOfChannels: 1, bitrate: AUDIO_BITRATE };
    try {
      if ((await AudioEncoder.isConfigSupported(c)).supported)
        return [c, id];
    } catch {}
  }
  return null;
}
function upsample(a) {
  const out = new Float32Array(a.length * 2);
  for (let i = 0;i < a.length; i++) {
    const cur = a[i] ?? 0;
    out[2 * i] = cur;
    out[2 * i + 1] = i + 1 < a.length ? (cur + (a[i + 1] ?? 0)) / 2 : cur;
  }
  return out;
}
async function encodeAudio([config, codec], samples) {
  const rate = config.sampleRate;
  const pcm = upsample(samples);
  const chunks = [], sizes = [], durs = [];
  const state = { desc: null, error: null };
  const enc = new AudioEncoder({
    output: (chunk, meta) => {
      const b = new Uint8Array(chunk.byteLength);
      chunk.copyTo(b);
      chunks.push(b);
      sizes.push(b.length);
      durs.push(chunk.duration ? Math.round(chunk.duration * rate / 1e6) : codec === A_AAC ? 1024 : 960);
      const description = meta?.decoderConfig?.description;
      if (description)
        state.desc = bytesOf(description);
    },
    error: (e) => {
      state.error = e;
    }
  });
  enc.configure(config);
  const step = rate;
  for (let i = 0;i < pcm.length; i += step) {
    const part = pcm.slice(i, i + step);
    const data = new AudioData({ format: "f32-planar", sampleRate: rate, numberOfFrames: part.length, numberOfChannels: 1, timestamp: Math.round(i * 1e6 / rate), data: part });
    enc.encode(data);
    data.close();
  }
  await enc.flush();
  enc.close();
  if (state.error)
    throw state.error;
  return { chunks, sizes, durs, desc: state.desc || new Uint8Array(0), codec, rate };
}
function mp4(video, audio, end) {
  const v = video || { chunks: [], sizes: [], keys: [], times: [], avcC: new Uint8Array(0) };
  const ticks = v.times.map((t) => Math.round(t * SCALE));
  const vdurs = ticks.map((t, i) => Math.max(1, (i + 1 < ticks.length ? ticks[i + 1] ?? 0 : Math.round(end * SCALE)) - t));
  const a = audio || { chunks: [], sizes: [], durs: [], desc: new Uint8Array(0), codec: A_NONE, rate: SAMPLE_RATE };
  const head = mp4Head([u32(v.sizes), u32(vdurs), new Uint8Array(v.keys), v.avcC || new Uint8Array(0), u32(a.sizes), u32(a.durs), a.desc], W, H, SCALE, a.codec, a.rate, a.rate, 1);
  return new Blob([Uint8Array.from(head), ...v.chunks, ...a.chunks], { type: video ? "video/mp4" : "audio/mp4" });
}
async function record2(frames, samples, end, progress) {
  const canvas = document.createElement("canvas");
  canvas.width = W;
  canvas.height = H;
  const ctx = must(canvas.getContext("2d"), "2D canvas");
  const tracks = [];
  let track = null;
  if (frames) {
    const videoTrack = must(canvas.captureStream(0).getVideoTracks()[0], "video track");
    if (!isFrameTrack(videoTrack))
      throw new Error("The canvas track cannot request frames.");
    track = videoTrack;
    tracks.push(videoTrack);
  }
  let ac = null, src = null;
  if (samples) {
    ac = new AudioContext({ sampleRate: SAMPLE_RATE });
    const buf = ac.createBuffer(1, samples.length, SAMPLE_RATE);
    buf.copyToChannel(samples.slice(), 0);
    src = ac.createBufferSource();
    src.buffer = buf;
    const dest = ac.createMediaStreamDestination();
    src.connect(dest);
    tracks.push(must(dest.stream.getAudioTracks()[0], "audio track"));
  }
  const type = frames ? "video/webm" : "audio/webm";
  const rec = new MediaRecorder(new MediaStream(tracks), { mimeType: MediaRecorder.isTypeSupported(type) ? type : "", videoBitsPerSecond: BITRATE, audioBitsPerSecond: AUDIO_BITRATE });
  const parts = [];
  rec.ondataavailable = (e) => {
    parts.push(e.data);
  };
  const stopped = new Promise((r) => {
    rec.onstop = () => r();
  });
  if (frames && track) {
    await frames[0]?.[1](ctx);
    track.requestFrame();
  }
  rec.start(1000);
  src?.start();
  const t0 = performance.now();
  const wait = (t) => new Promise((r) => setTimeout(r, Math.max(0, t * 1000 - (performance.now() - t0))));
  for (let i = 1;frames && track && i < frames.length; i++) {
    const [time, draw] = must(frames[i], "frame " + i);
    await draw(ctx);
    await wait(time);
    track.requestFrame();
    progress?.(time / end);
  }
  await wait(end);
  rec.stop();
  await stopped;
  await ac?.close();
  return new Blob(parts, { type: rec.mimeType || type });
}
var length = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s) % 60).padStart(2, "0")}`;
var endOf = (timeline) => timeline.segments.reduce((e, s) => Math.max(e, s.start + s.duration), 0);
var timelineOf = (lay) => must(lay.timeline, "video timeline");
async function video(ctx, opt, kind, progress) {
  const m = await media(ctx);
  const fonts = await embeddedFonts(PAGE_FACES);
  let lay = layout(ctx, m, LAYOUT_VIDEO, opt);
  let durations = "", samples = null, notes = [];
  if (kind === "narrated") {
    await load3();
    const first = timelineOf(lay);
    const c = await clips(first.cues.map((q) => q.text), first.voice, (p) => progress?.(p * 0.6));
    durations = c.durations;
    lay = layout(ctx, m, LAYOUT_VIDEO, { ...opt, durations });
    const timeline = timelineOf(lay);
    samples = mix(timeline.cues, c.clips, endOf(timeline));
    notes = [`Voice ${voiceFor(timeline.voice)}. Length ${length(endOf(timeline))}.`];
  }
  notes.push(...lay.warnings);
  const share = kind === "narrated" ? 0.6 : 0;
  const p = (x) => progress?.(share + x * (1 - share));
  const animated = kind === "manim" && !matchMedia("(prefers-reduced-motion: reduce)").matches;
  const timeline = timelineOf(lay);
  const frames = frameList(lay.pages, timeline, animated, m, fonts);
  const e = endOf(timeline);
  const vc = await videoConfig();
  const ac = samples ? await audioConfig() : null;
  let blob;
  if (vc && (!samples || ac)) {
    const v = await encodeVideo(vc, frames, p);
    blob = mp4(v, samples && ac ? await encodeAudio(ac, samples) : null, e);
  } else {
    blob = await record2(frames, samples, e, p);
  }
  const ext = blob.type.includes("webm") ? "webm" : "mp4";
  const files = [[ext, blob]];
  if (timeline.cues.length)
    files.push(["vtt", new Blob([captions(ctx, m, { ...opt, durations })], { type: "text/vtt;charset=utf-8" })]);
  return { files, notes };
}
async function podcast2(ctx, progress) {
  await load3();
  const first = podcast(ctx, "");
  const c = await clips(first.cues.map((q) => q.text), first.voice, (p) => progress?.(p * 0.9));
  const t = podcast(ctx, c.durations);
  const len = (t.cues.at(-1)?.end ?? 0) + 0.6;
  const samples = mix(t.cues, c.clips, len);
  const ac = await audioConfig();
  const blob = ac ? mp4(null, await encodeAudio(ac, samples), len) : await record2(null, samples, len, progress);
  return { files: [[blob.type.includes("webm") ? "webm" : "m4a", blob]], notes: [`Voice ${voiceFor(first.voice)}. Length ${length(len)}.`] };
}

// src/export.ts
var PRINT_NOTE = "Opens the print dialog. Select Save as PDF.";
var NO_VOICE = "Download the Kokoro voice in Settings first.";
var FORMAT_ROWS = [
  ["slidesPDF", "Slides and article", "Slides", "PDF", "Normal or Takahashi slides.", "print"],
  ["slidesPNG", "Slides and article", "Slide images", "PNG in ZIP", "One PNG image for each slide, 1920 pixels wide, with text descriptions.", ""],
  ["slidesSVG", "Slides and article", "Slide vector images", "SVG in ZIP", "One SVG file for each slide. Text, photos, equations, and plots become vector shapes.", ""],
  ["articlePDF", "Slides and article", "Article", "PDF", "A continuous, typeset article.", "print"],
  ["articleHTML", "Slides and article", "Article web page", "HTML", "The article as one web page. It works offline and keeps sliders.", ""],
  ["epub", "Slides and article", "Article book", "EPUB", "The article as an EPUB book for Books and other readers.", ""],
  ["handoutPDF", "Documents", "Handout with notes", "PDF", "Slides with public notes at the side, in black and white.", "print"],
  ["posterPDF", "Documents", "Conference poster", "PDF", "The article on one large page, in columns. A0, A1, 48 × 36 in, or 42 × 42 in.", "print"],
  ["articleMarkdown", "Documents", "Article Markdown", "Markdown", "The article text as one Markdown file.", ""],
  ["revisedMarkdown", "Documents", "Takahashi Markdown copy", "Markdown", "A copy with one Takahashi slide per paragraph. Your project does not change.", ""],
  ["interactiveHTML", "Interactive", "Interactive presentation", "HTML", "Works offline in a browser. Keeps reveals, sliders, and charts.", ""],
  ["video", "Audio and video", "Video", "MP4", "The presentation without sound.", ""],
  ["narratedVideo", "Audio and video", "Narrated video", "MP4", "The presentation with Kokoro narration and captions.", ""],
  ["manimVideo", "Audio and video", "Math animation video", "MP4", "Equations, plots, and steps with purposeful motion.", ""],
  ["podcast", "Audio and video", "Podcast", "M4A", "Kokoro narration as audio.", ""],
  ["narrationScript", "Text", "Narration script", "Text", "The exact text that narration speaks.", ""],
  ["transcript", "Text", "Transcript", "Text", "The narration text for readers.", ""],
  ["subtitles", "Text", "Subtitles", "WebVTT and SRT", "Timed captions for the video.", ""],
  ["promptText", "Text", "Prompt text for AI tools", "Text", "The Marklove rules and this project, to revise with an AI tool.", ""],
  ["presenterZIP", "Packages", "Presenter package", "ZIP", "Markdown, assets, and private notes.", ""],
  ["listenerZIP", "Packages", "Listener package", "ZIP", "Public content only. Private notes are removed.", ""],
  ["projectZIP", "Packages", "Project with version history", "ZIP", "The project folder with its Git history. Other Git apps can read it.", ""]
];
var FORMATS = FORMAT_ROWS.map(([id, group, name, label, summary, web]) => ({ id, group, name, label, summary, print: web === "print" }));
var formatById = (id) => must(FORMATS.find((f) => f.id === id), "format " + id);
var asFormatId = (s) => FORMATS.find((f) => f.id === s)?.id;
var WEIGHTS = { video: 6, manimVideo: 6, narratedVideo: 10, podcast: 4, slidesPDF: 2, articlePDF: 2, handoutPDF: 2, posterPDF: 2, slidesPNG: 3, slidesSVG: 5 };
var GROUPS = ["Slides and article", "Documents", "Interactive", "Audio and video", "Text", "Packages"];
var US = ["US", "CA", "MX", "PH"];
var region = () => (navigator.language || "").split("-")[1]?.toUpperCase() || "";
var PAPERS = ["a4", "letter"];
var ORIENTATIONS = ["portrait", "landscape"];
var APPEARANCES = ["system", "light", "dark"];
var STYLES = ["normal", "takahashi"];
function oneOf(list, v) {
  return list.find((x) => x === v);
}
var POSTERS = {
  a0: ["A0 (841 × 1189 mm)", 841, 1189, "mm"],
  a1: ["A1 (594 × 841 mm)", 594, 841, "mm"],
  in48x36: ["48 × 36 in", 36, 48, "in"],
  in42x42: ["42 × 42 in (square)", 42, 42, "in"]
};
var POSTER_KEYS = ["a0", "a1", "in48x36", "in42x42"];
function fileName(id, title, style) {
  const b = safeFileName(title);
  const st = style === "takahashi" ? "Takahashi" : "Normal";
  const names = {
    slidesPDF: `${b} – slides (${st}).pdf`,
    slidesPNG: `${b} – slides (${st}) PNG.zip`,
    slidesSVG: `${b} – slides (${st}) SVG.zip`,
    articlePDF: `${b} – article.pdf`,
    articleHTML: `${b} – article.html`,
    epub: `${b}.epub`,
    handoutPDF: `${b} – handout.pdf`,
    posterPDF: `${b} – poster.pdf`,
    interactiveHTML: `${b} – presentation.html`,
    articleMarkdown: `${b} – article.md`,
    revisedMarkdown: `${b} – Takahashi.md`,
    narrationScript: `${b} – narration script.txt`,
    transcript: `${b} – transcript.txt`,
    subtitles: `${b} – subtitles.vtt`,
    presenterZIP: `${b} – presenter.zip`,
    listenerZIP: `${b} – listener.zip`,
    projectZIP: `${b} – project with history.zip`,
    promptText: `${b} – prompt.txt`,
    video: `${b} – video.mp4`,
    narratedVideo: `${b} – narrated video.mp4`,
    manimVideo: `${b} – math animation.mp4`,
    podcast: `${b} – podcast.m4a`
  };
  return names[id];
}
function diagnostics(source, assetURLs = {}) {
  try {
    return { list: lint(source, assetURLs), error: "" };
  } catch (e) {
    return { list: [], error: e instanceof TooLarge ? e.message : "Marklove could not check the source. " + messageOf(e) };
  }
}
function affects(d, id, style) {
  if (!d.formats.includes(id))
    return false;
  if (d.style === "takahashi" && style !== "takahashi")
    return false;
  return true;
}
function lineOf(text, offset) {
  let n = 1;
  for (let i = text.indexOf(`
`);i >= 0 && i < offset; i = text.indexOf(`
`, i + 1))
    n++;
  return n;
}
function formatNames(d) {
  if (d.formats.length >= FORMATS.length - 2)
    return "All outputs";
  const names = FORMATS.filter((f) => d.formats.includes(f.id)).map((f) => f.name);
  return names.length > 3 ? `${names.slice(0, 3).join(", ")}, and ${names.length - 3} more` : names.join(", ");
}
function issueRow(d, text, goToSource) {
  const warn = d.severity === "warning";
  return h("div", { class: "issue" }, h("div", { class: "msg" }, h("span", { class: warn ? "status-warn" : "", "aria-label": warn ? "Warning" : "Information" }, warn ? "⚠ " : "ⓘ "), d.message), h("div", { class: "where", text: `Line ${lineOf(text, d.start)} · ${formatNames(d)}` }), d.detail ? h("details", {}, h("summary", { text: "More" }), h("p", { text: d.detail })) : null, h("button", { type: "button", class: "button", onclick: goToSource }, "Go to Source"));
}
var now = () => Math.floor(Date.now() / 1000);
async function singleFile(html, ctx) {
  let out = html;
  for (const [path, url] of Object.entries(ctx.assetURLs)) {
    if (!out.includes(url))
      continue;
    const blob = must(ctx.assets[path], "asset " + path);
    const data = await blobToDataURL(blob);
    out = out.split(url).join(data);
  }
  return out;
}
var textBlob = (t, type = "text/plain") => new Blob([t], { type: type + ";charset=utf-8" });
function blobOf(parts, type) {
  return new Blob(parts.map((p) => p instanceof Blob ? p : Uint8Array.from(p)), { type });
}
async function zipOf(files, mtime) {
  zipBegin();
  const parts = [];
  for (const [name, data] of files) {
    if (data instanceof Blob) {
      const g = await zipAddBlob(name, data, mtime);
      if (g)
        parts.push(...g);
    } else
      zipAdd(name, data, mtime);
  }
  parts.push(zipFinish());
  return blobOf(parts, "application/zip");
}
function packageFiles(ctx, markdown, paths) {
  const files = [[safeFileName(ctx.name) + ".md", markdown]];
  const missing = [];
  for (const p of paths) {
    const blob = ctx.assets[p];
    if (blob)
      files.push([p, blob]);
    else
      missing.push("Not included because the file is missing: " + p);
  }
  return { files, missing };
}
function listenerText(source, kind) {
  const r = listener(source, kind);
  if (typeof r !== "string")
    throw new Error("The listener output is not text.");
  return r;
}
function listenerPaths(source, kind) {
  const r = listener(source, kind);
  if (typeof r === "string")
    throw new Error("The listener output is not a list.");
  return r;
}
async function projectZip(ctx, versions) {
  const t = now();
  const md = safeFileName(ctx.name) + ".md";
  zipBegin();
  const parts = [];
  if (versions.length) {
    const name = ctx.gitName || "Marklove";
    gitBegin(name, ctx.gitEmail || "", t);
    const seen = new Set;
    for (const v of versions.slice().reverse()) {
      gitFile(md, v.markdown);
      for (const p of v.assets || []) {
        const blob = ctx.assets[p];
        if (!blob)
          continue;
        const g = await gitFileBlob(p, blob, t, seen);
        if (g)
          parts.push(...g);
      }
      gitCommit(v.message, Math.floor(v.time / 1000), -new Date(v.time).getTimezoneOffset());
      parts.push(zipTake());
    }
    gitFinish(t);
  }
  zipAdd(md, ctx.source, t);
  parts.push(zipTake());
  for (const [p, blob] of Object.entries(ctx.assets)) {
    const g = await zipAddBlob(p, blob, t);
    if (g)
      parts.push(...g);
  }
  parts.push(zipFinish());
  return blobOf(parts, "application/zip");
}
async function epub2(ctx, d) {
  const linked = epub(d, now(), 0);
  const parts = [];
  for (const p of linked) {
    const blob = ctx.assets[p];
    if (!blob)
      continue;
    const g = await zipAddBlob("OEBPS/media/" + p, blob, now());
    if (g)
      parts.push(...g);
  }
  parts.push(zipFinish());
  return blobOf(parts, "application/epub+zip");
}
function named(name, r) {
  return { kind: "files", files: r.files.map(([ext, blob]) => [name.replace(/\.\w+$/, "." + ext), blob]), notes: r.notes };
}
async function build2(id, ctx, opt, progress) {
  const takahashi = opt.style === "takahashi";
  const dark = opt.appearance === "system" ? ctx.prefersDark === null ? "" : ctx.prefersDark ? "dark" : "light" : opt.appearance;
  const name = fileName(id, ctx.title, opt.style);
  const fonts = await embeddedFonts();
  const slideDoc = doc(ctx.source, ctx.assetURLs, { appearance: dark, fonts });
  const articleDoc = doc(ctx.source, ctx.assetURLs, { kind: PAGE_ARTICLE, appearance: dark, fonts });
  const tk = takahashi ? O_TAKAHASHI : 0;
  const letter = opt.paper === "letter" ? 1 : 0;
  const printed = async (kind, o) => {
    await load2();
    const { html, notes } = await printHTML(ctx, kind, o);
    return { kind: "print", print: () => printPage(html), name, notes };
  };
  switch (id) {
    case "interactiveHTML":
      return { kind: "files", files: [[name, textBlob(await singleFile(page(slideDoc, PAGE_SLIDES, slideOptions(takahashi)), ctx), "text/html")]] };
    case "articleHTML":
      return { kind: "files", files: [[name, textBlob(await singleFile(page(articleDoc, PAGE_ARTICLE, O_TOC), ctx), "text/html")]] };
    case "epub":
      return { kind: "files", files: [[name, await epub2(ctx, doc(ctx.source, ctx.assetURLs, { kind: PAGE_ARTICLE, fonts: "" }))]] };
    case "articleMarkdown":
      return { kind: "files", files: [[name, textBlob(textOutput(slideDoc, TEXT_ARTICLE_MD, 0), "text/markdown")]] };
    case "revisedMarkdown":
      return { kind: "files", files: [[name, textBlob(textOutput(slideDoc, TEXT_REVISED_MD, tk), "text/markdown")]] };
    case "narrationScript":
      return { kind: "files", files: [[name, textBlob(textOutput(slideDoc, TEXT_NARRATION, 0))]] };
    case "transcript":
      return { kind: "files", files: [[name, textBlob(textOutput(slideDoc, TEXT_TRANSCRIPT, 0))]] };
    case "subtitles": {
      await load2();
      const m = await media(ctx);
      return { kind: "files", files: [
        [name, textBlob(captions(ctx, m, { takahashi }), "text/vtt")],
        [name.replace(/\.vtt$/, ".srt"), textBlob(captions(ctx, m, { takahashi, srt: true }), "application/x-subrip")]
      ] };
    }
    case "promptText":
      return { kind: "files", files: [[name, textBlob(listenerText(ctx.source, LIST_REVISION_PROMPT))]] };
    case "presenterZIP": {
      const paths = [...listenerPaths(ctx.source, LIST_PUBLIC_ASSETS), ...listenerPaths(ctx.source, LIST_PRIVATE_ASSETS)];
      const { files, missing } = packageFiles(ctx, ctx.source, paths);
      return { kind: "files", files: [[name, await zipOf(files, now())]], notes: missing };
    }
    case "listenerZIP": {
      const { files, missing } = packageFiles(ctx, listenerText(ctx.source, LIST_LISTENER_MD), listenerPaths(ctx.source, LIST_PUBLIC_ASSETS));
      return { kind: "files", files: [[name, await zipOf(files, now())]], notes: missing };
    }
    case "projectZIP":
      return { kind: "files", files: [[name, await projectZip(ctx, await ctx.versions())]] };
    case "slidesPDF":
      return printed(LAYOUT_SLIDES, { takahashi, appearance: dark });
    case "handoutPDF":
      return printed(LAYOUT_HANDOUT, { takahashi, a: letter });
    case "articlePDF":
      return printed(LAYOUT_ARTICLE, { appearance: "light", a: letter });
    case "posterPDF":
      return printed(LAYOUT_POSTER, { appearance: "light", a: POSTER_SIZES.indexOf(opt.posterSize), b: opt.posterOrientation === "landscape" ? 1 : 0 });
    case "slidesPNG":
    case "slidesSVG": {
      await load2();
      const { files, notes } = await (id === "slidesPNG" ? slidesPNG : slidesSVG)(ctx, { takahashi, appearance: dark }, progress);
      return { kind: "files", files: [[name, await zipOf(files, now())]], notes };
    }
    case "video":
    case "manimVideo":
      await load2();
      return named(name, await video(ctx, { takahashi, appearance: dark }, id === "video" ? "video" : "manim", progress));
    case "narratedVideo":
    case "podcast":
      if (!await installed())
        return { kind: "reason", reason: NO_VOICE };
      await load2();
      return named(name, id === "podcast" ? await podcast2(ctx, progress) : await video(ctx, { takahashi, appearance: dark }, "narrated", progress));
  }
}
async function printPage(html) {
  const frame = h("iframe", { title: "Print", style: { position: "fixed", left: "-10000px", top: "0", width: "1280px", height: "720px", border: "0" } });
  document.body.append(frame);
  const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
  await new Promise((res) => {
    frame.onload = () => res();
    frame.src = url;
  });
  const win = must(frame.contentWindow, "print window");
  try {
    await win.document.fonts.ready;
  } catch {}
  await Promise.all([...win.document.images].map((im) => im.complete ? 0 : new Promise((r) => {
    const done = () => r();
    im.onload = done;
    im.onerror = done;
  })));
  await new Promise((r) => setTimeout(r, 200));
  win.focus();
  win.print();
  setTimeout(() => {
    frame.remove();
    URL.revokeObjectURL(url);
  }, 2000);
}
var describe = (e) => e instanceof Error ? e.message || String(e) : String(e);
function exportSheet(ctx) {
  const last = ctx.lastChoice === undefined ? undefined : asFormatId(ctx.lastChoice);
  const st = {
    choice: last ?? "all",
    appearance: "system",
    paper: US.includes(region()) ? "letter" : "a4",
    posterSize: US.includes(region()) ? "in48x36" : "a0",
    posterOrientation: "portrait",
    showIssues: false,
    optionsOpen: false,
    error: ""
  };
  const { list: diags, error: lintError } = diagnostics(ctx.source, ctx.assetURLs);
  const style = () => ctx.style();
  const issuesFor = (id) => diags.filter((d) => affects(d, id, style()) && d.severity === "warning");
  const selected = () => {
    const c = st.choice;
    return c === "all" ? diags : diags.filter((d) => affects(d, c, style()));
  };
  const body = h("div", {});
  let dlg;
  const sheet = () => must(dlg, "export dialog");
  function choiceRow(id, title, label, sub, count) {
    const on = st.choice === id;
    return h("button", {
      type: "button",
      class: "choice",
      role: "radio",
      "aria-checked": String(on),
      disabled: false,
      "aria-label": title,
      "aria-description": sub + (count ? ` Warnings: ${count}` : ""),
      onclick: () => {
        st.choice = id;
        render();
        const row = body.querySelector(`[data-id="${id}"]`);
        if (row instanceof HTMLElement)
          row.focus();
      },
      "data-id": id
    }, h("span", { class: "dot", "aria-hidden": "true", text: on ? "◉" : "○" }), h("span", {}, h("span", { class: "name", text: title }), h("span", { class: "fmt", text: label }), h("span", { class: "sub", text: sub }), count ? h("span", { class: "warncount", text: `⚠ Warnings: ${count}` }) : null));
  }
  function render() {
    const scroll = dlg ? dlg.body.scrollTop : 0;
    body.replaceChildren();
    const warnCount = diags.filter((x) => x.severity === "warning").length;
    body.append(section(null, h("div", { role: "radiogroup", "aria-label": "Output" }, choiceRow("all", "All outputs", "ZIP", "Every format that the web version makes, in one ZIP file. The PDFs open the print dialog separately.", warnCount)), h("div", { class: "row" }, h("span", { class: "row-label", text: "Slide style" }), segmented("Slide style", [["normal", "Normal"], ["takahashi", "Takahashi"]], style(), (v) => {
      const chosen = oneOf(STYLES, v);
      if (chosen)
        ctx.setStyle(chosen);
      render();
    })), footnote("Every format is free.")));
    for (const g of GROUPS) {
      const rows = FORMATS.filter((f) => f.group === g).map((f) => {
        let sub = f.summary;
        if (f.id === "slidesPDF")
          sub = `${style() === "takahashi" ? "Takahashi" : "Normal"} slides. Change the style above.`;
        if (f.print)
          sub += " " + PRINT_NOTE;
        return choiceRow(f.id, f.name, f.label, sub, issuesFor(f.id).length);
      });
      const extra = g === "Packages" ? h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", title: "See the slides and notes that a listener gets from the Listener package", onclick: () => ctx.listenerPreview() }, "\uD83D\uDC65 Preview as a Listener")) : null;
      body.append(section(g, h("div", { role: "radiogroup", "aria-label": g }, rows), extra));
    }
    const sel = selected();
    const checks = [];
    if (lintError)
      checks.push(h("div", { class: "row" }, h("span", { class: "status-warn", text: "⚠ " + lintError })));
    else if (!sel.length)
      checks.push(h("div", { class: "row" }, h("span", { class: "status-ok", text: "✓ Ready to export" })));
    else {
      checks.push(h("div", { class: "row" }, h("span", { class: "status-warn", text: `⚠ Source checks to review: ${sel.length}` }), h("button", { type: "button", class: "button", "aria-expanded": String(st.showIssues), onclick: () => {
        st.showIssues = !st.showIssues;
        render();
      } }, st.showIssues ? "Hide" : "Show")));
      checks.push(footnote("Export stays available. Marklove uses a clear fallback for each issue and keeps every word."));
      if (st.showIssues)
        checks.push(h("div", {}, sel.map((x) => issueRow(x, ctx.source, () => {
          sheet().close();
          ctx.goToSource(x, true);
        }))));
    }
    body.append(section("Source checks", ...checks));
    const poster = POSTERS[st.posterSize];
    const optBox = h("details", { class: "group", open: st.optionsOpen }, h("summary", { text: "Options" }), selectRow("Appearance", [["system", "From the Project"], ["light", "Light"], ["dark", "Dark"]], st.appearance, (v) => {
      st.appearance = oneOf(APPEARANCES, v) ?? st.appearance;
    }), selectRow("Paper", [["a4", "A4"], ["letter", "US Letter"]], st.paper, (v) => {
      st.paper = oneOf(PAPERS, v) ?? st.paper;
    }), selectRow("Poster size", POSTER_KEYS.map((k) => [k, POSTERS[k][0]]), st.posterSize, (v) => {
      st.posterSize = oneOf(POSTER_KEYS, v) ?? st.posterSize;
      render();
    }), h("div", { class: "row" }, h("span", { class: "row-label", text: "Poster orientation" }), poster[1] === poster[2] ? h("span", { class: "row-hint", text: "Square" }) : segmented("Poster orientation", [["portrait", "Portrait"], ["landscape", "Landscape"]], st.posterOrientation, (v) => {
      st.posterOrientation = oneOf(ORIENTATIONS, v) ?? st.posterOrientation;
    })));
    optBox.addEventListener("toggle", () => {
      st.optionsOpen = optBox.open;
    });
    body.append(section(null, optBox));
    body.append(section(null, h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => {
      sheet().close();
      ctx.speakerReady();
    } }, "Start Speaker Ready")), footnote("Present with the current slide, the next slide, private notes, and a timer. The audience window shows the slides only.")));
    if (st.error)
      body.append(section(null, h("div", { class: "row" }, h("span", { class: "status-bad", role: "alert", text: "⊗ " + st.error }))));
    if (dlg)
      dlg.body.scrollTop = scroll;
  }
  async function start() {
    st.error = "";
    ctx.setChoice(st.choice);
    const ids = st.choice === "all" ? FORMATS.filter((f) => !f.print).map((f) => f.id) : [st.choice];
    const weight = (id) => WEIGHTS[id] || 1;
    const bar = h("progress", { max: String(ids.reduce((n, id) => n + weight(id), 0)) });
    const label = h("span", { text: "Preparing…" });
    const progress = h("div", { class: "progress", role: "status" }, bar, label);
    body.replaceChildren(progress);
    sheet().buttons.forEach((b) => {
      b.disabled = b.textContent === "Export";
    });
    await ctx.beforeExport();
    const opt = { style: style(), appearance: st.appearance, paper: st.paper, posterSize: st.posterSize, posterOrientation: st.posterOrientation };
    const results = [];
    const files = [];
    let base = 0;
    for (const id of ids) {
      label.textContent = `Exporting ${formatById(id).name}…`;
      bar.value = base;
      await new Promise((r) => setTimeout(r, 0));
      try {
        const r = await build2(id, ctx, opt, (p) => {
          bar.value = base + p * weight(id);
        });
        if (r.kind === "reason")
          results.push({ id, ok: false, reason: r.reason, notes: [] });
        else if (r.kind === "print") {
          await r.print();
          results.push({ id, ok: true, notes: ["The print dialog opened. Select Save as PDF. Suggested name: " + r.name, ...r.notes] });
        } else {
          files.push(...r.files);
          results.push({ id, ok: true, notes: r.notes || [] });
        }
      } catch (e) {
        const msg = e instanceof TooLarge ? e.message : "Marklove could not make the file. " + describe(e);
        results.push({ id, ok: false, reason: msg, notes: [] });
      }
      base += weight(id);
    }
    forget();
    let deliver = files;
    if (st.choice === "all") {
      label.textContent = "Making the ZIP file…";
      const lines = [`Marklove exports for "${ctx.title}"`, ""];
      for (const r of results)
        lines.push(`${formatById(r.id).name}: ${r.ok ? "created" : "not created. " + r.reason}`, ...r.notes.map((n) => "  " + n));
      for (const f of FORMATS.filter((f) => f.print))
        lines.push(`${f.name}: not in this ZIP. Select it in Export to print it as PDF.`);
      try {
        const zip = await zipOf([...files, ["README.txt", lines.join(`
`) + `
`]], now());
        deliver = [[`${safeFileName(ctx.title)} – Marklove exports.zip`, zip]];
      } catch (e) {
        st.error = "Export did not complete. " + messageOf(e);
      }
    }
    for (const [n, b] of deliver)
      download(b, n);
    showResults(results, deliver);
  }
  function showResults(results, deliver) {
    body.replaceChildren();
    sheet().buttons.forEach((b) => {
      if (b.textContent === "Export")
        b.hidden = true;
      if (b.textContent === "Cancel")
        b.textContent = "Done";
      b.disabled = false;
    });
    body.append(section(null, h("div", { class: "group" }, deliver.length ? h("p", { text: "The browser saves the files in its downloads folder. Select a file to save it again." }) : null, deliver.map(([n, b]) => h("div", {}, h("button", { type: "button", class: "linkbtn", onclick: () => download(b, n) }, "⇩ " + n))))));
    body.append(section("Results", h("div", {}, results.map((r) => h("div", { class: "issue" }, r.ok ? h("div", { class: "status-ok", text: "✓ " + formatById(r.id).name }) : h("div", { class: "status-bad", text: `${formatById(r.id).name}: not created` }), r.reason ? h("p", { class: "footnote", text: r.reason }) : null, r.notes.map((n) => h("p", { class: "footnote", text: n })))))));
    if (st.error)
      body.append(h("p", { class: "status-bad", role: "alert", text: st.error }));
    announce("Export complete.");
  }
  dlg = dialog({
    title: "Export",
    body,
    wide: false,
    buttons: [{ label: "Cancel", cancel: true }, { label: "Export", primary: true, action: () => {
      start();
      return false;
    } }]
  });
  render();
  const checked = body.querySelector('[aria-checked="true"]');
  if (checked instanceof HTMLElement)
    checked.focus();
}

// src/panels.ts
function errorMessage2(err) {
  return err instanceof Error ? err.message : String(err);
}
function inputOf(el) {
  if (!(el instanceof HTMLInputElement))
    throw new Error("Expected an input element");
  return el;
}
function buttonOf(el) {
  if (!(el instanceof HTMLButtonElement))
    throw new Error("Expected a button element");
  return el;
}
function inputTarget(e) {
  return e.target instanceof HTMLInputElement ? e.target : null;
}
function parseAppearance(v) {
  return v === "light" || v === "dark" ? v : "system";
}
function parseSyntax(v) {
  return v === "plain" || v === "vim" ? v : "sam";
}
function listenerText2(source, kind) {
  const r = listener(source, kind);
  if (typeof r !== "string")
    throw new Error("Expected text from the listener call");
  return r;
}
function randomId(prefix) {
  return prefix + Math.random().toString(36).slice(2);
}
function slider(label, min, max, step, value, fmt, onchange) {
  const id = randomId("r-");
  const out = h("span", { class: "row-hint", "aria-hidden": "true", text: fmt(value) });
  const input = h("input", {
    type: "range",
    id,
    min: String(min),
    max: String(max),
    step: String(step),
    value: String(value),
    "aria-valuetext": fmt(value),
    oninput: (e) => {
      const target = inputTarget(e);
      if (!target)
        return;
      const v = Number(target.value);
      out.textContent = fmt(v);
      target.setAttribute("aria-valuetext", fmt(v));
      onchange(v);
    }
  });
  return h("div", { class: "row" }, h("label", { for: id, class: "row-label" }, label, out), input);
}
function textRow(label, value, placeholder, onchange, attrs = {}) {
  const id = randomId("x-");
  return h("div", { class: "row" }, h("label", { for: id, class: "row-label", text: label }), h("input", { type: "text", id, value, placeholder, oninput: (e) => {
    const target = inputTarget(e);
    if (target)
      onchange(target.value);
  }, ...attrs }));
}
var themeOptions = () => themes().map((t) => [t.id, t.name]);
function settingsPanel(app) {
  const set = (k, v) => {
    setSetting(k, v);
    app.applySettings();
  };
  let d = null;
  const body = h("div", {}, section("Editor", selectRow("Theme", themeOptions(), settings.themeID, (v) => set("themeID", v)), selectRow("Appearance", [["system", "Automatic"], ["light", "Light"], ["dark", "Dark"]], settings.appearance, (v) => set("appearance", parseAppearance(v))), slider("Text size", 0.8, 1.8, 0.1, settings.editorTextScale, (v) => Math.round(v * 100) + "%", (v) => set("editorTextScale", v)), slider("Line spacing", 1, 2, 0.1, settings.editorLineSpacing, (v) => v.toFixed(1), (v) => set("editorLineSpacing", v)), toggleRow("Show Line Count", settings.showLineCount, (v) => set("showLineCount", v)), toggleRow("Wrap Lines", settings.wrapLines, (v) => set("wrapLines", v)), toggleRow("Increase Contrast", settings.increaseContrast, (v) => set("increaseContrast", v), "Text colors at 7:1 contrast or more."), selectRow("Find patterns", SYNTAXES, settings.findSyntax, (v) => {
    set("findSyntax", parseSyntax(v));
    app.findSyntaxChanged();
  }), h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => {
    d?.close();
    samTutorial();
  } }, "Sam Tutorial")), toggleRow("Vim Mode", settings.vimEnabled, (v) => set("vimEnabled", v), "Text commands and navigation. Marklove saves each change. :w saves a version. :q! goes back to the last version."), footnote("These settings stay in this browser. They do not change the project.")), section("Versions", toggleRow("Save Versions", settings.gitEnabled, (v) => set("gitEnabled", v)), textRow("Name", settings.gitName, "The front matter author", (v) => setSetting("gitName", v), { autocomplete: "name" }), textRow("Email", settings.gitEmail, "Optional", (v) => setSetting("gitEmail", v), { type: "email", autocomplete: "email", autocapitalize: "off", spellcheck: false }), footnote(`Marklove saves each change at once. It also saves a version after a pause in your typing, and when you press ${cmdKey}S or type :w. The version message says what changed. The project ZIP copy includes the history as Git, and other Git apps can read it.`)), voiceSection(app.text()), section("Storage", footnote("Projects, media, and versions stay in this browser, on this device. Nothing goes to a server. To move a project, save a ZIP copy and import it on the other device.")), section("About", footnote("Fonts: Courier Prime, Courier Prime Sans, Libre Baskerville, and KpMath, under the SIL Open Font License. The Kokoro voice is the kokoro-js web version of Kokoro-82M, under the Apache License 2.0.")));
  d = dialog({ title: "Settings", body });
}
function voiceSection(source) {
  const voice = meta(source, "voice") || DEFAULT_VOICE;
  const controls = h("div", {});
  const status = (t) => h("p", { class: "footnote", role: "status", text: t });
  function render(state, p) {
    controls.replaceChildren();
    if (state === "downloading") {
      controls.append(h("progress", { max: "1", value: String(p || 0), "aria-label": "Downloading the Voice" }), status(`Downloading the voice: ${Math.floor((p || 0) * 100)} percent.`));
      return;
    }
    if (state !== "installed") {
      controls.append(h("div", { class: "row" }, h("button", { type: "button", class: "button", onclick: download }, `Download the Voice (${SIZE_TEXT})`)), status(state ? "The download stopped. " + state : `Narrated video and the podcast need the Kokoro voice (${SIZE_TEXT}). After the download, the browser keeps the voice.`));
      return;
    }
    const play = buttonOf(h("button", { type: "button", class: "button", "aria-description": `Speaks one sentence in the voice ${voice}.` }, "Play a Sample"));
    play.onclick = async () => {
      play.disabled = true;
      try {
        await playSample(voice);
      } catch (e) {
        controls.append(status("The sample did not play. " + errorMessage2(e)));
      }
      play.disabled = false;
    };
    const del = h("button", { type: "button", class: "button", onclick: async () => {
      if (!await confirmBox({ title: "Delete the voice from this browser?", message: `This removes ${SIZE_TEXT}. You can download it again later.`, choices: [{ label: "Delete the Voice", value: true, danger: true }] }))
        return;
      await remove();
      render("");
    } }, "Delete the Voice");
    controls.append(h("div", { class: "row" }, play, del), status("The voice is in this browser. Narrated video and the podcast are available."));
  }
  async function download() {
    render("downloading", 0);
    try {
      await load3((p) => render("downloading", p));
      render("installed");
      announce("The voice is ready.");
    } catch (e) {
      render(errorMessage2(e));
    }
  }
  installed().then((ok) => render(ok ? "installed" : ""));
  return section("Narration", h("div", { class: "row" }, h("span", { class: "row-label", text: "Voice" }), h("span", { class: "row-hint", text: voice })), controls, footnote("Kokoro speaks the narration in this browser. The first download comes from jsDelivr and Hugging Face. To use a different voice, add voice: to the front matter, for example voice: bf_emma."));
}
function luminance(hex) {
  const n = parseInt(hex.slice(1), 16);
  const [r = 0, g = 0, b = 0] = [n >> 16 & 255, n >> 8 & 255, n & 255].map((c) => {
    const x = c / 255;
    return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contrast(a, b) {
  const x = luminance(a), y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}
var MIN_CONTRAST = 4.495;
function themeIssues(p) {
  const out = [];
  const roles = [
    ["Body text", p.text],
    ["Heading text", p.strong],
    ["Secondary text", p.dim],
    ["Accent", p.accent],
    ["Red", p.red],
    ["Green", p.green],
    ["Yellow", p.yellow],
    ["Blue", p.blue],
    ["Magenta", p.magenta],
    ["Cyan", p.cyan],
    ["Orange", p.orange],
    ["Violet", p.violet]
  ];
  for (const [role, fg] of roles) {
    const c = Math.min(contrast(fg, p.background), contrast(fg, p.surface));
    if (c < MIN_CONTRAST)
      out.push(`${p.name}: ${role} has a contrast of ${c.toFixed(2)}:1. It must be 4.5:1 or more.`);
  }
  return out;
}
function frontMatterSet(values, source) {
  const lines = source.split(`
`);
  if (lines[0]?.trim() === "---") {
    let end = lines.findIndex((l, i) => i > 0 && l.trim() === "---");
    if (end > 0) {
      for (const [key, value] of values) {
        let i = lines.slice(1, end).findIndex((l) => l.toLowerCase().startsWith(key + ":"));
        i = i < 0 ? -1 : i + 1;
        if (i > 0 && value !== null)
          lines[i] = `${key}: ${value}`;
        else if (i > 0) {
          lines.splice(i, 1);
          end--;
        } else if (value !== null) {
          lines.splice(end, 0, `${key}: ${value}`);
          end++;
        }
      }
      return lines.join(`
`);
    }
  }
  const set = values.filter(([, v]) => v !== null).map(([k, v]) => `${k}: ${v}`);
  if (!set.length)
    return source;
  return ["---", ...set, "---", "", ...lines].join(`
`);
}
function frontValue(source, key) {
  if (!source.startsWith("---"))
    return "";
  const end = source.indexOf(`
---`, 3);
  if (end < 0)
    return "";
  const line = source.slice(0, end).split(`
`).find((l) => l.toLowerCase().startsWith(key + ":"));
  return line ? line.slice(key.length + 1).trim().replace(/^["']|["']$/g, "") : "";
}
var ACCENTS = ["", "blue", "violet", "magenta", "red", "orange", "yellow", "green", "cyan"];
function customizePanel(app) {
  const src = app.text();
  const r = themeResolve(frontValue(src, "theme"), "");
  const st = { themeID: r.id, appearance: r.darkOnly ? null : r.prefersDark, accent: frontValue(src, "accent"), useInEditor: false };
  const themes2 = themes();
  const theme = () => themes2.find((t) => t.id === st.themeID) || themes2[0];
  const accents = ACCENTS.includes(st.accent) ? ACCENTS : [...ACCENTS, st.accent];
  const previewBox = h("div", {});
  const appearanceRow = selectRow("Appearance", [["auto", "Automatic"], ["light", "Light"], ["dark", "Dark"]], st.appearance === null ? "auto" : st.appearance ? "dark" : "light", (v) => {
    st.appearance = v === "auto" ? null : v === "dark";
    update();
  });
  let d = null;
  function update() {
    const t = theme();
    if (!t)
      return;
    query(appearanceRow, "select", HTMLSelectElement).disabled = t.darkOnly;
    const p = themePalette(t.id, st.accent, t.darkOnly ? true : !!st.appearance, false);
    const issues = themeIssues(p);
    previewBox.replaceChildren(h("div", { class: "theme-preview", style: { background: p.background, color: p.text } }, h("div", { style: { color: p.strong, fontWeight: "700" }, text: "Heading" }), h("div", {}, "Body text with a ", h("u", { style: { color: p.accent }, text: "link" })), h("div", { style: { color: p.dim, fontSize: "0.85em" }, text: "Secondary text" })), issues.length ? h("div", {}, issues.map((i) => h("p", { class: "status-warn", text: "⚠ " + i }))) : h("p", { class: "status-ok", text: "✓ All colors meet the readability checks." }));
    const applyButton = d?.buttons.find((b) => b.textContent === "Apply");
    if (applyButton)
      applyButton.disabled = issues.length > 0;
  }
  function apply() {
    const t = theme();
    if (!t)
      return;
    const value = st.appearance === null || t.darkOnly ? t.id : t.id + (st.appearance ? "-dark" : "-light");
    const text = app.text();
    const next = frontMatterSet([["theme", value], ["accent", st.accent || null]], text);
    if (next !== text)
      app.replaceAll(next);
    if (st.useInEditor) {
      setSetting("themeID", t.id);
      if (!t.darkOnly && st.appearance !== null)
        setSetting("appearance", st.appearance ? "dark" : "light");
      app.applySettings();
    }
    announce(`The project theme is ${t.name}.`);
  }
  const accentLabel = (a) => a ? a.startsWith("#") ? a.toUpperCase() : a.charAt(0).toUpperCase() + a.slice(1) : "Theme default";
  const body = h("div", {}, section("Project Theme", selectRow("Theme", themes2.map((t) => [t.id, t.name]), st.themeID, (v) => {
    st.themeID = v;
    update();
  }), appearanceRow, toggleRow("Use This Theme in the Editor Too", false, (v) => {
    st.useInEditor = v;
  }), footnote("For Preview, slides, the article, and the interactive page of this project. The editor uses the theme in Settings, unless you turn on the option above. Every theme is free. Marklove makes text colors darker or lighter where they are below 4.5:1 contrast.")), section("Accent", selectRow("Accent", accents.map((a) => [a, accentLabel(a)]), st.accent, (v) => {
    st.accent = v;
    update();
  })), section("Preview", h("div", { class: "group" }, previewBox)));
  d = dialog({ title: "Customize", body, buttons: [{ label: "Cancel", cancel: true }, { label: "Apply", primary: true, disabled: app.readOnly(), action: apply }] });
  update();
}
function outlinePanel(app) {
  let items = [];
  try {
    items = outline({ source: app.text() }, 0);
  } catch {
    items = [];
  }
  const title = app.title();
  let d = null;
  const list = h("div", { role: "list" }, items.map((f) => {
    const t = app.text();
    const line = t.slice(f.s0, t.indexOf(`
`, f.s0) < 0 ? t.length : t.indexOf(`
`, f.s0));
    const label = f.kind === 0 ? title : line.replace(/^#+\s*/, "") || "Slide";
    return h("div", { role: "listitem" }, h("button", {
      type: "button",
      class: "item linkbtn",
      style: { paddingLeft: f.kind === 2 ? "28px" : "12px", fontWeight: f.kind === 1 ? "700" : "400", display: "flex", width: "100%" },
      onclick: () => {
        d?.close();
        app.goToSource(f.s0, f.s0);
      }
    }, h("span", { text: label }), h("span", { class: "spacer" }), f.notes ? h("span", { class: "row-hint", "aria-label": "Has notes", text: "✎" }) : null));
  }));
  d = dialog({ title: "Outline", body: items.length ? section(null, list) : h("p", { class: "alert-text", text: "The project has no slides yet. Add a heading with ## to make a slide." }) });
}
var SYNTAX2 = [
  ["Slides", `# Section
## Slide title
Text for the slide.`],
  ["Reveal", `First point.

. . .

Second point appears on the next click.`],
  ["Speaker notes", `::: notes
Private text for the presenter.
:::`],
  ["Narration", `::: narration
The words that narration speaks for this slide.
:::`],
  ["Spoken explanation", `$$ E = mc^2 $$

::: explain
Energy equals mass times the speed of light squared.
:::`],
  ["Image", '![A description for people who cannot see it](images/photo.png "Optional caption")'],
  ["Decorative image", `<!-- decorative -->
![](images/pattern.png)`],
  ["Equation steps", `::: morph
$$ a = b + c $$
$$ a - c = b $$
:::`],
  ["Plot with slider", `::: plot
x: 0, 6.28
slider: k, 0.5, 3, 1, Frequency
y = sin(k*x)
:::`],
  ["Bar chart", `::: chart bar
| Item | Value |
| --- | ---: |
| A | 3 |
| B | 5 |
:::`],
  ["Article only", `<!-- article -->
Text for the article only.
<!-- /article -->`],
  ["Slides only", `<!-- slides -->
Text for the slides only.
<!-- /slides -->`]
];
function helpPanel(app) {
  let includeSelection = false;
  let d = null;
  const copyBtn = (label, make) => {
    const b = h("button", { type: "button", class: "button", onclick: async () => {
      try {
        await copyText(make());
      } catch (e) {
        announce(errorMessage2(e));
        return;
      }
      b.textContent = "Copied";
      announce("Copied");
    } }, label);
    return b;
  };
  const body = h("div", {}, section("Write in Markdown. Preview it. Export it.", h("p", { class: "group", text: "Marklove keeps your Markdown as plain text. Every rule below is visible in the source. Insert adds the same text for you." }), h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => {
    d?.close();
    app.openTour();
  } }, "✦ Open the Tour")), h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => {
    d?.close();
    samTutorial();
  } }, "Sam Tutorial: Structural Editing")), h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => {
    d?.close();
    welcome(app);
  } }, "Show the Welcome Again"))), section("Syntax", ...SYNTAX2.map(([name, text]) => h("div", { class: "item" }, h("div", { class: "item-title", text: name }), h("pre", { class: "code", text }), h("div", { class: "item-actions" }, h("button", { type: "button", class: "button", disabled: app.readOnly(), "aria-label": "Insert " + name, onclick: () => {
    d?.close();
    app.insertText(text);
  } }, "Insert"))))), section("Write with an AI Tool", h("p", { class: "group", text: "Copy a prompt with the Marklove rules. Paste it into Claude, ChatGPT, or another tool. The rules ask for short sentences that fit Takahashi slides, and for plots, charts, and equation steps. Then paste the Markdown back here. Marklove sends nothing by itself." }), toggleRow("Include the selected text", false, (v) => {
    includeSelection = v;
  }), h("div", { class: "row" }, copyBtn("Copy a Prompt for a New Presentation", () => authoringPrompt(includeSelection ? app.selectedText() : ""))), h("div", { class: "row" }, copyBtn("Copy a Prompt to Revise This Project", () => listenerText2(app.text(), LIST_REVISION_PROMPT))), footnote("The revision prompt includes your project without private notes.")), section("Vim Mode", h("p", { class: "group", text: 'Motions: h j k l w b e 0 ^ $ gg G f t % { }. Operators: d c y > < with motions and text objects such as iw, i", i(, ip, and i$ for math. Also x, p, u, Ctrl-R, ., v, V, /, n, :s, :w, and :q!. Shell commands and plugins are not available.' })), section("Keyboard Shortcuts", h("div", { class: "group" }, SHORTCUTS.map(([k, t]) => h("div", { class: "row" }, h("span", { class: "row-label", text: t }), h("kbd", { text: k }))))));
  d = dialog({ title: "Help", body, wide: true });
}
var K = cmdKey;
var ALT = cmdKey === "⌘" ? "⌥" : "Alt+";
var SH = cmdKey === "⌘" ? "⇧" : "Shift+";
var CTL = cmdKey === "⌘" ? "⌃" : "Ctrl+";
var combo = (...p) => cmdKey === "⌘" ? p.join("") : p.join("").replace(/\+(?=.)/g, "+");
var SHORTCUTS = [
  [combo(ALT, K, "N"), "New Project"],
  [combo(K, "O"), "Import Markdown or ZIP"],
  [combo(SH, K, "O"), "All Projects"],
  [combo(K, "S"), "Save a Version"],
  [combo(ALT, K, "Y"), "Version History"],
  [combo(K, "E"), "Export"],
  [combo(K, "F"), "Find"],
  [combo(ALT, K, "F"), "Find and Replace"],
  [combo(K, "G"), "Find Next"],
  [combo(SH, K, "G"), "Find Previous"],
  [combo(ALT, K, "X"), "Sam Command Line"],
  [combo(CTL === "Ctrl+" ? "Ctrl+Alt+" : "⌃⌘", "E"), "Preview Equation"],
  [combo(SH, K, "L"), "Outline"],
  [combo(ALT, K, "L"), "Show Line Count"],
  [combo(K, "Return"), "Preview or Edit"],
  [combo(SH, K, "R"), "Speaker Ready"],
  ["Escape", "Edit (in Preview)"]
];
async function projectsPanel(app, { received = false } = {}) {
  const list = h("div", { role: "list" });
  let d = null;
  async function render() {
    const all = (await projects()).filter((p) => !!p.isListener === received);
    list.replaceChildren();
    if (!all.length)
      list.append(h("p", { class: "alert-text", text: received ? "Nothing Received. Import a listener package (ZIP) to see it here. Received items open view only." : "No projects yet." }));
    for (const p of all) {
      const current = p.id === app.projectId();
      list.append(h("div", { class: "item", role: "listitem" }, h("button", { type: "button", class: "linkbtn", "aria-current": current ? "true" : null, onclick: () => {
        d?.close();
        app.openProject(p.id);
      } }, h("span", { class: "item-title", text: (current ? "✓ " : "") + p.name }), h("span", { class: "item-sub", text: new Date(p.modified).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) })), h("div", { class: "item-actions" }, h("button", { type: "button", class: "button danger", "aria-label": "Delete " + p.name, onclick: async () => {
        if (await app.deleteProject(p))
          await render();
      } }, "Delete"))));
    }
  }
  await render();
  d = dialog({
    title: received ? "Received" : "All Projects",
    body: section(null, list),
    buttons: [{ label: "Done", cancel: true }, { label: received ? "Import" : "New Project", primary: true, action: () => received ? app.importFiles() : app.newProject() }]
  });
}
function renamePanel(app) {
  const input = inputOf(h("input", { type: "text", value: app.projectName(), "aria-label": "Name", autocomplete: "off" }));
  let d = null;
  const go = async () => {
    const n = input.value.trim();
    if (!n)
      return false;
    await app.rename(n);
    return;
  };
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      go().then((r) => r !== false && d?.close());
    }
  });
  d = dialog({ title: "Rename Project", body: section(null, h("div", { class: "row" }, input)), buttons: [{ label: "Cancel", cancel: true }, { label: "Rename", primary: true, action: go }] });
  input.select();
}
var when = (t) => new Date(t).toLocaleString(undefined, { day: "numeric", month: "short", year: "numeric", hour: "numeric", minute: "2-digit" });
async function historyPanel(app) {
  const list = h("div", {});
  async function render() {
    const all = await versions(must(app.projectId(), "the open project"));
    list.replaceChildren();
    if (!settings.gitEnabled)
      list.append(h("p", { class: "status-warn", text: "⚠ Versions are off. Turn on Save Versions in Settings." }));
    if (!all.length)
      list.append(h("p", { class: "alert-text", text: `No Versions Yet. Marklove saves a version after a pause in your typing, and when you press ${cmdKey}S.` }));
    all.forEach((v, i) => {
      const [subject = "", ...rest] = v.message.split(`
`);
      const bodyText = rest.join(`
`).trim();
      list.append(h("div", { class: "item" }, h("div", { class: "item-title", text: subject }), h("div", { class: "item-sub", text: when(v.time) }), bodyText ? h("div", { class: "item-sub", style: { whiteSpace: "pre-wrap" }, text: bodyText.split(`
`).slice(0, 6).join(`
`) }) : null, h("div", { class: "item-actions" }, h("button", { type: "button", class: "button", onclick: () => versionDetail(v, all[i + 1] || null, app.text()) }, "Changes"), h("button", { type: "button", class: "button", disabled: i === 0 || app.readOnly(), onclick: async () => {
        const ok = await confirmBox({ title: "Restore this version?", message: `The project text and its files change to the version from ${when(v.time)}. Marklove first saves the current text as a version, so you can go back.`, choices: [{ label: "Restore", value: true, primary: true }] });
        if (ok) {
          await app.restoreVersion(v);
          await render();
        }
      } }, "Restore…"))));
    });
  }
  await render();
  dialog({
    title: "Version History",
    body: section(null, list),
    buttons: [{ label: "Done", cancel: true }, { label: "Save a Version Now", primary: true, disabled: !settings.gitEnabled || app.readOnly(), action: async () => {
      await app.saveVersion({ explicit: true });
      await render();
      return false;
    } }]
  });
}
var HUNK_CONTEXT = 3;
function hunks(a, b) {
  let lines;
  try {
    lines = diff(a, b);
  } catch {
    lines = [];
  }
  const ranges = [];
  lines.forEach((l, i) => {
    if (l.op === "same")
      return;
    const lo = Math.max(0, i - HUNK_CONTEXT), hi = Math.min(lines.length - 1, i + HUNK_CONTEXT);
    const last = ranges[ranges.length - 1];
    if (last && lo <= last[1] + 1)
      last[1] = hi;
    else
      ranges.push([lo, hi]);
  });
  return ranges.map(([lo, hi]) => {
    const part = lines.slice(lo, hi + 1);
    return { lines: part, added: part.filter((l) => l.op === "add").length, removed: part.filter((l) => l.op === "remove").length };
  });
}
function diffView(hs, summary) {
  const box = h("div", {}, h("p", { class: "footnote", text: summary }));
  for (const hk of hs) {
    const shown = hk.lines.filter((l) => l.op !== "remove");
    const first = hk.lines[0];
    const start = shown[0]?.new || first && (first.new || first.old) || 1;
    box.append(h("h4", { class: "hunk-head", text: shown.length <= 1 ? `Line ${start}` : `Lines ${start} to ${start + shown.length - 1}` }));
    for (const l of hk.lines) {
      const sign = l.op === "add" ? "+" : l.op === "remove" ? "−" : " ";
      const spoken = l.op === "add" ? "Added: " : l.op === "remove" ? "Removed: " : "";
      box.append(h("div", { class: "diff-line " + l.op, role: "text", "aria-label": spoken + l.text }, h("span", { class: "n", "aria-hidden": "true", text: String(l.new || l.old || "") }), h("span", { class: "s", "aria-hidden": "true", text: sign }), h("span", { class: "t", "aria-hidden": "true", text: l.text || " " })));
    }
  }
  return box;
}
function versionDetail(v, previous, current) {
  const content = h("div", {});
  const sum = (hs) => [hs.reduce((n, x) => n + x.added, 0), hs.reduce((n, x) => n + x.removed, 0)];
  function show(mode) {
    content.replaceChildren();
    if (mode === "text") {
      content.append(h("pre", { class: "code", text: v.markdown }));
      return;
    }
    const hs = mode === "changes" ? hunks(previous ? previous.markdown : "", v.markdown) : hunks(v.markdown, current);
    const [a, r] = sum(hs);
    let s;
    if (mode === "changes")
      s = !previous ? `The first version. Lines: ${a}.` : a + r === 0 ? "The text did not change in this version. Other files changed." : `Added lines: ${a}. Removed lines: ${r}.`;
    else
      s = a + r === 0 ? "This version has the same text as now." : `Since this version: added lines: ${a}. Removed lines: ${r}.`;
    content.append(diffView(hs, s));
  }
  const body = h("div", {}, h("div", { class: "row" }, segmented("Show", [["changes", "Changes"], ["compare", "Compared with Now"], ["text", "Text"]], "changes", show)), content);
  dialog({ title: v.message.split(`
`)[0] ?? "", body, wide: true });
  show("changes");
}
var PAGES = [
  ["Markdown in, slides out", "You write plain Markdown. Marklove draws each form from it.", `## Math that looks like math

::: morph
$$(a + b)^2$$
$$(a + b)(a + b)$$
$$a^2 + 2ab + b^2$$
:::`],
  ["Two styles, one file", "Normal slides hold a full idea. Takahashi slides show one short sentence in large type.", ""],
  ["Plots that move", "Drag a slider. The curve changes at once. Your audience can do this on the web page too. Marklove does not run code from your file. Plots use a small, safe formula language.", ""],
  ["Your words, in every form", "Export makes every form from the same file. Every export is free. Marklove saves each change at once, in this browser, and keeps versions that tell what changed.", ""]
];
function welcome(app) {
  let page = 0;
  const content = h("div", { class: "group" });
  let d = null;
  function render() {
    const entry = PAGES[page];
    const [skip, back, next] = d?.buttons ?? [];
    if (!entry || !skip || !back || !next)
      return;
    const [title, text, code] = entry;
    content.replaceChildren(h("h3", { text: title, tabindex: "-1" }), h("p", { text }), ...code ? [h("pre", { class: "code", "aria-label": "Markdown source", text: code })] : [], h("p", { class: "footnote", text: `Page ${page + 1} of ${PAGES.length}` }));
    back.hidden = page === 0;
    next.textContent = page === PAGES.length - 1 ? "Start Writing" : "Continue";
    skip.hidden = page === PAGES.length - 1;
    query(content, "h3", HTMLElement).focus();
  }
  const finish = () => {
    setSetting("onboardingSeen", true);
  };
  d = dialog({
    title: "Welcome to Marklove",
    body: content,
    onClose: finish,
    buttons: [
      { label: "Skip", cancel: true },
      { label: "Back", action: () => {
        page = Math.max(0, page - 1);
        render();
        return false;
      } },
      { label: "Continue", primary: true, action: () => {
        if (page < PAGES.length - 1) {
          page++;
          render();
          return false;
        }
        return;
      } }
    ]
  });
  d.body.append(h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => {
    d?.close();
    app.openTour();
  } }, "Open the Tour")));
  render();
}

// src/app.ts
var $ = (id) => byId(id, HTMLElement);
var enc2 = new TextEncoder;
var state = {
  project: null,
  assets: {},
  assetURLs: {},
  list: [],
  mode: "edit",
  view: "slides",
  outline: [],
  previewOffset: 0,
  html: "",
  saveTimer: undefined,
  idleTimer: undefined,
  lastVersion: 0,
  focus: null,
  exportChoice: "all",
  wasLarge: undefined
};
var frameOrNull = null;
function frame() {
  return must(frameOrNull, "the preview frame");
}
function currentProject() {
  return must(state.project, "the open project");
}
function errorMessage3(err) {
  return err instanceof Error ? err.message : String(err);
}
var readOnly = () => !!(state.project && state.project.isListener);
var tooLarge = (t) => enc2.encode(t).length > MAX_SOURCE_BYTES;
function frontValue2(source, key) {
  if (!source.startsWith("---"))
    return "";
  const end = source.indexOf(`
---`, 3);
  if (end < 0)
    return "";
  const line = source.slice(0, end).split(`
`).find((l) => l.toLowerCase().startsWith(key + ":"));
  return line ? line.slice(key.length + 1).trim().replace(/^["']|["']$/g, "") : "";
}
var docTitle = () => frontValue2(text2(), "title") || (state.project ? state.project.name : "Marklove");
var darkQuery = matchMedia("(prefers-color-scheme: dark)");
var contrastQuery = matchMedia("(prefers-contrast: more)");
function applyTheme() {
  const themes2 = themes();
  const t = themes2.find((x) => x.id === settings.themeID) || themes2[0];
  if (!t)
    return;
  const a = settings.appearance;
  const dark = t.darkOnly || a === "dark" || a === "system" && darkQuery.matches;
  const contrast = settings.increaseContrast || contrastQuery.matches;
  const p = themePalette(t.id, "", dark, contrast);
  const s = $("workspace").style;
  const colors = [
    ["bg", p.background],
    ["surface", p.surface],
    ["border", p.border],
    ["dim", p.dim],
    ["text", p.text],
    ["strong", p.strong],
    ["accent", p.accent],
    ["red", p.red],
    ["green", p.green],
    ["orange", p.orange],
    ["violet", p.violet],
    ["yellow", p.yellow]
  ];
  for (const [name, value] of colors)
    s.setProperty("--" + name, value);
  s.colorScheme = dark ? "dark" : "light";
  document.documentElement.classList.toggle("contrast", contrast);
  setPalette(p.roles);
}
function applySettings(reset = false) {
  applyTheme();
  setMetrics({ scale: settings.editorTextScale, spacing: settings.editorLineSpacing, wrap: settings.wrapLines });
  const vim = settings.vimEnabled && !readOnly();
  if (editor.vim !== vim || reset)
    setVim(vim);
  if (vim && tooLarge(text2()))
    vimInsert();
  updateStatus();
}
darkQuery.addEventListener("change", applyTheme);
contrastQuery.addEventListener("change", applyTheme);
function updateStatus() {
  const vim = editor.vim;
  $("vim-mode").hidden = !vim;
  $("vim-mode").textContent = vim ? vimModeName(editor.vimMode) : "";
  $("vim-line").textContent = vim ? editor.vimStatus : "";
  const ls = $("line-status");
  ls.hidden = !settings.showLineCount;
  if (settings.showLineCount) {
    const s = lineStatus();
    ls.textContent = `Line ${s.line} of ${s.lines} · Words: ${s.words}`;
  }
  $("statusbar").hidden = !vim && !settings.showLineCount;
}
function renderBanners() {
  const box = $("banners");
  box.replaceChildren();
  if (readOnly()) {
    box.append(h("div", { class: "banner", role: "status" }, h("span", { "aria-hidden": "true" }, "\uD83D\uDC65"), h("span", { class: "msg" }, h("strong", { text: "Received presentation" }), h("span", { class: "detail", text: "This presentation opens view only. Select Present to show it." }))));
  }
  if (tooLarge(text2())) {
    box.append(h("div", { class: "banner", role: "alert" }, h("span", { class: "warn", "aria-hidden": "true" }, "⚠"), h("span", { class: "msg" }, h("strong", { text: "The Markdown file is larger than 512 KB." }), h("span", { class: "detail", text: "Preview, checks, and export stop at this size. Split the text into more projects." }))));
  }
  const f = state.focus;
  if (f) {
    box.append(h("div", { class: "banner", role: "region", "aria-label": "Source issue" }, h("span", { class: "warn", "aria-hidden": "true" }, "⚠"), h("span", { class: "msg" }, h("strong", { text: f.message || "Source passage" }), f.detail ? h("span", { class: "detail", text: f.detail }) : null), f.returnToExport ? h("button", { type: "button", class: "button", onclick: () => {
      state.focus = null;
      renderBanners();
      openExport();
    } }, "Back to Export") : null, h("button", { type: "button", class: "iconbtn", "aria-label": "Close the explanation", title: "Close the explanation", onclick: () => {
      state.focus = null;
      renderBanners();
      focus();
    } }, "✕")));
  }
}
async function refreshList() {
  state.list = await projects();
}
function urlsFor(assets) {
  for (const u of Object.values(state.assetURLs))
    URL.revokeObjectURL(u);
  const out = {};
  for (const [p, b] of Object.entries(assets))
    out[p] = URL.createObjectURL(b);
  return out;
}
var source = () => byId("source", HTMLTextAreaElement);
function showProjectName(name) {
  $("title-text").textContent = name;
  $("title-menu").setAttribute("aria-label", "Project: " + name);
  $("title-menu").title = name;
  document.title = name + " – Marklove";
}
async function openProject(id, { preview = false } = {}) {
  if (state.project && state.project.id !== id) {
    await flushSave();
    await saveVersion({ auto: true });
    saveEditorState();
  }
  const p = await project(id);
  if (!p)
    return;
  state.project = p;
  state.assets = await assetBlobs(id);
  state.assetURLs = urlsFor(state.assets);
  state.focus = null;
  state.lastVersion = 0;
  setSetting("lastProject", id);
  editor.readOnly = readOnly();
  source().readOnly = readOnly();
  setText(p.markdown);
  updatePlaceholder();
  showProjectName(p.name);
  restoreEditorState();
  applySettings(true);
  renderBanners();
  if (find2.open)
    refresh();
  await refreshList();
  if (preview || readOnly())
    showPreview();
  else
    showEdit(false);
}
function saveEditorState() {
  if (!state.project)
    return;
  const [s, e] = selection();
  setEditorState(state.project.id, { s, e, top: source().scrollTop });
}
function restoreEditorState() {
  const st = editorState(currentProject().id);
  if (st) {
    setSelection(st.s, st.e, false);
    source().scrollTop = st.top || 0;
    $("highlight").scrollTop = st.top || 0;
  }
}
function updatePlaceholder() {
  $("placeholder").hidden = text2().length > 0;
}
async function newProject() {
  const p = await createProject({ name: "Untitled", markdown: "" });
  await firstVersion(p, `Create project “${p.name}”`);
  await openProject(p.id);
  focus();
}
async function firstVersion(p, message) {
  if (!settings.gitEnabled || tooLarge(p.markdown))
    return;
  const assets = await assetBlobs(p.id);
  await addVersion({ project: p.id, time: Date.now(), message, markdown: p.markdown, assets: Object.keys(assets) });
}
async function openTour() {
  const existing = (await projects()).find((p) => p.isDemo);
  if (existing) {
    await openProject(existing.id);
    return;
  }
  const t = tour();
  const assets = {};
  for (const [path, file] of Object.entries(t.assets)) {
    try {
      const r = await fetch(file);
      if (r.ok)
        assets[path] = await r.blob();
    } catch {
      continue;
    }
  }
  const p = await createProject({ name: t.name, markdown: t.markdown, assets, demo: true });
  await firstVersion(p, `Create project “${p.name}”`);
  await openProject(p.id);
}
function nameFromMarkdown(md, fallback) {
  return frontValue2(md, "title") || fallback.replace(/\.(md|markdown|txt|zip)$/i, "") || "Imported";
}
async function importFiles() {
  const files = await pickFile(".md,.markdown,.txt,.zip,text/markdown,text/plain,application/zip", true);
  let last = null;
  for (const f of files) {
    try {
      if (/\.zip$/i.test(f.name) || f.type === "application/zip") {
        const r = await packImport(f);
        if ("error" in r) {
          await alertBox(`Marklove could not import “${f.name}”. ${r.error}`);
          continue;
        }
        const listener = frontValue2(r.markdown, "marklove") === "listener";
        const name = (r.markdownName || f.name).replace(/\.(md|markdown|txt)$/i, "");
        const p = await createProject({ name, markdown: r.markdown, assets: r.assets, listener });
        if (!listener)
          await firstVersion(p, `Import project “${p.name}”`);
        if (r.warnings && r.warnings.length)
          await alertBox(r.warnings.join(`
`), "Imported with warnings");
        last = p;
      } else {
        const md = (await f.text()).replace(/\r\n?/g, `
`);
        if (tooLarge(md)) {
          await alertBox(`“${f.name}” is larger than 512 KB. Split it into more files, and import each file.`);
          continue;
        }
        const p = await createProject({ name: nameFromMarkdown(md, f.name), markdown: md });
        await firstVersion(p, `Import project “${p.name}”`);
        last = p;
      }
    } catch (e) {
      await alertBox(`Marklove could not import “${f.name}”. ${errorMessage3(e)}`);
    }
  }
  if (last) {
    await openProject(last.id);
    announce(`Imported “${last.name}”.`);
  }
}
async function deleteProject2(p) {
  const choice = await confirmBox({
    title: `Delete “${p.name}”?`,
    message: "This deletes the project, its images and media, and its version history from this browser. You cannot undo this.",
    choices: [{ label: "Save a ZIP Copy First", value: "zip" }, { label: "Delete Project", value: "delete", danger: true }]
  });
  if (!choice)
    return false;
  if (choice === "zip") {
    await saveZipCopy(p);
    return false;
  }
  await deleteProject(p.id);
  setEditorState(p.id, null);
  await refreshList();
  if (state.project && state.project.id === p.id) {
    state.project = null;
    const next = state.list.find((x) => !x.isListener) || state.list[0];
    if (next)
      await openProject(next.id);
    else
      await newProject();
  }
  announce(`Deleted “${p.name}”.`);
  return true;
}
async function saveZipCopy(p = state.project) {
  const target = p ?? currentProject();
  if (target.id === currentProject().id)
    await flushSave();
  const proj = must(await project(target.id), "the project to copy");
  const ctx = { name: proj.name, source: proj.markdown, assets: await assetBlobs(target.id), gitName: gitName(proj.markdown), gitEmail: settings.gitEmail };
  const blob = await projectZip(ctx, settings.gitEnabled ? await versions(target.id) : []);
  download(blob, safeFileName(proj.name) + ".zip");
}
async function rename(name) {
  const p = currentProject();
  if (name === p.name)
    return;
  const others = new Set(state.list.filter((x) => x.id !== p.id).map((x) => x.name.toLowerCase()));
  let n = safeFileName(name), i = 2;
  const base = n;
  while (others.has(n.toLowerCase()))
    n = base + " " + i++;
  p.name = n;
  await saveProject(p);
  showProjectName(n);
  await refreshList();
}
async function duplicate() {
  await flushSave();
  const p = await duplicateProject(currentProject());
  await firstVersion(p, `Create project “${p.name}”`);
  await openProject(p.id);
}
var SAVE_DELAY_MS = 500;
var IDLE_VERSION_MS = 30000;
var MIN_VERSION_GAP_MS = 120000;
function textChanged2() {
  updatePlaceholder();
  updateStatus();
  textChanged();
  if (state.focus) {
    state.focus = null;
    renderBanners();
  }
  clearTimeout(state.saveTimer);
  state.saveTimer = setTimeout(flushSave, SAVE_DELAY_MS);
  clearTimeout(state.idleTimer);
  state.idleTimer = setTimeout(autoVersion, IDLE_VERSION_MS);
  if (state.mode === "preview")
    schedulePreview();
  const big = tooLarge(text2());
  if (big)
    vimInsert();
  if (big !== state.wasLarge) {
    state.wasLarge = big;
    renderBanners();
  }
  updateEquation();
}
async function flushSave() {
  clearTimeout(state.saveTimer);
  const p = state.project;
  if (!p || readOnly())
    return;
  const t = text2();
  if (p.markdown === t)
    return;
  p.markdown = t;
  try {
    await saveProject(p);
  } catch (e) {
    announce("Marklove could not save the change. " + errorMessage3(e));
  }
}
function autoVersion() {
  const wait = state.lastVersion + MIN_VERSION_GAP_MS - Date.now();
  if (wait > 0) {
    state.idleTimer = setTimeout(autoVersion, wait);
    return;
  }
  saveVersion({ auto: true });
}
function gitName(md) {
  return settings.gitName || frontValue2(md, "author") || "Marklove";
}
async function saveVersion({ explicit = false, message = "" } = {}) {
  const p = state.project;
  if (!p || readOnly())
    return false;
  await flushSave();
  if (!settings.gitEnabled) {
    if (explicit)
      announce("Saved. Versions are off in Settings.");
    return false;
  }
  if (tooLarge(p.markdown)) {
    if (explicit)
      announce("The Markdown file is larger than 512 KB. Split it into more projects.");
    return false;
  }
  const all = await versions(p.id);
  const last = all[0];
  const paths = Object.keys(state.assets).sort();
  const same = last && last.markdown === p.markdown && (last.assets || []).slice().sort().join(`
`) === paths.join(`
`);
  if (same && !message) {
    if (explicit)
      announce("Saved. No changes since the last version.");
    return false;
  }
  let msg = message;
  if (!msg) {
    try {
      msg = commitMessage(last ? last.markdown : "", p.markdown);
    } catch {
      msg = "";
    }
    if (!msg.trim())
      msg = last ? `Change “${p.name}”` : `Create project “${p.name}”`;
  }
  await addVersion({ project: p.id, time: Date.now(), message: msg, markdown: p.markdown, assets: paths });
  state.lastVersion = Date.now();
  clearTimeout(state.idleTimer);
  if (explicit)
    announce("Saved a version: " + (msg.split(`
`)[0] ?? ""));
  return true;
}
async function restoreVersion(v) {
  if (tooLarge(text2())) {
    await alertBox("The text is larger than 512 KB, so Marklove cannot keep it as a version. Make it shorter before you restore an older version.");
    return;
  }
  if (!await saveVersion({ auto: true })) {
    const last = (await versions(currentProject().id))[0];
    if (!last || last.markdown !== text2()) {
      await alertBox("Marklove cannot keep the current text as a version. Turn on versions in Settings before you restore an older version.");
      return;
    }
  }
  replaceAll(v.markdown);
  await flushSave();
  const date = new Date(v.time).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  await saveVersion({ message: `Restore the version from ${date}` });
  announce("Restored the version from " + date);
}
async function discardToLastVersion() {
  const last = (await versions(currentProject().id))[0];
  if (!last) {
    announce("No version to go back to.");
    return;
  }
  replaceAll(last.markdown);
  announce("Went back to the last version.");
}
var IMAGE_LONG_EDGE = 2560;
var IMAGE_MAX_BYTES = 3 * 1024 * 1024;
var IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "gif", "webp", "svg"];
async function fitImage(file) {
  let bmp;
  try {
    bmp = await createImageBitmap(file);
  } catch {
    return { blob: file, ext: (file.name.split(".").pop() || "png").toLowerCase() };
  }
  const long = Math.max(bmp.width, bmp.height);
  const ext = (file.name.split(".").pop() || "").toLowerCase();
  if (long <= IMAGE_LONG_EDGE && file.size <= IMAGE_MAX_BYTES && IMAGE_EXTENSIONS.includes(ext))
    return { blob: file, ext: ext === "jpeg" ? "jpg" : ext };
  const scale = Math.min(1, IMAGE_LONG_EDGE / long);
  const c = document.createElement("canvas");
  c.width = Math.round(bmp.width * scale);
  c.height = Math.round(bmp.height * scale);
  const g = must(c.getContext("2d"), "a canvas context");
  g.fillStyle = "#fff";
  g.fillRect(0, 0, c.width, c.height);
  g.drawImage(bmp, 0, 0, c.width, c.height);
  const blob = must(await new Promise((r) => c.toBlob(r, "image/jpeg", 0.85)), "the encoded image");
  return { blob, ext: "jpg" };
}
async function addMedia(kind) {
  if (readOnly())
    return;
  const accept = kind === "image" ? "image/*" : kind === "video" ? "video/*" : "image/*,video/*";
  const [file] = await pickFile(accept);
  if (!file)
    return;
  const video = file.type.startsWith("video/");
  const folder = kind === "image" ? "images" : "media";
  const fitted = video ? { blob: file, ext: (file.name.split(".").pop() || "mp4").toLowerCase() } : await fitImage(file);
  const path = assetName(state.assets, folder, file.name, fitted.ext);
  await addAsset(currentProject().id, path, fitted.blob);
  state.assets[path] = fitted.blob;
  state.assetURLs[path] = URL.createObjectURL(fitted.blob);
  insert(snippet(`![⟦Describe the ${video ? "video" : "image"}⟧](${path})`));
}
var SNIPPETS = {
  slide: ["Slide", `## ⟦Slide title⟧
`],
  section: ["Section", `# ⟦Section title⟧
`],
  pause: ["Pause (Reveal)", `. . .

⟦Next part⟧`],
  notes: ["Speaker Notes", `::: notes
⟦Notes for the presenter only.⟧
:::`],
  narration: ["Narration", `::: narration
⟦The words that narration speaks for this slide.⟧
:::`],
  explanation: ["Spoken Explanation", `::: explain
⟦Explain the equation or picture above in words.⟧
:::`],
  publicNotes: ["Notes for Listeners", `::: public-notes
⟦Notes for listeners and the handout.⟧
:::`],
  inlineMath: ["Inline Math", "$⟦x^2⟧$", false],
  displayMath: ["Equation", `$$
⟦E = mc^2⟧
$$`],
  equationSteps: ["Equation Steps", `::: morph
$$⟦a = b + c⟧$$
$$a - c = b$$
:::`],
  table: ["Table", `| ⟦Heading⟧ | Heading |
| --- | --- |
| Cell | Cell |
| Cell | Cell |`],
  chart: ["Bar Chart from Table", `::: chart bar
| ⟦Label⟧ | Value |
| --- | ---: |
| A | 1 |
| B | 2 |
:::`],
  plot: ["Plot with Slider", `::: plot
x: 0, 6.28
xlabel: x
ylabel: y
slider: k, 0.5, 3, 1, Frequency
y = ⟦sin(k*x)⟧
:::`],
  codeBlock: ["Code Block", "```swift\n⟦code⟧\n```"],
  theorem: ["Theorem", `::: theorem ⟦Name⟧
Statement.
:::`],
  definition: ["Definition", `::: definition ⟦Term⟧
Meaning.
:::`],
  example: ["Example", `::: example ⟦Title⟧
Text.
:::`],
  alert: ["Alert", `::: alert ⟦Title⟧
Text.
:::`],
  columns: ["Two Columns", `::: columns
::: column
⟦Left⟧
:::
::: column
Right
:::
:::`],
  articleOnly: ["Article-Only Text", `<!-- article -->
⟦Text for the article only.⟧
<!-- /article -->`],
  slidesOnly: ["Slide-Only Text", `<!-- slides -->
⟦Text for the slides only.⟧
<!-- /slides -->`]
};
function snippetDef(id) {
  return SNIPPETS[id];
}
function perform(id) {
  if (readOnly())
    return;
  if (id === "title") {
    insertFrontMatter();
    return;
  }
  const [s, e] = selection();
  if (id === "articleOnly" && s !== e) {
    wrapSelectionInLines("<!-- article -->", "<!-- /article -->");
    return;
  }
  if (id === "slidesOnly" && s !== e) {
    wrapSelectionInLines("<!-- slides -->", "<!-- /slides -->");
    return;
  }
  const [, text, block = true] = snippetDef(id);
  insert(snippet(text, block));
}
function insertItems() {
  const it = (id) => ({ label: id === "title" ? "Title and Details" : snippetDef(id)[0], action: () => perform(id) });
  const groups = [
    ["Structure", ["title", "section", "columns"]],
    ["Narration", ["narration", "explanation", "publicNotes"]],
    ["Math", ["inlineMath", "equationSteps"]],
    ["Data", ["table", "plot", "chart", "codeBlock"]],
    ["Blocks", ["theorem", "definition", "example", "alert"]],
    ["Scope", ["articleOnly", "slidesOnly"]]
  ];
  const items = [it("slide"), { label: "Photo or Video…", action: () => addMedia("any") }, it("displayMath"), it("notes"), it("pause")];
  for (const [name, ids] of groups) {
    items.push({ separator: true }, { header: name }, ...ids.map(it));
    if (name === "Data")
      items.push({ separator: true }, { header: "Files" }, { label: "Image File…", action: () => addMedia("image") }, { label: "Video File…", action: () => addMedia("video") });
  }
  return items;
}
var parseSlideStyle = (v) => v === "takahashi" ? "takahashi" : "normal";
var takahashi = () => settings.slideStyle === "takahashi";
function buildPage(src) {
  const article = state.view === "article";
  const kind = article ? PAGE_ARTICLE : PAGE_SLIDES;
  const opts = article ? O_TOC : slideOptions(takahashi());
  const d = doc(src, state.assetURLs, { kind });
  const html = page(d, kind, opts);
  let outline2 = [];
  try {
    outline2 = outline(doc(src, state.assetURLs), slideOptions(takahashi()));
  } catch {
    outline2 = [];
  }
  return { html, outline: outline2 };
}
function showPreviewMessage(text) {
  frame().clear();
  const old = $("preview-pane").querySelector(".preview-message");
  if (old)
    old.remove();
  $("preview-pane").append(h("div", { class: "preview-message alert-text", role: "status", style: { padding: "24px" }, text }));
}
function refreshPreview(jump = false) {
  const t = text2();
  $("preview-pane").querySelector(".preview-message")?.remove();
  if (tooLarge(t)) {
    showPreviewMessage("The Markdown file is larger than 512 KB. Split it into more projects to see the preview.");
    return;
  }
  let r;
  try {
    r = buildPage(t);
  } catch (e) {
    showPreviewMessage("Marklove could not make the preview. " + errorMessage3(e));
    return;
  }
  state.outline = r.outline;
  state.html = r.html;
  const offset = jump ? state.previewOffset : selection()[0];
  const slide = r.outline.length ? slideAt(r.outline, offset) : null;
  const fr = frame();
  if (state.view === "slides")
    fr.show(r.html, slide ? encodeURIComponent(slide.id) : "");
  else {
    fr.onload = (f) => {
      fr.onload = null;
      if (jump && slide)
        scrollArticle(f, slide.id);
    };
    fr.show(r.html, "", !jump);
  }
}
function scrollArticle(f, id) {
  try {
    f.contentDocument?.getElementById(id)?.scrollIntoView({ block: "start" });
  } catch {
    return;
  }
}
var PREVIEW_DELAY_MS = 350;
var FOLLOW_DELAY_MS = 300;
var SPLIT_MIN_WIDTH = 900;
var previewTimer;
function schedulePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(() => refreshPreview(false), PREVIEW_DELAY_MS);
}
var followTimer;
function followCursor() {
  if (state.mode !== "preview" || !split())
    return;
  clearTimeout(followTimer);
  followTimer = setTimeout(() => {
    if (!state.outline.length || !state.html)
      return;
    const s = slideAt(state.outline, selection()[0]);
    if (!s)
      return;
    const fr = frame();
    if (state.view === "slides") {
      if (fr.currentId() !== s.id)
        fr.show(state.html, encodeURIComponent(s.id));
    } else if (fr.frame)
      scrollArticle(fr.frame, s.id);
  }, FOLLOW_DELAY_MS);
}
var split = () => !readOnly() && innerWidth > SPLIT_MIN_WIDTH;
function layout2() {
  const editing = state.mode === "edit";
  $("edit-actions").hidden = !editing || readOnly();
  $("present-actions").hidden = !editing || !readOnly();
  $("preview-actions").hidden = editing;
  $("preview-pane").hidden = editing;
  $("workspace").classList.toggle("split", !editing && !readOnly());
  $("editor-pane").hidden = !editing && readOnly();
  $("statusbar").classList.toggle("in-preview", !editing);
  $("fullscreen-btn").hidden = !document.fullscreenEnabled;
  $("edit-btn").hidden = readOnly();
}
function showPreview() {
  if (state.mode !== "preview") {
    state.previewOffset = selection()[0];
    saveEditorState();
  }
  state.mode = "preview";
  layout2();
  refreshPreview(true);
  if (!split())
    setTimeout(() => $("edit-btn").focus(), 0);
}
function showEdit(focusEditor = true) {
  const wasPreview = state.mode === "preview";
  if (wasPreview && state.view === "slides" && state.outline.length) {
    const id = frame().currentId();
    const s = state.outline.find((x) => x.id === id);
    if (s && !(s.s0 <= state.previewOffset && state.previewOffset < s.s1))
      setSelection(s.s0, s.s0);
  }
  if (document.fullscreenElement)
    document.exitFullscreen().catch(() => {});
  state.mode = "edit";
  layout2();
  frame().clear();
  if (focusEditor)
    focus();
}
function present() {
  if (state.mode !== "preview")
    showPreview();
  const pane = $("preview-pane");
  if (pane.requestFullscreen)
    pane.requestFullscreen().then(() => frame().frame?.focus()).catch(() => announce("The browser did not allow full screen."));
}
var eq = { open: false };
function toggleEquation() {
  eq.open = !eq.open;
  if (!eq.open) {
    $("eq-pop").hidden = true;
    return;
  }
  if (!updateEquation()) {
    eq.open = false;
    announce("Put the cursor in an equation to preview it.");
  }
}
function updateEquation() {
  const pop = $("eq-pop");
  if (!eq.open)
    return false;
  const t = text2();
  let m = null;
  try {
    m = mathAt(t, selection()[0]);
  } catch {
    m = null;
  }
  if (!m) {
    pop.hidden = true;
    return false;
  }
  const latex = m.latex;
  const bad = (mathCheck(latex) || "").split(`
`).filter(Boolean);
  const spoken = mathSpeech(latex).replace(/^[,\s]+|[,\s]+$/g, "");
  const math2 = h("div", { class: "eq-math" });
  if (bad.length)
    math2.append(h("p", { class: "eq-warn", text: `⚠ Marklove cannot draw ${bad.join(", ")}. Exports show the LaTeX text.` }));
  else
    math2.innerHTML = math(latex, true);
  pop.replaceChildren(math2, h("p", { class: "eq-spoken", "aria-label": "Spoken as: " + spoken, text: spoken }), h("div", { class: "eq-foot" }, h("span", { text: m.display ? "Display equation" : "Inline equation" }), h("span", { class: "spacer" }), h("button", { type: "button", class: "button", onclick: async () => {
    await copyText(latex);
    announce("Copied the LaTeX.");
  } }, "Copy LaTeX"), h("button", { type: "button", class: "iconbtn", "aria-label": "Close the equation preview", onclick: () => {
    eq.open = false;
    pop.hidden = true;
    focus();
  } }, "✕")));
  pop.hidden = false;
  return true;
}
var stylePicker = null;
function exportContext() {
  const src = text2();
  let prefersDark = null;
  try {
    prefersDark = themeResolve(frontValue2(src, "theme"), frontValue2(src, "accent")).prefersDark;
  } catch {
    prefersDark = null;
  }
  const project = currentProject();
  return {
    title: docTitle(),
    name: project.name,
    source: src,
    assets: state.assets,
    assetURLs: state.assetURLs,
    prefersDark,
    lastChoice: state.exportChoice,
    setChoice: (v) => {
      state.exportChoice = v;
    },
    style: () => settings.slideStyle,
    setStyle: (v) => {
      setSetting("slideStyle", parseSlideStyle(v));
      stylePicker?.setValue(v);
      if (state.mode === "preview")
        refreshPreview();
    },
    versions: () => settings.gitEnabled ? versions(project.id) : Promise.resolve([]),
    gitName: gitName(src),
    gitEmail: settings.gitEmail,
    beforeExport: async () => {
      await saveVersion({ auto: true });
    },
    listenerPreview: () => openListenerPreview(),
    speakerReady: () => openSpeakerReady(),
    goToSource: (d, fromExport) => goToSource(d, fromExport)
  };
}
function openExport() {
  if (tooLarge(text2())) {
    alertBox("The Markdown file is larger than 512 KB. Split it into more projects to export it.");
    return;
  }
  const ctx = exportContext();
  exportSheet(ctx);
}
function goToSource(d, fromExport) {
  if (state.mode !== "edit")
    showEdit(false);
  state.focus = { message: d.message, detail: d.detail, returnToExport: fromExport };
  renderBanners();
  focus();
  setSelection(d.start, Math.max(d.start, d.end));
}
function openSpeakerReady() {
  const r = speakerReady({ source: text2(), assets: state.assetURLs, takahashi: takahashi(), appearance: "", startOffset: selection()[0] });
  if ("error" in r)
    alertBox(r.error, "Speaker Ready");
}
function openListenerPreview() {
  const r = listenerPreview({ source: text2(), assets: state.assetURLs, takahashi: takahashi(), appearance: "" });
  if ("error" in r)
    alertBox(r.error, "Listener Preview");
}
var TITLE_MENU_PROJECTS = 8;
function titleItems() {
  const projects = state.list.filter((p) => !p.isListener).slice(0, TITLE_MENU_PROJECTS);
  return [
    { header: "Projects" },
    ...projects.map((p) => ({ label: p.name, checked: p.id === state.project?.id, action: () => openProject(p.id) })),
    { label: "New Project", shortcut: isMac ? "⌥⌘N" : "Ctrl+Alt+N", action: newProject },
    { label: "All Projects…", shortcut: isMac ? "⇧⌘O" : "Ctrl+Shift+O", action: () => projectsPanel(app2) },
    { label: "Received", action: () => projectsPanel(app2, { received: true }) },
    { separator: true },
    { label: "Rename…", disabled: readOnly(), action: () => renamePanel(app2) },
    { label: "Version History…", disabled: readOnly(), shortcut: isMac ? "⌥⌘Y" : "Ctrl+Alt+Y", action: () => historyPanel(app2) },
    { label: "Duplicate", action: duplicate },
    { label: "Import Markdown or ZIP…", shortcut: cmdKey + "O", action: importFiles },
    { label: "Save a ZIP Copy…", action: () => saveZipCopy() },
    { label: "Delete Project…", danger: true, action: () => deleteProject2(currentProject()) },
    { separator: true },
    { label: "Find and Replace…", disabled: readOnly(), shortcut: isMac ? "⌥⌘F" : "Ctrl+Alt+F", action: () => openFind({ replace: true }) },
    { label: "Outline", shortcut: isMac ? "⇧⌘L" : "Ctrl+Shift+L", action: () => outlinePanel(app2) },
    { label: "Speaker Ready", shortcut: isMac ? "⇧⌘R" : "Ctrl+Shift+R", action: openSpeakerReady },
    { label: "Customize…", disabled: readOnly(), action: () => customizePanel(app2) },
    { label: "Settings", action: () => settingsPanel(app2) },
    { label: "Help and Examples", action: () => helpPanel(app2) }
  ];
}
function handleKey(e) {
  if (e.defaultPrevented)
    return;
  const mod = isMac ? e.metaKey : e.ctrlKey;
  const ctlMac = isMac && e.ctrlKey;
  const code = e.code;
  const inDialog = !!document.querySelector("dialog[open]");
  const run = (fn) => {
    e.preventDefault();
    e.stopPropagation();
    closeMenu();
    fn();
  };
  if (e.key === "Escape" && state.mode === "preview" && !inDialog && !document.fullscreenElement && !(find2.open && document.activeElement?.closest("#findbar"))) {
    if (!readOnly())
      return run(() => showEdit());
  }
  if (!mod)
    return;
  if (inDialog)
    return;
  if (code === "KeyS" && !e.shiftKey && !e.altKey)
    return run(() => saveVersion({ explicit: true }));
  if (code === "KeyE" && (ctlMac || !isMac && e.altKey))
    return run(toggleEquation);
  if (code === "KeyE" && !e.shiftKey && !e.altKey)
    return run(openExport);
  if (code === "KeyF" && e.altKey)
    return run(() => openFind({ replace: true }));
  if (code === "KeyF" && !e.shiftKey)
    return run(() => openFind());
  if (code === "KeyG" && find2.open)
    return run(() => next(!e.shiftKey));
  if (code === "KeyX" && e.altKey)
    return run(() => openFind({ command: true }));
  if (code === "KeyO" && e.shiftKey)
    return run(() => projectsPanel(app2));
  if (code === "KeyO")
    return run(importFiles);
  if (code === "KeyY" && e.altKey)
    return run(() => historyPanel(app2));
  if (code === "KeyL" && e.altKey)
    return run(() => {
      setSetting("showLineCount", !settings.showLineCount);
      updateStatus();
    });
  if (code === "KeyL" && e.shiftKey)
    return run(() => outlinePanel(app2));
  if (code === "KeyR" && e.shiftKey)
    return run(openSpeakerReady);
  if (code === "KeyN" && e.altKey)
    return run(newProject);
  if (e.key === "Enter")
    return run(() => state.mode === "edit" ? showPreview() : readOnly() ? null : showEdit());
}
var app2 = {
  readOnly,
  text: () => text2(),
  title: docTitle,
  projectId: () => state.project?.id,
  projectName: () => state.project?.name || "",
  selectedText: () => text2().slice(...selection()),
  replaceAll: (t) => replaceAll(t),
  insertText: (t) => insert(snippet(t)),
  applySettings,
  openSettings: () => settingsPanel(app2),
  findSyntaxChanged: () => syntaxChanged(),
  openProject,
  newProject,
  importFiles,
  openTour,
  deleteProject: deleteProject2,
  rename,
  saveVersion,
  restoreVersion,
  goToSource: (s, e) => {
    if (state.mode !== "edit")
      showEdit(false);
    focus();
    setSelection(s, e);
  }
};
async function start() {
  try {
    await load();
    await loadParts();
    await open();
  } catch (e) {
    $("loading").textContent = "Marklove could not start. " + errorMessage3(e) + " Use a current browser, and open the page from a web server.";
    return;
  }
  $("preview-frame").remove();
  const fr = new PageFrame($("preview-pane"), "Preview");
  frameOrNull = fr;
  fr.onkey = handleKey;
  init({ textarea: source(), highlight: $("highlight"), box: $("editor"), placeholder: $("placeholder") });
  editor.onChange = textChanged2;
  editor.onSelect = () => {
    updateStatus();
    syncVimCursor();
    updateEquation();
    followCursor();
  };
  editor.onVimState = updateStatus;
  editor.onVimAction = (action, clip) => {
    if (action === "save")
      saveVersion({ explicit: true });
    else if (action === "discard")
      discardToLastVersion();
    else if (action === "copy" && clip)
      copyText(clip);
  };
  initFind($("findbar"), app2);
  attachMenu($("title-menu"), titleItems);
  attachMenu($("insert-btn"), insertItems);
  $("preview-btn").addEventListener("click", showPreview);
  $("export-btn").addEventListener("click", openExport);
  $("edit-btn").addEventListener("click", () => showEdit());
  $("present-only-btn").addEventListener("click", present);
  $("fullscreen-btn").addEventListener("click", present);
  $("export-btn").title = `Export slides, article, and other formats (${cmdKey}E)`;
  $("preview-btn").title = `Preview the slides (${cmdKey}Return)`;
  const viewPicker = segmented("View", [["slides", "Slides"], ["article", "Article"]], state.view, (v) => {
    state.view = v;
    $("style-picker").hidden = v !== "slides";
    refreshPreview(false);
  });
  $("view-picker").append(viewPicker);
  stylePicker = segmented("Slide style", [["normal", "Normal"], ["takahashi", "Takahashi"]], settings.slideStyle, (v) => {
    setSetting("slideStyle", parseSlideStyle(v));
    refreshPreview(false);
  });
  $("style-picker").append(stylePicker);
  document.addEventListener("keydown", handleKey);
  document.addEventListener("fullscreenchange", () => {
    $("workspace").classList.toggle("presenting", !!document.fullscreenElement);
  });
  addEventListener("resize", () => {
    if (state.mode === "preview")
      layout2();
  });
  addEventListener("pagehide", () => {
    flushSave();
    saveEditorState();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      flushSave();
      saveEditorState();
    }
  });
  applySettings();
  await refreshList();
  const last = state.list.find((p) => p.id === settings.lastProject);
  const firstWritable = state.list.find((p) => !p.isListener) || state.list[0];
  if (last)
    await openProject(last.id);
  else if (firstWritable)
    await openProject(firstWritable.id);
  else
    await openTour();
  $("loading").hidden = true;
  if (!settings.onboardingSeen)
    welcome(app2);
}
start();
