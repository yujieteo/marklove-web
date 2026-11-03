import * as C from "./core.ts";
import * as P from "./preview.ts";
import * as S from "./store.ts";
import * as G from "./pages.ts";
import * as V from "./video.ts";
import * as Voice from "./voice.ts";
import { h, dialog, section, footnote, segmented, selectRow, download, blobToDataURL, announce } from "./ui.ts";
import type { DialogHandle } from "./ui.ts";
import { must } from "./dom.ts";

const PRINT_NOTE = "Opens the print dialog. Select Save as PDF.";
const NO_VOICE = "Download the Kokoro voice in Settings first.";

const FORMAT_ROWS = [
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
    ["projectZIP", "Packages", "Project with version history", "ZIP", "The project folder with its Git history. Other Git apps can read it.", ""],
] as const;

type FormatId = (typeof FORMAT_ROWS)[number][0];

interface Format {
    id: FormatId;
    group: string;
    name: string;
    label: string;
    summary: string;
    print: boolean;
}

const FORMATS: Format[] = FORMAT_ROWS.map(([id, group, name, label, summary, web]) => ({ id, group, name, label, summary, print: web === "print" }));

const formatById = (id: FormatId): Format => must(FORMATS.find((f) => f.id === id), "format " + id);
const asFormatId = (s: string): FormatId | undefined => FORMATS.find((f) => f.id === s)?.id;

const WEIGHTS: Partial<Record<FormatId, number>> = { video: 6, manimVideo: 6, narratedVideo: 10, podcast: 4, slidesPDF: 2, articlePDF: 2, handoutPDF: 2, posterPDF: 2, slidesPNG: 3, slidesSVG: 5 };

const GROUPS = ["Slides and article", "Documents", "Interactive", "Audio and video", "Text", "Packages"];

const US = ["US", "CA", "MX", "PH"];
const region = (): string => (navigator.language || "").split("-")[1]?.toUpperCase() || "";

const PAPERS = ["a4", "letter"] as const;
type Paper = (typeof PAPERS)[number];
const ORIENTATIONS = ["portrait", "landscape"] as const;
type Orientation = (typeof ORIENTATIONS)[number];
const APPEARANCES = ["system", "light", "dark"] as const;
const STYLES = ["normal", "takahashi"] as const;

function oneOf<T extends string>(list: readonly T[], v: string): T | undefined {
    return list.find((x) => x === v);
}

const POSTERS = {
    a0: ["A0 (841 × 1189 mm)", 841, 1189, "mm"], a1: ["A1 (594 × 841 mm)", 594, 841, "mm"],
    in48x36: ["48 × 36 in", 36, 48, "in"], in42x42: ["42 × 42 in (square)", 42, 42, "in"],
} as const;

type PosterKey = keyof typeof POSTERS;
const POSTER_KEYS: readonly PosterKey[] = ["a0", "a1", "in48x36", "in42x42"];

function fileName(id: FormatId, title: string, style: string): string {
    const b = S.safeFileName(title);
    const st = style === "takahashi" ? "Takahashi" : "Normal";
    const names: Record<FormatId, string> = {
        slidesPDF: `${b} – slides (${st}).pdf`, slidesPNG: `${b} – slides (${st}) PNG.zip`, slidesSVG: `${b} – slides (${st}) SVG.zip`, articlePDF: `${b} – article.pdf`, articleHTML: `${b} – article.html`, epub: `${b}.epub`,
        handoutPDF: `${b} – handout.pdf`, posterPDF: `${b} – poster.pdf`, interactiveHTML: `${b} – presentation.html`,
        articleMarkdown: `${b} – article.md`, revisedMarkdown: `${b} – Takahashi.md`, narrationScript: `${b} – narration script.txt`,
        transcript: `${b} – transcript.txt`, subtitles: `${b} – subtitles.vtt`, presenterZIP: `${b} – presenter.zip`,
        listenerZIP: `${b} – listener.zip`, projectZIP: `${b} – project with history.zip`, promptText: `${b} – prompt.txt`,
        video: `${b} – video.mp4`, narratedVideo: `${b} – narrated video.mp4`, manimVideo: `${b} – math animation.mp4`, podcast: `${b} – podcast.m4a`,
    };
    return names[id];
}

