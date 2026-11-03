import * as C from "./core.ts";
import { h, dialog, segmented, announce } from "./ui.ts";
import { must } from "./dom.ts";

interface Parts {
    style: string;
    runtime: string;
    articleStyle: string;
    articleScript: string;
    fonts: string;
}

const parts: Parts = { style: "", runtime: "", articleStyle: "", articleScript: "", fonts: "" };

export type Face = readonly [family: string, file: string, style: string, weight: string];

const FACES: readonly Face[] = [
    ["Courier Prime", "CourierPrime-Regular.woff2", "normal", "400"],
    ["Courier Prime", "CourierPrime-Bold.woff2", "normal", "700"],
    ["Courier Prime", "CourierPrime-Italic.woff2", "italic", "400"],
    ["Courier Prime", "CourierPrime-BoldItalic.woff2", "italic", "700"],
    ["KpMath", "KpMath-Light.otf", "normal", "400"],
    ["Courier Prime Sans", "CourierPrimeSans-Regular.woff2", "normal", "400"],
    ["Courier Prime Sans", "CourierPrimeSans-Bold.woff2", "normal", "700"],
];

export const PAGE_FACES: readonly Face[] = [
    ["Libre Baskerville", "LibreBaskerville-Variable.ttf", "normal", "400 700"],
    ["Libre Baskerville", "LibreBaskerville-Italic-Variable.ttf", "italic", "400 700"],
    ...FACES,
];

export function faceCSS(url: (file: string) => string, faces: readonly Face[] = FACES): string {
    return faces.map(([family, file, style, weight]) => {
        const format = file.endsWith(".woff2") ? "woff2" : file.endsWith(".ttf") ? "truetype" : "opentype";
        return `@font-face{font-family:"${family}";src:url(${url(file)}) format("${format}");font-style:${style};font-weight:${weight};font-display:swap}\n`;
    }).join("");
}

export const fontURL = (f: string): string => new URL("fonts/" + f, location.href).href;

export function messageOf(e: unknown): string {
    return e instanceof Error ? e.message : String(e);
}

export async function loadParts(): Promise<void> {
    const get = (p: string): Promise<string> => fetch(p).then((r) => { if (!r.ok) throw new Error(p); return r.text(); });
    const [style, runtime, articleStyle, articleScript] =
        await Promise.all([get("style.css"), get("runtime.js"), get("article.css"), get("article.js")]);
    parts.style = style;
    parts.runtime = runtime;
    parts.articleStyle = articleStyle;
    parts.articleScript = articleScript;
    parts.fonts = faceCSS(fontURL);
}

export function readDataURL(blob: Blob): Promise<string> {
    return new Promise((res) => {
        const r = new FileReader();
        r.onload = () => res(typeof r.result === "string" ? r.result : "");
        r.readAsDataURL(blob);
    });
}

