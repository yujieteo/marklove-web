// Tests of the built core (web/marklove.wasm) through web/core.js.
//   node --test tests/core.test.mjs
// The Project ZIP test also runs `git fsck` when git is installed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as C from "../web/core.js";

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
const doc = { source: src, assets: { "images/cat.png": "blob:cat" } };
const T = 1700000000;

test("slides page", () => {
    const p = C.page(doc, C.PAGE_SLIDES, C.O_NARRATION);
    assert.match(p, /<title>Waves<\/title>/);
    assert.match(p, /<math><semantics>/);
    assert.match(p, /data-step="1"/);
    assert.match(p, /src="blob:cat"/);
});

test("article page and Markdown", () => {
    assert.match(C.page(doc, C.PAGE_ARTICLE, C.O_TOC), /<h2 id="s-sound">Sound<\/h2>/);
    assert.match(C.textOutput(doc, C.TEXT_ARTICLE_MD, 0), /^---\ntitle: Waves/);
});

test("outline gives slides with UTF-16 ranges and notes", () => {
    const o = C.outline(doc, 0);
    assert.equal(o.length, 2);
    assert.equal(o[1].notes, "Say hello.");
    assert.equal(o[1].steps, 2);
    assert.equal(src.slice(o[1].s0, o[1].s0 + 7), "# Sound");
});

test("subtitles", () => {
    assert.match(C.textOutput(doc, C.TEXT_VTT, 0), /^WEBVTT\n\n1\n00:00:00\.300 --> /);
});

test("source checks", () => {
    const d = C.lint("# A\n\n![](missing.png)\n");
    assert.deepEqual(d.map((x) => x.code),
        ["missingTitle", "missingImage", "missingDescription", "needsExplanation"]);
    assert.equal(d[1].start, 5);
});

test("equations", () => {
    assert.match(C.math("\\frac{1}{2}", true), /<mfrac>/);
    assert.match(C.math("\\nosuchcommand", false), /tex-fallback/);
});

test("find and sam", () => {
    assert.deepEqual(C.find("a b a", "a", "plain", false).matches, [[0, 1], [4, 5]]);
    assert.equal(C.sam(",x/a/c/o/", "a b a", 0, 0, false).text, "o b o");
});

test("themes", () => {
    assert.ok(C.themes().length >= 20);
    assert.match(C.themeCSS("nord", ""), /--accent/);
});

test("too large source", () => {
    const big = "x".repeat(C.MAX_SOURCE_BYTES + 1);
    assert.throws(() => C.page({ source: big }, 0, 0), C.TooLarge);
    assert.throws(() => C.find(big, "x", "plain", false), C.TooLarge);
    assert.throws(() => C.highlightMarkdown(big), C.TooLarge);
    assert.throws(() => C.vimKey(big, 0, 0, "x"), C.TooLarge);
    assert.throws(() => C.diff("", big), C.TooLarge);
    assert.match(C.page({ ...doc, fonts: "/*" + big + "*/" }, C.PAGE_SLIDES, 0), /<title>Waves<\/title>/);
});

test("ZIP with a too large Markdown file", async () => {
    C.zipBegin();
    C.zipAdd("talk.md", "x".repeat(C.MAX_SOURCE_BYTES - 1), T);
    const parts = [C.zipTake(), C.zipFinish()];
    const ok = await C.packImport(new Blob(parts));
    assert.equal(ok.markdown.length, C.MAX_SOURCE_BYTES - 1);
    // The same ZIP, with a size of 512 KB + 1 in the headers of the entry.
    const z = new Uint8Array(await new Blob(parts).arrayBuffer());
    const v = new DataView(z.buffer);
    for (let i = 0; i + 4 <= z.length; i++) {
        const sig = v.getUint32(i, true);
        if (sig === 0x04034B50) v.setUint32(i + 22, C.MAX_SOURCE_BYTES + 1, true);
        if (sig === 0x02014B50) v.setUint32(i + 24, C.MAX_SOURCE_BYTES + 1, true);
    }
    assert.match((await C.packImport(new Blob([z]))).error, /larger than 512 KB/);
});

