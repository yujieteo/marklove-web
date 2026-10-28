// The panels: Settings, Customize, Outline, Help, projects, Rename, Version
// History and the welcome (Panels.swift, VersionHistory.swift, OnboardingView.swift).

import * as C from "./core.js";
import * as S from "./store.js";
import * as Voice from "./voice.js";
import { samTutorial, SYNTAXES } from "./find.js";
import { h, dialog, section, footnote, toggleRow, selectRow, segmented, confirmBox, copyText, announce, cmdKey } from "./ui.js";

// --- Settings -------------------------------------------------------------------------

function slider(label, min, max, step, value, fmt, onchange) {
    const id = "r-" + Math.random().toString(36).slice(2);
    const out = h("span", { class: "row-hint", "aria-hidden": "true", text: fmt(value) });
    const input = h("input", {
        type: "range", id, min: String(min), max: String(max), step: String(step), value: String(value), "aria-valuetext": fmt(value),
        oninput: (e) => { const v = Number(e.target.value); out.textContent = fmt(v); e.target.setAttribute("aria-valuetext", fmt(v)); onchange(v); },
    });
    return h("div", { class: "row" }, h("label", { for: id, class: "row-label" }, label, out), input);
}

function textRow(label, value, placeholder, onchange, attrs = {}) {
    const id = "x-" + Math.random().toString(36).slice(2);
    return h("div", { class: "row" }, h("label", { for: id, class: "row-label", text: label }),
        h("input", { type: "text", id, value, placeholder, oninput: (e) => onchange(e.target.value), ...attrs }));
}

const themeOptions = () => C.themes().map((t) => [t.id, t.name]);

export function settingsPanel(app) {
    const set = (k, v) => { S.setSetting(k, v); app.applySettings(); };
    const body = h("div", {},
        section("Editor",
            selectRow("Theme", themeOptions(), S.settings.themeID, (v) => set("themeID", v)),
            selectRow("Appearance", [["system", "Automatic"], ["light", "Light"], ["dark", "Dark"]], S.settings.appearance, (v) => set("appearance", v)),
            slider("Text size", 0.8, 1.8, 0.1, S.settings.editorTextScale, (v) => Math.round(v * 100) + "%", (v) => set("editorTextScale", v)),
            slider("Line spacing", 1, 2, 0.1, S.settings.editorLineSpacing, (v) => v.toFixed(1), (v) => set("editorLineSpacing", v)),
            toggleRow("Show Line Count", S.settings.showLineCount, (v) => set("showLineCount", v)),
            toggleRow("Wrap Lines", S.settings.wrapLines, (v) => set("wrapLines", v)),
            toggleRow("Increase Contrast", S.settings.increaseContrast, (v) => set("increaseContrast", v), "Text colors at 7:1 contrast or more."),
            selectRow("Find patterns", SYNTAXES, S.settings.findSyntax, (v) => { set("findSyntax", v); app.findSyntaxChanged(); }),
            h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => { d.close(); samTutorial(); } }, "Sam Tutorial")),
            toggleRow("Vim Mode", S.settings.vimEnabled, (v) => set("vimEnabled", v), "Text commands and navigation. Marklove saves each change. :w saves a version. :q! goes back to the last version."),
            footnote("These settings stay in this browser. They do not change the project.")),
        section("Versions",
            toggleRow("Save Versions", S.settings.gitEnabled, (v) => set("gitEnabled", v)),
            textRow("Name", S.settings.gitName, "The front matter author", (v) => S.setSetting("gitName", v), { autocomplete: "name" }),
            textRow("Email", S.settings.gitEmail, "Optional", (v) => S.setSetting("gitEmail", v), { type: "email", autocomplete: "email", autocapitalize: "off", spellcheck: false }),
            footnote(`Marklove saves each change at once. It also saves a version after a pause in your typing, and when you press ${cmdKey}S or type :w. The version message says what changed. The project ZIP copy includes the history as Git, and other Git apps can read it.`)),
        voiceSection(app.text()),
        section("Storage",
            footnote("Projects, media, and versions stay in this browser, on this device. Nothing goes to a server. To move a project, save a ZIP copy and import it on the other device.")),
        section("About",
            footnote("Fonts: Courier Prime, Courier Prime Sans, Libre Baskerville, and KpMath, under the SIL Open Font License. The Kokoro voice is the kokoro-js web version of Kokoro-82M, under the Apache License 2.0.")));
    const d = dialog({ title: "Settings", body });
}

