// The source editor: a transparent textarea over a highlighted copy of the
// text, as SourceEditor and EditorController in the app. All changes go
// through replaceRange, so that the browser's Undo keeps working.

import * as C from "./core.js";
import { announce } from "./ui.js";

const enc = new TextEncoder();

export const editor = {
    ta: null, pre: null, box: null, placeholder: null,
    onChange: () => {}, onSelect: () => {}, onVimAction: () => {}, onVimState: () => {},
    boldRoles: new Set(), italicRoles: new Set(),
    vim: false, vimMode: "normal", vimStatus: "", vimCursor: -1, vimPrevKey: "", vimClipReg: false,
    findHits: [], readOnly: false,
};

// --- set up -----------------------------------------------------------------

export function init({ textarea, highlight, box, placeholder }) {
    Object.assign(editor, { ta: textarea, pre: highlight, box, placeholder });
    const typo = C.typography().editor;
    editor.boldRoles = new Set(typo.bold);
    editor.italicRoles = new Set(typo.italic);
    textarea.addEventListener("input", () => { paint(); editor.onChange(textarea.value); });
    textarea.addEventListener("scroll", syncScroll);
    document.addEventListener("selectionchange", () => { if (document.activeElement === textarea) editor.onSelect(); });
    textarea.addEventListener("keydown", vimKeydown);
    new ResizeObserver(() => { applyMetrics(); syncScroll(); }).observe(box);
}

let metrics = { scale: 1, spacing: 1.4, wrap: true };

export function setMetrics(m) {
    metrics = { ...metrics, ...m };
    applyMetrics();
}

// EditorMetrics: a line of at most 76 characters, in the middle of the view.
function applyMetrics() {
    const size = 15 * metrics.scale;
    const width = editor.box.clientWidth;
    const narrow = width < 600;
    const minSide = narrow ? 16 : 20;
    const side = Math.max(minSide, (width - size * 0.6 * 76) / 2);
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

// --- the text -----------------------------------------------------------------

export const text = () => editor.ta.value;

// Opens a new text: no Undo history from the previous project.
export function setText(t) {
    editor.ta.value = t;
    editor.ta.setSelectionRange(0, 0);
    editor.ta.scrollTop = 0;
    paint();
}

export function selection() { return [editor.ta.selectionStart, editor.ta.selectionEnd]; }

export function setSelection(s, e = s, reveal = true) {
    const n = editor.ta.value.length;
    s = Math.max(0, Math.min(s, n));
    e = Math.max(s, Math.min(e, n));
    editor.ta.setSelectionRange(s, e);
    if (reveal) revealSelection();
    editor.onSelect();
}

export function focus() { editor.ta.focus({ preventScroll: true }); }

// Scrolls so that the selection is in view: the textarea scrolls only to the
// caret when it has focus, so this measures the line in the mirror.
export function revealSelection() {
    const [s] = selection();
    const y = offsetTop(s);
    const ta = editor.ta;
    if (y < ta.scrollTop + 20 || y > ta.scrollTop + ta.clientHeight - 60) ta.scrollTop = Math.max(0, y - ta.clientHeight / 3);
    syncScroll();
}

// The vertical position of a UTF-16 offset in the text, from the mirror.
export function offsetTop(offset) {
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

export function caretRect() {
    const pre = editor.pre;
    const [s] = selection();
    const mark = document.createElement("span");
    mark.textContent = "​";
    const t = editor.ta.value;
    const saved = [...pre.childNodes];
    pre.textContent = t.slice(0, s);
    pre.append(mark, t.slice(s) + " ");
    const r = { top: mark.offsetTop - editor.ta.scrollTop, left: mark.offsetLeft - editor.ta.scrollLeft, height: mark.offsetHeight };
    pre.replaceChildren(...saved);
    return r;
}

// Replaces text as one undoable step.
export function replaceRange(s, e, t) {
    const ta = editor.ta;
    if (editor.readOnly) return;
    ta.focus({ preventScroll: true });
    ta.setSelectionRange(s, e);
    let ok = false;
    try { ok = document.execCommand("insertText", false, t); } catch { ok = false; }
    if (!ok || ta.value.slice(s, s + t.length) !== t) {
        ta.setRangeText(t, s, e, "end");
        paint();
        editor.onChange(ta.value);
    }
}

// Replaces only the part that changed, so the scroll position stays and one
// Undo restores the text (FindState.replaceChangedPart).
export function replaceAll(next, { undoable = true } = {}) {
    const old = editor.ta.value;
    if (old === next) return;
    let p = 0;
    while (p < old.length && p < next.length && old.charCodeAt(p) === next.charCodeAt(p)) p++;
    let q = 0;
    while (q < old.length - p && q < next.length - p && old.charCodeAt(old.length - 1 - q) === next.charCodeAt(next.length - 1 - q)) q++;
    const isTrail = (c) => c >= 0xDC00 && c <= 0xDFFF;
    while (p > 0 && (isTrail(old.charCodeAt(p)) || isTrail(next.charCodeAt(p)))) p--;
    while (q > 0 && (isTrail(old.charCodeAt(old.length - q)) || isTrail(next.charCodeAt(next.length - q)))) q--;
    const middle = next.slice(p, next.length - q);
    if (undoable) replaceRange(p, old.length - q, middle);
    else {
        const top = editor.ta.scrollTop;
        editor.ta.setRangeText(middle, p, old.length - q, "preserve");
        editor.ta.scrollTop = top;
        paint();
        editor.onChange(editor.ta.value);
    }
}

// --- Insert -------------------------------------------------------------------

// A template with a placeholder between ⟦ and ⟧ (Snippet).
export function snippet(template, block = true) {
    const o = template.indexOf("⟦"), c = template.indexOf("⟧");
    if (o >= 0 && c > o) {
        return { text: template.slice(0, o) + template.slice(o + 1, c) + template.slice(c + 1), sel: [o, c - o - 1], block };
    }
    return { text: template, sel: [template.length, 0], block };
}

export function insert(sn) {
    const t = text();
    const [s, e] = selection();
    let prefix = "", suffix = "";
    if (sn.block) {
        const before = t.slice(0, s);
        if (before) prefix = before.endsWith("\n\n") ? "" : before.endsWith("\n") ? "\n" : "\n\n";
        const after = t.slice(e);
        if (!after.startsWith("\n")) suffix = after ? "\n\n" : "\n";
    }
    replaceRange(s, e, prefix + sn.text + suffix);
    const start = s + prefix.length + sn.sel[0];
    setSelection(start, start + sn.sel[1]);
    focus();
}

export function frontMatterLines(date = new Date()) {
    const lang = (navigator.language || "en").split("-")[0];
    return [
        "title: ⟦Title⟧", "subtitle: Subtitle", "author: Name", "institute: Institute",
        "date: " + date.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }),
        "lang: " + lang, "theme: selenized-light", "accent: blue", "voice: af_heart",
    ];
}

