import { test, expect } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as C from "../src/core.ts";
import { blobOf, failure, get, list, num, parse, str } from "./support.ts";

await C.load();

const src = `---
title: Waves
author: A. Writer
---

# Sound

Speed is $v = f\\lambda$.

. . .

More text é.

![A cat](images/cat.png)

::: notes
Say hello.
:::
`;
const doc: C.Doc = { source: src, assets: { "images/cat.png": "blob:cat" } };
const T = 1700000000;
const LOCAL_FILE_HEADER = 0x04034B50;
const CENTRAL_DIRECTORY_HEADER = 0x02014B50;
const LOCAL_SIZE_FIELD = 22;
const CENTRAL_SIZE_FIELD = 24;
const SYNTAXES = ["sam", "plain", "vim"] as const;

function matchesOf(r: C.FindResult): C.Span[] {
    if ("matches" in r) return r.matches;
    throw new Error(r.error);
}

function textOf(r: C.ReplaceResult | C.SamResult): string | null {
    if ("error" in r) throw new Error(r.error);
    return "text" in r ? r.text : null;
}

function imported(r: C.PackResult): Extract<C.PackResult, { markdown: string }> {
    if ("error" in r) throw new Error(r.error);
    return r;
}

test("slides page", () => {
    const p = C.page(doc, C.PAGE_SLIDES, C.O_NARRATION);
    expect(p).toMatch(/<title>Waves<\/title>/);
    expect(p).toMatch(/<math><semantics>/);
    expect(p).toMatch(/data-step="1"/);
    expect(p).toMatch(/src="blob:cat"/);
});

test("article page and Markdown", () => {
    expect(C.page(doc, C.PAGE_ARTICLE, C.O_TOC)).toMatch(/<h2 id="s-sound">Sound<\/h2>/);
    expect(C.textOutput(doc, C.TEXT_ARTICLE_MD, 0)).toMatch(/^---\ntitle: Waves/);
});

test("outline gives slides with UTF-16 ranges and notes", () => {
    const o = C.outline(doc, 0);
    expect(o.length).toBe(2);
    const second = o[1];
    if (!second) throw new Error("no second slide");
    expect(second.notes).toBe("Say hello.");
    expect(second.steps).toBe(2);
    expect(src.slice(second.s0, second.s0 + 7)).toBe("# Sound");
});

test("subtitles", () => {
    expect(C.textOutput(doc, C.TEXT_VTT, 0)).toMatch(/^WEBVTT\n\n1\n00:00:00\.300 --> /);
});

test("source checks", () => {
    const d = C.lint("# A\n\n![](missing.png)\n", {});
    expect(d.map((x) => x.code)).toEqual(["missingTitle", "missingImage", "missingDescription", "needsExplanation"]);
    expect(d[1]?.start).toBe(5);
});

test("equations", () => {
    expect(C.math("\\frac{1}{2}", true)).toMatch(/<mfrac>/);
    expect(C.math("\\nosuchcommand", false)).toMatch(/tex-fallback/);
});

test("find and sam", () => {
    expect(matchesOf(C.find("a b a", "a", "plain", false))).toEqual([[0, 1], [4, 5]]);
    expect(textOf(C.sam(",x/a/c/o/", "a b a", 0, 0, false))).toBe("o b o");
});

test("themes", () => {
    expect(C.themes().length).toBeGreaterThanOrEqual(20);
    expect(C.themeCSS("nord", "")).toMatch(/--accent/);
});

test("too large source", () => {
    const big = "x".repeat(C.MAX_SOURCE_BYTES + 1);
    expect(() => C.page({ source: big }, 0, 0)).toThrow(/The Markdown file is larger than 512 KB/);
    expect(() => C.find("x", big, "plain", false)).toThrow(/The text is larger than 512 KB/);
    expect(() => C.find(big, "x", "plain", false)).toThrow(C.TooLarge);
    expect(() => C.highlightMarkdown(big)).toThrow(C.TooLarge);
    expect(() => C.vimKey(big, 0, 0, "x")).toThrow(C.TooLarge);
    expect(() => C.diff("", big)).toThrow(C.TooLarge);
    expect(C.page({ ...doc, fonts: "/*" + big + "*/" }, C.PAGE_SLIDES, 0)).toMatch(/<title>Waves<\/title>/);
});

