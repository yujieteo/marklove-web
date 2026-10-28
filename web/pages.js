// Laid-out pages (PageRenderer): the core lays out the slides, the article,
// the handout and the poster, and draws each page as SVG (core/pagesvg.goose).
// This file measures the text for the core, draws the SVG into a canvas, and
// makes the PNG, SVG and PDF exports from the pages.

import * as C from "./core.js";
import * as P from "./preview.js";

export const LAYOUT_SLIDES = 0, LAYOUT_VIDEO = 1, LAYOUT_ARTICLE = 2, LAYOUT_HANDOUT = 3, LAYOUT_POSTER = 4;
export const LY_ALL = 0, LY_BASE = 1, LY_NEW = 2, LY_LEAVE = 3, LY_GROW = 4, LY_BG = 5;
export const POSTER_SIZES = ["a0", "a1", "in48x36", "in42x42"];

const decoder = new TextDecoder();
let core = null;

// --- measurement --------------------------------------------------------------------

const canvas2d = document.createElement("canvas").getContext("2d");

// The advance of the text at 100 px (font is a CSS font with "100px").
function measure(text, font) {
    canvas2d.font = font;
    return canvas2d.measureText(text).width;
}

// Equation metrics at a font size of 1: which 0 width, 1 ascent, 2 descent,
// 3 the distance from the top of the box to the baseline. The box has the
// style of math_div in core/pagesvg.goose.
const mathCache = new Map();
let mathHost = null;
function mathMetric(latex, display, which) {
    const key = display + "\n" + latex;
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
        box.innerHTML = C.math(latex, display === 1);
        const base = document.createElement("span");
        base.style.cssText = "display:inline-block;width:0;height:0";
        box.append(base);
        mathHost.append(box);
        // Block math puts the baseline mark on a new line: measure it inline.
        // In the page, the box of block math starts at the top of the math.
        const el = box.querySelector("math") || box.firstElementChild;
        if (el && display === 1) el.style.display = "inline math";
        const b = box.getBoundingClientRect(), r = el ? el.getBoundingClientRect() : b;
        const y = base.getBoundingClientRect().bottom;
        m = el ? [r.width / 100, (y - r.top) / 100, (r.bottom - y) / 100, (y - (display === 1 ? r.top : b.top)) / 100] : [-1, -1, -1, -1];
        box.remove();
        mathCache.set(key, m);
    }
    return m[which];
}

// The fonts of the pages must be ready before the core measures text.
async function loadFonts() {
    const st = document.createElement("style");
    st.textContent = P.faceCSS(P.fontURL, P.PAGE_FACES);
    document.head.append(st);
    await Promise.all(P.PAGE_FACES.map(([family, , style, weight]) =>
        Promise.all(weight.split(" ").map((w) => document.fonts.load(`${style} ${w} 16px "${family}"`).catch(() => null)))));
}

export async function load() {
    if (core) return;
    await loadFonts();
    core = await C.instance({ mlMeasure: measure, mlMath: mathMetric });
}

const text = (name, inputs, ...ints) => decoder.decode(core(name, inputs, ...ints));

// --- media ----------------------------------------------------------------------------

const isVideo = (path) => /\.(mp4|m4v|mov|webm)$/i.test(path);

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

const toDataURL = (blob) => new Promise((res) => { const r = new FileReader(); r.onload = () => res(r.result); r.readAsDataURL(blob); });

// The sizes of the images and videos (argument 6), and the data: URLs that
// the SVG pages use: an image as it is, a video as its first frame.
export async function media(ctx) {
    const paths = Object.keys(ctx.assetURLs);
    const sizes = [], urls = [];
    for (const path of paths) {
        const blob = ctx.assets[path];
        let url = "";
        if (!blob) { urls.push(url); continue; }
        try {
            if (isVideo(path)) {
                const v = await videoElement(blob);
                if (v) {
                    const c = document.createElement("canvas");
                    c.width = v.videoWidth; c.height = v.videoHeight;
                    c.getContext("2d").drawImage(v, 0, 0);
                    url = c.toDataURL("image/jpeg", 0.9);
                    sizes.push(`${path}\t${v.videoWidth}\t${v.videoHeight}\n`);
                    URL.revokeObjectURL(v.src);
                }
            } else {
                const bm = await createImageBitmap(blob);
                sizes.push(`${path}\t${bm.width}\t${bm.height}\n`);
                bm.close();
                url = await toDataURL(blob);
            }
        } catch { url = ""; }
        urls.push(url);
    }
    return { sizes: sizes.join(""), urls };
}

// --- layout and drawing ----------------------------------------------------------------

// Lays out the document. The core keeps the pages for pageSVG and the
// exports below. durations: "sentence\tseconds" lines for the video.
export function layout(ctx, m, kind, { takahashi = false, appearance = "", a = 0, b = 0, durations = "" } = {}) {
    const args = C.docArgs({ source: ctx.source, assets: ctx.assetURLs, appearance });
    const opts = (takahashi ? C.O_TAKAHASHI : 0) | C.O_NARRATION | C.O_PUBLIC_NOTES;
    return JSON.parse(text("ml_layout", [...args, m.sizes, durations], kind, opts, a, b));
}

