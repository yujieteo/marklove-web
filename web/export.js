// Export (ExportSheet.swift and ExportRunner.swift). The core lays out the
// PDF pages, the slide images and the video (web/pages.js, web/video.js).
// PDFs open the print dialog with these pages.

import * as C from "./core.js";
import * as P from "./preview.js";
import * as S from "./store.js";
import * as G from "./pages.js";
import * as V from "./video.js";
import * as Voice from "./voice.js";
import { h, dialog, section, footnote, segmented, selectRow, download, blobToDataURL, announce } from "./ui.js";

const PRINT_NOTE = "Opens the print dialog. Select Save as PDF.";
const NO_VOICE = "Download the Kokoro voice in Settings first.";

// ExportFormat, in the same sequence.
export const FORMATS = [
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
].map(([id, group, name, label, summary, web]) => ({ id, group, name, label, summary, print: web === "print" }));

// The share of the progress for each format (ExportRunner.weight).
const WEIGHTS = { video: 6, manimVideo: 6, narratedVideo: 10, podcast: 4, slidesPDF: 2, articlePDF: 2, handoutPDF: 2, posterPDF: 2, slidesPNG: 3, slidesSVG: 5 };

const GROUPS = ["Slides and article", "Documents", "Interactive", "Audio and video", "Text", "Packages"];
const byId = Object.fromEntries(FORMATS.map((f) => [f.id, f]));
const usesSlideStyle = new Set(["slidesPDF", "slidesPNG", "slidesSVG", "handoutPDF", "interactiveHTML", "video", "narratedVideo"]);

const US = ["US", "CA", "MX", "PH"];
const region = () => (navigator.language || "").split("-")[1]?.toUpperCase() || "";

export const POSTERS = {
    a0: ["A0 (841 × 1189 mm)", 841, 1189, "mm"], a1: ["A1 (594 × 841 mm)", 594, 841, "mm"],
    in48x36: ["48 × 36 in", 36, 48, "in"], in42x42: ["42 × 42 in (square)", 42, 42, "in"],
};

export function fileName(id, title, style) {
    const b = S.safeFileName(title);
    const st = style === "takahashi" ? "Takahashi" : "Normal";
    return {
        slidesPDF: `${b} – slides (${st}).pdf`, slidesPNG: `${b} – slides (${st}) PNG.zip`, slidesSVG: `${b} – slides (${st}) SVG.zip`, articlePDF: `${b} – article.pdf`, articleHTML: `${b} – article.html`, epub: `${b}.epub`,
        handoutPDF: `${b} – handout.pdf`, posterPDF: `${b} – poster.pdf`, interactiveHTML: `${b} – presentation.html`,
        articleMarkdown: `${b} – article.md`, revisedMarkdown: `${b} – Takahashi.md`, narrationScript: `${b} – narration script.txt`,
        transcript: `${b} – transcript.txt`, subtitles: `${b} – subtitles.vtt`, presenterZIP: `${b} – presenter.zip`,
        listenerZIP: `${b} – listener.zip`, projectZIP: `${b} – project with history.zip`, promptText: `${b} – prompt.txt`,
        video: `${b} – video.mp4`, narratedVideo: `${b} – narrated video.mp4`, manimVideo: `${b} – math animation.mp4`, podcast: `${b} – podcast.m4a`,
    }[id];
}

// --- the source checks ----------------------------------------------------------

// The assets are the {path: URL} map, as for core.page.
export function diagnostics(source, assetURLs = {}) {
    try { return { list: C.lint(source, assetURLs), error: "" }; }
    catch (e) { return { list: [], error: e instanceof C.TooLarge ? e.message : "Marklove could not check the source. " + e.message }; }
}

function affects(d, id, style) {
    if (!d.formats.includes(id)) return false;
    if (d.style === "takahashi" && style !== "takahashi") return false;
    return true;
}

export function lineOf(text, offset) {
    let n = 1;
    for (let i = text.indexOf("\n"); i >= 0 && i < offset; i = text.indexOf("\n", i + 1)) n++;
    return n;
}

function formatNames(d) {
    if (d.formats.length >= FORMATS.length - 2) return "All outputs";
    const names = FORMATS.filter((f) => d.formats.includes(f.id)).map((f) => f.name);
    return names.length > 3 ? `${names.slice(0, 3).join(", ")}, and ${names.length - 3} more` : names.join(", ");
}