test("ZIP with a too large Markdown file", async () => {
    C.zipBegin();
    C.zipAdd("talk.md", "x".repeat(C.MAX_SOURCE_BYTES - 1), T);
    const parts = [C.zipTake(), C.zipFinish()];
    const ok = imported(await C.packImport(blobOf(parts)));
    expect(ok.markdown.length).toBe(C.MAX_SOURCE_BYTES - 1);
    const z = new Uint8Array(await blobOf(parts).arrayBuffer());
    const v = new DataView(z.buffer);
    for (let i = 0; i + 4 <= z.length; i++) {
        const sig = v.getUint32(i, true);
        if (sig === LOCAL_FILE_HEADER) v.setUint32(i + LOCAL_SIZE_FIELD, C.MAX_SOURCE_BYTES + 1, true);
        if (sig === CENTRAL_DIRECTORY_HEADER) v.setUint32(i + CENTRAL_SIZE_FIELD, C.MAX_SOURCE_BYTES + 1, true);
    }
    expect(failure(await C.packImport(new Blob([z])))).toMatch(/larger than 512 KB/);
});

test("Find, Replace and sam stop at too many matches or a too large result", () => {
    const t = "a".repeat(200000);
    for (const syntax of SYNTAXES) {
        expect(failure(C.find(t, "a", syntax, false))).toMatch(/too many matches/);
        expect(failure(C.replace("a".repeat(1000), "a", "b".repeat(1000), syntax, false, 0, 0, true))).toMatch(/larger than 512 KB/);
    }
    expect(matchesOf(C.find("a".repeat(1000), "a", "plain", false)).length).toBe(1000);
    expect(failure(C.sam(",x/a/d", t, 0, 0, false))).toMatch(/too many matches/);
    expect(failure(C.sam(",x/a/,p", "a".repeat(1000), 0, 0, false))).toMatch(/larger than 512 KB/);
    expect(failure(C.sam(",t$\n,t$\n,t$", "a".repeat(100000), 0, 0, false))).toMatch(/larger than 512 KB/);
    expect(failure(C.replace("aaaa", "a*", "&".repeat(400000), "sam", false, 0, 0, true))).toMatch(/larger than 512 KB/);
});

test("Vim \"+p puts the system clipboard", () => {
    C.vimReset();
    C.vimClipboard("clip");
    let t = "ab";
    let sel: C.Span = [0, 0];
    for (const k of ['"', "+", "p"]) {
        const r = C.vimKey(t, sel[0], sel[1], k);
        if (r.text !== null) t = r.text;
        sel = r.sel;
    }
    expect(t).toBe("aclipb");
});

test("Vim put with a count stops at 512 KB", () => {
    C.vimReset();
    const t = "a".repeat(200000) + "\n";
    let sel: C.Span = [0, 0];
    for (const k of ["y", "y", "3"]) sel = C.vimKey(t, sel[0], sel[1], k).sel;
    const r = C.vimKey(t, sel[0], sel[1], "p");
    expect(r.text === null || r.text === t).toBe(true);
    expect(r.status).toMatch(/larger than 512 KB/);
    expect(C.vimKey(t, 0, 0, "p").text?.length).toBe(2 * t.length);
});

