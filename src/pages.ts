import * as C from "./core.ts";
import * as P from "./preview.ts";
import { isRecord, must } from "./dom.ts";

export const LAYOUT_SLIDES = 0, LAYOUT_VIDEO = 1, LAYOUT_ARTICLE = 2, LAYOUT_HANDOUT = 3, LAYOUT_POSTER = 4;
export const LY_ALL = 0, LY_BASE = 1, LY_NEW = 2, LY_LEAVE = 3, LY_GROW = 4;
export const POSTER_SIZES = ["a0", "a1", "in48x36", "in42x42"];

const decoder = new TextDecoder();

let core: C.CoreCall | null = null;

export interface PageCtx {
    source: string;
    assets: Record<string, Blob>;
    assetURLs: Record<string, string>;
    title: string;
}

export interface Media {
    sizes: string;
    urls: string[];
}

export interface PageInfo {
    width: number;
    height: number;
    steps: number;
    title: string;
    text: string;
}

interface Segment {
    page: number;
    step: number;
    start: number;
    duration: number;
}

interface Cue {
    start: number;
    end: number;
    text: string;
}

export interface Timeline {
    voice: string;
    segments: Segment[];
    cues: Cue[];
}

export interface Layout {
    pages: PageInfo[];
    warnings: string[];
    timeline: Timeline | null;
}

export interface LayoutOptions {
    takahashi?: boolean;
    appearance?: string;
    a?: number;
    b?: number;
    durations?: string;
}

export interface ExportFiles {
    files: [string, Blob | string][];
    notes: string[];
}

function record(v: unknown, what: string): Record<string, unknown> {
    if (!isRecord(v)) throw new Error("Bad " + what);
    return v;
}

function num(o: Record<string, unknown>, k: string): number {
    const v = o[k];
    if (typeof v !== "number") throw new Error("Bad number " + k);
    return v;
}

function str(o: Record<string, unknown>, k: string): string {
    const v = o[k];
    if (typeof v !== "string") throw new Error("Bad string " + k);
    return v;
}

function list(o: Record<string, unknown>, k: string): unknown[] {
    const v = o[k];
    if (!Array.isArray(v)) throw new Error("Bad list " + k);
    return v;
}

function parseTimeline(v: unknown): Timeline {
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
        }),
    };
}

function parseLayout(v: unknown): Layout {
    const o = record(v, "layout");
    return {
        pages: list(o, "pages").map((p) => {
            const r = record(p, "page");
            return { width: num(r, "width"), height: num(r, "height"), steps: num(r, "steps"), title: str(r, "title"), text: str(r, "text") };
        }),
        warnings: str(o, "warnings").split("\n").filter(Boolean),
        timeline: o["timeline"] === undefined ? null : parseTimeline(o["timeline"]),
    };
}

interface Region {
    x: number;
    y: number;
    scale: number;
    width: number;
    height: number;
    colors: number;
    minArea: number;
    tolerance: number;
    label: string;
}

function parseRegions(v: unknown): Region[] {
    if (!Array.isArray(v)) throw new Error("Bad regions");
    return v.map((x) => {
        const r = record(x, "region");
        return {
            x: num(r, "x"), y: num(r, "y"), scale: num(r, "scale"), width: num(r, "width"), height: num(r, "height"),
            colors: num(r, "colors"), minArea: num(r, "minArea"), tolerance: num(r, "tolerance"), label: str(r, "label"),
        };
    });
}

let canvas2d: CanvasRenderingContext2D | null = null;

function measure(text: string, font: string): number {
    canvas2d ??= must(document.createElement("canvas").getContext("2d"), "2D canvas");
    canvas2d.font = font;
    return canvas2d.measureText(text).width;
}

type MathMetrics = [number, number, number, number];

const mathCache = new Map<string, MathMetrics>();
let mathHost: HTMLElement | null = null;

function styleOf(el: Element): CSSStyleDeclaration | null {
    return "style" in el && el.style instanceof CSSStyleDeclaration ? el.style : null;
}

