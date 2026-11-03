import * as C from "./core.ts";
import * as S from "./store.ts";
import * as E from "./editor.ts";
import * as P from "./preview.ts";
import * as F from "./find.ts";
import * as X from "./export.ts";
import * as UI from "./panels.ts";
import type { MenuItem } from "./ui.ts";
import { h, announce, attachMenu, closeMenu, alertBox, confirmBox, segmented, download, pickFile, copyText, isMac, cmdKey } from "./ui.ts";
import { byId, must } from "./dom.ts";

type Project = NonNullable<Awaited<ReturnType<typeof S.project>>>;
type Version = Awaited<ReturnType<typeof S.versions>>[number];
type OutlineItem = ReturnType<typeof C.outline>[number];
type Frame = InstanceType<typeof P.PageFrame>;

interface SourceFocus {
    message: string;
    detail: string | undefined;
    returnToExport: boolean;
}

interface SourceTarget {
    message: string;
    detail: string | undefined;
    start: number;
    end: number;
}

interface SaveVersionOptions {
    explicit?: boolean;
    auto?: boolean;
    message?: string;
}

type Timer = ReturnType<typeof setTimeout> | undefined;

interface AppState {
    project: Project | null;
    assets: Record<string, Blob>;
    assetURLs: Record<string, string>;
    list: Project[];
    mode: "edit" | "preview";
    view: string;
    outline: OutlineItem[];
    previewOffset: number;
    html: string;
    saveTimer: Timer;
    idleTimer: Timer;
    lastVersion: number;
    focus: SourceFocus | null;
    exportChoice: string;
    wasLarge: boolean | undefined;
}

const $ = (id: string): HTMLElement => byId(id, HTMLElement);
const enc = new TextEncoder();

const state: AppState = {
    project: null, assets: {}, assetURLs: {}, list: [],
    mode: "edit", view: "slides", outline: [], previewOffset: 0, html: "",
    saveTimer: undefined, idleTimer: undefined, lastVersion: 0, focus: null, exportChoice: "all",
    wasLarge: undefined,
};
let frameOrNull: Frame | null = null;

function frame(): Frame {
    return must(frameOrNull, "the preview frame");
}

function currentProject(): Project {
    return must(state.project, "the open project");
}

function errorMessage(err: unknown): string {
    return err instanceof Error ? err.message : String(err);
}

const readOnly = (): boolean => !!(state.project && state.project.isListener);
const tooLarge = (t: string): boolean => enc.encode(t).length > C.MAX_SOURCE_BYTES;