function diagnostics(source: string, assetURLs: Record<string, string> = {}): { list: C.LintIssue[]; error: string } {
    try { return { list: C.lint(source, assetURLs), error: "" }; }
    catch (e) { return { list: [], error: e instanceof C.TooLarge ? e.message : "Marklove could not check the source. " + P.messageOf(e) }; }
}

function affects(d: C.LintIssue, id: FormatId, style: string): boolean {
    if (!d.formats.includes(id)) return false;
    if (d.style === "takahashi" && style !== "takahashi") return false;
    return true;
}

function lineOf(text: string, offset: number): number {
    let n = 1;
    for (let i = text.indexOf("\n"); i >= 0 && i < offset; i = text.indexOf("\n", i + 1)) n++;
    return n;
}

function formatNames(d: C.LintIssue): string {
    if (d.formats.length >= FORMATS.length - 2) return "All outputs";
    const names = FORMATS.filter((f) => d.formats.includes(f.id)).map((f) => f.name);
    return names.length > 3 ? `${names.slice(0, 3).join(", ")}, and ${names.length - 3} more` : names.join(", ");
}

function issueRow(d: C.LintIssue, text: string, goToSource: () => void): HTMLElement {
    const warn = d.severity === "warning";
    return h("div", { class: "issue" },
        h("div", { class: "msg" }, h("span", { class: warn ? "status-warn" : "", "aria-label": warn ? "Warning" : "Information" }, warn ? "⚠ " : "ⓘ "), d.message),
        h("div", { class: "where", text: `Line ${lineOf(text, d.start)} · ${formatNames(d)}` }),
        d.detail ? h("details", {}, h("summary", { text: "More" }), h("p", { text: d.detail })) : null,
        h("button", { type: "button", class: "button", onclick: goToSource }, "Go to Source"));
}

const now = (): number => Math.floor(Date.now() / 1000);

export interface ExportCtx extends G.PageCtx {
    name: string;
    lastChoice?: string | undefined;
    prefersDark: boolean | null;
    gitName?: string | undefined;
    gitEmail?: string | undefined;
    style(): S.SlideStyle;
    setStyle(v: S.SlideStyle): void;
    setChoice(choice: string): void;
    versions(): Promise<S.Version[]>;
    beforeExport(): Promise<void>;
    goToSource(issue: C.LintIssue, select: boolean): void;
    listenerPreview(): void;
    speakerReady(): void;
}

type FileEntry = [string, Blob | string];

async function singleFile(html: string, ctx: ExportCtx): Promise<string> {
    let out = html;
    for (const [path, url] of Object.entries(ctx.assetURLs)) {
        if (!out.includes(url)) continue;
        const blob = must(ctx.assets[path], "asset " + path);
        const data = await blobToDataURL(blob);
        out = out.split(url).join(data);
    }
    return out;
}

const textBlob = (t: string, type = "text/plain"): Blob => new Blob([t], { type: type + ";charset=utf-8" });

function blobOf(parts: (Uint8Array | Blob)[], type: string): Blob {
    return new Blob(parts.map((p) => p instanceof Blob ? p : Uint8Array.from(p)), { type });
}

async function zipOf(files: FileEntry[], mtime: number): Promise<Blob> {
    C.zipBegin();
    const parts: (Uint8Array | Blob)[] = [];
    for (const [name, data] of files) {
        if (data instanceof Blob) { const g = await C.zipAddBlob(name, data, mtime); if (g) parts.push(...g); }
        else C.zipAdd(name, data, mtime);
    }
    parts.push(C.zipFinish());
    return blobOf(parts, "application/zip");
}