// Title and Details: adds the front matter, or the keys that it does not have.
export function insertFrontMatter() {
    const t = text();
    const lines = frontMatterLines().map((l) => l.replace("⟦", "").replace("⟧", ""));
    const key = (l) => (l.split(":")[0] || "").trim().toLowerCase();
    if (t.startsWith("---\n")) {
        const close = t.indexOf("\n---", 3);
        if (close >= 0) {
            const body = t.slice(4, Math.max(4, close));
            const have = new Set(body.split("\n").map(key));
            const missing = lines.filter((l) => !have.has(key(l)));
            if (missing.length) replaceRange(close, close, (close > 4 ? "\n" : "") + missing.join("\n"));
            selectTitleValue();
            return;
        }
    }
    const block = "---\n" + lines.join("\n") + "\n---\n" + (t.length === 0 || t.startsWith("\n") ? "" : "\n");
    replaceRange(0, 0, block);
    selectTitleValue();
}

function selectTitleValue() {
    const t = text();
    const i = t.slice(0, 4000).indexOf("\ntitle:");
    if (i >= 0) {
        let s = i + 7;
        while (t[s] === " ") s++;
        let e = t.indexOf("\n", s);
        if (e < 0) e = t.length;
        setSelection(s, e);
    } else setSelection(0, 0);
    focus();
}

export function wrapSelectionInLines(start, end) {
    const t = text();
    const [s, e] = selection();
    if (s === e) { insert(snippet(start + "\n⟦⟧\n" + end)); return; }
    const ls = t.lastIndexOf("\n", s - 1) + 1;
    let le = t.indexOf("\n", e > s && t[e - 1] === "\n" ? e - 1 : e);
    le = le < 0 ? t.length : le + 1;
    let body = t.slice(ls, le);
    if (!body.endsWith("\n")) body += "\n";
    const rep = start + "\n" + body + end + "\n";
    replaceRange(ls, le, rep);
    setSelection(ls, ls + rep.length);
}

// --- highlighting -------------------------------------------------------------

let roleColors = {};