const embedded = new Map<readonly Face[], string>();
export async function embeddedFonts(faces: readonly Face[] = FACES): Promise<string> {
    const known = embedded.get(faces);
    if (known !== undefined) return known;
    const urls = new Map<string, string>();
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

export interface PageDoc {
    source: string;
    assets: Record<string, string>;
    fonts: string;
    style: string;
    script: string;
    appearance: string;
}

export interface DocOptions {
    kind?: number;
    appearance?: string;
    fonts?: string;
}

export function doc(source: string, assets: Record<string, string>, { kind = C.PAGE_SLIDES, appearance = "", fonts = parts.fonts }: DocOptions = {}): PageDoc {
    const article = kind === C.PAGE_ARTICLE;
    return { source, assets, fonts, style: article ? parts.articleStyle : parts.style, script: article ? parts.articleScript : parts.runtime, appearance };
}

export function slideOptions(takahashi: boolean): number {
    return (takahashi ? C.O_TAKAHASHI : 0) | C.O_NARRATION | C.O_PUBLIC_NOTES;
}

export class PageFrame {
    host: HTMLElement;
    title: string;
    chrome: boolean;
    frame: HTMLIFrameElement | null = null;
    url: string | null = null;
    html = "";
    onload: ((frame: HTMLIFrameElement) => void) | null = null;
    onkey: ((e: KeyboardEvent) => void) | null = null;

    constructor(host: HTMLElement, title: string, { chrome = true }: { chrome?: boolean } = {}) {
        this.host = host;
        this.title = title;
        this.chrome = chrome;
    }

    show(html: string, hash = "", keepScroll = false): void {
        this.html = html;
        const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
        const f = document.createElement("iframe");
        f.title = this.title;
        const old = this.frame, oldURL = this.url;
        let scroll = 0;
        if (keepScroll && old) { try { scroll = old.contentWindow?.scrollY ?? 0; } catch { scroll = 0; } }
        if (old) { f.style.position = "absolute"; f.style.visibility = "hidden"; f.style.inset = "0"; }
        f.addEventListener("load", () => {
            try {
                const d = must(f.contentDocument, "frame document");
                if (!this.chrome) {
                    const st = d.createElement("style");
                    st.textContent = ".bar{display:none!important}.deck{padding:8px!important}.skip{display:none}";
                    d.head.append(st);
                }
                if (scroll) must(f.contentWindow, "frame window").scrollTo(0, scroll);
                d.addEventListener("keydown", (e) => this.onkey?.(e));
            } catch { }
            if (old) { old.remove(); f.style.position = ""; f.style.visibility = ""; f.style.inset = ""; }
            if (oldURL) URL.revokeObjectURL(oldURL);
            this.onload?.(f);
        }, { once: true });
        f.src = url + (hash ? "#" + hash : "");
        this.host.append(f);
        this.frame = f;
        this.url = url;
    }

    currentId(): string {
        try { return decodeURIComponent(must(this.frame?.contentWindow, "frame window").location.hash.slice(1)); } catch { return ""; }
    }

    key(name: string, times = 1): void {
        try {
            const d = must(this.frame?.contentDocument, "frame document");
            for (let i = 0; i < times; i++) d.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true }));
        } catch { }
    }

    clear(): void {
        if (this.frame) this.frame.remove();
        if (this.url) URL.revokeObjectURL(this.url);
        this.frame = null;
        this.url = null;
    }
}

export function slideAt<T extends { s0: number; s1: number }>(outline: readonly T[], offset: number): T | undefined {
    let best = outline[0];
    for (const s of outline) {
        if (s.s0 <= offset && offset < s.s1) return s;
        if (s.s0 <= offset) best = s;
    }
    return best;
}

export interface SpeakerOptions {
    source: string;
    assets: Record<string, string>;
    takahashi: boolean;
    appearance: string;
    startOffset: number | null | undefined;
}

const NO_SLIDES_MESSAGE = "No Slides. Add a slide title with ## to make a slide.";