function packageFiles(ctx: ExportCtx, markdown: string, paths: string[]): { files: FileEntry[]; missing: string[] } {
    const files: FileEntry[] = [[S.safeFileName(ctx.name) + ".md", markdown]];
    const missing: string[] = [];
    for (const p of paths) {
        const blob = ctx.assets[p];
        if (blob) files.push([p, blob]);
        else missing.push("Not included because the file is missing: " + p);
    }
    return { files, missing };
}

function listenerText(source: string, kind: number): string {
    const r = C.listener(source, kind);
    if (typeof r !== "string") throw new Error("The listener output is not text.");
    return r;
}

function listenerPaths(source: string, kind: number): string[] {
    const r = C.listener(source, kind);
    if (typeof r === "string") throw new Error("The listener output is not a list.");
    return r;
}

export async function projectZip(ctx: Pick<ExportCtx, "name" | "source" | "assets" | "gitName" | "gitEmail">, versions: S.Version[]): Promise<Blob> {
    const t = now();
    const md = S.safeFileName(ctx.name) + ".md";
    C.zipBegin();
    const parts: (Uint8Array | Blob)[] = [];
    if (versions.length) {
        const name = ctx.gitName || "Marklove";
        C.gitBegin(name, ctx.gitEmail || "", t);
        const seen = new Set<string>();
        for (const v of versions.slice().reverse()) {
            C.gitFile(md, v.markdown);
            for (const p of v.assets || []) {
                const blob = ctx.assets[p];
                if (!blob) continue;
                const g = await C.gitFileBlob(p, blob, t, seen);
                if (g) parts.push(...g);
            }
            C.gitCommit(v.message, Math.floor(v.time / 1000), -new Date(v.time).getTimezoneOffset());
            parts.push(C.zipTake());
        }
        C.gitFinish(t);
    }
    C.zipAdd(md, ctx.source, t);
    parts.push(C.zipTake());
    for (const [p, blob] of Object.entries(ctx.assets)) {
        const g = await C.zipAddBlob(p, blob, t);
        if (g) parts.push(...g);
    }
    parts.push(C.zipFinish());
    return blobOf(parts, "application/zip");
}

async function epub(ctx: ExportCtx, d: C.Doc): Promise<Blob> {
    const linked = C.epub(d, now(), 0);
    const parts: (Uint8Array | Blob)[] = [];
    for (const p of linked) {
        const blob = ctx.assets[p];
        if (!blob) continue;
        const g = await C.zipAddBlob("OEBPS/media/" + p, blob, now());
        if (g) parts.push(...g);
    }
    parts.push(C.zipFinish());
    return blobOf(parts, "application/epub+zip");
}

function named(name: string, r: V.VideoResult): FormatFiles {
    return { kind: "files", files: r.files.map(([ext, blob]): [string, Blob] => [name.replace(/\.\w+$/, "." + ext), blob]), notes: r.notes };
}

interface ExportOptions {
    style: S.SlideStyle;
    appearance: S.Appearance;
    paper: Paper;
    posterSize: PosterKey;
    posterOrientation: Orientation;
}

interface FormatFiles {
    kind: "files";
    files: [string, Blob][];
    notes?: string[] | undefined;
}

interface FormatPrint {
    kind: "print";
    print: () => Promise<void>;
    name: string;
    notes: string[];
}

interface FormatReason {
    kind: "reason";
    reason: string;
}

type BuildResult = FormatFiles | FormatPrint | FormatReason;