// The Kokoro voice (VoiceModelControls): Download, Play a Sample, and Delete.
function voiceSection(source) {
    const voice = C.meta(source, "voice") || Voice.DEFAULT_VOICE;
    const controls = h("div", {});
    const status = (t) => h("p", { class: "footnote", role: "status", text: t });
    async function render(state, p) {
        controls.replaceChildren();
        if (state === "downloading") {
            controls.append(h("progress", { max: "1", value: String(p || 0), "aria-label": "Downloading the Voice" }),
                status(`Downloading the voice: ${Math.floor((p || 0) * 100)} percent.`));
            return;
        }
        if (state !== "installed") {
            controls.append(h("div", { class: "row" }, h("button", { type: "button", class: "btn small", onclick: download }, `Download the Voice (${Voice.SIZE_TEXT})`)),
                status(state ? "The download stopped. " + state : `Narrated video and the podcast need the Kokoro voice (${Voice.SIZE_TEXT}). After the download, the browser keeps the voice.`));
            return;
        }
        const play = h("button", { type: "button", class: "btn small", "aria-description": `Speaks one sentence in the voice ${voice}.` }, "Play a Sample");
        play.onclick = async () => {
            play.disabled = true;
            try { await Voice.playSample(voice); } catch (e) { controls.append(status("The sample did not play. " + (e.message || e))); }
            play.disabled = false;
        };
        const del = h("button", { type: "button", class: "btn small", onclick: async () => {
            if (!(await confirmBox({ title: "Delete the voice from this browser?", message: `This removes ${Voice.SIZE_TEXT}. You can download it again later.`, choices: [{ label: "Delete the Voice", value: true, danger: true }] }))) return;
            await Voice.remove();
            render("");
        } }, "Delete the Voice");
        controls.append(h("div", { class: "row" }, play, del), status("The voice is in this browser. Narrated video and the podcast are available."));
    }
    async function download() {
        render("downloading", 0);
        try { await Voice.load((p) => render("downloading", p)); render("installed"); announce("The voice is ready."); }
        catch (e) { render(e.message || String(e)); }
    }
    Voice.installed().then((ok) => render(ok ? "installed" : ""));
    return section("Narration", h("div", { class: "row" }, h("span", { class: "row-label", text: "Voice" }), h("span", { class: "row-hint", text: voice })), controls,
        footnote("Kokoro speaks the narration in this browser. The first download comes from jsDelivr and Hugging Face. To use a different voice, add voice: to the front matter, for example voice: bf_emma."));
}

// --- Customize ------------------------------------------------------------------------

function luminance(hex) {
    const n = parseInt(hex.slice(1), 16);
    const ch = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}