function frontValue(source: string, key: string): string {
    if (!source.startsWith("---")) return "";
    const end = source.indexOf("\n---", 3);
    if (end < 0) return "";
    const line = source.slice(0, end).split("\n").find((l) => l.toLowerCase().startsWith(key + ":"));
    return line ? line.slice(key.length + 1).trim().replace(/^["']|["']$/g, "") : "";
}
const docTitle = (): string => frontValue(E.text(), "title") || (state.project ? state.project.name : "Marklove");

const darkQuery = matchMedia("(prefers-color-scheme: dark)");
const contrastQuery = matchMedia("(prefers-contrast: more)");

function applyTheme(): void {
    const themes = C.themes();
    const t = themes.find((x) => x.id === S.settings.themeID) || themes[0];
    if (!t) return;
    const a = S.settings.appearance;
    const dark = t.darkOnly || a === "dark" || (a === "system" && darkQuery.matches);
    const contrast = S.settings.increaseContrast || contrastQuery.matches;
    const p = C.themePalette(t.id, "", dark, contrast);
    const s = $("workspace").style;
    const colors: [string, string][] = [
        ["bg", p.background], ["surface", p.surface], ["border", p.border], ["dim", p.dim], ["text", p.text], ["strong", p.strong],
        ["accent", p.accent], ["red", p.red], ["green", p.green], ["orange", p.orange], ["violet", p.violet], ["yellow", p.yellow],
    ];
    for (const [name, value] of colors) s.setProperty("--" + name, value);
    s.colorScheme = dark ? "dark" : "light";
    document.documentElement.classList.toggle("contrast", contrast);
    E.setPalette(p.roles);
}

function applySettings(reset: boolean = false): void {
    applyTheme();
    E.setMetrics({ scale: S.settings.editorTextScale, spacing: S.settings.editorLineSpacing, wrap: S.settings.wrapLines });
    const vim = S.settings.vimEnabled && !readOnly();
    if (E.editor.vim !== vim || reset) E.setVim(vim);
    if (vim && tooLarge(E.text())) E.vimInsert();
    updateStatus();
}
darkQuery.addEventListener("change", applyTheme);
contrastQuery.addEventListener("change", applyTheme);

function updateStatus(): void {
    const vim = E.editor.vim;
    $("vim-mode").hidden = !vim;
    $("vim-mode").textContent = vim ? E.vimModeName(E.editor.vimMode) : "";
    $("vim-line").textContent = vim ? E.editor.vimStatus : "";
    const ls = $("line-status");
    ls.hidden = !S.settings.showLineCount;
    if (S.settings.showLineCount) {
        const s = E.lineStatus();
        ls.textContent = `Line ${s.line} of ${s.lines} · Words: ${s.words}`;
    }
    $("statusbar").hidden = !vim && !S.settings.showLineCount;
}

function renderBanners(): void {
    const box = $("banners");
    box.replaceChildren();
    if (readOnly()) {
        box.append(h("div", { class: "banner", role: "status" }, h("span", { "aria-hidden": "true" }, "👥"),
            h("span", { class: "msg" }, h("strong", { text: "Received presentation" }), h("span", { class: "detail", text: "This presentation opens view only. Select Present to show it." }))));
    }
    if (tooLarge(E.text())) {
        box.append(h("div", { class: "banner", role: "alert" }, h("span", { class: "warn", "aria-hidden": "true" }, "⚠"),
            h("span", { class: "msg" }, h("strong", { text: "The Markdown file is larger than 512 KB." }), h("span", { class: "detail", text: "Preview, checks, and export stop at this size. Split the text into more projects." }))));
    }
    const f = state.focus;
    if (f) {
        box.append(h("div", { class: "banner", role: "region", "aria-label": "Source issue" },
            h("span", { class: "warn", "aria-hidden": "true" }, "⚠"),
            h("span", { class: "msg" }, h("strong", { text: f.message || "Source passage" }), f.detail ? h("span", { class: "detail", text: f.detail }) : null),
            f.returnToExport ? h("button", { type: "button", class: "button", onclick: () => { state.focus = null; renderBanners(); openExport(); } }, "Back to Export") : null,
            h("button", { type: "button", class: "iconbtn", "aria-label": "Close the explanation", title: "Close the explanation", onclick: () => { state.focus = null; renderBanners(); E.focus(); } }, "✕")));
    }
}

async function refreshList(): Promise<void> { state.list = await S.projects(); }

function urlsFor(assets: Record<string, Blob>): Record<string, string> {
    for (const u of Object.values(state.assetURLs)) URL.revokeObjectURL(u);
    const out: Record<string, string> = {};
    for (const [p, b] of Object.entries(assets)) out[p] = URL.createObjectURL(b);
    return out;
}

const source = (): HTMLTextAreaElement => byId("source", HTMLTextAreaElement);

function showProjectName(name: string): void {
    $("title-text").textContent = name;
    $("title-menu").setAttribute("aria-label", "Project: " + name);
    $("title-menu").title = name;
    document.title = name + " – Marklove";
}

async function openProject(id: string, { preview = false }: { preview?: boolean } = {}): Promise<void> {
    if (state.project && state.project.id !== id) { await flushSave(); await saveVersion({ auto: true }); saveEditorState(); }
    const p = await S.project(id);
    if (!p) return;
    state.project = p;
    state.assets = await S.assetBlobs(id);
    state.assetURLs = urlsFor(state.assets);
    state.focus = null;
    state.lastVersion = 0;
    S.setSetting("lastProject", id);
    E.editor.readOnly = readOnly();
    source().readOnly = readOnly();
    E.setText(p.markdown);
    updatePlaceholder();
    showProjectName(p.name);
    restoreEditorState();
    applySettings(true);
    renderBanners();
    if (F.find.open) F.refresh();
    await refreshList();
    if (preview || readOnly()) showPreview(); else showEdit(false);
}

function saveEditorState(): void {
    if (!state.project) return;
    const [s, e] = E.selection();
    S.setEditorState(state.project.id, { s, e, top: source().scrollTop });
}

function restoreEditorState(): void {
    const st = S.editorState(currentProject().id);
    if (st) { E.setSelection(st.s, st.e, false); source().scrollTop = st.top || 0; $("highlight").scrollTop = st.top || 0; }
}

function updatePlaceholder(): void { $("placeholder").hidden = E.text().length > 0; }

async function newProject(): Promise<void> {
    const p = await S.createProject({ name: "Untitled", markdown: "" });
    await firstVersion(p, `Create project “${p.name}”`);
    await openProject(p.id);
    E.focus();
}

async function firstVersion(p: Project, message: string): Promise<void> {
    if (!S.settings.gitEnabled || tooLarge(p.markdown)) return;
    const assets = await S.assetBlobs(p.id);
    await S.addVersion({ project: p.id, time: Date.now(), message, markdown: p.markdown, assets: Object.keys(assets) });
}

async function openTour(): Promise<void> {
    const existing = (await S.projects()).find((p) => p.isDemo);
    if (existing) { await openProject(existing.id); return; }
    const t = C.tour();
    const assets: Record<string, Blob> = {};
    for (const [path, file] of Object.entries(t.assets)) {
        try { const r = await fetch(file); if (r.ok) assets[path] = await r.blob(); } catch { continue; }
    }
    const p = await S.createProject({ name: t.name, markdown: t.markdown, assets, demo: true });
    await firstVersion(p, `Create project “${p.name}”`);
    await openProject(p.id);
}

function nameFromMarkdown(md: string, fallback: string): string {
    return frontValue(md, "title") || fallback.replace(/\.(md|markdown|txt|zip)$/i, "") || "Imported";
}

async function importFiles(): Promise<void> {
    const files = await pickFile(".md,.markdown,.txt,.zip,text/markdown,text/plain,application/zip", true);
    let last: Project | null = null;
    for (const f of files) {
        try {
            if (/\.zip$/i.test(f.name) || f.type === "application/zip") {
                const r = await C.packImport(f);
                if ("error" in r) { await alertBox(`Marklove could not import “${f.name}”. ${r.error}`); continue; }
                const listener = frontValue(r.markdown, "marklove") === "listener";
                const name = (r.markdownName || f.name).replace(/\.(md|markdown|txt)$/i, "");
                const p = await S.createProject({ name, markdown: r.markdown, assets: r.assets, listener });
                if (!listener) await firstVersion(p, `Import project “${p.name}”`);
                if (r.warnings && r.warnings.length) await alertBox(r.warnings.join("\n"), "Imported with warnings");
                last = p;
            } else {
                const md = (await f.text()).replace(/\r\n?/g, "\n");
                if (tooLarge(md)) { await alertBox(`“${f.name}” is larger than 512 KB. Split it into more files, and import each file.`); continue; }
                const p = await S.createProject({ name: nameFromMarkdown(md, f.name), markdown: md });
                await firstVersion(p, `Import project “${p.name}”`);
                last = p;
            }
        } catch (e) { await alertBox(`Marklove could not import “${f.name}”. ${errorMessage(e)}`); }
    }
    if (last) { await openProject(last.id); announce(`Imported “${last.name}”.`); }
}

async function deleteProject(p: Project): Promise<boolean> {
    const choice = await confirmBox({
        title: `Delete “${p.name}”?`,
        message: "This deletes the project, its images and media, and its version history from this browser. You cannot undo this.",
        choices: [{ label: "Save a ZIP Copy First", value: "zip" }, { label: "Delete Project", value: "delete", danger: true }],
    });
    if (!choice) return false;
    if (choice === "zip") { await saveZipCopy(p); return false; }
    await S.deleteProject(p.id);
    S.setEditorState(p.id, null);
    await refreshList();
    if (state.project && state.project.id === p.id) {
        state.project = null;
        const next = state.list.find((x) => !x.isListener) || state.list[0];
        if (next) await openProject(next.id); else await newProject();
    }
    announce(`Deleted “${p.name}”.`);
    return true;
}

async function saveZipCopy(p: Project | null = state.project): Promise<void> {
    const target = p ?? currentProject();
    if (target.id === currentProject().id) await flushSave();
    const proj = must(await S.project(target.id), "the project to copy");
    const ctx = { name: proj.name, source: proj.markdown, assets: await S.assetBlobs(target.id), gitName: gitName(proj.markdown), gitEmail: S.settings.gitEmail };
    const blob = await X.projectZip(ctx, S.settings.gitEnabled ? await S.versions(target.id) : []);
    download(blob, S.safeFileName(proj.name) + ".zip");
}

async function rename(name: string): Promise<void> {
    const p = currentProject();
    if (name === p.name) return;
    const others = new Set(state.list.filter((x) => x.id !== p.id).map((x) => x.name.toLowerCase()));
    let n = S.safeFileName(name), i = 2;
    const base = n;
    while (others.has(n.toLowerCase())) n = base + " " + i++;
    p.name = n;
    await S.saveProject(p);
    showProjectName(n);
    await refreshList();
}

async function duplicate(): Promise<void> {
    await flushSave();
    const p = await S.duplicateProject(currentProject());
    await firstVersion(p, `Create project “${p.name}”`);
    await openProject(p.id);
}

const SAVE_DELAY_MS = 500;
const IDLE_VERSION_MS = 30000;
const MIN_VERSION_GAP_MS = 120000;

function textChanged(): void {
    updatePlaceholder();
    updateStatus();
    F.textChanged();
    if (state.focus) { state.focus = null; renderBanners(); }
    clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(flushSave, SAVE_DELAY_MS);
    clearTimeout(state.idleTimer);
    state.idleTimer = setTimeout(autoVersion, IDLE_VERSION_MS);
    if (state.mode === "preview") schedulePreview();
    const big = tooLarge(E.text());
    if (big) E.vimInsert();
    if (big !== state.wasLarge) { state.wasLarge = big; renderBanners(); }
    updateEquation();
}

async function flushSave(): Promise<void> {
    clearTimeout(state.saveTimer);
    const p = state.project;
    if (!p || readOnly()) return;
    const t = E.text();
    if (p.markdown === t) return;
    p.markdown = t;
    try { await S.saveProject(p); }
    catch (e) { announce("Marklove could not save the change. " + errorMessage(e)); }
}

function autoVersion(): void {
    const wait = state.lastVersion + MIN_VERSION_GAP_MS - Date.now();
    if (wait > 0) { state.idleTimer = setTimeout(autoVersion, wait); return; }
    void saveVersion({ auto: true });
}

function gitName(md: string): string { return S.settings.gitName || frontValue(md, "author") || "Marklove"; }

async function saveVersion({ explicit = false, message = "" }: SaveVersionOptions = {}): Promise<boolean> {
    const p = state.project;
    if (!p || readOnly()) return false;
    await flushSave();
    if (!S.settings.gitEnabled) { if (explicit) announce("Saved. Versions are off in Settings."); return false; }
    if (tooLarge(p.markdown)) { if (explicit) announce("The Markdown file is larger than 512 KB. Split it into more projects."); return false; }
    const all = await S.versions(p.id);
    const last = all[0];
    const paths = Object.keys(state.assets).sort();
    const same = last && last.markdown === p.markdown && (last.assets || []).slice().sort().join("\n") === paths.join("\n");
    if (same && !message) { if (explicit) announce("Saved. No changes since the last version."); return false; }
    let msg = message;
    if (!msg) {
        try { msg = C.commitMessage(last ? last.markdown : "", p.markdown); }
        catch { msg = ""; }
        if (!msg.trim()) msg = last ? `Change “${p.name}”` : `Create project “${p.name}”`;
    }
    await S.addVersion({ project: p.id, time: Date.now(), message: msg, markdown: p.markdown, assets: paths });
    state.lastVersion = Date.now();
    clearTimeout(state.idleTimer);
    if (explicit) announce("Saved a version: " + (msg.split("\n")[0] ?? ""));
    return true;
}

async function restoreVersion(v: Version): Promise<void> {
    if (tooLarge(E.text())) {
        await alertBox("The text is larger than 512 KB, so Marklove cannot keep it as a version. Make it shorter before you restore an older version.");
        return;
    }
    if (!(await saveVersion({ auto: true }))) {
        const last = (await S.versions(currentProject().id))[0];
        if (!last || last.markdown !== E.text()) {
            await alertBox("Marklove cannot keep the current text as a version. Turn on versions in Settings before you restore an older version.");
            return;
        }
    }
    E.replaceAll(v.markdown);
    await flushSave();
    const date = new Date(v.time).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
    await saveVersion({ message: `Restore the version from ${date}` });
    announce("Restored the version from " + date);
}

async function discardToLastVersion(): Promise<void> {
    const last = (await S.versions(currentProject().id))[0];
    if (!last) { announce("No version to go back to."); return; }
    E.replaceAll(last.markdown);
    announce("Went back to the last version.");
}

const IMAGE_LONG_EDGE = 2560;
const IMAGE_MAX_BYTES = 3 * 1024 * 1024;
const IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "gif", "webp", "svg"];

interface FittedMedia {
    blob: Blob;
    ext: string;
}

async function fitImage(file: File): Promise<FittedMedia> {
    let bmp: ImageBitmap;
    try { bmp = await createImageBitmap(file); } catch { return { blob: file, ext: (file.name.split(".").pop() || "png").toLowerCase() }; }
    const long = Math.max(bmp.width, bmp.height);
    const ext = (file.name.split(".").pop() || "").toLowerCase();
    if (long <= IMAGE_LONG_EDGE && file.size <= IMAGE_MAX_BYTES && IMAGE_EXTENSIONS.includes(ext)) return { blob: file, ext: ext === "jpeg" ? "jpg" : ext };
    const scale = Math.min(1, IMAGE_LONG_EDGE / long);
    const c = document.createElement("canvas");
    c.width = Math.round(bmp.width * scale);
    c.height = Math.round(bmp.height * scale);
    const g = must(c.getContext("2d"), "a canvas context");
    g.fillStyle = "#fff";
    g.fillRect(0, 0, c.width, c.height);
    g.drawImage(bmp, 0, 0, c.width, c.height);
    const blob = must(await new Promise<Blob | null>((r) => c.toBlob(r, "image/jpeg", 0.85)), "the encoded image");
    return { blob, ext: "jpg" };
}

async function addMedia(kind: string): Promise<void> {
    if (readOnly()) return;
    const accept = kind === "image" ? "image/*" : kind === "video" ? "video/*" : "image/*,video/*";
    const [file] = await pickFile(accept);
    if (!file) return;
    const video = file.type.startsWith("video/");
    const folder = kind === "image" ? "images" : "media";
    const fitted = video ? { blob: file, ext: (file.name.split(".").pop() || "mp4").toLowerCase() } : await fitImage(file);
    const path = S.assetName(state.assets, folder, file.name, fitted.ext);
    await S.addAsset(currentProject().id, path, fitted.blob);
    state.assets[path] = fitted.blob;
    state.assetURLs[path] = URL.createObjectURL(fitted.blob);
    E.insert(E.snippet(`![⟦Describe the ${video ? "video" : "image"}⟧](${path})`));
}

type SnippetDef = readonly [label: string, text: string, block?: boolean];

const SNIPPETS = {
    slide: ["Slide", "## ⟦Slide title⟧\n"], section: ["Section", "# ⟦Section title⟧\n"], pause: ["Pause (Reveal)", ". . .\n\n⟦Next part⟧"],
    notes: ["Speaker Notes", "::: notes\n⟦Notes for the presenter only.⟧\n:::"],
    narration: ["Narration", "::: narration\n⟦The words that narration speaks for this slide.⟧\n:::"],
    explanation: ["Spoken Explanation", "::: explain\n⟦Explain the equation or picture above in words.⟧\n:::"],
    publicNotes: ["Notes for Listeners", "::: public-notes\n⟦Notes for listeners and the handout.⟧\n:::"],
    inlineMath: ["Inline Math", "$⟦x^2⟧$", false], displayMath: ["Equation", "$$\n⟦E = mc^2⟧\n$$"],
    equationSteps: ["Equation Steps", "::: morph\n$$⟦a = b + c⟧$$\n$$a - c = b$$\n:::"],
    table: ["Table", "| ⟦Heading⟧ | Heading |\n| --- | --- |\n| Cell | Cell |\n| Cell | Cell |"],
    chart: ["Bar Chart from Table", "::: chart bar\n| ⟦Label⟧ | Value |\n| --- | ---: |\n| A | 1 |\n| B | 2 |\n:::"],
    plot: ["Plot with Slider", "::: plot\nx: 0, 6.28\nxlabel: x\nylabel: y\nslider: k, 0.5, 3, 1, Frequency\ny = ⟦sin(k*x)⟧\n:::"],
    codeBlock: ["Code Block", "```swift\n⟦code⟧\n```"],
    theorem: ["Theorem", "::: theorem ⟦Name⟧\nStatement.\n:::"], definition: ["Definition", "::: definition ⟦Term⟧\nMeaning.\n:::"],
    example: ["Example", "::: example ⟦Title⟧\nText.\n:::"], alert: ["Alert", "::: alert ⟦Title⟧\nText.\n:::"],
    columns: ["Two Columns", "::: columns\n::: column\n⟦Left⟧\n:::\n::: column\nRight\n:::\n:::"],
    articleOnly: ["Article-Only Text", "<!-- article -->\n⟦Text for the article only.⟧\n<!-- /article -->"],
    slidesOnly: ["Slide-Only Text", "<!-- slides -->\n⟦Text for the slides only.⟧\n<!-- /slides -->"],
} as const satisfies Record<string, SnippetDef>;

type SnippetId = keyof typeof SNIPPETS;
type InsertId = SnippetId | "title";

function snippetDef(id: SnippetId): SnippetDef { return SNIPPETS[id]; }

function perform(id: InsertId): void {
    if (readOnly()) return;
    if (id === "title") { E.insertFrontMatter(); return; }
    const [s, e] = E.selection();
    if (id === "articleOnly" && s !== e) { E.wrapSelectionInLines("<!-- article -->", "<!-- /article -->"); return; }
    if (id === "slidesOnly" && s !== e) { E.wrapSelectionInLines("<!-- slides -->", "<!-- /slides -->"); return; }
    const [, text, block = true] = snippetDef(id);
    E.insert(E.snippet(text, block));
}

function insertItems(): MenuItem[] {
    const it = (id: InsertId): MenuItem => ({ label: id === "title" ? "Title and Details" : snippetDef(id)[0], action: () => perform(id) });
    const groups: [string, InsertId[]][] = [
        ["Structure", ["title", "section", "columns"]], ["Narration", ["narration", "explanation", "publicNotes"]],
        ["Math", ["inlineMath", "equationSteps"]], ["Data", ["table", "plot", "chart", "codeBlock"]],
        ["Blocks", ["theorem", "definition", "example", "alert"]], ["Scope", ["articleOnly", "slidesOnly"]],
    ];
    const items: MenuItem[] = [it("slide"), { label: "Photo or Video…", action: () => addMedia("any") }, it("displayMath"), it("notes"), it("pause")];
    for (const [name, ids] of groups) {
        items.push({ separator: true }, { header: name }, ...ids.map(it));
        if (name === "Data") items.push({ separator: true }, { header: "Files" },
            { label: "Image File…", action: () => addMedia("image") }, { label: "Video File…", action: () => addMedia("video") });
    }
    return items;
}

const parseSlideStyle = (v: string): S.SlideStyle => (v === "takahashi" ? "takahashi" : "normal");

const takahashi = (): boolean => S.settings.slideStyle === "takahashi";

function buildPage(src: string): { html: string; outline: OutlineItem[] } {
    const article = state.view === "article";
    const kind = article ? C.PAGE_ARTICLE : C.PAGE_SLIDES;
    const opts = article ? C.O_TOC : P.slideOptions(takahashi());
    const d = P.doc(src, state.assetURLs, { kind });
    const html = C.page(d, kind, opts);
    let outline: OutlineItem[] = [];
    try { outline = C.outline(P.doc(src, state.assetURLs), P.slideOptions(takahashi())); } catch { outline = []; }
    return { html, outline };
}

function showPreviewMessage(text: string): void {
    frame().clear();
    const old = $("preview-pane").querySelector(".preview-message");
    if (old) old.remove();
    $("preview-pane").append(h("div", { class: "preview-message alert-text", role: "status", style: { padding: "24px" }, text }));
}

function refreshPreview(jump: boolean = false): void {
    const t = E.text();
    $("preview-pane").querySelector(".preview-message")?.remove();
    if (tooLarge(t)) { showPreviewMessage("The Markdown file is larger than 512 KB. Split it into more projects to see the preview."); return; }
    let r: { html: string; outline: OutlineItem[] };
    try { r = buildPage(t); } catch (e) { showPreviewMessage("Marklove could not make the preview. " + errorMessage(e)); return; }
    state.outline = r.outline;
    state.html = r.html;
    const offset = jump ? state.previewOffset : E.selection()[0];
    const slide = r.outline.length ? P.slideAt(r.outline, offset) : null;
    const fr = frame();
    if (state.view === "slides") fr.show(r.html, slide ? encodeURIComponent(slide.id) : "");
    else {
        fr.onload = (f) => { fr.onload = null; if (jump && slide) scrollArticle(f, slide.id); };
        fr.show(r.html, "", !jump);
    }
}

function scrollArticle(f: HTMLIFrameElement, id: string): void {
    try { f.contentDocument?.getElementById(id)?.scrollIntoView({ block: "start" }); } catch { return; }
}

const PREVIEW_DELAY_MS = 350;
const FOLLOW_DELAY_MS = 300;
const SPLIT_MIN_WIDTH = 900;

let previewTimer: Timer;
function schedulePreview(): void { clearTimeout(previewTimer); previewTimer = setTimeout(() => refreshPreview(false), PREVIEW_DELAY_MS); }

let followTimer: Timer;
function followCursor(): void {
    if (state.mode !== "preview" || !split()) return;
    clearTimeout(followTimer);
    followTimer = setTimeout(() => {
        if (!state.outline.length || !state.html) return;
        const s = P.slideAt(state.outline, E.selection()[0]);
        if (!s) return;
        const fr = frame();
        if (state.view === "slides") { if (fr.currentId() !== s.id) fr.show(state.html, encodeURIComponent(s.id)); }
        else if (fr.frame) scrollArticle(fr.frame, s.id);
    }, FOLLOW_DELAY_MS);
}

const split = (): boolean => !readOnly() && innerWidth > SPLIT_MIN_WIDTH;

function layout(): void {
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

function showPreview(): void {
    if (state.mode !== "preview") { state.previewOffset = E.selection()[0]; saveEditorState(); }
    state.mode = "preview";
    layout();
    refreshPreview(true);
    if (!split()) setTimeout(() => $("edit-btn").focus(), 0);
}

function showEdit(focusEditor: boolean = true): void {
    const wasPreview = state.mode === "preview";
    if (wasPreview && state.view === "slides" && state.outline.length) {
        const id = frame().currentId();
        const s = state.outline.find((x) => x.id === id);
        if (s && !(s.s0 <= state.previewOffset && state.previewOffset < s.s1)) E.setSelection(s.s0, s.s0);
    }
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    state.mode = "edit";
    layout();
    frame().clear();
    if (focusEditor) E.focus();
}

function present(): void {
    if (state.mode !== "preview") showPreview();
    const pane = $("preview-pane");
    if (pane.requestFullscreen) pane.requestFullscreen().then(() => frame().frame?.focus()).catch(() => announce("The browser did not allow full screen."));
}

const eq = { open: false };

function toggleEquation(): void {
    eq.open = !eq.open;
    if (!eq.open) { $("eq-pop").hidden = true; return; }
    if (!updateEquation()) { eq.open = false; announce("Put the cursor in an equation to preview it."); }
}

function updateEquation(): boolean {
    const pop = $("eq-pop");
    if (!eq.open) return false;
    const t = E.text();
    let m: ReturnType<typeof C.mathAt> = null;
    try { m = C.mathAt(t, E.selection()[0]); } catch { m = null; }
    if (!m) { pop.hidden = true; return false; }
    const latex = m.latex;
    const bad = (C.mathCheck(latex) || "").split("\n").filter(Boolean);
    const spoken = C.mathSpeech(latex).replace(/^[,\s]+|[,\s]+$/g, "");
    const math = h("div", { class: "eq-math" });
    if (bad.length) math.append(h("p", { class: "eq-warn", text: `⚠ Marklove cannot draw ${bad.join(", ")}. Exports show the LaTeX text.` }));
    else math.innerHTML = C.math(latex, true);
    pop.replaceChildren(math,
        h("p", { class: "eq-spoken", "aria-label": "Spoken as: " + spoken, text: spoken }),
        h("div", { class: "eq-foot" }, h("span", { text: m.display ? "Display equation" : "Inline equation" }), h("span", { class: "spacer" }),
            h("button", { type: "button", class: "button", onclick: async () => { await copyText(latex); announce("Copied the LaTeX."); } }, "Copy LaTeX"),
            h("button", { type: "button", class: "iconbtn", "aria-label": "Close the equation preview", onclick: () => { eq.open = false; pop.hidden = true; E.focus(); } }, "✕")));
    pop.hidden = false;
    return true;
}

let stylePicker: ReturnType<typeof segmented> | null = null;

function exportContext() {
    const src = E.text();
    let prefersDark: boolean | null = null;
    try { prefersDark = C.themeResolve(frontValue(src, "theme"), frontValue(src, "accent")).prefersDark; } catch { prefersDark = null; }
    const project = currentProject();
    return {
        title: docTitle(), name: project.name, source: src, assets: state.assets, assetURLs: state.assetURLs, prefersDark,
        lastChoice: state.exportChoice, setChoice: (v: string) => { state.exportChoice = v; },
        style: () => S.settings.slideStyle, setStyle: (v: string) => { S.setSetting("slideStyle", parseSlideStyle(v)); stylePicker?.setValue(v); if (state.mode === "preview") refreshPreview(); },
        versions: () => (S.settings.gitEnabled ? S.versions(project.id) : Promise.resolve([])),
        gitName: gitName(src), gitEmail: S.settings.gitEmail,
        beforeExport: async () => { await saveVersion({ auto: true }); },
        listenerPreview: () => openListenerPreview(),
        speakerReady: () => openSpeakerReady(),
        goToSource: (d: SourceTarget, fromExport: boolean) => goToSource(d, fromExport),
    };
}

function openExport(): void {
    if (tooLarge(E.text())) { void alertBox("The Markdown file is larger than 512 KB. Split it into more projects to export it."); return; }
    const ctx = exportContext();
    void X.exportSheet(ctx);
}

function goToSource(d: SourceTarget, fromExport: boolean): void {
    if (state.mode !== "edit") showEdit(false);
    state.focus = { message: d.message, detail: d.detail, returnToExport: fromExport };
    renderBanners();
    E.focus();
    E.setSelection(d.start, Math.max(d.start, d.end));
}

function openSpeakerReady(): void {
    const r = P.speakerReady({ source: E.text(), assets: state.assetURLs, takahashi: takahashi(), appearance: "", startOffset: E.selection()[0] });
    if ("error" in r) void alertBox(r.error, "Speaker Ready");
}

function openListenerPreview(): void {
    const r = P.listenerPreview({ source: E.text(), assets: state.assetURLs, takahashi: takahashi(), appearance: "" });
    if ("error" in r) void alertBox(r.error, "Listener Preview");
}

const TITLE_MENU_PROJECTS = 8;

function titleItems(): MenuItem[] {
    const projects = state.list.filter((p) => !p.isListener).slice(0, TITLE_MENU_PROJECTS);
    return [
        { header: "Projects" },
        ...projects.map((p): MenuItem => ({ label: p.name, checked: p.id === state.project?.id, action: () => openProject(p.id) })),
        { label: "New Project", shortcut: isMac ? "⌥⌘N" : "Ctrl+Alt+N", action: newProject },
        { label: "All Projects…", shortcut: isMac ? "⇧⌘O" : "Ctrl+Shift+O", action: () => UI.projectsPanel(app) },
        { label: "Received", action: () => UI.projectsPanel(app, { received: true }) },
        { separator: true },
        { label: "Rename…", disabled: readOnly(), action: () => UI.renamePanel(app) },
        { label: "Version History…", disabled: readOnly(), shortcut: isMac ? "⌥⌘Y" : "Ctrl+Alt+Y", action: () => UI.historyPanel(app) },
        { label: "Duplicate", action: duplicate },
        { label: "Import Markdown or ZIP…", shortcut: cmdKey + "O", action: importFiles },
        { label: "Save a ZIP Copy…", action: () => saveZipCopy() },
        { label: "Delete Project…", danger: true, action: () => deleteProject(currentProject()) },
        { separator: true },
        { label: "Find and Replace…", disabled: readOnly(), shortcut: isMac ? "⌥⌘F" : "Ctrl+Alt+F", action: () => F.openFind({ replace: true }) },
        { label: "Outline", shortcut: isMac ? "⇧⌘L" : "Ctrl+Shift+L", action: () => UI.outlinePanel(app) },
        { label: "Speaker Ready", shortcut: isMac ? "⇧⌘R" : "Ctrl+Shift+R", action: openSpeakerReady },
        { label: "Customize…", disabled: readOnly(), action: () => UI.customizePanel(app) },
        { label: "Settings", action: () => UI.settingsPanel(app) },
        { label: "Help and Examples", action: () => UI.helpPanel(app) },
    ];
}

function handleKey(e: KeyboardEvent): void {
    if (e.defaultPrevented) return;
    const mod = isMac ? e.metaKey : e.ctrlKey;
    const ctlMac = isMac && e.ctrlKey;
    const code = e.code;
    const inDialog = !!document.querySelector("dialog[open]");
    const run = (fn: () => unknown): void => { e.preventDefault(); e.stopPropagation(); closeMenu(); fn(); };
    if (e.key === "Escape" && state.mode === "preview" && !inDialog && !document.fullscreenElement && !(F.find.open && document.activeElement?.closest("#findbar"))) {
        if (!readOnly()) return run(() => showEdit());
    }
    if (!mod) return;
    if (inDialog) return;
    if (code === "KeyS" && !e.shiftKey && !e.altKey) return run(() => saveVersion({ explicit: true }));
    if (code === "KeyE" && (ctlMac || (!isMac && e.altKey))) return run(toggleEquation);
    if (code === "KeyE" && !e.shiftKey && !e.altKey) return run(openExport);
    if (code === "KeyF" && e.altKey) return run(() => F.openFind({ replace: true }));
    if (code === "KeyF" && !e.shiftKey) return run(() => F.openFind());
    if (code === "KeyG" && F.find.open) return run(() => F.next(!e.shiftKey));
    if (code === "KeyX" && e.altKey) return run(() => F.openFind({ command: true }));
    if (code === "KeyO" && e.shiftKey) return run(() => UI.projectsPanel(app));
    if (code === "KeyO") return run(importFiles);
    if (code === "KeyY" && e.altKey) return run(() => UI.historyPanel(app));
    if (code === "KeyL" && e.altKey) return run(() => { S.setSetting("showLineCount", !S.settings.showLineCount); updateStatus(); });
    if (code === "KeyL" && e.shiftKey) return run(() => UI.outlinePanel(app));
    if (code === "KeyR" && e.shiftKey) return run(openSpeakerReady);
    if (code === "KeyN" && e.altKey) return run(newProject);
    if (e.key === "Enter") return run(() => (state.mode === "edit" ? showPreview() : readOnly() ? null : showEdit()));
}

const app: UI.PanelApp = {
    readOnly, text: () => E.text(), title: docTitle, projectId: () => state.project?.id, projectName: () => state.project?.name || "",
    selectedText: () => E.text().slice(...E.selection()),
    replaceAll: (t) => E.replaceAll(t),
    insertText: (t) => E.insert(E.snippet(t)),
    applySettings, openSettings: () => UI.settingsPanel(app), findSyntaxChanged: () => F.syntaxChanged(),
    openProject, newProject, importFiles, openTour, deleteProject, rename,
    saveVersion, restoreVersion,
    goToSource: (s, e) => { if (state.mode !== "edit") showEdit(false); E.focus(); E.setSelection(s, e); },
};

async function start(): Promise<void> {
    try {
        await C.load();
        await P.loadParts();
        await S.open();
    } catch (e) {
        $("loading").textContent = "Marklove could not start. " + errorMessage(e) + " Use a current browser, and open the page from a web server.";
        return;
    }
    $("preview-frame").remove();
    const fr = new P.PageFrame($("preview-pane"), "Preview");
    frameOrNull = fr;
    fr.onkey = handleKey;
    E.init({ textarea: source(), highlight: $("highlight"), box: $("editor"), placeholder: $("placeholder") });
    E.editor.onChange = textChanged;
    E.editor.onSelect = () => { updateStatus(); E.syncVimCursor(); updateEquation(); followCursor(); };
    E.editor.onVimState = updateStatus;
    E.editor.onVimAction = (action, clip) => {
        if (action === "save") void saveVersion({ explicit: true });
        else if (action === "discard") void discardToLastVersion();
        else if (action === "copy" && clip) void copyText(clip);
    };
    F.initFind($("findbar"), app);

    attachMenu($("title-menu"), titleItems);
    attachMenu($("insert-btn"), insertItems);
    $("preview-btn").addEventListener("click", showPreview);
    $("export-btn").addEventListener("click", openExport);
    $("edit-btn").addEventListener("click", () => showEdit());
    $("present-only-btn").addEventListener("click", present);
    $("fullscreen-btn").addEventListener("click", present);
    $("export-btn").title = `Export slides, article, and other formats (${cmdKey}E)`;
    $("preview-btn").title = `Preview the slides (${cmdKey}Return)`;
    const viewPicker = segmented("View", [["slides", "Slides"], ["article", "Article"]], state.view, (v: string) => { state.view = v; $("style-picker").hidden = v !== "slides"; refreshPreview(false); });
    $("view-picker").append(viewPicker);
    stylePicker = segmented("Slide style", [["normal", "Normal"], ["takahashi", "Takahashi"]], S.settings.slideStyle, (v: string) => { S.setSetting("slideStyle", parseSlideStyle(v)); refreshPreview(false); });
    $("style-picker").append(stylePicker);
    document.addEventListener("keydown", handleKey);
    document.addEventListener("fullscreenchange", () => { $("workspace").classList.toggle("presenting", !!document.fullscreenElement); });
    addEventListener("resize", () => { if (state.mode === "preview") layout(); });
    addEventListener("pagehide", () => { void flushSave(); saveEditorState(); });
    document.addEventListener("visibilitychange", () => { if (document.hidden) { void flushSave(); saveEditorState(); } });

    applySettings();
    await refreshList();
    const last = state.list.find((p) => p.id === S.settings.lastProject);
    const firstWritable = state.list.find((p) => !p.isListener) || state.list[0];
    if (last) await openProject(last.id);
    else if (firstWritable) await openProject(firstWritable.id);
    else await openTour();
    $("loading").hidden = true;
    if (!S.settings.onboardingSeen) UI.welcome(app);
}

void start();