async function build(id: FormatId, ctx: ExportCtx, opt: ExportOptions, progress: (p: number) => void): Promise<BuildResult> {
    const takahashi = opt.style === "takahashi";
    const dark = opt.appearance === "system" ? (ctx.prefersDark === null ? "" : ctx.prefersDark ? "dark" : "light") : opt.appearance;
    const name = fileName(id, ctx.title, opt.style);
    const fonts = await P.embeddedFonts();
    const slideDoc = P.doc(ctx.source, ctx.assetURLs, { appearance: dark, fonts });
    const articleDoc = P.doc(ctx.source, ctx.assetURLs, { kind: C.PAGE_ARTICLE, appearance: dark, fonts });
    const tk = takahashi ? C.O_TAKAHASHI : 0;
    const letter = opt.paper === "letter" ? 1 : 0;
    const printed = async (kind: number, o: G.LayoutOptions): Promise<FormatPrint> => {
        await G.load();
        const { html, notes } = await G.printHTML(ctx, kind, o);
        return { kind: "print", print: () => printPage(html), name, notes };
    };
    switch (id) {
        case "interactiveHTML":
            return { kind: "files", files: [[name, textBlob(await singleFile(C.page(slideDoc, C.PAGE_SLIDES, P.slideOptions(takahashi)), ctx), "text/html")]] };
        case "articleHTML":
            return { kind: "files", files: [[name, textBlob(await singleFile(C.page(articleDoc, C.PAGE_ARTICLE, C.O_TOC), ctx), "text/html")]] };
        case "epub":
            return { kind: "files", files: [[name, await epub(ctx, P.doc(ctx.source, ctx.assetURLs, { kind: C.PAGE_ARTICLE, fonts: "" }))]] };
        case "articleMarkdown": return { kind: "files", files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_ARTICLE_MD, 0), "text/markdown")]] };
        case "revisedMarkdown": return { kind: "files", files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_REVISED_MD, tk), "text/markdown")]] };
        case "narrationScript": return { kind: "files", files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_NARRATION, 0))]] };
        case "transcript": return { kind: "files", files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_TRANSCRIPT, 0))]] };
        case "subtitles": {
            await G.load();
            const m = await G.media(ctx);
            return { kind: "files", files: [[name, textBlob(G.captions(ctx, m, { takahashi }), "text/vtt")],
                [name.replace(/\.vtt$/, ".srt"), textBlob(G.captions(ctx, m, { takahashi, srt: true }), "application/x-subrip")]] };
        }
        case "promptText": return { kind: "files", files: [[name, textBlob(listenerText(ctx.source, C.LIST_REVISION_PROMPT))]] };
        case "presenterZIP": {
            const paths = [...listenerPaths(ctx.source, C.LIST_PUBLIC_ASSETS), ...listenerPaths(ctx.source, C.LIST_PRIVATE_ASSETS)];
            const { files, missing } = packageFiles(ctx, ctx.source, paths);
            return { kind: "files", files: [[name, await zipOf(files, now())]], notes: missing };
        }
        case "listenerZIP": {
            const { files, missing } = packageFiles(ctx, listenerText(ctx.source, C.LIST_LISTENER_MD), listenerPaths(ctx.source, C.LIST_PUBLIC_ASSETS));
            return { kind: "files", files: [[name, await zipOf(files, now())]], notes: missing };
        }
        case "projectZIP": return { kind: "files", files: [[name, await projectZip(ctx, await ctx.versions())]] };
        case "slidesPDF": return printed(G.LAYOUT_SLIDES, { takahashi, appearance: dark });
        case "handoutPDF": return printed(G.LAYOUT_HANDOUT, { takahashi, a: letter });
        case "articlePDF": return printed(G.LAYOUT_ARTICLE, { appearance: "light", a: letter });
        case "posterPDF": return printed(G.LAYOUT_POSTER, { appearance: "light", a: G.POSTER_SIZES.indexOf(opt.posterSize), b: opt.posterOrientation === "landscape" ? 1 : 0 });
        case "slidesPNG": case "slidesSVG": {
            await G.load();
            const { files, notes } = await (id === "slidesPNG" ? G.slidesPNG : G.slidesSVG)(ctx, { takahashi, appearance: dark }, progress);
            return { kind: "files", files: [[name, await zipOf(files, now())]], notes };
        }
        case "video": case "manimVideo":
            await G.load();
            return named(name, await V.video(ctx, { takahashi, appearance: dark }, id === "video" ? "video" : "manim", progress));
        case "narratedVideo": case "podcast":
            if (!(await Voice.installed())) return { kind: "reason", reason: NO_VOICE };
            await G.load();
            return named(name, id === "podcast" ? await V.podcast(ctx, progress)
                : await V.video(ctx, { takahashi, appearance: dark }, "narrated", progress));
    }
}

