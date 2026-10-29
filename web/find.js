// Find and Replace (FindBar.swift) and the sam tutorial (SamTutorialView.swift).
// Patterns are Plan 9 (sam) regular expressions, or plain text.

import * as C from "./core.js";
import * as E from "./editor.js";
import { h, announce, attachMenu, dialog, section, footnote } from "./ui.js";
import { settings, setSetting } from "./store.js";

export const find = {
    open: false, showsReplace: false, showsCommand: false, matchCase: false,
    query: "", replacement: "", command: "",
    matches: [], current: -1, error: "", lastCount: null,
    commandOutput: [], commandStatus: "", commandError: "",
};

let bar = null;
let app = null;
const els = {};

export const SYNTAXES = [["sam", "Sam (Plan 9)"], ["vim", "Vim"], ["plain", "Plain text"]];
const syntax = () => (SYNTAXES.some((s) => s[0] === settings.findSyntax) ? settings.findSyntax : "sam");
const usesSam = () => syntax() === "sam";

export function initFind(el, appRef) {
    bar = el;
    app = appRef;
}

// --- matching -------------------------------------------------------------------

function toU16(t, pairs) {
    if (!pairs.length) return [];
    const map = E.byteMap(t);
    return pairs.map(([s, e]) => [map[s], map[e]]);
}

export function refresh(select = false) {
    find.error = "";
    if (!find.open || !find.query) { find.matches = []; find.current = -1; E.setFindHits([]); render(); return; }
    const t = E.text();
    let r;
    try { r = C.find(t, find.query, syntax(), !find.matchCase); } catch (e) { r = { error: e.message }; }
    if (r.error) { find.error = r.error; find.matches = []; }
    else find.matches = toU16(t, r.matches);
    const caret = E.selection()[0];
    find.current = find.matches.length ? Math.max(0, find.matches.findIndex(([s]) => s >= caret)) : -1;
    E.setFindHits(find.matches);
    if (select && find.current >= 0) show(find.current);
    render();
}

function show(i) {
    if (i < 0 || i >= find.matches.length) return;
    find.current = i;
    const [s, e] = find.matches[i];
    E.setSelection(s, e);
    render();
}

export function next(forward = true) {
    refresh();
    if (!find.matches.length) return;
    const [cs, ce] = E.selection();
    let i;
    if (forward) {
        i = find.matches.findIndex(([s]) => s > cs || (s === cs && cs === ce));
        if (i < 0) i = 0;
    } else {
        i = -1;
        find.matches.forEach(([s], k) => { if (s < cs) i = k; });
        if (i < 0) i = find.matches.length - 1;
    }
    show(i);
}

function replaceCurrent() {
    const t = E.text();
    const [s, e] = E.selection();
    let r;
    try { r = C.replace(t, find.query, find.replacement, syntax(), !find.matchCase, C.utf8Offset(t, s), C.utf8Offset(t, e), false); }
    catch (err) { r = { error: err.message }; }
    if (r.error) { find.error = r.error; render(); return; }
    if (!r.count) { next(); return; }
    E.replaceAll(r.text);
    const caret = C.utf16Offset(r.text, r.selection[1]);
    E.setSelection(caret, caret);
    next();
}

function replaceAllMatches() {
    const t = E.text();
    let r;
    try { r = C.replace(t, find.query, find.replacement, syntax(), !find.matchCase, 0, 0, true); }
    catch (err) { r = { error: err.message }; }
    if (r.error) { find.error = r.error; render(); return; }
    if (r.count) E.replaceAll(r.text);
    find.lastCount = r.count || 0;
    announce(find.lastCount + (find.lastCount === 1 ? " replacement." : " replacements."));
    refresh();
}

function runCommand() {
    const t = E.text();
    const [s, e] = E.selection();
    let r;
    try { r = C.sam(find.command, t, C.utf8Offset(t, s), C.utf8Offset(t, e), !find.matchCase); }
    catch (err) { r = { error: err.message }; }
    if (r.error) {
        find.commandError = r.error; find.commandStatus = ""; find.commandOutput = [];
        announce(r.error);
    } else {
        const nt = r.text === null ? t : r.text;
        if (r.text !== null) E.replaceAll(r.text);
        E.setSelection(C.utf16Offset(nt, r.selection[0]), C.utf16Offset(nt, r.selection[1]));
        find.commandOutput = r.printed || [];
        find.commandError = "";
        if (r.text === null && r.summary === "No changes." && s === e && !find.command.trim().startsWith(","))
            find.commandStatus = "No changes. Dot is empty. Put , before the command to use the whole file.";
        else find.commandStatus = r.summary;
        announce(find.commandStatus);
    }
    refresh();
}

