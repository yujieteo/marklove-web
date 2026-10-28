// The Marklove core: Goose compiled to WebAssembly. Each function writes its
// inputs (strings or bytes) into the core, calls one export, and copies the
// result out. See core/marklove.goose for the meaning of each call.

import createModule from "./marklove.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export const O_TAKAHASHI = 1, O_TOC = 2, O_NARRATION = 4, O_PUBLIC_NOTES = 8;
export const PAGE_SLIDES = 0, PAGE_ARTICLE = 1;
export const TEXT_ARTICLE_MD = 0, TEXT_REVISED_MD = 1, TEXT_NARRATION = 2,
    TEXT_TRANSCRIPT = 3, TEXT_VTT = 4, TEXT_SRT = 5;
export const LIST_LISTENER_MD = 0, LIST_PUBLIC_ASSETS = 1, LIST_PRIVATE_ASSETS = 2,
    LIST_REVISION_PROMPT = 3;

// The core keeps each value in a data stack of 8 MB with no guard page
// (see core/io.h), so a larger source could overwrite other data. A source
// of this size is far larger than a long talk or article.
export const MAX_SOURCE_BYTES = 512 * 1024;
export class TooLarge extends Error {}

let M = null;
let lenPtr = 0;

export async function load() {
    if (M) return;
    M = await createModule();
    M._goose_init(0, 0);
    lenPtr = M._malloc(8);
}

function put(inputs) {
    inputs.forEach((v, i) => {
        const b = typeof v === "string" ? encoder.encode(v) : v;
        const p = M._ml_in_alloc(i, b.length);
        M.HEAPU8.set(b, p);
    });
}

function bytes(name, inputs, ...ints) {
    put(inputs);
    const p = M["_" + name](...ints, lenPtr);
    const n = Number(new BigInt64Array(M.HEAPU8.buffer, lenPtr, 1)[0]);
    return M.HEAPU8.slice(p, p + n);
}

const text = (name, inputs, ...ints) => decoder.decode(bytes(name, inputs, ...ints));
const json = (name, inputs, ...ints) => JSON.parse(text(name, inputs, ...ints));

function plain(name, inputs, ...ints) {
    put(inputs);
    return M["_" + name](...ints);
}

// A document: the source, the assets ({path: url}) and the page parts.
function docArgs(d) {
    if (encoder.encode(d.source).length > MAX_SOURCE_BYTES)
        throw new TooLarge("The Markdown file is larger than 512 KB. Split it into more projects.");
    const assets = Object.entries(d.assets || {}).map(([k, v]) => k + "\t" + v + "\n").join("");
    return [d.source, assets, d.fonts || "", d.style || "", d.script || "", d.appearance || ""];
}

export const page = (d, kind, opts) => text("ml_page", docArgs(d), kind, opts);
export const textOutput = (d, kind, opts) => text("ml_text", docArgs(d), kind, opts);
export const outline = (d, opts) => json("ml_outline", docArgs(d), opts);
// assets: {path: url}, as in page(). A path without an entry gives "missingImage".
export const lint = (source, assets) => json("ml_lint", docArgs({ source, assets }));
// Starts an EPUB in the ZIP builder. Returns the media paths that it links.
export const epub = (d, date, opts) =>
    text("ml_epub", docArgs(d), date, opts).split("\n").filter(Boolean);

export const listener = (source, kind) => {
    const t = text("ml_listener", docArgs({ source }), kind);
    return kind === LIST_PUBLIC_ASSETS || kind === LIST_PRIVATE_ASSETS ? JSON.parse(t) : t;
};
export const authoringPrompt = (draft) => text("ml_authoring_prompt", [draft]);
// The tour project: {name, markdown, assets: {project path: bundled file}}.
export const tour = () => json("ml_tour", []);
// The equation at a UTF-16 offset: {latex, display, start, end} or null.
export const mathAt = (t, offset) => json("ml_math_at", [t], offset);
export const mathSpeech = (latex) => text("ml_math_speech", [latex]);

export const math = (latex, display) => text("ml_math", [latex], display ? 1 : 0);
export const mathCheck = (latex) => text("ml_math_check", [latex]);

export const themes = () => json("ml_theme_list", []);
export const themeResolve = (theme, accent) => json("ml_theme_resolve", [theme, accent]);
export const themeCSS = (theme, accent) => text("ml_theme_css", [theme, accent]);
export const themePalette = (theme, accent, dark, moreContrast) =>
    json("ml_theme_palette", [theme, accent], dark ? 1 : 0, moreContrast ? 1 : 0);
export const typography = () => json("ml_typography", []);

export const highlight = (code, lang) => text("ml_highlight", [code, lang]);
export const highlightMarkdown = (source) => json("ml_highlight_md", [source]);

// Editing. The offsets are UTF-8 bytes: see utf8Offset and utf16Offset.
// syntax: "sam", "plain" or "vim" (the Find setting).
const SYNTAX = { sam: 0, plain: 1, vim: 2 };
export const find = (t, pattern, syntax, ignoreCase) =>
    json("ml_find", [t, pattern], SYNTAX[syntax], ignoreCase ? 1 : 0);