export function speakerReady({ source, assets, takahashi, appearance, startOffset }: SpeakerOptions): { error: string } | { dlg: ReturnType<typeof dialog> } {
    const d = doc(source, assets, { appearance });
    const opts = slideOptions(takahashi);
    let html: string;
    let outline: ReturnType<typeof C.outline>;
    try { html = C.page(d, C.PAGE_SLIDES, opts); outline = C.outline(d, opts); }
    catch (e) { return { error: messageOf(e) }; }
    if (!outline.length) return { error: NO_SLIDES_MESSAGE };
    const startSlide = slideAt(outline, startOffset ?? 0);
    let index = Math.max(0, startSlide ? outline.indexOf(startSlide) : -1);
    if (startOffset === null || startOffset === undefined) index = 0;
    let step = 0;
    const slideAtIndex = (i: number): (typeof outline)[number] => must(outline[i], "slide " + i);

    const curHost = h("div", { style: { position: "relative" } });
    const nextHost = h("div", { style: { position: "relative" } });
    const cur = new PageFrame(curHost, "Current slide", { chrome: false });
    const nxt = new PageFrame(nextHost, "Next slide", { chrome: false });
    const counter = h("span", { class: "counter", role: "status" });
    const nextLabel = h("p", { class: "cap-label", text: "Next" });
    const last = h("p", { class: "footnote", text: "This is the last slide.", hidden: true });
    const notes = h("div", { class: "notes", tabindex: "0", "aria-label": "Private notes" });
    const time = h("span", { class: "time", role: "timer" }, "0:00:00");
    let audience: Window | null = null;
    let started = 0, elapsed = 0;
    let timer: ReturnType<typeof setInterval> | undefined;

    const fmt = (s: number): string => `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
    const tick = (): void => {
        const s = Math.floor((elapsed + (started ? Date.now() - started : 0)) / 1000);
        time.textContent = fmt(s);
        time.setAttribute("aria-label", "Time: " + fmt(s));
    };
    const startBtn = h("button", { type: "button", class: "button primary", onclick: () => {
        if (started) { elapsed += Date.now() - started; started = 0; clearInterval(timer); startBtn.textContent = "Start"; }
        else { started = Date.now(); timer = setInterval(tick, 1000); startBtn.textContent = "Pause"; }
        tick();
    } }, "Start");
    const resetBtn = h("button", { type: "button", class: "button", onclick: () => { elapsed = 0; if (started) started = Date.now(); tick(); } }, "Reset");

    const counterText = (): string => {
        const s = slideAtIndex(index);
        return `Slide ${index + 1} of ${outline.length}` + (s.steps > 1 ? `, step ${step + 1} of ${s.steps}` : "");
    };

    function update(): void {
        const s = slideAtIndex(index);
        counter.textContent = counterText();
        notes.textContent = s.notes || "No notes for this slide.";
        const n = outline[index + 1];
        nextLabel.hidden = nextHost.hidden = !n;
        last.hidden = !!n;
        if (n) nxt.show(html, n.id);
    }
    nxt.onload = () => { const n = outline[index + 1]; if (n && n.steps > 1) nxt.key("ArrowRight", n.steps - 1); };
    cur.onload = () => { cur.key("ArrowRight", step); };

    function go(delta: number, toCur = true, toAudience = true): void {
        const s = slideAtIndex(index);
        let moved = false;
        if (delta > 0) {
            if (step < s.steps - 1) { step++; moved = true; }
            else if (index < outline.length - 1) { index++; step = 0; moved = true; update(); }
        } else {
            if (step > 0) { step--; moved = true; }
            else if (index > 0) { index--; step = slideAtIndex(index).steps - 1; moved = true; update(); }
        }
        if (!moved) return;
        const k = delta > 0 ? "ArrowRight" : "ArrowLeft";
        if (toCur) cur.key(k);
        if (toAudience && audience && !audience.closed) {
            try { audience.document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true })); } catch { }
        }
        counter.textContent = counterText();
    }

    const forward = (k: string): boolean => ["ArrowRight", " ", "PageDown"].includes(k);
    const back = (k: string): boolean => ["ArrowLeft", "PageUp"].includes(k);
    const keys = (e: KeyboardEvent): void => {
        if (forward(e.key)) { e.preventDefault(); go(1); }
        else if (back(e.key)) { e.preventDefault(); go(-1); }
    };
    cur.onkey = (e) => {
        if (!e.isTrusted) return;
        if (forward(e.key)) go(1, false, true);
        else if (back(e.key)) go(-1, false, true);
    };

    const prevBtn = h("button", { type: "button", class: "button", "aria-label": "Previous Slide", title: "Previous slide", onclick: () => go(-1) }, "◀");
    const nextBtn = h("button", { type: "button", class: "button", "aria-label": "Next Slide", title: "Next slide", onclick: () => go(1) }, "▶");
    const body = h("div", { class: "speaker" },
        h("div", { class: "col" }, curHost, h("div", { class: "ctl" }, prevBtn, counter, nextBtn)),
        h("div", { class: "col" }, h("div", { class: "timer" }, time, startBtn, resetBtn), nextLabel, nextHost, last,
            h("p", { class: "cap-label", text: "Notes" }), notes));

    function openAudience(): void {
        const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
        const win = window.open(url + "#" + encodeURIComponent(slideAtIndex(index).id), "marklove-audience");
        audience = win;
        if (!win) { announce("The browser blocked the audience window. Allow pop-ups for this page."); return; }
        win.addEventListener("load", () => {
            try {
                if (step) for (let i = 0; i < step; i++) win.document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
                win.document.addEventListener("keydown", (e) => {
                    if (!e.isTrusted) return;
                    if (forward(e.key)) go(1, true, false);
                    else if (back(e.key)) go(-1, true, false);
                });
            } catch { }
            setTimeout(() => URL.revokeObjectURL(url), 5000);
        }, { once: true });
    }

    const dlg = dialog({
        title: "Speaker Ready", body, buttons: [
            { label: "End", cancel: true },
            { label: "Open Audience Window", action: () => { openAudience(); return false; } },
        ],
        onClose: () => { clearInterval(timer); cur.clear(); nxt.clear(); if (audience && !audience.closed) audience.close(); },
    });
    dlg.dlg.classList.add("full");
    must(dlg.buttons[1], "audience button").title = "Show the slides in a separate window. Move it to the projector and make it full screen.";
    dlg.dlg.addEventListener("keydown", (e) => {
        const onButton = e.target instanceof Element && e.target.tagName === "BUTTON";
        if (!onButton || e.key !== " ") keys(e);
    });
    cur.show(html, slideAtIndex(index).id);
    update();
    tick();
    prevBtn.focus();
    return { dlg };
}

export interface ListenerOptions {
    source: string;
    assets: Record<string, string>;
    takahashi: boolean;
    appearance: string;
}

export function listenerPreview({ source, assets, takahashi, appearance }: ListenerOptions): { error: string } | ReturnType<typeof dialog> {
    let md: string;
    let html: string;
    try {
        const listened = C.listener(source, C.LIST_LISTENER_MD);
        if (typeof listened !== "string") throw new Error("The listener output is not text.");
        md = listened;
        html = C.page(doc(md, assets, { appearance }), C.PAGE_SLIDES, (takahashi ? C.O_TAKAHASHI : 0) | C.O_PUBLIC_NOTES);
    } catch (e) { return { error: messageOf(e) }; }
    const host = h("div", { style: { position: "relative", flex: "1", display: "flex" } });
    const frame = new PageFrame(host, "Listener slides");
    const text = h("pre", { class: "code", hidden: true, tabindex: "0", "aria-label": "Listener Markdown", text: md });
    const pick = segmented("Show", [["slides", "Slides"], ["text", "Text"]], "slides", (v) => {
        host.hidden = v !== "slides";
        host.style.display = v === "slides" ? "flex" : "none";
        text.hidden = v !== "text";
    });
    const body = h("div", { style: { display: "flex", flexDirection: "column", gap: "10px", flex: "1" } },
        h("div", { class: "banner", style: { borderRadius: "8px" } }, h("span", { "aria-hidden": "true" }, "👥"),
            h("span", { class: "msg", text: "This is what a listener sees. Private notes are not in the Listener package. Select Reading view in the page to see the notes for listeners." })),
        pick, host, text);
    const d = dialog({ title: "Listener Preview", body, wide: true, onClose: () => frame.clear() });
    d.dlg.classList.add("full");
    frame.show(html);
    if (host.firstElementChild) host.firstElementChild.classList.add("listener-frame");
    frame.onload = (f) => f.classList.add("listener-frame");
    return d;
}