export function issueRow(d, text, goToSource) {
    const warn = d.severity === "warning";
    return h("div", { class: "issue" },
        h("div", { class: "msg" }, h("span", { class: warn ? "status-warn" : "", "aria-label": warn ? "Warning" : "Information" }, warn ? "⚠ " : "ⓘ "), d.message),
        h("div", { class: "where", text: `Line ${lineOf(text, d.start)} · ${formatNames(d)}` }),
        d.detail ? h("details", {}, h("summary", { text: "More" }), h("p", { text: d.detail })) : null,
        h("button", { type: "button", class: "btn small", onclick: goToSource }, "Go to Source"));
}

// --- builders -------------------------------------------------------------------------

const now = () => Math.floor(Date.now() / 1000);

async function singleFile(html, ctx) {
    for (const [path, url] of Object.entries(ctx.assetURLs)) {
        if (!html.includes(url)) continue;
        const data = await blobToDataURL(ctx.assets[path]);
        html = html.split(url).join(data);
    }
    return html;
}

const textBlob = (t, type = "text/plain") => new Blob([t], { type: type + ";charset=utf-8" });

async function zipOf(files, mtime) {
    C.zipBegin();
    const parts = [];
    for (const [name, data] of files) {
        if (data instanceof Blob) { const g = await C.zipAddBlob(name, data, mtime); if (g) parts.push(...g); }
        else C.zipAdd(name, data, mtime);
    }
    parts.push(C.zipFinish());
    return new Blob(parts, { type: "application/zip" });
}

function packageFiles(ctx, markdown, paths) {
    const files = [[S.safeFileName(ctx.name) + ".md", markdown]];
    const missing = [];
    for (const p of paths) {
        if (ctx.assets[p]) files.push([p, ctx.assets[p]]);
        else missing.push("Not included because the file is missing: " + p);
    }
    return { files, missing };
}