function contrast(a, b) {
    const x = luminance(a), y = luminance(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

// ThemeValidator.issues.
export function themeIssues(p) {
    const out = [];
    const roles = [["Body text", p.text], ["Heading text", p.strong], ["Secondary text", p.dim], ["Accent", p.accent],
        ["Red", p.red], ["Green", p.green], ["Yellow", p.yellow], ["Blue", p.blue], ["Magenta", p.magenta], ["Cyan", p.cyan], ["Orange", p.orange], ["Violet", p.violet]];
    for (const [role, fg] of roles) {
        const c = Math.min(contrast(fg, p.background), contrast(fg, p.surface));
        if (c < 4.495) out.push(`${p.name}: ${role} has a contrast of ${c.toFixed(2)}:1. It must be 4.5:1 or more.`);
    }
    return out;
}

// FrontMatterEditor.set: sets each key to its value. A null value removes the key.
export function frontMatterSet(values, source) {
    const lines = source.split("\n");
    if (lines[0]?.trim() === "---") {
        let end = lines.findIndex((l, i) => i > 0 && l.trim() === "---");
        if (end > 0) {
            for (const [key, value] of values) {
                let i = lines.slice(1, end).findIndex((l) => l.toLowerCase().startsWith(key + ":"));
                i = i < 0 ? -1 : i + 1;
                if (i > 0 && value !== null) lines[i] = `${key}: ${value}`;
                else if (i > 0) { lines.splice(i, 1); end--; }
                else if (value !== null) { lines.splice(end, 0, `${key}: ${value}`); end++; }
            }
            return lines.join("\n");
        }
    }
    const set = values.filter(([, v]) => v !== null).map(([k, v]) => `${k}: ${v}`);
    if (!set.length) return source;
    return ["---", ...set, "---", "", ...lines].join("\n");
}

function frontValue(source, key) {
    if (!source.startsWith("---")) return "";
    const end = source.indexOf("\n---", 3);
    if (end < 0) return "";
    const line = source.slice(0, end).split("\n").find((l) => l.toLowerCase().startsWith(key + ":"));
    return line ? line.slice(key.length + 1).trim().replace(/^["']|["']$/g, "") : "";
}

const ACCENTS = ["", "blue", "violet", "magenta", "red", "orange", "yellow", "green", "cyan"];

export function customizePanel(app) {
    const src = app.text();
    const r = C.themeResolve(frontValue(src, "theme"), "");
    const st = { themeID: r.id, appearance: r.darkOnly ? null : r.prefersDark, accent: frontValue(src, "accent"), useInEditor: false };
    const themes = C.themes();
    const theme = () => themes.find((t) => t.id === st.themeID) || themes[0];
    const accents = ACCENTS.includes(st.accent) ? ACCENTS : [...ACCENTS, st.accent];
    const previewBox = h("div", {});
    const appearanceRow = selectRow("Appearance", [["auto", "Automatic"], ["light", "Light"], ["dark", "Dark"]],
        st.appearance === null ? "auto" : st.appearance ? "dark" : "light",
        (v) => { st.appearance = v === "auto" ? null : v === "dark"; update(); });
    let d;
    function update() {
        const t = theme();
        appearanceRow.querySelector("select").disabled = t.darkOnly;
        const p = C.themePalette(t.id, st.accent, t.darkOnly ? true : !!st.appearance, false);
        const issues = themeIssues(p);
        previewBox.replaceChildren(
            h("div", { class: "theme-preview", style: { background: p.background, color: p.text } },
                h("div", { style: { color: p.strong, fontWeight: "700" }, text: "Heading" }),
                h("div", {}, "Body text with a ", h("u", { style: { color: p.accent }, text: "link" })),
                h("div", { style: { color: p.dim, fontSize: "0.85em" }, text: "Secondary text" })),
            issues.length ? h("div", {}, issues.map((i) => h("p", { class: "status-warn", text: "⚠ " + i })))
                : h("p", { class: "status-ok", text: "✓ All colors meet the readability checks." }));
        if (d) d.buttons.find((b) => b.textContent === "Apply").disabled = issues.length > 0;
    }
    function apply() {
        const t = theme();
        const value = st.appearance === null || t.darkOnly ? t.id : t.id + (st.appearance ? "-dark" : "-light");
        const text = app.text();
        const next = frontMatterSet([["theme", value], ["accent", st.accent || null]], text);
        if (next !== text) app.replaceAll(next);
        if (st.useInEditor) {
            S.setSetting("themeID", t.id);
            if (!t.darkOnly && st.appearance !== null) S.setSetting("appearance", st.appearance ? "dark" : "light");
            app.applySettings();
        }
        announce(`The project theme is ${t.name}.`);
    }
    const body = h("div", {},
        section("Project Theme",
            selectRow("Theme", themes.map((t) => [t.id, t.name]), st.themeID, (v) => { st.themeID = v; update(); }),
            appearanceRow,
            toggleRow("Use This Theme in the Editor Too", false, (v) => { st.useInEditor = v; }),
            footnote("For Preview, slides, the article, and the interactive page of this project. The editor uses the theme in Settings, unless you turn on the option above. Every theme is free. Marklove makes text colors darker or lighter where they are below 4.5:1 contrast.")),
        section("Accent", selectRow("Accent", accents.map((a) => [a, a ? (a.startsWith("#") ? a.toUpperCase() : a[0].toUpperCase() + a.slice(1)) : "Theme default"]), st.accent, (v) => { st.accent = v; update(); })),
        section("Preview", h("div", { class: "group" }, previewBox)));
    d = dialog({ title: "Customize", body, buttons: [{ label: "Cancel", cancel: true }, { label: "Apply", primary: true, disabled: app.readOnly(), action: apply }] });
    update();
}

// --- Outline ------------------------------------------------------------------------------

export function outlinePanel(app) {
    let items = [];
    try { items = C.outline({ source: app.text() }, 0); } catch (e) { items = []; }
    const title = app.title();
    const list = h("div", { role: "list" }, items.map((f) => {
        const t = app.text();
        const line = t.slice(f.s0, t.indexOf("\n", f.s0) < 0 ? t.length : t.indexOf("\n", f.s0));
        const label = f.kind === 0 ? title : line.replace(/^#+\s*/, "") || "Slide";
        return h("div", { role: "listitem" }, h("button", {
            type: "button", class: "item linkbtn", style: { paddingLeft: f.kind === 2 ? "28px" : "12px", fontWeight: f.kind === 1 ? "700" : "400", display: "flex", width: "100%" },
            onclick: () => { d.close(); app.goToSource(f.s0, f.s0); },
        }, h("span", { text: label }), h("span", { class: "spacer" }), f.notes ? h("span", { class: "row-hint", "aria-label": "Has notes", text: "✎" }) : null));
    }));
    const d = dialog({ title: "Outline", body: items.length ? section(null, list) : h("p", { class: "alert-text", text: "The project has no slides yet. Add a heading with ## to make a slide." }) });
}

// --- Help ------------------------------------------------------------------------------------

const SYNTAX = [
    ["Slides", "# Section\n## Slide title\nText for the slide."],
    ["Reveal", "First point.\n\n. . .\n\nSecond point appears on the next click."],
    ["Speaker notes", "::: notes\nPrivate text for the presenter.\n:::"],
    ["Narration", "::: narration\nThe words that narration speaks for this slide.\n:::"],
    ["Spoken explanation", "$$ E = mc^2 $$\n\n::: explain\nEnergy equals mass times the speed of light squared.\n:::"],
    ["Image", "![A description for people who cannot see it](images/photo.png \"Optional caption\")"],
    ["Decorative image", "<!-- decorative -->\n![](images/pattern.png)"],
    ["Equation steps", "::: morph\n$$ a = b + c $$\n$$ a - c = b $$\n:::"],
    ["Plot with slider", "::: plot\nx: 0, 6.28\nslider: k, 0.5, 3, 1, Frequency\ny = sin(k*x)\n:::"],
    ["Bar chart", "::: chart bar\n| Item | Value |\n| --- | ---: |\n| A | 3 |\n| B | 5 |\n:::"],
    ["Article only", "<!-- article -->\nText for the article only.\n<!-- /article -->"],
    ["Slides only", "<!-- slides -->\nText for the slides only.\n<!-- /slides -->"],
];

export function helpPanel(app) {
    let includeSelection = false;
    const copyBtn = (label, make) => {
        const b = h("button", { type: "button", class: "btn", onclick: async () => {
            try { await copyText(make()); } catch (e) { announce(e.message); return; }
            b.textContent = "Copied"; announce("Copied");
        } }, label);
        return b;
    };
    const body = h("div", {},
        section("Write in Markdown. Preview it. Export it.",
            h("p", { class: "group", text: "Marklove keeps your Markdown as plain text. Every rule below is visible in the source. Insert adds the same text for you." }),
            h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => { d.close(); app.openTour(); } }, "✦ Open the Tour")),
            h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => { d.close(); samTutorial(); } }, "Sam Tutorial: Structural Editing")),
            h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => { d.close(); welcome(app); } }, "Show the Welcome Again"))),
        section("Syntax", ...SYNTAX.map(([name, text]) => h("div", { class: "item" },
            h("div", { class: "item-title", text: name }),
            h("pre", { class: "code", text }),
            h("div", { class: "item-actions" }, h("button", { type: "button", class: "btn small", disabled: app.readOnly(), "aria-label": "Insert " + name, onclick: () => { d.close(); app.insertText(text); } }, "Insert"))))),
        section("Write with an AI Tool",
            h("p", { class: "group", text: "Copy a prompt with the Marklove rules. Paste it into Claude, ChatGPT, or another tool. The rules ask for short sentences that fit Takahashi slides, and for plots, charts, and equation steps. Then paste the Markdown back here. Marklove sends nothing by itself." }),
            toggleRow("Include the selected text", false, (v) => { includeSelection = v; }),
            h("div", { class: "row" }, copyBtn("Copy a Prompt for a New Presentation", () => C.authoringPrompt(includeSelection ? app.selectedText() : ""))),
            h("div", { class: "row" }, copyBtn("Copy a Prompt to Revise This Project", () => C.listener(app.text(), C.LIST_REVISION_PROMPT))),
            footnote("The revision prompt includes your project without private notes.")),
        section("Vim Mode",
            h("p", { class: "group", text: "Motions: h j k l w b e 0 ^ $ gg G f t % { }. Operators: d c y > < with motions and text objects such as iw, i\", i(, ip, and i$ for math. Also x, p, u, Ctrl-R, ., v, V, /, n, :s, :w, and :q!. Shell commands and plugins are not available." })),
        section("Keyboard Shortcuts", h("div", { class: "group" }, SHORTCUTS.map(([k, t]) => h("div", { class: "row" }, h("span", { class: "row-label", text: t }), h("kbd", { text: k }))))));
    const d = dialog({ title: "Help", body, wide: true });
}