function statusText() {
    if (find.error) return find.error;
    if (!find.query) return "";
    if (!find.matches.length) return "No matches";
    if (find.current >= 0) return `${find.current + 1} of ${find.matches.length}`;
    return `Matches: ${find.matches.length}`;
}

// --- the bar ------------------------------------------------------------------

export function openFind({ replace = false, command = false } = {}) {
    if (app.readOnly()) return;
    find.open = true;
    if (replace) find.showsReplace = true;
    if (command && usesSam()) find.showsCommand = true;
    build();
    bar.hidden = false;
    const target = command && find.showsCommand ? els.command : replace ? els.replace : els.query;
    const sel = E.text().slice(...E.selection());
    if (!command && sel && !sel.includes("\n") && !replace) { find.query = sel; els.query.value = sel; }
    target.focus();
    target.select?.();
    refresh(true);
}

export function closeFind() {
    find.open = false;
    bar.hidden = true;
    E.setFindHits([]);
    E.focus();
}

function build() {
    bar.replaceChildren();
    const q = h("input", {
        type: "text", value: find.query, placeholder: { sam: "Find (Sam)", vim: "Find (Vim)", plain: "Find" }[syntax()], "aria-label": "Find",
        autocomplete: "off", autocapitalize: "off", spellcheck: "false",
        title: usesSam() ? "Sam (Plan 9) pattern" : "",
        oninput: (e) => { find.query = e.target.value; find.lastCount = null; refresh(true); },
        onkeydown: (e) => { if (e.key === "Enter") { e.preventDefault(); next(!e.shiftKey); } },
    });
    const status = h("span", { class: "find-status", role: "status", "aria-live": "polite" });
    const prev = h("button", { type: "button", class: "iconbtn", "aria-label": "Previous Match", title: "Previous Match (⇧⌘G)", onclick: () => next(false) }, "▲");
    const nxt = h("button", { type: "button", class: "iconbtn", "aria-label": "Next Match", title: "Next Match (⌘G)", onclick: () => next(true) }, "▼");
    const opts = h("button", { type: "button", class: "iconbtn", "aria-label": "Find Options", title: "Replace, Match Case, and the sam command line" }, "⋯");
    attachMenu(opts, () => [
        { label: "Replace", checked: find.showsReplace, action: () => { find.showsReplace = !find.showsReplace; build(); if (find.showsReplace) els.replace.focus(); refresh(); } },
        usesSam() ? { label: "Sam Command Line", checked: find.showsCommand, action: () => { find.showsCommand = !find.showsCommand; build(); if (find.showsCommand) els.command.focus(); refresh(); } } : null,
        { label: "Match Case", checked: find.matchCase, action: () => { find.matchCase = !find.matchCase; refresh(true); } },
        { separator: true },
        usesSam() ? { label: "Sam Tutorial…", action: () => samTutorial() } : null,
        { label: "Pattern Syntax: " + (SYNTAXES.find((s) => s[0] === syntax())[1]) + "…", action: () => app.openSettings() },
    ].filter(Boolean), { align: "end" });
    const close = h("button", { type: "button", class: "iconbtn", "aria-label": "Close Find", title: "Close Find (Escape)", onclick: closeFind }, "✕");
    bar.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "⌕"), q, status, prev, nxt, opts, close));
    Object.assign(els, { query: q, status, prev, next: nxt });

    if (find.showsReplace) {
        const r = h("input", {
            type: "text", value: find.replacement, "aria-label": "Replace with", autocomplete: "off", spellcheck: "false",
            placeholder: { sam: "Replace (\\1, &, \\n)", vim: "Replace (\\1, &, \\u, \\r)", plain: "Replace" }[syntax()],
            oninput: (e) => { find.replacement = e.target.value; },
            onkeydown: (e) => { if (e.key === "Enter") { e.preventDefault(); replaceCurrent(); } },
        });
        const one = h("button", { type: "button", class: "button", onclick: replaceCurrent }, "Replace");
        const all = h("button", { type: "button", class: "button", "aria-label": "Replace All", onclick: replaceAllMatches }, "All");
        const count = h("span", { class: "find-status" });
        bar.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "⇄"), r, one, all), count);
        Object.assign(els, { replace: r, replaceOne: one, replaceAll: all, count });
    } else els.replace = q;

    if (usesSam() && find.showsCommand) {
        const c = h("textarea", {
            rows: "1", "aria-label": "Sam command", placeholder: "Sam command, for example ,x/teh/c/the/", spellcheck: "false",
            autocomplete: "off", autocapitalize: "off", title: "Runs on the selection. Put a comma first to use the whole file.",
            oninput: (e) => { find.command = e.target.value; e.target.rows = Math.min(5, e.target.value.split("\n").length); run.disabled = !find.command.trim(); },
            onkeydown: (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); if (find.command.trim()) runCommand(); } },
        });
        c.value = find.command;
        const run = h("button", { type: "button", class: "button", title: "Run the sam command (⌘Return)", disabled: !find.command.trim(), onclick: runCommand }, "Run");
        const cstatus = h("div", { class: "find-status", role: "status" });
        const out = h("pre", { class: "sam-output", "aria-label": "Command output", hidden: true });
        bar.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "»"), c, run), cstatus, out);
        Object.assign(els, { command: c, cstatus, out });
    } else els.command = q;
    bar.onkeydown = (e) => { if (e.key === "Escape") { e.preventDefault(); closeFind(); } };
    render();
}

