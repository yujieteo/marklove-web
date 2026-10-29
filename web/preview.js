// Pages from the core: Preview, Present, Speaker Ready and the listener
// preview (PreviewScreen, SpeakerReadyView, ListenerPreviewView).

import * as C from "./core.js";
import { h, dialog, segmented, announce } from "./ui.js";

export const parts = { style: "", runtime: "", articleStyle: "", articleScript: "", fonts: "" };

const FACES = [
    ["Courier Prime", "CourierPrime-Regular.woff2", "normal", "400"],
    ["Courier Prime", "CourierPrime-Bold.woff2", "normal", "700"],
    ["Courier Prime", "CourierPrime-Italic.woff2", "italic", "400"],
    ["Courier Prime", "CourierPrime-BoldItalic.woff2", "italic", "700"],
    ["KpMath", "KpMath-Light.otf", "normal", "400"],
    ["Courier Prime Sans", "CourierPrimeSans-Regular.woff2", "normal", "400"],
    ["Courier Prime Sans", "CourierPrimeSans-Bold.woff2", "normal", "700"],
];

// The laid-out pages (web/pages.js) also use Libre Baskerville for the slides.
export const PAGE_FACES = [
    ["Libre Baskerville", "LibreBaskerville-Variable.ttf", "normal", "400 700"],
    ["Libre Baskerville", "LibreBaskerville-Italic-Variable.ttf", "italic", "400 700"],
    ...FACES,
];

export function faceCSS(url, faces = FACES) {
    return faces.map(([family, file, style, weight]) => {
        const format = file.endsWith(".woff2") ? "woff2" : file.endsWith(".ttf") ? "truetype" : "opentype";
        return `@font-face{font-family:"${family}";src:url(${url(file)}) format("${format}");font-style:${style};font-weight:${weight};font-display:swap}\n`;
    }).join("");
}

export const fontURL = (f) => new URL("fonts/" + f, location.href).href;

export async function loadParts() {
    const get = (p) => fetch(p).then((r) => { if (!r.ok) throw new Error(p); return r.text(); });
    [parts.style, parts.runtime, parts.articleStyle, parts.articleScript] =
        await Promise.all([get("style.css"), get("runtime.js"), get("article.css"), get("article.js")]);
    // The preview loads the fonts from the app folder: a short style sheet.
    parts.fonts = faceCSS(fontURL);
}

// The fonts as data: URLs, so that an exported file works offline (HTMLExporter.fontFaces).
const embedded = new Map();
export async function embeddedFonts(faces = FACES) {
    if (embedded.has(faces)) return embedded.get(faces);
    const urls = {};
    for (const [, file] of faces) {
        const blob = await (await fetch("fonts/" + file)).blob();
        const mime = file.endsWith(".woff2") ? "font/woff2" : file.endsWith(".ttf") ? "font/ttf" : "font/otf";
        const b64 = await new Promise((res) => { const r = new FileReader(); r.onload = () => res(r.result.split(",")[1]); r.readAsDataURL(blob); });
        urls[file] = `data:${mime};base64,${b64}`;
    }
    embedded.set(faces, faceCSS((f) => urls[f], faces));
    return embedded.get(faces);
}

// A document for the core.
export function doc(source, assets, { kind = C.PAGE_SLIDES, appearance = "", fonts = parts.fonts } = {}) {
    const article = kind === C.PAGE_ARTICLE;
    return { source, assets, fonts, style: article ? parts.articleStyle : parts.style, script: article ? parts.articleScript : parts.runtime, appearance };
}

export function slideOptions(takahashi) { return (takahashi ? C.O_TAKAHASHI : 0) | C.O_NARRATION | C.O_PUBLIC_NOTES; }

// --- a page in a frame ------------------------------------------------------------

// Shows HTML in a frame from a blob: URL, so that the runtime can use the
// address (#slide). The frame changes only when the new page has loaded.
export class PageFrame {
    constructor(host, title, { chrome = true } = {}) {
        this.host = host;
        this.title = title;
        this.chrome = chrome;
        this.frame = null;
        this.url = null;
        this.html = "";
        this.onload = null;
        this.onkey = null;
    }

    show(html, hash = "", keepScroll = false) {
        this.html = html;
        const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
        const f = document.createElement("iframe");
        f.title = this.title;
        const old = this.frame, oldURL = this.url;
        let scroll = 0;
        if (keepScroll && old) { try { scroll = old.contentWindow.scrollY; } catch { scroll = 0; } }
        if (old) { f.style.position = "absolute"; f.style.visibility = "hidden"; f.style.inset = "0"; }
        f.addEventListener("load", () => {
            try {
                const d = f.contentDocument;
                if (!this.chrome) {
                    const st = d.createElement("style");
                    st.textContent = ".bar{display:none!important}.deck{padding:8px!important}.skip{display:none}";
                    d.head.append(st);
                }
                if (scroll) f.contentWindow.scrollTo(0, scroll);
                d.addEventListener("keydown", (e) => this.onkey && this.onkey(e));
            } catch { /* not the same origin */ }
            if (old) { old.remove(); f.style.position = ""; f.style.visibility = ""; f.style.inset = ""; }
            if (oldURL) URL.revokeObjectURL(oldURL);
            this.onload && this.onload(f);
        }, { once: true });
        f.src = url + (hash ? "#" + hash : "");
        this.host.append(f);
        this.frame = f;
        this.url = url;
    }

    // The id of the slide that the runtime shows.
    currentId() {
        try { return decodeURIComponent(this.frame.contentWindow.location.hash.slice(1)); } catch { return ""; }
    }