const K = cmdKey, ALT = cmdKey === "⌘" ? "⌥" : "Alt+", SH = cmdKey === "⌘" ? "⇧" : "Shift+", CTL = cmdKey === "⌘" ? "⌃" : "Ctrl+";
const combo = (...p) => cmdKey === "⌘" ? p.join("") : p.join("").replace(/\+(?=.)/g, "+");
const SHORTCUTS = [
    [combo(ALT, K, "N"), "New Project"], [combo(K, "O"), "Import Markdown or ZIP"], [combo(SH, K, "O"), "All Projects"],
    [combo(K, "S"), "Save a Version"], [combo(ALT, K, "Y"), "Version History"], [combo(K, "E"), "Export"],
    [combo(K, "F"), "Find"], [combo(ALT, K, "F"), "Find and Replace"], [combo(K, "G"), "Find Next"], [combo(SH, K, "G"), "Find Previous"],
    [combo(ALT, K, "X"), "Sam Command Line"], [combo(CTL === "Ctrl+" ? "Ctrl+Alt+" : "⌃⌘", "E"), "Preview Equation"],
    [combo(SH, K, "L"), "Outline"], [combo(ALT, K, "L"), "Show Line Count"], [combo(K, "Return"), "Preview or Edit"],
    [combo(SH, K, "R"), "Speaker Ready"], ["Escape", "Edit (in Preview)"],
];