// The narration cues of the podcast, with the real sentence lengths.
export function podcast(ctx, durations) {
    const args = C.docArgs({ source: ctx.source, assets: ctx.assetURLs });
    return JSON.parse(text("ml_podcast", [...args, "", durations], C.O_NARRATION));
}

export const pageSVG = (page, step, layer = LY_ALL, progress = 1, scale = 1) =>
    text("ml_page_svg", [], page, step, layer, progress, scale);

// Puts the fonts and the media into an SVG page, so that it draws alone.
export function resolve(svg, m, fonts) {
    return svg.replace("/*ml-fonts*/", fonts)
        .replace(/href="(asset|poster):(-?\d+)"/g, (_, kind, i) => `href="${m.urls[+i] || ""}"`);
}

// Draws an SVG page into a new canvas of w × h pixels.
export async function raster(svg, w, h) {
    const img = new Image();
    img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
    await img.decode();
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    c.getContext("2d").drawImage(img, 0, 0, w, h);
    return c;
}

const toBlob = (c, type) => new Promise((res) => c.toBlob(res, type));

// --- exports ---------------------------------------------------------------------------

// "Slide 01.png": at least two digits (SlideImageExporter).
const slideName = (i, n, ext) => `Slide ${String(i + 1).padStart(Math.max(2, String(n).length), "0")}.${ext}`;

function descriptions(pages, ext) {
    return pages.map((p, i) => slideName(i, pages.length, ext).replace(/\.\w+$/, "") + "\n" + p.text).join("\n\n") + "\n";
}

// One PNG image for each slide, 1920 pixels wide, with Descriptions.txt.
export async function slidesPNG(ctx, opt, progress) {
    const m = await media(ctx);
    const fonts = await P.embeddedFonts(P.PAGE_FACES);
    const { pages } = layout(ctx, m, LAYOUT_SLIDES, opt);
    const files = [];
    for (let i = 0; i < pages.length; i++) {
        progress?.(i / pages.length);
        const s = 1920 / pages[i].width;
        const w = 1920, hgt = Math.round(pages[i].height * s);
        files.push([slideName(i, pages.length, "png"), await toBlob(await raster(resolve(pageSVG(i, -1, LY_ALL, 1, s), m, fonts), w, hgt), "image/png")]);
    }
    files.push(["Descriptions.txt", descriptions(pages, "png")]);
    return files;
}

// One SVG file for each slide. The text, photos, equations and plots are
// drawn alone and traced into vector shapes (SlideImageExporter.svg).
export async function slidesSVG(ctx, opt, progress) {
    const m = await media(ctx);
    const fonts = await P.embeddedFonts(P.PAGE_FACES);
    const { pages } = layout(ctx, m, LAYOUT_SLIDES, opt);
    const files = [];
    for (let i = 0; i < pages.length; i++) {
        progress?.(i / pages.length);
        let svg = text("ml_export_svg", [], i);
        const regions = JSON.parse(text("ml_regions", []));
        const traced = [];
        for (let k = 0; k < regions.length; k++) {
            const r = regions[k];
            const c = await raster(resolve(text("ml_region_svg", [], k), m, fonts), r.width, r.height);
            const px = c.getContext("2d").getImageData(0, 0, r.width, r.height).data;
            traced.push(text("ml_trace_arg", [new Uint8Array(px.buffer), r.label], r.width, r.height, r.colors, r.minArea, r.tolerance, r.x, r.y, r.scale));
        }
        svg = svg.replace(/<!--ml-region (\d+)-->\n/g, (_, k) => traced[+k] || "");
        files.push([slideName(i, pages.length, "svg"), new Blob([svg], { type: "image/svg+xml" })]);
    }
    files.push(["Descriptions.txt", descriptions(pages, "svg")]);
    return files;
}

// The pages of a PDF as one HTML page for the print dialog: each page is an
// SVG image at its own paper size.
export async function printHTML(ctx, kind, opt) {
    const m = await media(ctx);
    const urls = m.urls.slice();
    Object.values(ctx.assetURLs).forEach((u, i) => { if (!isVideo(Object.keys(ctx.assetURLs)[i])) urls[i] = u; });
    const { pages } = layout(ctx, m, kind, opt);
    const w = pages[0]?.width || 960, hgt = pages[0]?.height || 540;
    const body = pages.map((p, i) => resolve(pageSVG(i, -1), { urls }, "")
        .replace(/^<svg /, `<svg class="page" `)).join("");
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${ctx.title.replace(/[<&]/g, "")}</title>
<style>${P.faceCSS(P.fontURL, P.PAGE_FACES)}@page{size:${w}pt ${hgt}pt;margin:0}html,body{margin:0;padding:0}
svg.page{display:block;width:${w}pt;height:${hgt}pt;break-after:page;page-break-after:always}
svg.page:last-child{break-after:auto;page-break-after:auto}</style></head><body>${body}</body></html>`;
}

// The captions of the video (WebVTT), with the real sentence lengths.
export function captions(ctx, m, { takahashi = false, durations = "" } = {}) {
    const args = C.docArgs({ source: ctx.source, assets: ctx.assetURLs });
    return text("ml_text", [...args, m.sizes, durations], C.TEXT_VTT, takahashi ? C.O_TAKAHASHI : 0);
}

// The start of an MP4 file (core/video.goose). The samples follow it.
export const mp4Head = (inputs, ...ints) => core("ml_mp4", inputs, ...ints);