function render() {
    if (!bar || bar.hidden && !find.open) return;
    if (!els.status) return;
    const st = statusText();
    els.status.textContent = st;
    els.status.classList.toggle("error", !!find.error);
    els.prev.disabled = els.next.disabled = !find.matches.length;
    if (find.showsReplace && els.replaceOne) {
        els.replaceOne.disabled = els.replaceAll.disabled = !find.matches.length;
        els.count.textContent = find.lastCount === null ? "" : `${find.lastCount} ${find.lastCount === 1 ? "replacement" : "replacements"}.`;
    }
    if (els.cstatus) {
        els.cstatus.textContent = find.commandError || find.commandStatus;
        els.cstatus.classList.toggle("error", !!find.commandError);
        els.out.hidden = !find.commandOutput.length;
        els.out.textContent = find.commandOutput.join("\n");
    }
}

// The text changed: the matches move.
let refreshTimer = 0;
export function textChanged() {
    if (!find.open || !find.query) return;
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => refresh(false), 120);
}

export function syntaxChanged() {
    if (find.open) { build(); refresh(true); }
}

// --- the sam tutorial ---------------------------------------------------------------

const NUMBERS = "Air 343 m/s\nWater 1480 m/s\nSteel 5960 m/s\n";
const LESSONS = [
    ["1. Dot and addresses", ["Dot is the selected text. Each command works on dot.",
        "An address selects new text. `2` is line 2. `,` is the whole file. `$` is the end.",
        "`/word/` is the next match after dot. `?word?` is the match before dot.",
        "Type `1,2` or `/Steel/` below. The highlight shows the new dot."], NUMBERS, "2"],
    ["2. Plan 9 patterns", ["A pattern finds text. `.` is any character. `[0-9]` is one digit. `[^ ]` is any character but a space.",
        "`*` is zero or more. `+` is one or more. `?` is zero or one. `|` separates alternatives. `( )` makes a group.",
        "`^` is the start of a line. `$` is the end of a line. A `\\` before a character finds that character.",
        "Sam takes the longest match at the first position. So `/a|ab/` finds `ab`, not `a`."], NUMBERS, "/[0-9]+/"],
    ["3. Change text", ["`c/text/` changes dot to the text. `a/text/` adds text after dot. `i/text/` adds text before dot. `d` deletes dot.",
        "An address can come before the command. `/Water/c/Sea water/` changes the next Water.",
        "In the text, `\\n` is a new line."], NUMBERS, "/Water/c/Sea water/"],
    ["4. Loop with x", ["`x/pattern/ command` runs the command on each match in dot.",
        "`,x/teh/c/the/` corrects each teh in the file. The comma makes dot the whole file.",
        "This is the main idea of sam: first select, then change."], "teh cat sat on teh mat\nteh end\n", ",x/teh/c/the/"],
    ["5. Lines and guards", ["`x` without a pattern runs the command on each line.",
        "`g/pattern/ command` runs the command only when dot has a match. `v/pattern/ command` runs it when dot has no match.",
        "`,x g/Steel/d` deletes each line with Steel. `,x v/Air/d` keeps only the lines with Air."], NUMBERS, ",x g/Steel/d"],
    ["6. Substitute with groups", ["`s/pattern/text/` replaces the first match in dot. Add `g` at the end to replace all matches.",
        "In the text, `&` is the full match. `\\1` to `\\9` are the groups in `( )`.",
        "This command puts each number before its name."], NUMBERS, ",s/([A-Za-z]+) ([0-9]+)/\\2 \\1/g"],
    ["7. Between the matches with y", ["`y/pattern/ command` runs the command on the text between the matches.",
        "Here, `y` selects each item between the commas, and `c` changes it."], "red, green, blue", ",y/, / c/color/"],
    ["8. Loops in loops, and braces", ["A loop can contain a loop. `,x/[A-Za-z]+ [0-9]+/ x/[0-9]+/ p` shows the numbers after a word.",
        "`{ }` runs several commands on the same dot. Put each command on its own line.",
        "Sam makes all changes at the end, together. Undo removes them in one step."], NUMBERS, ",x/[0-9]+/ {\ni/[/\na/]/\n}"],
    ["9. Show results", ["`p` shows the text of dot. `=` shows the line numbers and the character positions of dot.",
        "Use `p` to check a loop before you change text."], NUMBERS, ",x/[A-Z][a-z]+/ p"],
];
const REFERENCE = [
    [",", "The whole file"], ["n  #n", "Line n; the position after n characters"], ["/re/  ?re?", "The next match; the match before dot"],
    ["a,b  a;b", "From a to b; b starts at a"], [".  $  +  -", "Dot; the end; the next line; the line before"],
    ["x/re/ cmd", "Run cmd on each match"], ["y/re/ cmd", "Run cmd between the matches"], ["g/re/ cmd", "Run cmd if dot has a match"],
    ["v/re/ cmd", "Run cmd if dot has no match"], ["s/re/text/g", "Replace matches; & and \\1 to \\9"], ["c a i", "Change, append, insert: c/text/"],
    ["d", "Delete dot"], ["m addr  t addr", "Move or copy dot to after addr"], ["p  =", "Show the text; show the line numbers"],
    ["{ … }", "Several commands, one on each line"],
];