// --- projects -------------------------------------------------------------------------------

export async function projectsPanel(app, { received = false } = {}) {
    const list = h("div", { role: "list" });
    let d;
    async function render() {
        const all = (await S.projects()).filter((p) => !!p.isListener === received);
        list.replaceChildren();
        if (!all.length) list.append(h("p", { class: "alert-text", text: received ? "Nothing Received. Import a listener package (ZIP) to see it here. Received items open view only." : "No projects yet." }));
        for (const p of all) {
            const current = p.id === app.projectId();
            list.append(h("div", { class: "item", role: "listitem" },
                h("button", { type: "button", class: "linkbtn", "aria-current": current ? "true" : null, onclick: () => { d.close(); app.openProject(p.id); } },
                    h("span", { class: "item-title", text: (current ? "✓ " : "") + p.name }),
                    h("span", { class: "item-sub", text: new Date(p.modified).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) })),
                h("div", { class: "item-actions" },
                    h("button", { type: "button", class: "btn small danger", "aria-label": "Delete " + p.name, onclick: async () => { if (await app.deleteProject(p)) render(); } }, "Delete"))));
        }
    }
    await render();
    d = dialog({
        title: received ? "Received" : "All Projects", body: section(null, list),
        buttons: [{ label: "Done", cancel: true }, { label: received ? "Import" : "New Project", primary: true, action: () => (received ? app.importFiles() : app.newProject()) }],
    });
}