export function setPalette(roles) {
    roleColors = roles;
    let css = "";
    for (const [role, color] of Object.entries(roles)) css += `.highlight .r-${role}{color:${color}}`;
    let st = document.getElementById("role-colors");
    if (!st) { st = document.createElement("style"); st.id = "role-colors"; document.head.append(st); }
    st.textContent = css;
    paint();
}

// UTF-8 byte offset to UTF-16 offset, for each byte boundary.
export function byteMap(t) {
    const map = new Uint32Array(enc.encode(t).length + 1);
    let b = 0;
    for (let i = 0; i < t.length; i++) {
        const c = t.charCodeAt(i);
        let n;
        if (c < 0x80) n = 1;
        else if (c < 0x800) n = 2;
        else if (c >= 0xD800 && c <= 0xDBFF) { n = 4; for (let k = 0; k < 4; k++) map[b + k] = i; b += 4; i++; continue; }
        else n = 3;
        for (let k = 0; k < n; k++) map[b + k] = i;
        b += n;
    }
    map[b] = t.length;
    return map;
}

let paintTimer = 0;

export function paint() {
    const t = editor.ta.value;
    editor.placeholder.hidden = t.length > 0 || editor.readOnly;
    cancelAnimationFrame(paintTimer);
    if (t.length > 60000) {
        editor.pre.textContent = t + " ";
        paintTimer = requestAnimationFrame(() => paintNow(t));
    } else paintNow(t);
    syncScroll();
}

const ROLE_NAMES = [];
function roleIndex(name) {
    let i = ROLE_NAMES.indexOf(name);
    if (i < 0) { ROLE_NAMES.push(name); i = ROLE_NAMES.length - 1; }
    return i;
}

function paintNow(t) {
    if (t !== editor.ta.value) return;
    let spans = [];
    try { spans = t.length ? C.highlightMarkdown(t) : []; } catch { spans = []; }
    const n = t.length;
    const roles = new Int16Array(n).fill(-1);
    if (spans.length) {
        const map = byteMap(t);
        for (const [s, e, role] of spans) {
            const a = map[Math.min(s, map.length - 1)], b = map[Math.min(e, map.length - 1)];
            roles.fill(roleIndex(role), a, b);
        }
    }
    const marks = new Uint8Array(n);
    for (const [a, b] of editor.findHits) marks.fill(1, a, b);
    const vc = editor.vim && editor.vimMode !== "insert" ? editor.vimCursor : -1;
    if (vc >= 0 && vc < n && t[vc] !== "\n") marks[vc] = 2;
    const c = editor.vim && editor.vimMode !== "insert" ? editor.vimCursor : -1;
    // A cursor on a line break or at the end: a space with the cursor color.
    const extra = c >= 0 && (c >= n || t[c] === "\n") ? c : -1;
    const cursorSpan = () => { const sp = document.createElement("span"); sp.className = "vim-cursor"; sp.textContent = " "; return sp; };
    const frag = document.createDocumentFragment();
    let i = 0;
    while (i < n) {
        if (i === extra) frag.append(cursorSpan());
        let j = i + 1;
        while (j < n && j !== extra && roles[j] === roles[i] && marks[j] === marks[i]) j++;
        const r = roles[i], m = marks[i];
        const chunk = t.slice(i, j);
        if (r < 0 && !m) frag.append(chunk);
        else {
            const sp = document.createElement("span");
            const name = r >= 0 ? ROLE_NAMES[r] : "";
            let cls = name ? "r-" + name : "";
            if (editor.boldRoles.has(name)) cls += " b";
            if (editor.italicRoles.has(name)) cls += " i";
            if (m === 1) cls += " find-hit";
            if (m === 2) cls += " vim-cursor";
            sp.className = cls;
            sp.textContent = chunk;
            frag.append(sp);
        }
        i = j;
    }
    if (extra >= n) frag.append(cursorSpan());
    frag.append(" ");
    editor.pre.replaceChildren(frag);
}

export function setFindHits(hits) {
    editor.findHits = hits;
    paint();
}

// --- status ---------------------------------------------------------------------

export function lineStatus() {
    const t = editor.ta.value;
    const loc = editor.ta.selectionStart;
    let lines = 1, line = 1;
    for (let i = t.indexOf("\n"); i >= 0; i = t.indexOf("\n", i + 1)) { lines++; if (i < loc) line++; }
    const words = (t.match(/[^\s]+/g) || []).length;
    return { line, lines, words };
}

// --- Vim mode -------------------------------------------------------------------