test("project ZIP with Git history and import", async () => {
    const img = new Blob([new Uint8Array(3000).fill(7)]);
    const parts: (Uint8Array | Blob)[] = [];
    const seen = new Set<string>();
    C.zipBegin();
    C.gitBegin("A. Writer", "writer@example.com", T);
    for (const [i, text] of ["v1\n", "v2\n"].entries()) {
        C.gitFile("talk.md", text);
        const g = await C.gitFileBlob("images/cat.png", img, T, seen);
        if (g) parts.push(...g);
        expect(C.gitCommit("Version " + i, T + i * 60, 480)).toMatch(/^[0-9a-f]{40}$/);
        parts.push(C.zipTake());
    }
    C.gitFinish(T);
    C.zipAdd("talk.md", "v2\n", T);
    parts.push(C.zipTake());
    const cat = await C.zipAddBlob("images/cat.png", img, T);
    if (!cat) throw new Error("cat.png was not added");
    parts.push(...cat);
    parts.push(C.zipFinish());
    const zip = blobOf(parts);

    const result = imported(await C.packImport(zip));
    expect(result.markdown).toBe("v2\n");
    expect(result.assets["images/cat.png"]?.size).toBe(3000);

    let git = true;
    try { execFileSync("git", ["--version"]); } catch { git = false; }
    if (!git) return;
    const dir = mkdtempSync(join(tmpdir(), "marklove-web-"));
    try {
        writeFileSync(join(dir, "p.zip"), new Uint8Array(await zip.arrayBuffer()));
        execFileSync("unzip", ["-q", "p.zip", "-d", "p"], { cwd: dir });
        execFileSync("git", ["fsck", "--strict"], { cwd: join(dir, "p") });
        const log = execFileSync("git", ["log", "--format=%s"], { cwd: join(dir, "p") }).toString();
        expect(log).toBe("Version 1\nVersion 0\n");
        expect(execFileSync("git", ["status", "--porcelain"], { cwd: join(dir, "p") }).toString()).toBe("");
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test("EPUB links its media", () => {
    C.zipBegin();
    expect(C.epub(doc, T, 0)).toEqual(["images/cat.png"]);
    expect(C.zipFinish().length).toBeGreaterThan(1000);
});

test("find and replace with Vim patterns", () => {
    expect(matchesOf(C.find("Cat cat", "\\<cat\\>", "vim", true))).toEqual([[0, 3], [4, 7]]);
    expect(matchesOf(C.find("Cat cat", "Cat", "vim", true))).toEqual([[0, 3]]);
    expect(textOf(C.replace("ab ab", "\\(a\\)b", "\\u\\1x", "vim", true, 0, 0, true))).toBe("Ax Ax");
    expect(failure(C.find("a", "\\(", "vim", true))).toBeTruthy();
});

const P = await C.instance({});
const dec = new TextDecoder();
const call = (name: C.MlName, inputs: C.Input[], ...ints: number[]): string => dec.decode(P(name, inputs, ...ints));
const pageArgs = (source: string, durations = ""): C.Input[] =>
    [...C.docArgs({ source, assets: doc.assets }), "images/cat.png\t400\t300\n", durations];
const layout = (kind: number, a = 0, b = 0, durations = ""): unknown =>
    parse(call("ml_layout", pageArgs(src, durations), kind, C.O_NARRATION, a, b));

test("page layouts for slides, video, article, handout and poster", () => {
    const slides = layout(0);
    expect(list(get(slides, "pages")).length).toBe(2);
    expect([get(slides, "pages", 0, "width"), get(slides, "pages", 0, "height")]).toEqual([960, 540]);
    expect(get(slides, "pages", 1, "title")).toBe("Sound");
    expect(get(slides, "pages", 1, "steps")).toBe(2);
    const svg = call("ml_page_svg", [], 1, -1, 0, 1, 2);
    expect(svg).toMatch(/^<svg [^>]*width="1920" height="1080" viewBox="0 0 960 540"/);
    expect(svg).toMatch(/\/\*ml-fonts\*\//);
    expect(svg).toMatch(/href="asset:0"/);
    const video = layout(1);
    expect(list(get(video, "timeline", "segments")).length).toBe(3);
    expect(get(video, "timeline", "voice")).toBe("");
    const article = layout(2, 1);
    expect([get(article, "pages", 0, "width"), get(article, "pages", 0, "height")]).toEqual([612, 792]);
    expect(list(get(layout(3), "pages")).length).toBeGreaterThanOrEqual(1);
    const poster = layout(4, 0, 0);
    expect(list(get(poster, "pages")).length).toBe(1);
    expect(num(get(poster, "pages", 0, "height"))).toBeGreaterThan(num(get(poster, "pages", 0, "width")));
});

test("SVG export marks the regions to trace", () => {
    layout(0);
    const svg = call("ml_export_svg", [], 1);
    expect(svg).toMatch(/<title id="title">Sound<\/title>/);
    expect(svg).toMatch(/<!--ml-region 0-->/);
    const regions = list(parse(call("ml_regions", [])));
    expect(regions.length).toBeGreaterThanOrEqual(2);
    expect(regions.some((r) => get(r, "label") === "A cat")).toBe(true);
    expect(call("ml_region_svg", [], 0)).toMatch(/^<svg /);
});

test("trace makes paths from pixels", () => {
    const w = 20, h = 20, px = new Uint8Array(w * h * 4);
    for (let y = 5; y < 15; y++) for (let x = 5; x < 15; x++) { const i = (y * w + x) * 4; px[i] = 255; px[i + 3] = 255; }
    const g = call("ml_trace_arg", [px, "A box"], w, h, 4, 2, 0.6, 10, 20, 2);
    expect(g).toMatch(/^<g transform="translate\(10 20\) scale\(0.5000\)" fill-rule="evenodd" role="img" aria-label="A box">/);
    expect(g).toMatch(/<path fill="#ff0000" d="M5 5L15 5L15 15L5 15Z"\/>/);
});

test("trace of a large region keeps the per-pixel arrays out of a data stack", () => {
    const big = new Uint8Array(3000 * 1500 * 4);
    for (let i = 0; i < big.length; i += 4 * 7) { big[i + 1] = 200; big[i + 3] = 255; }
    expect(call("ml_trace_arg", [big, ""], 3000, 1500, 8, 1, 0.5, 0, 0, 4)).toMatch(/aria-hidden="true"/);
});

test("video and podcast timing use the real sentence lengths", () => {
    const first = layout(1);
    const cue = list(get(first, "timeline", "cues")).find((c) => get(c, "text") === "More text é.");
    const cueText = str(get(cue, "text"));
    const longer = layout(1, 0, 0, `${cueText}\t9.5\n`);
    const again = list(get(longer, "timeline", "cues")).find((c) => get(c, "text") === cueText);
    expect(Math.round((num(get(again, "end")) - num(get(again, "start"))) * 10)).toBe(95);
    const pod = parse(call("ml_podcast", pageArgs(src, `${cueText}\t9.5\n`), C.O_NARRATION));
    expect(list(get(pod, "segments")).length).toBe(0);
    expect(get(pod, "cues", 0, "start")).toBe(0.3);
    const cues = list(get(pod, "cues"));
    for (let i = 1; i < cues.length; i++) expect(num(get(cues, i, "start"))).toBeGreaterThanOrEqual(num(get(cues, i - 1, "end")));
    expect(call("ml_text", pageArgs(src, `${cueText}\t9.5\n`), C.TEXT_VTT, 0)).toMatch(/^WEBVTT/);
});

test("MP4 header with video and AAC audio", () => {
    const u32 = (v: number[]): Uint8Array => new Uint8Array(new Uint32Array(v).buffer);
    const head = P("ml_mp4", [u32([100, 50]), u32([600, 20]), new Uint8Array([1, 0]), new Uint8Array([1, 100, 0, 40]),
        u32([10, 12]), u32([1024, 1024]), new Uint8Array([17, 144])], 1920, 1080, 600, 1, 48000, 48000, 1);
    const view = new DataView(head.buffer);
    const boxes: [string, number][] = [];
    for (let at = 0; at < head.length;) {
        const size = view.getUint32(at);
        const name = dec.decode(head.subarray(at + 4, at + 8));
        boxes.push([name, size]);
        if (name === "mdat") break;
        at += size;
    }
    expect(boxes.map((b) => b[0])).toEqual(["ftyp", "moov", "mdat"]);
    expect(boxes[2]?.[1]).toBe(8 + 150 + 22);
    const text = dec.decode(head);
    for (const box of ["avcC", "mp4a", "esds", "stts", "stss", "stsz", "stco"]) expect(text.includes(box)).toBe(true);
});

test("front matter value", () => {
    expect(C.meta("---\nvoice: bf_emma\n---\n\n# A\n", "voice")).toBe("bf_emma");
    expect(C.meta(src, "voice")).toBe("");
});