export function renamePanel(app) {
    const input = h("input", { type: "text", value: app.projectName(), "aria-label": "Name", autocomplete: "off" });
    const go = async () => { const n = input.value.trim(); if (!n) return false; await app.rename(n); };
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); go().then((r) => r !== false && d.close()); } });
    const d = dialog({ title: "Rename Project", body: section(null, h("div", { class: "row" }, input)), buttons: [{ label: "Cancel", cancel: true }, { label: "Rename", primary: true, action: go }] });
    input.select();
}

// --- Version History --------------------------------------------------------------------------

const when = (t) => new Date(t).toLocaleString(undefined, { day: "numeric", month: "short", year: "numeric", hour: "numeric", minute: "2-digit" });

export async function historyPanel(app) {
    const list = h("div", {});
    let d;
    async function render() {
        const all = await S.versions(app.projectId());
        list.replaceChildren();
        if (!S.settings.gitEnabled) list.append(h("p", { class: "status-warn", text: "⚠ Versions are off. Turn on Save Versions in Settings." }));
        if (!all.length) list.append(h("p", { class: "alert-text", text: `No Versions Yet. Marklove saves a version after a pause in your typing, and when you press ${cmdKey}S.` }));
        all.forEach((v, i) => {
            const [subject, ...rest] = v.message.split("\n");
            const bodyText = rest.join("\n").trim();
            list.append(h("div", { class: "item" },
                h("div", { class: "item-title", text: subject }),
                h("div", { class: "item-sub", text: when(v.time) }),
                bodyText ? h("div", { class: "item-sub", style: { whiteSpace: "pre-wrap" }, text: bodyText.split("\n").slice(0, 6).join("\n") }) : null,
                h("div", { class: "item-actions" },
                    h("button", { type: "button", class: "btn small", onclick: () => versionDetail(v, all[i + 1] || null, app.text()) }, "Changes"),
                    h("button", { type: "button", class: "btn small", disabled: i === 0 || app.readOnly(), onclick: async () => {
                        const ok = await confirmBox({ title: "Restore this version?", message: `The project text and its files change to the version from ${when(v.time)}. Marklove first saves the current text as a version, so you can go back.`, choices: [{ label: "Restore", value: true, primary: true }] });
                        if (ok) { await app.restoreVersion(v); render(); }
                    } }, "Restore…"))));
        });
    }
    await render();
    d = dialog({
        title: "Version History", body: section(null, list),
        buttons: [{ label: "Done", cancel: true }, { label: "Save a Version Now", primary: true, disabled: !S.settings.gitEnabled || app.readOnly(), action: async () => { await app.saveVersion({ explicit: true }); await render(); return false; } }],
    });
}