// Text with `code` parts.
function richText(s) {
    const p = h("p", {});
    s.split("`").forEach((part, i) => p.append(i % 2 ? h("code", { text: part }) : part));
    return p;
}

function lesson([title, text, sample, command]) {
    const result = h("div", {});
    const input = h("textarea", { rows: "1", "aria-label": "Command for " + title, spellcheck: "false", autocapitalize: "off", class: "lesson-cmd" });
    input.value = command;
    const reset = h("button", { type: "button", class: "button", hidden: true, onclick: () => { input.value = command; update(); } }, "Reset");
    function update() {
        reset.hidden = input.value === command;
        input.rows = Math.min(5, input.value.split("\n").length);
        result.replaceChildren();
        let r;
        try { r = C.sam(input.value, sample, 0, 0, false); } catch (e) { r = { error: e.message }; }
        if (r.error) { result.append(h("p", { class: "error-text", role: "status", text: "⚠ " + r.error })); return; }
        const t = r.text === null ? sample : r.text;
        const a = C.utf16Offset(t, r.selection[0]), b = C.utf16Offset(t, r.selection[1]);
        const code = h("pre", { class: "code", "aria-label": "Result" }, t.slice(0, a), b > a ? h("mark", { text: t.slice(a, b) }) : null, t.slice(b));
        result.append(h("p", { class: "cap-label", text: "Result" }), code);
        if (r.printed && r.printed.length) result.append(h("pre", { class: "code", "aria-label": "Output", text: r.printed.join("\n") }));
        result.append(footnote(r.summary));
    }
    input.addEventListener("input", update);
    update();
    return section(title, h("div", { class: "group" },
        text.map(richText),
        h("p", { class: "cap-label", text: "Sample text" }), h("pre", { class: "code", "aria-label": "Sample text", text: sample }),
        h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "»"), input, reset),
        result));
}

export function samTutorial() {
    const body = h("div", {},
        section("Structural editing", h("div", { class: "group" }, h("p", { text: "Sam is the text editor of Plan 9. Its commands select text first, then change it. In Marklove, open Find and use the Sam pattern syntax (Settings). Type a command in the command line and select Run." }))),
        LESSONS.map(lesson),
        section("Reference", h("div", { class: "group" }, REFERENCE.map(([k, v]) => h("div", { class: "find-row" }, h("strong", { class: "code-key", style: { fontFamily: "var(--mono)", minWidth: "9em" }, text: k }), h("span", { class: "row-hint", text: v })))),
            footnote("Marklove does not have sam's file commands, such as w, e, and q. Marklove saves each change for you.")));
    dialog({
        title: "Sam Tutorial", body, wide: true,
        buttons: [
            { label: "Use Sam in Find", cancel: true, disabled: app.readOnly(), action: () => { setSetting("findSyntax", "sam"); find.showsCommand = true; setTimeout(() => openFind({ command: true }), 0); } },
            { label: "Done", primary: true },
        ],
    });
}