test("Find, Replace and sam stop at too many matches or a too large result", () => {
    const t = "a".repeat(200000);
    for (const syntax of ["sam", "plain", "vim"]) {
        assert.match(C.find(t, "a", syntax, false).error, /too many matches/);
        assert.match(C.replace("a".repeat(1000), "a", "b".repeat(1000), syntax, false, 0, 0, true).error, /larger than 512 KB/);
    }
    assert.equal(C.find("a".repeat(1000), "a", "plain", false).matches.length, 1000);
    assert.match(C.sam(",x/a/d", t, 0, 0, false).error, /too many matches/);
    assert.match(C.sam(",x/a/,p", "a".repeat(1000), 0, 0, false).error, /larger than 512 KB/);
    assert.match(C.sam(",t$\n,t$\n,t$", "a".repeat(100000), 0, 0, false).error, /larger than 512 KB/);
    assert.match(C.replace("aaaa", "a*", "&".repeat(400000), "sam", false, 0, 0, true).error, /larger than 512 KB/);
});

test("Vim \"+p puts the system clipboard", () => {
    C.vimReset();
    C.vimClipboard("clip");
    let t = "ab";
    let sel = [0, 0];
    for (const k of ['"', "+", "p"]) {
        const r = C.vimKey(t, sel[0], sel[1], k);
        if (r.text !== null && r.text !== undefined) t = r.text;
        sel = r.sel;
    }
    assert.equal(t, "aclipb");
});

test("project ZIP with Git history and import", async () => {
    const img = new Blob([new Uint8Array(3000).fill(7)]);
    const parts = [];
    const seen = new Set();
    C.zipBegin();
    C.gitBegin("A. Writer", "writer@example.com", T);
    for (const [i, text] of ["v1\n", "v2\n"].entries()) {
        C.gitFile("talk.md", text);
        const g = await C.gitFileBlob("images/cat.png", img, T, seen);
        if (g) parts.push(...g);
        assert.match(C.gitCommit("Version " + i, T + i * 60, 480), /^[0-9a-f]{40}$/);
        parts.push(C.zipTake());
    }
    C.gitFinish(T);
    C.zipAdd("talk.md", "v2\n", T);
    parts.push(C.zipTake());
    parts.push(...(await C.zipAddBlob("images/cat.png", img, T)));
    parts.push(C.zipFinish());
    const zip = new Blob(parts);

    const imported = await C.packImport(zip);
    assert.equal(imported.markdown, "v2\n");
    assert.equal(imported.assets["images/cat.png"].size, 3000);

    let git = true;
    try { execFileSync("git", ["--version"]); } catch { git = false; }
    if (!git) return;
    const dir = mkdtempSync(join(tmpdir(), "marklove-web-"));
    try {
        writeFileSync(join(dir, "p.zip"), new Uint8Array(await zip.arrayBuffer()));
        execFileSync("unzip", ["-q", "p.zip", "-d", "p"], { cwd: dir });
        execFileSync("git", ["fsck", "--strict"], { cwd: join(dir, "p") });
        const log = execFileSync("git", ["log", "--format=%s"], { cwd: join(dir, "p") }).toString();
        assert.equal(log, "Version 1\nVersion 0\n");
        assert.equal(execFileSync("git", ["status", "--porcelain"], { cwd: join(dir, "p") }).toString(), "");
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test("EPUB links its media", () => {
    C.zipBegin();
    assert.deepEqual(C.epub(doc, T, 0), ["images/cat.png"]);
    assert.ok(C.zipFinish().length > 1000);
});

test("find and replace with Vim patterns", () => {
    assert.deepEqual(C.find("Cat cat", "\\<cat\\>", "vim", true).matches, [[0, 3], [4, 7]]);
    assert.deepEqual(C.find("Cat cat", "Cat", "vim", true).matches, [[0, 3]]);
    assert.equal(C.replace("ab ab", "\\(a\\)b", "\\u\\1x", "vim", true, 0, 0, true).text, "Ax Ax");
    assert.ok(C.find("a", "\\(", "vim", true).error);
});
