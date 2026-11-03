import * as C from "./core.ts";
import type { Span, Syntax } from "./core.ts";
import * as E from "./editor.ts";
import { h, announce, attachMenu, dialog, section, footnote } from "./ui.ts";
import type { MenuItem } from "./ui.ts";
import { settings, setSetting } from "./store.ts";
import type { FindSyntax } from "./store.ts";
import { must } from "./dom.ts";

export interface FindState {
    open: boolean;
    showsReplace: boolean;
    showsCommand: boolean;
    matchCase: boolean;
    query: string;
    replacement: string;
    command: string;
    matches: Span[];
    current: number;
    error: string;
    lastCount: number | null;
    commandOutput: string[];
    commandStatus: string;
    commandError: string;
}

export interface FindApp {
    readOnly(): boolean;
    openSettings(): void;
}

type Field = HTMLInputElement | HTMLTextAreaElement;

interface Els {
    query?: HTMLInputElement;
    replace?: Field;
    command?: Field;
    status?: HTMLSpanElement;
    prev?: HTMLButtonElement;
    next?: HTMLButtonElement;
    replaceOne?: HTMLButtonElement;
    replaceAll?: HTMLButtonElement;
    count?: HTMLSpanElement;
    cstatus?: HTMLDivElement;
    out?: HTMLPreElement;
}

type Lesson = readonly [string, readonly string[], string, string];

export const find: FindState = {
    open: false, showsReplace: false, showsCommand: false, matchCase: false,
    query: "", replacement: "", command: "",
    matches: [], current: -1, error: "", lastCount: null,
    commandOutput: [], commandStatus: "", commandError: "",
};

let bar: HTMLElement | null = null;
let app: FindApp | null = null;
const els: Els = {};

const REFRESH_DELAY_MS = 120;
const MAX_COMMAND_ROWS = 5;
const WHOLE_FILE_HINT = "No changes. Dot is empty. Put , before the command to use the whole file.";

export const SYNTAXES: readonly (readonly [FindSyntax, string])[] = [["sam", "Sam (Plan 9)"], ["vim", "Vim"], ["plain", "Plain text"]];
const syntax = (): Syntax => settings.findSyntax;
const syntaxName = (): string => SYNTAXES.find((s) => s[0] === syntax())?.[1] ?? "";
const usesSam = (): boolean => syntax() === "sam";
const barEl = (): HTMLElement => must(bar, "find bar");
const appRef = (): FindApp => must(app, "find app");
const messageOf = (e: unknown): string => (e instanceof Error ? e.message : String(e));

export function initFind(el: HTMLElement, appRefValue: FindApp): void {
    bar = el;
    app = appRefValue;
}

function toU16(t: string, pairs: Span[]): Span[] {
    if (!pairs.length) return [];
    const map = E.byteMap(t);
    return pairs.map(([s, e]) => [map[s] ?? t.length, map[e] ?? t.length]);
}

export function refresh(select = false): void {
    find.error = "";
    if (!find.open || !find.query) { find.matches = []; find.current = -1; E.setFindHits([]); render(); return; }
    const t = E.text();
    let r: C.FindResult;
    try { r = C.find(t, find.query, syntax(), !find.matchCase); } catch (e) { r = { error: messageOf(e) }; }
    if ("error" in r) { find.error = r.error; find.matches = []; }
    else find.matches = toU16(t, r.matches);
    const caret = E.selection()[0];
    find.current = find.matches.length ? Math.max(0, find.matches.findIndex(([s]) => s >= caret)) : -1;
    E.setFindHits(find.matches);
    if (select && find.current >= 0) show(find.current);
    render();
}

function show(i: number): void {
    const m = find.matches[i];
    if (!m) return;
    find.current = i;
    E.setSelection(m[0], m[1]);
    render();
}