export const replace = (t, pattern, replacement, syntax, ignoreCase, selS, selE, all) =>
    json("ml_replace", [t, pattern, replacement], SYNTAX[syntax], ignoreCase ? 1 : 0, selS, selE, all ? 1 : 0);
export const sam = (command, t, selS, selE, ignoreCase) =>
    json("ml_sam", [command, t], selS, selE, ignoreCase ? 1 : 0);
export const diff = (a, b) => json("ml_diff", [a, b]);
export const commitMessage = (a, b) => text("ml_commit_message", [a, b]);

export const vimReset = () => plain("ml_vim_reset", []);
export const vimClipboard = (t) => plain("ml_vim_clipboard", [t]);
export const vimKey = (t, selS, selE, key) => json("ml_vim_key", [t, key], selS, selE);

// ZIP files. Times are Unix seconds. Large files (media) stay in
// JavaScript: zipAddBlob gives the parts to put into the final Blob.
export const zipBegin = () => plain("ml_zip_begin", []);
export const zipAdd = (name, data, mtime) => plain("ml_zip_add", [name, data], mtime);
export const zipAddDir = (name, mtime) => plain("ml_zip_add_dir", [name], mtime);
export const zipTake = () => bytes("ml_zip_take", []);
export const zipFinish = () => bytes("ml_zip_finish", []);

const CHUNK = 1 << 20;

export async function crc32(blob) {
    let crc = 0;
    for (let i = 0; i < blob.size; i += CHUNK) {
        const part = new Uint8Array(await blob.slice(i, i + CHUNK).arrayBuffer());
        crc = plain("ml_crc32", [part], crc);
    }
    return crc;
}

// Adds a file whose bytes stay in a Blob. Returns the parts to append to
// the archive, or null when the name is not valid or already there.
export async function zipAddBlob(name, blob, mtime) {
    const crc = await crc32(blob);
    const head = bytes("ml_zip_add_ref", [name], blob.size, crc, mtime);
    return head.length ? [head, blob] : null;
}

// Reads a project ZIP: {markdownName, markdown, assets, warnings} with each
// asset as a Blob, or {error}.
export async function packImport(zipBlob) {
    const z = new Uint8Array(await zipBlob.arrayBuffer());
    const p = M._ml_in_alloc(0, z.length);
    M.HEAPU8.set(z, p);
    const r = M._ml_pack_import_arg(lenPtr);
    const n = Number(new BigInt64Array(M.HEAPU8.buffer, lenPtr, 1)[0]);
    const result = JSON.parse(decoder.decode(M.HEAPU8.slice(r, r + n)));
    M._ml_in_alloc(0, 0);
    if (result.error) return result;
    const assets = {};
    for (const a of result.assets) {
        let data = zipBlob.slice(a.offset, a.offset + a.csize);
        if (a.method === 8)
            data = await new Response(data.stream().pipeThrough(new DecompressionStream("deflate-raw"))).blob();
        if (data.size !== a.usize || (await crc32(data)) >>> 0 !== a.crc >>> 0) {
            result.warnings.push("Skipped " + a.path + ": the file is damaged.");
            continue;
        }
        assets[a.path] = data;
    }
    result.assets = assets;
    return result;
}

// A Git history in the ZIP builder, oldest version first: gitBegin, then
// for each version gitFile or gitFileBlob for each file and gitCommit, then
// gitFinish. Call zipBegin first and zipTake after each commit.
export const gitBegin = (name, email, mtime) => plain("ml_git_begin", [name, email], mtime);
export const gitFile = (path, data) => plain("ml_git_file", [path, data]) !== 0;
export const gitCommit = (message, time, tzMinutes) => text("ml_git_commit", [message], time, tzMinutes);
export const gitFinish = (mtime) => plain("ml_git_finish", [], mtime);

// A large file in the history. Its blob object stays in JavaScript: the
// result is the archive parts of the object, or null when the history has
// the object already (seen holds the object names).
export async function gitFileBlob(path, blob, mtime, seen) {
    const head = encoder.encode("blob " + blob.size + "\0");
    const raw = new Blob([head, blob]);
    const sha = [...new Uint8Array(await crypto.subtle.digest("SHA-1", await raw.arrayBuffer()))]
        .map((b) => b.toString(16).padStart(2, "0")).join("");
    if (plain("ml_git_file_ref", [path, sha], blob.size) === 0) return null;
    if (seen.has(sha)) return null;
    seen.add(sha);
    const z = await new Response(raw.stream().pipeThrough(new CompressionStream("deflate"))).blob();
    return zipAddBlob(".git/objects/" + sha.slice(0, 2) + "/" + sha.slice(2), z, mtime);
}

// Offsets between a JavaScript string (UTF-16) and its UTF-8 bytes.
export function utf8Offset(s, u16) { return encoder.encode(s.slice(0, u16)).length; }
export function utf16Offset(s, u8) {
    const b = encoder.encode(s);
    return decoder.decode(b.subarray(0, u8)).length;
}