function mathMetric(latex: string, display: number, which: number): number {
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
        const el = box.querySelector("math") || box.firstElementChild;
        const elStyle = el ? styleOf(el) : null;
        if (elStyle && display === 1) elStyle.display = "inline math";
        const b = box.getBoundingClientRect(), r = el ? el.getBoundingClientRect() : b;
        const y = base.getBoundingClientRect().bottom;
        m = el ? [r.width / 100, (y - r.top) / 100, (r.bottom - y) / 100, (y - (display === 1 ? r.top : b.top)) / 100] : [-1, -1, -1, -1];
        box.remove();
        mathCache.set(key, m);
    }
    return m[which] ?? -1;
}

async function loadFonts(): Promise<void> {
    const st = document.createElement("style");
    st.textContent = P.faceCSS(P.fontURL, P.PAGE_FACES);
    document.head.append(st);
    await Promise.all(P.PAGE_FACES.map(([family, , style, weight]) =>
        Promise.all(weight.split(" ").map((w) => document.fonts.load(`${style} ${w} 16px "${family}"`).catch(() => null)))));
}

export async function load(): Promise<void> {
    if (core) return;
    await loadFonts();
    core = await C.instance({ mlMeasure: measure, mlMath: mathMetric });
}

const callCore = (name: C.MlName, inputs: C.Input[], ...ints: number[]): Uint8Array =>
    must(core, "page core")(name, inputs, ...ints);

const text = (name: C.MlName, inputs: C.Input[], ...ints: number[]): string => decoder.decode(callCore(name, inputs, ...ints));

const isVideo = (path: string): boolean => /\.(mp4|m4v|mov|webm)$/i.test(path);

function videoElement(blob: Blob): Promise<HTMLVideoElement | null> {
    const v = document.createElement("video");
    v.muted = true;
    v.preload = "auto";
    v.src = URL.createObjectURL(blob);
    return new Promise((res) => {
        v.onloadeddata = () => res(v);
        v.onerror = () => res(null);
    });
}

export async function media(ctx: PageCtx): Promise<Media> {
    const paths = Object.keys(ctx.assetURLs);
    const sizes: string[] = [], urls: string[] = [];
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
                    must(c.getContext("2d"), "2D canvas").drawImage(v, 0, 0);
                    url = c.toDataURL("image/jpeg", 0.9);
                    sizes.push(`${path}\t${v.videoWidth}\t${v.videoHeight}\n`);
                    URL.revokeObjectURL(v.src);
                }
            } else {
                const bm = await createImageBitmap(blob);
                sizes.push(`${path}\t${bm.width}\t${bm.height}\n`);
                bm.close();
                url = await P.readDataURL(blob);
            }
        } catch { url = ""; }
        urls.push(url);
    }
    return { sizes: sizes.join(""), urls };
}

export function layout(ctx: PageCtx, m: Media, kind: number, { takahashi = false, appearance = "", a = 0, b = 0, durations = "" }: LayoutOptions = {}): Layout {
    const args = C.docArgs({ source: ctx.source, assets: ctx.assetURLs, appearance });
    const opts = (takahashi ? C.O_TAKAHASHI : 0) | C.O_NARRATION | C.O_PUBLIC_NOTES;
    return parseLayout(JSON.parse(text("ml_layout", [...args, m.sizes, durations], kind, opts, a, b)));
}

export function podcast(ctx: PageCtx, durations: string): Timeline {
    const args = C.docArgs({ source: ctx.source, assets: ctx.assetURLs });
    return parseTimeline(JSON.parse(text("ml_podcast", [...args, "", durations], C.O_NARRATION)));
}

export const pageSVG = (page: number, step: number, layer = LY_ALL, progress = 1, scale = 1): string =>
    text("ml_page_svg", [], page, step, layer, progress, scale);

export function resolve(svg: string, m: { urls: string[] }, fonts: string): string {
    return svg.replace("/*ml-fonts*/", fonts)
        .replace(/href="(asset|poster):(-?\d+)"/g, (_, _kind: string, i: string) => `href="${m.urls[+i] || ""}"`);
}

export async function raster(svg: string, w: number, h: number): Promise<HTMLCanvasElement> {
    const img = new Image();
    img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
    await img.decode();
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    must(c.getContext("2d"), "2D canvas").drawImage(img, 0, 0, w, h);
    return c;
}

const toBlob = (c: HTMLCanvasElement, type: string): Promise<Blob> => new Promise((res, rej) => {
    c.toBlob((b) => { if (b) res(b); else rej(new Error("The canvas has no image.")); }, type);
});

const slideName = (i: number, n: number, ext: string): string => `Slide ${String(i + 1).padStart(Math.max(2, String(n).length), "0")}.${ext}`;