async function printPage(html: string): Promise<void> {
    const frame = h("iframe", { title: "Print", style: { position: "fixed", left: "-10000px", top: "0", width: "1280px", height: "720px", border: "0" } });
    document.body.append(frame);
    const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
    await new Promise<void>((res) => { frame.onload = () => res(); frame.src = url; });
    const win = must(frame.contentWindow, "print window");
    try { await win.document.fonts.ready; } catch { }
    await Promise.all([...win.document.images].map((im) => im.complete ? 0 : new Promise<void>((r) => {
        const done = (): void => r();
        im.onload = done;
        im.onerror = done;
    })));
    await new Promise((r) => setTimeout(r, 200));
    win.focus();
    win.print();
    setTimeout(() => { frame.remove(); URL.revokeObjectURL(url); }, 2000);
}

type Choice = "all" | FormatId;

interface SheetState {
    choice: Choice;
    appearance: S.Appearance;
    paper: Paper;
    posterSize: PosterKey;
    posterOrientation: Orientation;
    showIssues: boolean;
    optionsOpen: boolean;
    error: string;
}

interface ExportResult {
    id: FormatId;
    ok: boolean;
    reason?: string;
    notes: string[];
}

const describe = (e: unknown): string => e instanceof Error ? (e.message || String(e)) : String(e);