export async function projectZip(ctx, versions) {
    const t = now();
    const md = S.safeFileName(ctx.name) + ".md";
    C.zipBegin();
    const parts = [];
    if (versions.length) {
        const name = ctx.gitName || "Marklove";
        C.gitBegin(name, ctx.gitEmail || "", t);
        const seen = new Set();
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
    return new Blob(parts, { type: "application/zip" });
}

async function epub(ctx, d) {
    const linked = C.epub(d, now(), 0);
    const parts = [];
    for (const p of linked) {
        const blob = ctx.assets[p];
        if (!blob) continue;
        const g = await C.zipAddBlob("OEBPS/media/" + p, blob, now());
        if (g) parts.push(...g);
    }
    parts.push(C.zipFinish());
    return new Blob(parts, { type: "application/epub+zip" });
}

// Video and audio: [extension, blob] parts get the name of the format.
function named(name, r) {
    return { files: r.files.map(([ext, blob]) => [name.replace(/\.\w+$/, "." + ext), blob]), notes: r.notes };
}

// Makes one format. Returns {files: [[name, blob]], notes}, {print: fn},
// or {reason} when it cannot be made. progress receives values from 0 to 1.
async function build(id, ctx, opt, progress) {
    const takahashi = opt.style === "takahashi";
    const dark = opt.appearance === "system" ? (ctx.prefersDark === null ? "" : ctx.prefersDark ? "dark" : "light") : opt.appearance;
    const name = fileName(id, ctx.title, opt.style);
    const fonts = await P.embeddedFonts();
    const slideDoc = P.doc(ctx.source, ctx.assetURLs, { appearance: dark, fonts });
    const articleDoc = P.doc(ctx.source, ctx.assetURLs, { kind: C.PAGE_ARTICLE, appearance: dark, fonts });
    const tk = takahashi ? C.O_TAKAHASHI : 0;
    switch (id) {
        case "interactiveHTML":
            return { files: [[name, textBlob(await singleFile(C.page(slideDoc, C.PAGE_SLIDES, P.slideOptions(takahashi)), ctx), "text/html")]] };
        case "articleHTML":
            return { files: [[name, textBlob(await singleFile(C.page(articleDoc, C.PAGE_ARTICLE, C.O_TOC), ctx), "text/html")]] };
        case "epub":
            return { files: [[name, await epub(ctx, P.doc(ctx.source, ctx.assetURLs, { kind: C.PAGE_ARTICLE, fonts: "" }))]] };
        case "articleMarkdown": return { files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_ARTICLE_MD, 0), "text/markdown")]] };
        case "revisedMarkdown": return { files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_REVISED_MD, tk), "text/markdown")]] };
        case "narrationScript": return { files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_NARRATION, 0))]] };
        case "transcript": return { files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_TRANSCRIPT, 0))]] };
        case "subtitles":
            return { files: [[name, textBlob(C.textOutput(slideDoc, C.TEXT_VTT, tk), "text/vtt")],
                [name.replace(/\.vtt$/, ".srt"), textBlob(C.textOutput(slideDoc, C.TEXT_SRT, tk), "application/x-subrip")]] };
        case "promptText": return { files: [[name, textBlob(C.listener(ctx.source, C.LIST_REVISION_PROMPT))]] };
        case "presenterZIP": {
            const paths = [...C.listener(ctx.source, C.LIST_PUBLIC_ASSETS), ...C.listener(ctx.source, C.LIST_PRIVATE_ASSETS)];
            const { files, missing } = packageFiles(ctx, ctx.source, paths);
            return { files: [[name, await zipOf(files, now())]], notes: missing };
        }
        case "listenerZIP": {
            const { files, missing } = packageFiles(ctx, C.listener(ctx.source, C.LIST_LISTENER_MD), C.listener(ctx.source, C.LIST_PUBLIC_ASSETS));
            return { files: [[name, await zipOf(files, now())]], notes: missing };
        }
        case "projectZIP": return { files: [[name, await projectZip(ctx, await ctx.versions())]] };
        case "slidesPDF": case "handoutPDF": case "articlePDF": case "posterPDF": {
            await G.load();
            const letter = opt.paper === "letter" ? 1 : 0;
            const [kind, o] = {
                slidesPDF: [G.LAYOUT_SLIDES, { takahashi, appearance: dark }],
                handoutPDF: [G.LAYOUT_HANDOUT, { takahashi, a: letter }],
                articlePDF: [G.LAYOUT_ARTICLE, { appearance: "light", a: letter }],
                posterPDF: [G.LAYOUT_POSTER, { appearance: "light", a: G.POSTER_SIZES.indexOf(opt.posterSize), b: opt.posterOrientation === "landscape" ? 1 : 0 }],
            }[id];
            const html = await G.printHTML(ctx, kind, o);
            return { print: () => printPage(html), name };
        }
        case "slidesPNG": case "slidesSVG": {
            await G.load();
            const files = await (id === "slidesPNG" ? G.slidesPNG : G.slidesSVG)(ctx, { takahashi, appearance: dark }, progress);
            return { files: [[name, await zipOf(files, now())]] };
        }
        case "video": case "manimVideo":
            await G.load();
            return named(name, await V.video(ctx, { takahashi, appearance: dark }, id === "video" ? "video" : "manim", progress));
        case "narratedVideo": case "podcast":
            if (!(await Voice.installed())) return { reason: NO_VOICE };
            await G.load();
            return named(name, id === "podcast" ? await V.podcast(ctx, progress)
                : await V.video(ctx, { takahashi, appearance: dark }, "narrated", progress));
    }
    return null;
}

// --- printing ------------------------------------------------------------------------

// Prints the pages of a page HTML (pages.printHTML) from a hidden frame.
async function printPage(html) {
    const frame = h("iframe", { title: "Print", style: { position: "fixed", left: "-10000px", top: "0", width: "1280px", height: "720px", border: "0" } });
    document.body.append(frame);
    const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
    await new Promise((res) => { frame.onload = res; frame.src = url; });
    const win = frame.contentWindow;
    try { await win.document.fonts.ready; } catch { /* no fonts */ }
    await Promise.all([...win.document.images].map((im) => im.complete ? 0 : new Promise((r) => { im.onload = im.onerror = r; })));
    await new Promise((r) => setTimeout(r, 200));
    win.focus();
    win.print();
    setTimeout(() => { frame.remove(); URL.revokeObjectURL(url); }, 2000);
}

// --- the sheet --------------------------------------------------------------------------