// LineDiff.hunks: changed lines with three lines of context.
function hunks(a, b) {
    let lines;
    try { lines = C.diff(a, b); } catch { lines = []; }
    const ranges = [];
    lines.forEach((l, i) => {
        if (l.op === "same") return;
        const lo = Math.max(0, i - 3), hi = Math.min(lines.length - 1, i + 3);
        const last = ranges[ranges.length - 1];
        if (last && lo <= last[1] + 1) last[1] = hi; else ranges.push([lo, hi]);
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
        const start = (shown[0] && shown[0].new) || (hk.lines[0] && (hk.lines[0].new || hk.lines[0].old)) || 1;
        box.append(h("h4", { class: "hunk-head", text: shown.length <= 1 ? `Line ${start}` : `Lines ${start} to ${start + shown.length - 1}` }));
        for (const l of hk.lines) {
            const sign = l.op === "add" ? "+" : l.op === "remove" ? "−" : " ";
            const spoken = l.op === "add" ? "Added: " : l.op === "remove" ? "Removed: " : "";
            box.append(h("div", { class: "diff-line " + l.op, role: "text", "aria-label": spoken + l.text },
                h("span", { class: "n", "aria-hidden": "true", text: String(l.new || l.old || "") }),
                h("span", { class: "s", "aria-hidden": "true", text: sign }),
                h("span", { class: "t", "aria-hidden": "true", text: l.text || " " })));
        }
    }
    return box;
}

function versionDetail(v, previous, current) {
    const content = h("div", {});
    const sum = (hs) => [hs.reduce((n, x) => n + x.added, 0), hs.reduce((n, x) => n + x.removed, 0)];
    function show(mode) {
        content.replaceChildren();
        if (mode === "text") { content.append(h("pre", { class: "code", text: v.markdown })); return; }
        const hs = mode === "changes" ? hunks(previous ? previous.markdown : "", v.markdown) : hunks(v.markdown, current);
        const [a, r] = sum(hs);
        let s;
        if (mode === "changes") s = !previous ? `The first version. Lines: ${a}.` : a + r === 0 ? "The text did not change in this version. Other files changed." : `Added lines: ${a}. Removed lines: ${r}.`;
        else s = a + r === 0 ? "This version has the same text as now." : `Since this version: added lines: ${a}. Removed lines: ${r}.`;
        content.append(diffView(hs, s));
    }
    const body = h("div", {}, h("div", { class: "row" }, segmented("Show", [["changes", "Changes"], ["compare", "Compared with Now"], ["text", "Text"]], "changes", show)), content);
    dialog({ title: v.message.split("\n")[0], body, wide: true });
    show("changes");
}

// --- the welcome --------------------------------------------------------------------------------

const PAGES = [
    ["Markdown in, slides out", "You write plain Markdown. Marklove draws each form from it.", "## Math that looks like math\n\n::: morph\n$$(a + b)^2$$\n$$(a + b)(a + b)$$\n$$a^2 + 2ab + b^2$$\n:::"],
    ["Two styles, one file", "Normal slides hold a full idea. Takahashi slides show one short sentence in large type.", ""],
    ["Plots that move", "Drag a slider. The curve changes at once. Your audience can do this on the web page too. Marklove does not run code from your file. Plots use a small, safe formula language.", ""],
    ["Your words, in every form", "Export makes every form from the same file. Every export is free. Marklove saves each change at once, in this browser, and keeps versions that tell what changed.", ""],
];

export function welcome(app) {
    let page = 0;
    const content = h("div", { class: "group" });
    let d;
    function render() {
        const [title, text, code] = PAGES[page];
        content.replaceChildren(
            h("h3", { text: title, tabindex: "-1" }), h("p", { text }),
            code ? h("pre", { class: "code", "aria-label": "Markdown source", text: code }) : null,
            h("p", { class: "footnote", text: `Page ${page + 1} of ${PAGES.length}` }));
        const [skip, back, next] = d.buttons;
        back.hidden = page === 0;
        next.textContent = page === PAGES.length - 1 ? "Start Writing" : "Continue";
        skip.hidden = page === PAGES.length - 1;
        content.querySelector("h3").focus();
    }
    const finish = () => { S.setSetting("onboardingSeen", true); };
    d = dialog({
        title: "Welcome to Marklove", body: content, onClose: finish,
        buttons: [
            { label: "Skip", cancel: true },
            { label: "Back", action: () => { page = Math.max(0, page - 1); render(); return false; } },
            { label: "Continue", primary: true, action: () => { if (page < PAGES.length - 1) { page++; render(); return false; } } },
        ],
    });
    d.body.append(h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => { d.close(); app.openTour(); } }, "Open the Tour")));
    render();
}