    key(name, times = 1) {
        try {
            const d = this.frame.contentDocument;
            for (let i = 0; i < times; i++) d.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true }));
        } catch { /* not loaded */ }
    }

    clear() {
        if (this.frame) this.frame.remove();
        if (this.url) URL.revokeObjectURL(this.url);
        this.frame = null;
        this.url = null;
    }
}

// The slide that contains a UTF-16 offset of the source.
export function slideAt(outline, offset) {
    let best = outline[0];
    for (const s of outline) {
        if (s.s0 <= offset && offset < s.s1) return s;
        if (s.s0 <= offset) best = s;
    }
    return best;
}

// --- Speaker Ready -----------------------------------------------------------------

export function speakerReady({ source, assets, takahashi, appearance, startOffset }) {
    const d = doc(source, assets, { appearance });
    const opts = slideOptions(takahashi);
    let html, outline;
    try { html = C.page(d, C.PAGE_SLIDES, opts); outline = C.outline(d, opts); }
    catch (e) { return { error: e.message }; }
    if (!outline.length) return { error: "No Slides. Add a slide title with ## to make a slide." };
    let index = Math.max(0, outline.indexOf(slideAt(outline, startOffset ?? 0)));
    if (startOffset === null || startOffset === undefined) index = 0;
    let step = 0;

    const curHost = h("div", { style: { position: "relative" } });
    const nextHost = h("div", { style: { position: "relative" } });
    const cur = new PageFrame(curHost, "Current slide", { chrome: false });
    const nxt = new PageFrame(nextHost, "Next slide", { chrome: false });
    const counter = h("span", { class: "counter", role: "status" });
    const nextLabel = h("p", { class: "cap-label", text: "Next" });
    const last = h("p", { class: "footnote", text: "This is the last slide.", hidden: true });
    const notes = h("div", { class: "notes", tabindex: "0", "aria-label": "Private notes" });
    const time = h("span", { class: "time", role: "timer" }, "0:00:00");
    let audience = null;
    let started = 0, elapsed = 0, timer = 0;

    const fmt = (s) => `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
    const tick = () => {
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

    function update() {
        const s = outline[index];
        counter.textContent = `Slide ${index + 1} of ${outline.length}` + (s.steps > 1 ? `, step ${step + 1} of ${s.steps}` : "");
        notes.textContent = s.notes || "No notes for this slide.";
        const n = outline[index + 1];
        nextLabel.hidden = nextHost.hidden = !n;
        last.hidden = !!n;
        if (n) nxt.show(html, n.id);
    }
    nxt.onload = () => { const n = outline[index + 1]; if (n && n.steps > 1) nxt.key("ArrowRight", n.steps - 1); };
    cur.onload = () => { cur.key("ArrowRight", step); };

    // Moves one step. The runtime in each frame moves with the same key,
    // except in the frame where the key came from.
    function go(delta, toCur = true, toAudience = true) {
        const s = outline[index];
        let moved = false;
        if (delta > 0) {
            if (step < s.steps - 1) { step++; moved = true; }
            else if (index < outline.length - 1) { index++; step = 0; moved = true; update(); }
        } else {
            if (step > 0) { step--; moved = true; }
            else if (index > 0) { index--; step = outline[index].steps - 1; moved = true; update(); }
        }
        if (!moved) return;
        const k = delta > 0 ? "ArrowRight" : "ArrowLeft";
        if (toCur) cur.key(k);
        if (toAudience && audience && !audience.closed) {
            try { audience.document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true })); } catch { /* closed */ }
        }
        const sl = outline[index];
        counter.textContent = `Slide ${index + 1} of ${outline.length}` + (sl.steps > 1 ? `, step ${step + 1} of ${sl.steps}` : "");
    }

    const forward = (k) => ["ArrowRight", " ", "PageDown"].includes(k), back = (k) => ["ArrowLeft", "PageUp"].includes(k);
    const keys = (e) => {
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

    function openAudience() {
        const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
        audience = window.open(url + "#" + encodeURIComponent(outline[index].id), "marklove-audience");
        if (!audience) { announce("The browser blocked the audience window. Allow pop-ups for this page."); return; }
        audience.addEventListener("load", () => {
            try {
                if (step) for (let i = 0; i < step; i++) audience.document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
                // Keys in the audience window move the speaker view too.
                audience.document.addEventListener("keydown", (e) => {
                    if (!e.isTrusted) return;
                    if (forward(e.key)) go(1, true, false);
                    else if (back(e.key)) go(-1, true, false);
                });
            } catch { /* closed */ }
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
    dlg.buttons[1].title = "Show the slides in a separate window. Move it to the projector and make it full screen.";
    dlg.dlg.addEventListener("keydown", (e) => { if (e.target.tagName !== "BUTTON" || e.key !== " ") keys(e); });
    cur.show(html, outline[index].id);
    update();
    tick();
    prevBtn.focus();
    return { dlg };
}

// --- the listener preview -----------------------------------------------------------

export function listenerPreview({ source, assets, takahashi, appearance }) {
    let md, html;
    try {
        md = C.listener(source, C.LIST_LISTENER_MD);
        html = C.page(doc(md, assets, { appearance }), C.PAGE_SLIDES, (takahashi ? C.O_TAKAHASHI : 0) | C.O_PUBLIC_NOTES);
    } catch (e) { return { error: e.message }; }
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
    host.firstChild && host.firstChild.classList.add("listener-frame");
    frame.onload = (f) => f.classList.add("listener-frame");
    return d;
}