export function next(forward = true): void {
    refresh();
    if (!find.matches.length) return;
    const [cs, ce] = E.selection();
    let i: number;
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

function replaceCurrent(): void {
    const t = E.text();
    const [s, e] = E.selection();
    let r: C.ReplaceResult;
    try { r = C.replace(t, find.query, find.replacement, syntax(), !find.matchCase, C.utf8Offset(t, s), C.utf8Offset(t, e), false); }
    catch (err) { r = { error: messageOf(err) }; }
    if ("error" in r) { find.error = r.error; render(); return; }
    if (!r.count || r.text === undefined || !r.selection) { next(); return; }
    E.replaceAll(r.text);
    const caret = C.utf16Offset(r.text, r.selection[1]);
    E.setSelection(caret, caret);
    next();
}

function replaceAllMatches(): void {
    const t = E.text();
    let r: C.ReplaceResult;
    try { r = C.replace(t, find.query, find.replacement, syntax(), !find.matchCase, 0, 0, true); }
    catch (err) { r = { error: messageOf(err) }; }
    if ("error" in r) { find.error = r.error; render(); return; }
    if (r.count && r.text !== undefined) E.replaceAll(r.text);
    find.lastCount = r.count || 0;
    announce(find.lastCount + (find.lastCount === 1 ? " replacement." : " replacements."));
    refresh();
}

function runCommand(): void {
    const t = E.text();
    const [s, e] = E.selection();
    let r: C.SamResult;
    try { r = C.sam(find.command, t, C.utf8Offset(t, s), C.utf8Offset(t, e), !find.matchCase); }
    catch (err) { r = { error: messageOf(err) }; }
    if ("error" in r) {
        find.commandError = r.error; find.commandStatus = ""; find.commandOutput = [];
        announce(r.error);
    } else {
        const nt = r.text === null ? t : r.text;
        if (r.text !== null) E.replaceAll(r.text);
        E.setSelection(C.utf16Offset(nt, r.selection[0]), C.utf16Offset(nt, r.selection[1]));
        find.commandOutput = r.printed;
        find.commandError = "";
        if (r.text === null && r.summary === "No changes." && s === e && !find.command.trim().startsWith(","))
            find.commandStatus = WHOLE_FILE_HINT;
        else find.commandStatus = r.summary;
        announce(find.commandStatus);
    }
    refresh();
}

function statusText(): string {
    if (find.error) return find.error;
    if (!find.query) return "";
    if (!find.matches.length) return "No matches";
    if (find.current >= 0) return `${find.current + 1} of ${find.matches.length}`;
    return `Matches: ${find.matches.length}`;
}

export function openFind({ replace = false, command = false }: { replace?: boolean; command?: boolean } = {}): void {
    if (appRef().readOnly()) return;
    find.open = true;
    if (replace) find.showsReplace = true;
    if (command && usesSam()) find.showsCommand = true;
    build();
    barEl().hidden = false;
    const query = must(els.query, "find field");
    const target = command && find.showsCommand ? must(els.command, "command field") : replace ? must(els.replace, "replace field") : query;
    const [from, to] = E.selection();
    const sel = E.text().slice(from, to);
    if (!command && sel && !sel.includes("\n") && !replace) { find.query = sel; query.value = sel; }
    target.focus();
    target.select();
    refresh(true);
}

function closeFind(): void {
    find.open = false;
    barEl().hidden = true;
    E.setFindHits([]);
    E.focus();
}

function build(): void {
    const box = barEl();
    box.replaceChildren();
    const q = h("input", {
        type: "text", value: find.query, placeholder: { sam: "Find (Sam)", vim: "Find (Vim)", plain: "Find" }[syntax()], "aria-label": "Find",
        autocomplete: "off", autocapitalize: "off", spellcheck: "false",
        title: usesSam() ? "Sam (Plan 9) pattern" : "",
        oninput: (e) => { if (e.target instanceof HTMLInputElement) { find.query = e.target.value; find.lastCount = null; refresh(true); } },
        onkeydown: (e: KeyboardEvent) => { if (e.key === "Enter") { e.preventDefault(); next(!e.shiftKey); } },
    });
    const status = h("span", { class: "find-status", role: "status", "aria-live": "polite" });
    const prev = h("button", { type: "button", class: "iconbtn", "aria-label": "Previous Match", title: "Previous Match (⇧⌘G)", onclick: () => next(false) }, "▲");
    const nxt = h("button", { type: "button", class: "iconbtn", "aria-label": "Next Match", title: "Next Match (⌘G)", onclick: () => next(true) }, "▼");
    const opts = h("button", { type: "button", class: "iconbtn", "aria-label": "Find Options", title: "Replace, Match Case, and the sam command line" }, "⋯");
    attachMenu(opts, () => {
        const items: (MenuItem | null)[] = [
            { label: "Replace", checked: find.showsReplace, action: () => { find.showsReplace = !find.showsReplace; build(); if (find.showsReplace) els.replace?.focus(); refresh(); } },
            usesSam() ? { label: "Sam Command Line", checked: find.showsCommand, action: () => { find.showsCommand = !find.showsCommand; build(); if (find.showsCommand) els.command?.focus(); refresh(); } } : null,
            { label: "Match Case", checked: find.matchCase, action: () => { find.matchCase = !find.matchCase; refresh(true); } },
            { separator: true },
            usesSam() ? { label: "Sam Tutorial…", action: () => samTutorial() } : null,
            { label: "Pattern Syntax: " + syntaxName() + "…", action: () => appRef().openSettings() },
        ];
        return items.filter((item) => item !== null);
    }, { align: "end" });
    const close = h("button", { type: "button", class: "iconbtn", "aria-label": "Close Find", title: "Close Find (Escape)", onclick: closeFind }, "✕");
    box.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "⌕"), q, status, prev, nxt, opts, close));
    Object.assign(els, { query: q, status, prev, next: nxt });

    if (find.showsReplace) {
        const r = h("input", {
            type: "text", value: find.replacement, "aria-label": "Replace with", autocomplete: "off", spellcheck: "false",
            placeholder: { sam: "Replace (\\1, &, \\n)", vim: "Replace (\\1, &, \\u, \\r)", plain: "Replace" }[syntax()],
            oninput: (e) => { if (e.target instanceof HTMLInputElement) find.replacement = e.target.value; },
            onkeydown: (e: KeyboardEvent) => { if (e.key === "Enter") { e.preventDefault(); replaceCurrent(); } },
        });
        const one = h("button", { type: "button", class: "button", onclick: replaceCurrent }, "Replace");
        const all = h("button", { type: "button", class: "button", "aria-label": "Replace All", onclick: replaceAllMatches }, "All");
        const count = h("span", { class: "find-status" });
        box.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "⇄"), r, one, all), count);
        Object.assign(els, { replace: r, replaceOne: one, replaceAll: all, count });
    } else els.replace = q;

    if (usesSam() && find.showsCommand) {
        const run = h("button", { type: "button", class: "button", title: "Run the sam command (⌘Return)", disabled: !find.command.trim(), onclick: runCommand }, "Run");
        const c = h("textarea", {
            rows: "1", "aria-label": "Sam command", placeholder: "Sam command, for example ,x/teh/c/the/", spellcheck: "false",
            autocomplete: "off", autocapitalize: "off", title: "Runs on the selection. Put a comma first to use the whole file.",
            oninput: (e) => {
                if (!(e.target instanceof HTMLTextAreaElement)) return;
                find.command = e.target.value;
                e.target.rows = Math.min(MAX_COMMAND_ROWS, e.target.value.split("\n").length);
                run.disabled = !find.command.trim();
            },
            onkeydown: (e: KeyboardEvent) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); if (find.command.trim()) runCommand(); } },
        });
        c.value = find.command;
        const cstatus = h("div", { class: "find-status", role: "status" });
        const out = h("pre", { class: "sam-output", "aria-label": "Command output", hidden: true });
        box.append(h("div", { class: "find-row" }, h("span", { class: "glyph", "aria-hidden": "true" }, "»"), c, run), cstatus, out);
        Object.assign(els, { command: c, cstatus, out });
    } else els.command = q;
    box.onkeydown = (e) => { if (e.key === "Escape") { e.preventDefault(); closeFind(); } };
    render();
}