function descriptions(pages: PageInfo[], ext: string): string {
    return pages.map((p, i) => slideName(i, pages.length, ext).replace(/\.\w+$/, "") + "\n" + p.text).join("\n\n") + "\n";
}

export async function slidesPNG(ctx: PageCtx, opt: LayoutOptions, progress?: (p: number) => void): Promise<ExportFiles> {
    const m = await media(ctx);
    const fonts = await P.embeddedFonts(P.PAGE_FACES);
    const { pages, warnings } = layout(ctx, m, LAYOUT_SLIDES, opt);
    const files: ExportFiles["files"] = [];
    for (const [i, page] of pages.entries()) {
        progress?.(i / pages.length);
        const s = 1920 / page.width;
        const w = 1920, hgt = Math.round(page.height * s);
        files.push([slideName(i, pages.length, "png"), await toBlob(await raster(resolve(pageSVG(i, -1, LY_ALL, 1, s), m, fonts), w, hgt), "image/png")]);
    }
    files.push(["Descriptions.txt", descriptions(pages, "png")]);
    return { files, notes: warnings };
}

export async function slidesSVG(ctx: PageCtx, opt: LayoutOptions, progress?: (p: number) => void): Promise<ExportFiles> {
    const m = await media(ctx);
    const fonts = await P.embeddedFonts(P.PAGE_FACES);
    const { pages, warnings } = layout(ctx, m, LAYOUT_SLIDES, opt);
    const files: ExportFiles["files"] = [];
    for (let i = 0; i < pages.length; i++) {
        progress?.(i / pages.length);
        let svg = text("ml_export_svg", [], i);
        const regions = parseRegions(JSON.parse(text("ml_regions", [])));
        const traced: string[] = [];
        for (const [k, r] of regions.entries()) {
            const c = await raster(resolve(text("ml_region_svg", [], k), m, fonts), r.width, r.height);
            const px = must(c.getContext("2d"), "2D canvas").getImageData(0, 0, r.width, r.height).data;
            traced.push(text("ml_trace_arg", [new Uint8Array(px.buffer), r.label], r.width, r.height, r.colors, r.minArea, r.tolerance, r.x, r.y, r.scale));
        }
        svg = svg.replace(/<!--ml-region (\d+)-->\n/g, (_, k: string) => traced[+k] || "");
        files.push([slideName(i, pages.length, "svg"), new Blob([svg], { type: "image/svg+xml" })]);
    }
    files.push(["Descriptions.txt", descriptions(pages, "svg")]);
    return { files, notes: warnings };
}

export async function printHTML(ctx: PageCtx, kind: number, opt: LayoutOptions): Promise<{ html: string; notes: string[] }> {
    const m = await media(ctx);
    const urls = m.urls.slice();
    Object.entries(ctx.assetURLs).forEach(([path, u], i) => { if (!isVideo(path)) urls[i] = u; });
    const { pages, warnings } = layout(ctx, m, kind, opt);
    const w = pages[0]?.width || 960, hgt = pages[0]?.height || 540;
    const body = pages.map((_, i) => resolve(pageSVG(i, -1), { urls }, "")
        .replace(/^<svg /, `<svg class="page" `)).join("");
    const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${ctx.title.replace(/[<&]/g, "")}</title>
<style>${P.faceCSS(P.fontURL, P.PAGE_FACES)}@page{size:${w}pt ${hgt}pt;margin:0}html,body{margin:0;padding:0}
svg.page{display:block;width:${w}pt;height:${hgt}pt;break-after:page;page-break-after:always}
svg.page:last-child{break-after:auto;page-break-after:auto}</style></head><body>${body}</body></html>`;
    return { html, notes: warnings };
}

export function captions(ctx: PageCtx, m: Media, { takahashi = false, durations = "", srt = false }: { takahashi?: boolean; durations?: string; srt?: boolean } = {}): string {
    const args = C.docArgs({ source: ctx.source, assets: ctx.assetURLs });
    return text("ml_text", [...args, m.sizes, durations], srt ? C.TEXT_SRT : C.TEXT_VTT, takahashi ? C.O_TAKAHASHI : 0);
}

export const mp4Head = (inputs: Uint8Array[], ...ints: number[]): Uint8Array => callCore("ml_mp4", inputs, ...ints);