export function exportSheet(ctx) {
    const st = {
        choice: ctx.lastChoice || "all", appearance: "system", paper: US.includes(region()) ? "letter" : "a4",
        posterSize: US.includes(region()) ? "in48x36" : "a0", posterOrientation: "portrait", showIssues: false,
    };
    const { list: diags, error: lintError } = diagnostics(ctx.source, ctx.assetURLs);
    const style = () => ctx.style();
    const issuesFor = (id) => diags.filter((d) => affects(d, id, style()) && d.severity === "warning");
    const selected = () => st.choice === "all" ? diags : diags.filter((d) => affects(d, st.choice, style()));
    const body = h("div", {});
    let d;

    function choiceRow(id, title, label, sub, count, disabled) {
        const on = st.choice === id;
        return h("button", {
            type: "button", class: "choice", role: "radio", "aria-checked": String(on), disabled: !!disabled,
            "aria-label": title, "aria-description": sub + (count ? ` Warnings: ${count}` : ""),
            onclick: () => { st.choice = id; render(); body.querySelector(`[data-id="${id}"]`)?.focus(); }, "data-id": id,
        }, h("span", { class: "dot", "aria-hidden": "true", text: on ? "◉" : "○" }),
            h("span", {}, h("span", { class: "name", text: title }), h("span", { class: "fmt", text: label }),
                h("span", { class: "sub", text: sub }), count ? h("span", { class: "warncount", text: `⚠ Warnings: ${count}` }) : null));
    }

    function render() {
        const scroll = d ? d.body.scrollTop : 0;
        body.replaceChildren();
        const warnCount = diags.filter((x) => x.severity === "warning").length;
        body.append(section(null,
            h("div", { role: "radiogroup", "aria-label": "Output" }, choiceRow("all", "All outputs", "ZIP", "Every format that the web version makes, in one ZIP file. The PDFs open the print dialog separately.", warnCount)),
            h("div", { class: "row" }, h("span", { class: "row-label", text: "Slide style" }),
                segmented("Slide style", [["normal", "Normal"], ["takahashi", "Takahashi"]], style(), (v) => { ctx.setStyle(v); render(); })),
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
        const checks = [];
        if (lintError) checks.push(h("div", { class: "row" }, h("span", { class: "status-warn", text: "⚠ " + lintError })));
        else if (!sel.length) checks.push(h("div", { class: "row" }, h("span", { class: "status-ok", text: "✓ Ready to export" })));
        else {
            checks.push(h("div", { class: "row" }, h("span", { class: "status-warn", text: `⚠ Source checks to review: ${sel.length}` }),
                h("button", { type: "button", class: "btn small", "aria-expanded": String(st.showIssues), onclick: () => { st.showIssues = !st.showIssues; render(); } }, st.showIssues ? "Hide" : "Show")));
            checks.push(footnote("Export stays available. Marklove uses a clear fallback for each issue and keeps every word."));
            if (st.showIssues) checks.push(h("div", {}, sel.map((x) => issueRow(x, ctx.source, () => { d.close(); ctx.goToSource(x, true); }))));
        }
        body.append(section("Source checks", ...checks));
        const optBox = h("details", { class: "group", open: st.optionsOpen }, h("summary", { text: "Options" }),
            selectRow("Appearance", [["system", "From the Project"], ["light", "Light"], ["dark", "Dark"]], st.appearance, (v) => { st.appearance = v; }),
            selectRow("Paper", [["a4", "A4"], ["letter", "US Letter"]], st.paper, (v) => { st.paper = v; }),
            selectRow("Poster size", Object.entries(POSTERS).map(([k, v]) => [k, v[0]]), st.posterSize, (v) => { st.posterSize = v; render(); }),
            h("div", { class: "row" }, h("span", { class: "row-label", text: "Poster orientation" }),
                POSTERS[st.posterSize][1] === POSTERS[st.posterSize][2] ? h("span", { class: "row-hint", text: "Square" }) :
                    segmented("Poster orientation", [["portrait", "Portrait"], ["landscape", "Landscape"]], st.posterOrientation, (v) => { st.posterOrientation = v; })));
        optBox.addEventListener("toggle", () => { st.optionsOpen = optBox.open; });
        body.append(section(null, optBox));
        body.append(section(null, h("div", { class: "row" }, h("button", { type: "button", class: "linkbtn", onclick: () => { d.close(); ctx.speakerReady(); } }, "Start Speaker Ready")),
            footnote("Present with the current slide, the next slide, private notes, and a timer. The audience window shows the slides only.")));
        if (st.error) body.append(section(null, h("div", { class: "row" }, h("span", { class: "status-bad", role: "alert", text: "⊗ " + st.error }))));
        if (d) d.body.scrollTop = scroll;
    }

    async function start() {
        st.error = "";
        ctx.setChoice(st.choice);
        const ids = st.choice === "all" ? FORMATS.filter((f) => !f.print).map((f) => f.id) : [st.choice];
        const weight = (id) => WEIGHTS[id] || 1;
        const progress = h("div", { class: "progress", role: "status" }, h("progress", { max: String(ids.reduce((n, id) => n + weight(id), 0)) }), h("span", { text: "Preparing…" }));
        body.replaceChildren(progress);
        d.buttons.forEach((b) => { b.disabled = b.textContent === "Export"; });
        await ctx.beforeExport();
        const opt = { style: style(), appearance: st.appearance, paper: st.paper, posterSize: st.posterSize, posterOrientation: st.posterOrientation };
        const results = [];
        const files = [];
        let base = 0;
        for (const id of ids) {
            progress.lastChild.textContent = `Exporting ${byId[id].name}…`;
            progress.firstChild.value = base;
            await new Promise((r) => setTimeout(r, 0));
            try {
                const r = await build(id, ctx, opt, (p) => { progress.firstChild.value = base + p * weight(id); });
                if (r.reason) results.push({ id, ok: false, reason: r.reason, notes: [] });
                else if (r.print) {
                    await r.print();
                    results.push({ id, ok: true, notes: ["The print dialog opened. Select Save as PDF. Suggested name: " + r.name] });
                } else {
                    files.push(...r.files);
                    results.push({ id, ok: true, files: r.files, notes: r.notes || [] });
                }
            } catch (e) {
                const msg = e instanceof C.TooLarge ? e.message : "Marklove could not make the file. " + (e.message || e);
                results.push({ id, ok: false, reason: msg, notes: [] });
            }
            base += weight(id);
        }
        Voice.forget();
        let deliver = files;
        if (st.choice === "all") {
            progress.lastChild.textContent = "Making the ZIP file…";
            const lines = [`Marklove exports for "${ctx.title}"`, ""];
            for (const r of results) lines.push(`${byId[r.id].name}: ${r.ok ? "created" : "not created. " + r.reason}`, ...r.notes.map((n) => "  " + n));
            for (const f of FORMATS.filter((f) => f.print)) lines.push(`${f.name}: not in this ZIP. Select it in Export to print it as PDF.`);
            try {
                const zip = await zipOf([...files, ["README.txt", lines.join("\n") + "\n"]], now());
                deliver = [[`${S.safeFileName(ctx.title)} – Marklove exports.zip`, zip]];
            } catch (e) { st.error = "Export did not complete. " + e.message; }
        }
        for (const [n, b] of deliver) download(b, n);
        showResults(results, deliver);
    }

    function showResults(results, deliver) {
        body.replaceChildren();
        d.buttons.forEach((b) => { if (b.textContent === "Export") b.hidden = true; if (b.textContent === "Cancel") b.textContent = "Done"; b.disabled = false; });
        body.append(section(null, h("div", { class: "group" },
            deliver.length ? h("p", { text: "The browser saves the files in its downloads folder. Select a file to save it again." }) : null,
            deliver.map(([n, b]) => h("div", {}, h("button", { type: "button", class: "linkbtn", onclick: () => download(b, n) }, "⇩ " + n))))));
        body.append(section("Results", h("div", {}, results.map((r) => h("div", { class: "issue" },
            r.ok ? h("div", { class: "status-ok", text: "✓ " + byId[r.id].name }) : h("div", { class: "status-bad", text: `${byId[r.id].name}: not created` }),
            r.reason ? h("p", { class: "footnote", text: r.reason }) : null,
            r.notes.map((n) => h("p", { class: "footnote", text: n })))))));
        if (st.error) body.append(h("p", { class: "status-bad", role: "alert", text: st.error }));
        announce("Export complete.");
    }

    d = dialog({
        title: "Export", body, wide: false,
        buttons: [{ label: "Cancel", cancel: true }, { label: "Export", primary: true, action: () => { start(); return false; } }],
    });
    render();
    body.querySelector('[aria-checked="true"]')?.focus();
}