function render(): void {
    if (!bar || bar.hidden && !find.open) return;
    if (!els.status || !els.prev || !els.next) return;
    els.status.textContent = statusText();
    els.status.classList.toggle("error", !!find.error);
    els.prev.disabled = els.next.disabled = !find.matches.length;
    if (find.showsReplace && els.replaceOne && els.replaceAll && els.count) {
        els.replaceOne.disabled = els.replaceAll.disabled = !find.matches.length;
        els.count.textContent = find.lastCount === null ? "" : `${find.lastCount} ${find.lastCount === 1 ? "replacement" : "replacements"}.`;
    }
    if (els.cstatus && els.out) {
        els.cstatus.textContent = find.commandError || find.commandStatus;
        els.cstatus.classList.toggle("error", !!find.commandError);
        els.out.hidden = !find.commandOutput.length;
        els.out.textContent = find.commandOutput.join("\n");
    }
}

let refreshTimer: ReturnType<typeof setTimeout> | undefined;
export function textChanged(): void {
    if (!find.open || !find.query) return;
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => refresh(false), REFRESH_DELAY_MS);
}

export function syntaxChanged(): void {
    if (find.open) { build(); refresh(true); }
}

const NUMBERS = "Air 343 m/s\nWater 1480 m/s\nSteel 5960 m/s\n";
const LESSONS: readonly Lesson[] = [
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
const REFERENCE: readonly (readonly [string, string])[] = [
    [",", "The whole file"], ["n  #n", "Line n; the position after n characters"], ["/re/  ?re?", "The next match; the match before dot"],
    ["a,b  a;b", "From a to b; b starts at a"], [".  $  +  -", "Dot; the end; the next line; the line before"],
    ["x/re/ cmd", "Run cmd on each match"], ["y/re/ cmd", "Run cmd between the matches"], ["g/re/ cmd", "Run cmd if dot has a match"],
    ["v/re/ cmd", "Run cmd if dot has no match"], ["s/re/text/g", "Replace matches; & and \\1 to \\9"], ["c a i", "Change, append, insert: c/text/"],
    ["d", "Delete dot"], ["m addr  t addr", "Move or copy dot to after addr"], ["p  =", "Show the text; show the line numbers"],
    ["{ … }", "Several commands, one on each line"],
];

function richText(s: string): HTMLParagraphElement {
    const p = h("p", {});
    s.split("`").forEach((part, i) => p.append(i % 2 ? h("code", { text: part }) : part));
    return p;
}

function lesson([title, text, sample, command]: Lesson): HTMLElement {
    const result = h("div", {});
    const input = h("textarea", { rows: "1", "aria-label": "Command for " + title, spellcheck: "false", autocapitalize: "off", class: "lesson-cmd" });
    input.value = command;
    const reset = h("button", { type: "button", class: "button", hidden: true, onclick: () => { input.value = command; update(); } }, "Reset");
    function update(): void {
        reset.hidden = input.value === command;
        input.rows = Math.min(MAX_COMMAND_ROWS, input.value.split("\n").length);
        result.replaceChildren();
        let r: C.SamResult;
        try { r = C.sam(input.value, sample, 0, 0, false); } catch (e) { r = { error: messageOf(e) }; }
        if ("error" in r) { result.append(h("p", { class: "error-text", role: "status", text: "⚠ " + r.error })); return; }
        const t = r.text === null ? sample : r.text;
        const a = C.utf16Offset(t, r.selection[0]), b = C.utf16Offset(t, r.selection[1]);
        const code = h("pre", { class: "code", "aria-label": "Result" }, t.slice(0, a), b > a ? h("mark", { text: t.slice(a, b) }) : null, t.slice(b));
        result.append(h("p", { class: "cap-label", text: "Result" }), code);
        if (r.printed.length) result.append(h("pre", { class: "code", "aria-label": "Output", text: r.printed.join("\n") }));
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

export function samTutorial(): void {
    const body = h("div", {},
        section("Structural editing", h("div", { class: "group" }, h("p", { text: "Sam is the text editor of Plan 9. Its commands select text first, then change it. In Marklove, open Find and use the Sam pattern syntax (Settings). Type a command in the command line and select Run." }))),
        LESSONS.map(lesson),
        section("Reference", h("div", { class: "group" }, REFERENCE.map(([k, v]) => h("div", { class: "find-row" }, h("strong", { class: "code-key", style: { fontFamily: "var(--mono)", minWidth: "9em" }, text: k }), h("span", { class: "row-hint", text: v })))),
            footnote("Marklove does not have sam's file commands, such as w, e, and q. Marklove saves each change for you.")));
    dialog({
        title: "Sam Tutorial", body, wide: true,
        buttons: [
            { label: "Use Sam in Find", cancel: true, disabled: appRef().readOnly(), action: () => { setSetting("findSyntax", "sam"); find.showsCommand = true; setTimeout(() => openFind({ command: true }), 0); } },
            { label: "Done", primary: true },
        ],
    });
}