const MODE_NAMES = { normal: "NORMAL", insert: "INSERT", visual: "VISUAL", "visual-line": "VISUAL LINE", command: "COMMAND" };
const MODE_SPOKEN = { normal: "Normal mode", insert: "Insert mode", visual: "Visual mode", "visual-line": "Visual line mode", command: "Command line" };
export const vimModeName = (m) => MODE_NAMES[m] || "NORMAL";

export function setVim(on) {
    editor.vim = on;
    if (on) {
        C.vimReset();
        editor.vimMode = "normal";
        editor.vimStatus = "";
        editor.vimCursor = editor.ta.selectionStart;
    }
    editor.box.classList.toggle("vim-normal", on && editor.vimMode !== "insert");
    paint();
    editor.onVimState();
}

function keyName(e) {
    if (e.metaKey || e.altKey && e.key.length !== 1) return null;
    const named = ["Escape", "Enter", "Backspace", "Tab", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"];
    if (e.ctrlKey) {
        if (e.key === "[") return "Escape";
        if (e.key.length === 1) return "Ctrl-" + e.key.toLowerCase();
        return null;
    }
    if (named.includes(e.key)) return e.key;
    if ([...e.key].length === 1) return e.key;
    return null;
}

function vimKeydown(e) {
    if (!editor.vim || editor.readOnly || e.isComposing) return;
    const key = keyName(e);
    if (!key) return;
    // Insert mode: typed text and the line keys go to the text area.
    if (editor.vimMode === "insert" && key !== "Escape" && !key.startsWith("Ctrl-")) return;
    // "+ and "* name the system clipboard: p and P read it first.
    const prev = editor.vimPrevKey;
    editor.vimPrevKey = key;
    if (editor.vimMode === "command") editor.vimClipReg = false;
    else if (prev === '"' && (key === "+" || key === "*")) editor.vimClipReg = true;
    else if (editor.vimClipReg && (key === "p" || key === "P")) {
        editor.vimClipReg = false;
        e.preventDefault();
        e.stopPropagation();
        clipboardKey(key);
        return;
    } else if (!/^[0-9]$/.test(key)) editor.vimClipReg = false;
    if (runVimKey(key)) {
        e.preventDefault();
        e.stopPropagation();
    }
}

async function clipboardKey(key) {
    let clip = "";
    try { clip = await navigator.clipboard.readText(); } catch { /* no permission: the register is empty */ }
    try { C.vimClipboard(clip); } catch (err) { vimMessage(err.message); return; }
    runVimKey(key);
}

// Returns true when the key had an effect in Vim.
function runVimKey(key) {
    const t = editor.ta.value;
    const [s16, e16] = selection();
    let r;
    try { r = C.vimKey(t, C.utf8Offset(t, s16), C.utf8Offset(t, e16), key); }
    catch (err) {
        if (!(err instanceof C.TooLarge)) throw err;
        vimMessage(err.message);
        return true;
    }
    if (!r.handled) return false;
    applyVim(r);
    return true;
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
    const a = C.utf16Offset(t, r.sel[0]), b = C.utf16Offset(t, r.sel[1]);
    const cursor = C.utf16Offset(t, r.cursor);
    const prev = editor.vimMode;
    editor.vimMode = r.mode;
    editor.vimStatus = r.status || "";
    editor.vimCursor = cursor;
    if (r.mode === "visual" || r.mode === "visual-line") editor.ta.setSelectionRange(Math.min(a, b), Math.max(a, b));
    else editor.ta.setSelectionRange(cursor, cursor);
    editor.box.classList.toggle("vim-normal", r.mode !== "insert");
    if (prev !== r.mode) announce(MODE_SPOKEN[r.mode] || "");
    paint();
    revealCaret();
    editor.onSelect();
    editor.onVimState();
    if (r.action) editor.onVimAction(r.action, r.clip);
}

function revealCaret() {
    const ta = editor.ta;
    const y = offsetTop(editor.vimCursor >= 0 ? editor.vimCursor : ta.selectionStart);
    if (y < ta.scrollTop + 10 || y > ta.scrollTop + ta.clientHeight - 40) ta.scrollTop = Math.max(0, y - ta.clientHeight / 3);
    syncScroll();
}

// The cursor moved by mouse or by a toolbar command: the engine reads it at the next key.
export function syncVimCursor() {
    if (!editor.vim) return;
    const c = editor.ta.selectionStart;
    if (c !== editor.vimCursor && editor.vimMode !== "insert") { editor.vimCursor = c; paint(); }
}