export function exportSheet(ctx: ExportCtx): void {
    const last = ctx.lastChoice === undefined ? undefined : asFormatId(ctx.lastChoice);
    const st: SheetState = {
        choice: last ?? "all", appearance: "system", paper: US.includes(region()) ? "letter" : "a4",
        posterSize: US.includes(region()) ? "in48x36" : "a0", posterOrientation: "portrait", showIssues: false,
        optionsOpen: false, error: "",
    };
    const { list: diags, error: lintError } = diagnostics(ctx.source, ctx.assetURLs);
    const style = (): S.SlideStyle => ctx.style();
    const issuesFor = (id: FormatId): C.LintIssue[] => diags.filter((d) => affects(d, id, style()) && d.severity === "warning");
    const selected = (): C.LintIssue[] => {
        const c = st.choice;
        return c === "all" ? diags : diags.filter((d) => affects(d, c, style()));
    };
    const body = h("div", {});
    let dlg: DialogHandle | undefined;
    const sheet = (): DialogHandle => must(dlg, "export dialog");

    function choiceRow(id: Choice, title: string, label: string, sub: string, count: number): HTMLElement {
        const on = st.choice === id;
        return h("button", {
            type: "button", class: "choice", role: "radio", "aria-checked": String(on), disabled: false,
            "aria-label": title, "aria-description": sub + (count ? ` Warnings: ${count}` : ""),
            onclick: () => {
                st.choice = id;
                render();
                const row = body.querySelector(`[data-id="${id}"]`);
                if (row instanceof HTMLElement) row.focus();
            }, "data-id": id,
        }, h("span", { class: "dot", "aria-hidden": "true", text: on ? "◉" : "○" }),
            h("span", {}, h("span", { class: "name", text: title }), h("span", { class: "fmt", text: label }),
                h("span", { class: "sub", text: sub }), count ? h("span", { class: "warncount", text: `⚠ Warnings: ${count}` }) : null));
    }

    function render(): void {
        const scroll = dlg ? dlg.body.scrollTop : 0;
        body.replaceChildren();
        const warnCount = diags.filter((x) => x.severity === "warning").length;
        body.append(section(null,
            h("div", { role: "radiogroup", "aria-label": "Output" }, choiceRow("all", "All outputs", "ZIP", "Every format that the web version makes, in one ZIP file. The PDFs open the print dialog separately.", warnCount)),
            h("div", { class: "row" }, h("span", { class: "row-label", text: "Slide style" }),
                segmented("Slide style", [["normal", "Normal"], ["takahashi", "Takahashi"]], style(), (v) => {
                    const chosen = oneOf(STYLES, v);
                    if (chosen) ctx.setStyle(chosen);
                    render();
                })),
            footnote("Every format is free.")));
        for (const g of GROUPS) {
            const rows = FORMATS.filter((f) => f.group === g).map((f) => {
                let sub = f.summary;
                if (f.id === "slidesPDF") sub = `${style() === "takahashi" ? "Takahashi" : "Normal"} slides. Change the style above.`;
                if (f.print) sub += " " + PRINT_NOTE;
                return choiceRow(f.id, f.name, f.label, sub, issuesFor(f.id).length);
            });
            const extra = g === "Packages" ? h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", title: "See the slides and notes that a listener gets from the Listener package", onclick: () => ctx.listenerPreview() }, "👥 Preview as a Listener")) : null;
            body.append(section(g, h("div", { role: "radiogroup", "aria-label": g }, rows), extra));
        }
        const sel = selected();
        const checks: HTMLElement[] = [];
        if (lintError) checks.push(h("div", { class: "row" }, h("span", { class: "status-warn", text: "⚠ " + lintError })));
        else if (!sel.length) checks.push(h("div", { class: "row" }, h("span", { class: "status-ok", text: "✓ Ready to export" })));
        else {
            checks.push(h("div", { class: "row" }, h("span", { class: "status-warn", text: `⚠ Source checks to review: ${sel.length}` }),
                h("button", { type: "button", class: "button", "aria-expanded": String(st.showIssues), onclick: () => { st.showIssues = !st.showIssues; render(); } }, st.showIssues ? "Hide" : "Show")));
            checks.push(footnote("Export stays available. Marklove uses a clear fallback for each issue and keeps every word."));
            if (st.showIssues) checks.push(h("div", {}, sel.map((x) => issueRow(x, ctx.source, () => { sheet().close(); ctx.goToSource(x, true); }))));
        }
        body.append(section("Source checks", ...checks));
        const poster = POSTERS[st.posterSize];
        const optBox = h("details", { class: "group", open: st.optionsOpen }, h("summary", { text: "Options" }),
            selectRow("Appearance", [["system", "From the Project"], ["light", "Light"], ["dark", "Dark"]], st.appearance, (v) => { st.appearance = oneOf(APPEARANCES, v) ?? st.appearance; }),
            selectRow("Paper", [["a4", "A4"], ["letter", "US Letter"]], st.paper, (v) => { st.paper = oneOf(PAPERS, v) ?? st.paper; }),
            selectRow("Poster size", POSTER_KEYS.map((k): [string, string] => [k, POSTERS[k][0]]), st.posterSize, (v) => { st.posterSize = oneOf(POSTER_KEYS, v) ?? st.posterSize; render(); }),
            h("div", { class: "row" }, h("span", { class: "row-label", text: "Poster orientation" }),
                poster[1] === poster[2] ? h("span", { class: "row-hint", text: "Square" }) :
                    segmented("Poster orientation", [["portrait", "Portrait"], ["landscape", "Landscape"]], st.posterOrientation, (v) => { st.posterOrientation = oneOf(ORIENTATIONS, v) ?? st.posterOrientation; })));
        optBox.addEventListener("toggle", () => { st.optionsOpen = optBox.open; });
        body.append(section(null, optBox));
        body.append(section(null, h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => { sheet().close(); ctx.speakerReady(); } }, "Start Speaker Ready")),
            footnote("Present with the current slide, the next slide, private notes, and a timer. The audience window shows the slides only.")));
        if (st.error) body.append(section(null, h("div", { class: "row" }, h("span", { class: "status-bad", role: "alert", text: "⊗ " + st.error }))));
        if (dlg) dlg.body.scrollTop = scroll;
    }

    async function start(): Promise<void> {
        st.error = "";
        ctx.setChoice(st.choice);
        const ids = st.choice === "all" ? FORMATS.filter((f) => !f.print).map((f) => f.id) : [st.choice];
        const weight = (id: FormatId): number => WEIGHTS[id] || 1;
        const bar = h("progress", { max: String(ids.reduce((n, id) => n + weight(id), 0)) });
        const label = h("span", { text: "Preparing…" });
        const progress = h("div", { class: "progress", role: "status" }, bar, label);
        body.replaceChildren(progress);
        sheet().buttons.forEach((b) => { b.disabled = b.textContent === "Export"; });
        await ctx.beforeExport();
        const opt: ExportOptions = { style: style(), appearance: st.appearance, paper: st.paper, posterSize: st.posterSize, posterOrientation: st.posterOrientation };
        const results: ExportResult[] = [];
        const files: [string, Blob][] = [];
        let base = 0;
        for (const id of ids) {
            label.textContent = `Exporting ${formatById(id).name}…`;
            bar.value = base;
            await new Promise((r) => setTimeout(r, 0));
            try {
                const r = await build(id, ctx, opt, (p) => { bar.value = base + p * weight(id); });
                if (r.kind === "reason") results.push({ id, ok: false, reason: r.reason, notes: [] });
                else if (r.kind === "print") {
                    await r.print();
                    results.push({ id, ok: true, notes: ["The print dialog opened. Select Save as PDF. Suggested name: " + r.name, ...r.notes] });
                } else {
                    files.push(...r.files);
                    results.push({ id, ok: true, notes: r.notes || [] });
                }
            } catch (e) {
                const msg = e instanceof C.TooLarge ? e.message : "Marklove could not make the file. " + describe(e);
                results.push({ id, ok: false, reason: msg, notes: [] });
            }
            base += weight(id);
        }
        Voice.forget();
        let deliver = files;
        if (st.choice === "all") {
            label.textContent = "Making the ZIP file…";
            const lines = [`Marklove exports for "${ctx.title}"`, ""];
            for (const r of results) lines.push(`${formatById(r.id).name}: ${r.ok ? "created" : "not created. " + r.reason}`, ...r.notes.map((n) => "  " + n));
            for (const f of FORMATS.filter((f) => f.print)) lines.push(`${f.name}: not in this ZIP. Select it in Export to print it as PDF.`);
            try {
                const zip = await zipOf([...files, ["README.txt", lines.join("\n") + "\n"]], now());
                deliver = [[`${S.safeFileName(ctx.title)} – Marklove exports.zip`, zip]];
            } catch (e) { st.error = "Export did not complete. " + P.messageOf(e); }
        }
        for (const [n, b] of deliver) download(b, n);
        showResults(results, deliver);
    }

    function showResults(results: ExportResult[], deliver: [string, Blob][]): void {
        body.replaceChildren();
        sheet().buttons.forEach((b) => { if (b.textContent === "Export") b.hidden = true; if (b.textContent === "Cancel") b.textContent = "Done"; b.disabled = false; });
        body.append(section(null, h("div", { class: "group" },
            deliver.length ? h("p", { text: "The browser saves the files in its downloads folder. Select a file to save it again." }) : null,
            deliver.map(([n, b]) => h("div", {}, h("button", { type: "button", class: "linkbtn", onclick: () => download(b, n) }, "⇩ " + n))))));
        body.append(section("Results", h("div", {}, results.map((r) => h("div", { class: "issue" },
            r.ok ? h("div", { class: "status-ok", text: "✓ " + formatById(r.id).name }) : h("div", { class: "status-bad", text: `${formatById(r.id).name}: not created` }),
            r.reason ? h("p", { class: "footnote", text: r.reason }) : null,
            r.notes.map((n) => h("p", { class: "footnote", text: n })))))));
        if (st.error) body.append(h("p", { class: "status-bad", role: "alert", text: st.error }));
        announce("Export complete.");
    }

    dlg = dialog({
        title: "Export", body, wide: false,
        buttons: [{ label: "Cancel", cancel: true }, { label: "Export", primary: true, action: () => { void start(); return false; } }],
    });
    render();
    const checked = body.querySelector('[aria-checked="true"]');
    if (checked instanceof HTMLElement) checked.focus();
}
