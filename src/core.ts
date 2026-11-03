import createModule from "../web/marklove.mjs";
import type { MarkloveModule, MarkloveHooks } from "../web/marklove.mjs";
import { isRecord, must } from "./dom.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export const O_TAKAHASHI = 1, O_TOC = 2, O_NARRATION = 4, O_PUBLIC_NOTES = 8;
export const PAGE_SLIDES = 0, PAGE_ARTICLE = 1;
export const TEXT_ARTICLE_MD = 0, TEXT_REVISED_MD = 1, TEXT_NARRATION = 2,
    TEXT_TRANSCRIPT = 3, TEXT_VTT = 4, TEXT_SRT = 5;
export const LIST_LISTENER_MD = 0, LIST_PUBLIC_ASSETS = 1, LIST_PRIVATE_ASSETS = 2,
    LIST_REVISION_PROMPT = 3;

export const MAX_SOURCE_BYTES = 512 * 1024;
export class TooLarge extends Error {}

export type Input = string | Uint8Array;
export type MlName = `ml_${string}`;
export type CoreCall = (name: MlName, inputs: Input[], ...ints: number[]) => Uint8Array;
export type Assets = Record<string, string>;

export interface Doc {
    source: string;
    assets?: Assets | undefined;
    fonts?: string | undefined;
    style?: string | undefined;
    script?: string | undefined;
    appearance?: string | undefined;
}

export interface OutlineEntry {
    id: string;
    frame: number;
    kind: number;
    s0: number;
    s1: number;
    steps: number;
    notes: string;
}

export interface LintIssue {
    code: string;
    severity: string;
    message: string;
    detail: string;
    start: number;
    end: number;
    formats: string[];
    style?: string;
}

export interface TourProject {
    name: string;
    markdown: string;
    assets: Record<string, string>;
}

export interface MathAt {
    latex: string;
    display: boolean;
    start: number;
    end: number;
}

interface ThemeColors {
    name: string;
    isDark: boolean;
    background: string;
    surface: string;
    border: string;
    dim: string;
    text: string;
    strong: string;
    accent: string;
    red: string;
    green: string;
    yellow: string;
    blue: string;
    magenta: string;
    cyan: string;
    orange: string;
    violet: string;
    series: string[];
}

export interface ThemePalette extends ThemeColors {
    roles: Record<string, string>;
}

export interface Theme {
    id: string;
    name: string;
    credit: string;
    darkOnly: boolean;
    light: ThemeColors;
    dark: ThemeColors;
}

export interface ThemeChoice {
    id: string;
    name: string;
    darkOnly: boolean;
    prefersDark: boolean | null;
}

export interface EditorTypography {
    font: string;
    pointSize: number;
    pointSizeIOS: number;
    lineHeight: number;
    maxLineCharacters: number;
    bold: string[];
    italic: string[];
}

export type Span = [number, number];
export type HighlightSpan = [number, number, string];
export type FindResult = { error: string } | { matches: Span[] };
interface Replaced {
    count: number;
    text?: string;
    selection?: Span;
}
export type ReplaceResult = { error: string } | Replaced;
export type SamResult = { error: string } | { text: string | null; selection: Span; printed: string[]; summary: string };
type DiffOp = "same" | "add" | "remove";
export interface DiffLine {
    op: DiffOp;
    text: string;
    old?: number;
    new?: number;
}

type VimMode = "normal" | "insert" | "visual" | "visual-line" | "command";
type VimAction = "" | "save" | "discard" | "copy";
export interface VimKeyResult {
    handled: boolean;
    text: string | null;
    cursor: number;
    sel: Span;
    mode: VimMode;
    status: string;
    action: VimAction;
    clip?: string;
}

export type PackResult =
    | { error: string }
    | { markdownName: string; markdown: string; assets: Record<string, Blob>; warnings: string[] };

export type Syntax = "sam" | "plain" | "vim";

function field(o: Record<string, unknown>, key: string): unknown {
    return o[key];
}

function asRecord(v: unknown, what: string): Record<string, unknown> {
    if (!isRecord(v)) throw new Error("The core gave no object for " + what);
    return v;
}

function asString(v: unknown, what: string): string {
    if (typeof v !== "string") throw new Error("The core gave no string for " + what);
    return v;
}

function asNumber(v: unknown, what: string): number {
    if (typeof v !== "number") throw new Error("The core gave no number for " + what);
    return v;
}

function asBool(v: unknown, what: string): boolean {
    if (typeof v !== "boolean") throw new Error("The core gave no boolean for " + what);
    return v;
}

function asArray(v: unknown, what: string): unknown[] {
    if (!Array.isArray(v)) throw new Error("The core gave no array for " + what);
    return v;
}

function asStrings(v: unknown, what: string): string[] {
    return asArray(v, what).map((x) => asString(x, what));
}

function asSpan(v: unknown, what: string): Span {
    const a = asArray(v, what);
    return [asNumber(a[0], what), asNumber(a[1], what)];
}

function strField(o: Record<string, unknown>, key: string): string {
    return asString(field(o, key), key);
}

function numField(o: Record<string, unknown>, key: string): number {
    return asNumber(field(o, key), key);
}

function boolField(o: Record<string, unknown>, key: string): boolean {
    return asBool(field(o, key), key);
}

function stringMap(v: unknown, what: string): Record<string, string> {
    const out: Record<string, string> = {};
    for (const [k, x] of Object.entries(asRecord(v, what))) out[k] = asString(x, what);
    return out;
}

function parseJSON(s: string): unknown {
    return JSON.parse(s);
}

let M: MarkloveModule | null = null;
let lenPtr = 0;

function mod(): MarkloveModule {
    return must(M, "loaded core. Call load() first");
}

function exportOf(m: MarkloveModule, name: MlName): (...ints: number[]) => number {
    const key: `_ml_${string}` = `_${name}`;
    return must(m[key], "core export " + name);
}

export async function load(): Promise<void> {
    if (M) return;
    M = await createModule();
    M._goose_init(0, 0);
    lenPtr = M._malloc(8);
}

function put(inputs: Input[], m: MarkloveModule): void {
    const all = inputs.map((v) => {
        if (typeof v !== "string") return v;
        const b = encoder.encode(v);
        if (b.length > MAX_SOURCE_BYTES)
            throw new TooLarge("The text is larger than 512 KB.");
        return b;
    });
    all.forEach((b, i) => {
        const p = m._ml_in_alloc(i, b.length);
        m.HEAPU8.set(b, p);
    });
}

function readLength(m: MarkloveModule, len: number): number {
    return Number(must(new BigInt64Array(m.HEAPU8.buffer, len, 1)[0], "result length"));
}

function result(m: MarkloveModule, p: number, len: number): Uint8Array {
    const n = readLength(m, len);
    return m.HEAPU8.slice(p, p + n);
}

function callBytes(m: MarkloveModule, len: number, name: MlName, inputs: Input[], ints: number[]): Uint8Array {
    put(inputs, m);
    return result(m, exportOf(m, name)(...ints, len), len);
}

function bytes(name: MlName, inputs: Input[], ...ints: number[]): Uint8Array {
    return callBytes(mod(), lenPtr, name, inputs, ints);
}

export async function instance(hooks: MarkloveHooks): Promise<CoreCall> {
    const m = await createModule(hooks);
    m._goose_init(0, 0);
    const len = m._malloc(8);
    return (name, inputs, ...ints) => callBytes(m, len, name, inputs, ints);
}

const text = (name: MlName, inputs: Input[], ...ints: number[]): string => decoder.decode(bytes(name, inputs, ...ints));
const json = (name: MlName, inputs: Input[], ...ints: number[]): unknown => parseJSON(text(name, inputs, ...ints));

function plain(name: MlName, inputs: Input[], ...ints: number[]): number {
    const m = mod();
    put(inputs, m);
    return exportOf(m, name)(...ints);
}

export function docArgs(d: Doc): Input[] {
    if (encoder.encode(d.source).length > MAX_SOURCE_BYTES)
        throw new TooLarge("The Markdown file is larger than 512 KB. Split it into more projects.");
    const assets = Object.entries(d.assets || {}).map(([k, v]) => k + "\t" + v + "\n").join("");
    const part = (t: string | undefined) => encoder.encode(t || "");
    return [d.source, assets, part(d.fonts), part(d.style), part(d.script), d.appearance || ""];
}

export const meta = (source: string, key: string): string => text("ml_meta", [...docArgs({ source }), key]);
export const page = (d: Doc, kind: number, opts: number): string => text("ml_page", docArgs(d), kind, opts);
export const textOutput = (d: Doc, kind: number, opts: number): string => text("ml_text", docArgs(d), kind, opts);

function parseOutline(v: unknown): OutlineEntry[] {
    return asArray(v, "outline").map((x) => {
        const o = asRecord(x, "outline entry");
        return {
            id: strField(o, "id"), frame: numField(o, "frame"), kind: numField(o, "kind"),
            s0: numField(o, "s0"), s1: numField(o, "s1"), steps: numField(o, "steps"), notes: strField(o, "notes"),
        };
    });
}

export const outline = (d: Doc, opts: number): OutlineEntry[] => parseOutline(json("ml_outline", docArgs(d), opts));

function parseLint(v: unknown): LintIssue[] {
    return asArray(v, "lint").map((x) => {
        const o = asRecord(x, "lint issue");
        const issue: LintIssue = {
            code: strField(o, "code"), severity: strField(o, "severity"), message: strField(o, "message"),
            detail: strField(o, "detail"), start: numField(o, "start"), end: numField(o, "end"),
            formats: asStrings(field(o, "formats"), "formats"),
        };
        const style = field(o, "style");
        if (typeof style === "string") issue.style = style;
        return issue;
    });
}

export const lint = (source: string, assets: Assets): LintIssue[] => parseLint(json("ml_lint", docArgs({ source, assets })));

export const epub = (d: Doc, date: number, opts: number): string[] =>
    text("ml_epub", docArgs(d), date, opts).split("\n").filter(Boolean);

export function listener(source: string, kind: typeof LIST_PUBLIC_ASSETS | typeof LIST_PRIVATE_ASSETS): string[];
export function listener(source: string, kind: number): string;
export function listener(source: string, kind: number): string | string[] {
    const t = text("ml_listener", docArgs({ source }), kind);
    return kind === LIST_PUBLIC_ASSETS || kind === LIST_PRIVATE_ASSETS ? asStrings(parseJSON(t), "listener assets") : t;
}
export const authoringPrompt = (draft: string): string => text("ml_authoring_prompt", [draft]);

export function tour(): TourProject {
    const o = asRecord(json("ml_tour", []), "tour");
    return { name: strField(o, "name"), markdown: strField(o, "markdown"), assets: stringMap(field(o, "assets"), "tour assets") };
}

export function mathAt(t: string, offset: number): MathAt | null {
    const v = json("ml_math_at", [t], offset);
    if (v === null) return null;
    const o = asRecord(v, "math");
    return { latex: strField(o, "latex"), display: boolField(o, "display"), start: numField(o, "start"), end: numField(o, "end") };
}
export const mathSpeech = (latex: string): string => text("ml_math_speech", [latex]);

export const math = (latex: string, display: boolean): string => text("ml_math", [latex], display ? 1 : 0);
export const mathCheck = (latex: string): string => text("ml_math_check", [latex]);

function parseColors(v: unknown, what: string): ThemeColors {
    const o = asRecord(v, what);
    return {
        name: strField(o, "name"), isDark: boolField(o, "isDark"),
        background: strField(o, "background"), surface: strField(o, "surface"), border: strField(o, "border"),
        dim: strField(o, "dim"), text: strField(o, "text"), strong: strField(o, "strong"), accent: strField(o, "accent"),
        red: strField(o, "red"), green: strField(o, "green"), yellow: strField(o, "yellow"), blue: strField(o, "blue"),
        magenta: strField(o, "magenta"), cyan: strField(o, "cyan"), orange: strField(o, "orange"), violet: strField(o, "violet"),
        series: asStrings(field(o, "series"), "series"),
    };
}

export function themes(): Theme[] {
    return asArray(json("ml_theme_list", []), "themes").map((x) => {
        const o = asRecord(x, "theme");
        return {
            id: strField(o, "id"), name: strField(o, "name"), credit: strField(o, "credit"), darkOnly: boolField(o, "darkOnly"),
            light: parseColors(field(o, "light"), "light"), dark: parseColors(field(o, "dark"), "dark"),
        };
    });
}

export function themeResolve(theme: string, accent: string): ThemeChoice {
    const o = asRecord(json("ml_theme_resolve", [theme, accent]), "theme choice");
    const prefers = field(o, "prefersDark");
    return {
        id: strField(o, "id"), name: strField(o, "name"), darkOnly: boolField(o, "darkOnly"),
        prefersDark: prefers === null ? null : asBool(prefers, "prefersDark"),
    };
}
export const themeCSS = (theme: string, accent: string): string => text("ml_theme_css", [theme, accent]);

export function themePalette(theme: string, accent: string, dark: boolean, moreContrast: boolean): ThemePalette {
    const v = json("ml_theme_palette", [theme, accent], dark ? 1 : 0, moreContrast ? 1 : 0);
    return { ...parseColors(v, "palette"), roles: stringMap(field(asRecord(v, "palette"), "roles"), "roles") };
}

export function typography(): { editor: EditorTypography } & Record<string, unknown> {
    const all = asRecord(json("ml_typography", []), "typography");
    const o = asRecord(field(all, "editor"), "editor typography");
    return {
        ...all,
        editor: {
            font: strField(o, "font"), pointSize: numField(o, "pointSize"), pointSizeIOS: numField(o, "pointSizeIOS"),
            lineHeight: numField(o, "lineHeight"), maxLineCharacters: numField(o, "maxLineCharacters"),
            bold: asStrings(field(o, "bold"), "bold"), italic: asStrings(field(o, "italic"), "italic"),
        },
    };
}

export function highlightMarkdown(source: string): HighlightSpan[] {
    return asArray(json("ml_highlight_md", [source]), "highlight").map((x) => {
        const a = asArray(x, "highlight span");
        return [asNumber(a[0], "start"), asNumber(a[1], "end"), asString(a[2], "role")];
    });
}

const SYNTAX: Record<Syntax, number> = { sam: 0, plain: 1, vim: 2 };

function failure(o: Record<string, unknown>): { error: string } | null {
    const e = field(o, "error");
    return typeof e === "string" ? { error: e } : null;
}

export function find(t: string, pattern: string, syntax: Syntax, ignoreCase: boolean): FindResult {
    const o = asRecord(json("ml_find", [t, pattern], SYNTAX[syntax], ignoreCase ? 1 : 0), "find");
    return failure(o) ?? { matches: asArray(field(o, "matches"), "matches").map((x) => asSpan(x, "match")) };
}

export function replace(t: string, pattern: string, replacement: string, syntax: Syntax, ignoreCase: boolean,
    selS: number, selE: number, all: boolean): ReplaceResult {
    const o = asRecord(json("ml_replace", [t, pattern, replacement], SYNTAX[syntax], ignoreCase ? 1 : 0, selS, selE, all ? 1 : 0), "replace");
    const bad = failure(o);
    if (bad) return bad;
    const replaced: Replaced = { count: numField(o, "count") };
    const body = field(o, "text");
    if (typeof body === "string") replaced.text = body;
    const sel = field(o, "selection");
    if (sel !== undefined) replaced.selection = asSpan(sel, "selection");
    return replaced;
}

export function sam(command: string, t: string, selS: number, selE: number, ignoreCase: boolean): SamResult {
    const o = asRecord(json("ml_sam", [command, t], selS, selE, ignoreCase ? 1 : 0), "sam");
    const bad = failure(o);
    if (bad) return bad;
    const body = field(o, "text");
    return {
        text: body === null ? null : asString(body, "text"), selection: asSpan(field(o, "selection"), "selection"),
        printed: asStrings(field(o, "printed"), "printed"), summary: strField(o, "summary"),
    };
}

function asDiffOp(v: unknown): DiffOp {
    if (v === "same" || v === "add" || v === "remove") return v;
    throw new Error("The core gave an unknown diff operation");
}

export function diff(a: string, b: string): DiffLine[] {
    return asArray(json("ml_diff", [a, b]), "diff").map((x) => {
        const o = asRecord(x, "diff line");
        const line: DiffLine = { op: asDiffOp(field(o, "op")), text: strField(o, "text") };
        const old = field(o, "old");
        const created = field(o, "new");
        if (typeof old === "number") line.old = old;
        if (typeof created === "number") line.new = created;
        return line;
    });
}
export const commitMessage = (a: string, b: string): string => text("ml_commit_message", [a, b]);

export const vimReset = (): number => plain("ml_vim_reset", []);
export const vimClipboard = (t: string): number => plain("ml_vim_clipboard", [t]);

function asVimMode(v: unknown): VimMode {
    if (v === "normal" || v === "insert" || v === "visual" || v === "visual-line" || v === "command") return v;
    throw new Error("The core gave an unknown Vim mode");
}

function asVimAction(v: unknown): VimAction {
    if (v === "" || v === "save" || v === "discard" || v === "copy") return v;
    throw new Error("The core gave an unknown Vim action");
}

export function vimKey(t: string, selS: number, selE: number, key: string): VimKeyResult {
    const o = asRecord(json("ml_vim_key", [t, key], selS, selE), "vim key");
    const body = field(o, "text");
    const r: VimKeyResult = {
        handled: boolField(o, "handled"), text: body === null ? null : asString(body, "text"),
        cursor: numField(o, "cursor"), sel: asSpan(field(o, "sel"), "sel"), mode: asVimMode(field(o, "mode")),
        status: strField(o, "status"), action: asVimAction(field(o, "action")),
    };
    const clip = field(o, "clip");
    if (typeof clip === "string") r.clip = clip;
    return r;
}

export const zipBegin = (): number => plain("ml_zip_begin", []);
export const zipAdd = (name: string, data: Input, mtime: number): number => plain("ml_zip_add", [name, data], mtime);
export const zipTake = (): Uint8Array => bytes("ml_zip_take", []);
export const zipFinish = (): Uint8Array => bytes("ml_zip_finish", []);

const CHUNK = 1 << 20;

async function crc32(blob: Blob): Promise<number> {
    let crc = 0;
    for (let i = 0; i < blob.size; i += CHUNK) {
        const part = new Uint8Array(await blob.slice(i, i + CHUNK).arrayBuffer());
        crc = plain("ml_crc32", [part], crc);
    }
    return crc;
}

export async function zipAddBlob(name: string, blob: Blob, mtime: number): Promise<(Uint8Array | Blob)[] | null> {
    const crc = await crc32(blob);
    const head = bytes("ml_zip_add_ref", [name], blob.size, crc, mtime);
    return head.length ? [head, blob] : null;
}

interface PackAsset {
    path: string;
    method: number;
    offset: number;
    csize: number;
    usize: number;
    crc: number;
}

function parsePackAsset(v: unknown): PackAsset {
    const o = asRecord(v, "pack asset");
    return {
        path: strField(o, "path"), method: numField(o, "method"), offset: numField(o, "offset"),
        csize: numField(o, "csize"), usize: numField(o, "usize"), crc: numField(o, "crc"),
    };
}

const DEFLATE_METHOD = 8;

export async function packImport(zipBlob: Blob): Promise<PackResult> {
    const m = mod();
    const z = new Uint8Array(await zipBlob.arrayBuffer());
    const p = m._ml_in_alloc(0, z.length);
    m.HEAPU8.set(z, p);
    const r = m._ml_pack_import_arg(lenPtr);
    const n = readLength(m, lenPtr);
    const raw = asRecord(parseJSON(decoder.decode(m.HEAPU8.slice(r, r + n))), "pack");
    m._ml_in_alloc(0, 0);
    const bad = failure(raw);
    if (bad) return bad;
    const warnings = asStrings(field(raw, "warnings"), "warnings");
    const assets: Record<string, Blob> = {};
    for (const a of asArray(field(raw, "assets"), "assets").map(parsePackAsset)) {
        let data = zipBlob.slice(a.offset, a.offset + a.csize);
        if (a.method === DEFLATE_METHOD)
            data = await new Response(data.stream().pipeThrough(new DecompressionStream("deflate-raw"))).blob();
        if (data.size !== a.usize || (await crc32(data)) >>> 0 !== a.crc >>> 0) {
            warnings.push("Skipped " + a.path + ": the file is damaged.");
            continue;
        }
        assets[a.path] = data;
    }
    return { markdownName: strField(raw, "markdownName"), markdown: strField(raw, "markdown"), assets, warnings };
}

export const gitBegin = (name: string, email: string, mtime: number): number => plain("ml_git_begin", [name, email], mtime);
export const gitFile = (path: string, data: Input): boolean => plain("ml_git_file", [path, data]) !== 0;
export const gitCommit = (message: string, time: number, tzMinutes: number): string => text("ml_git_commit", [message], time, tzMinutes);
export const gitFinish = (mtime: number): number => plain("ml_git_finish", [], mtime);

export async function gitFileBlob(path: string, blob: Blob, mtime: number, seen: Set<string>): Promise<(Uint8Array | Blob)[] | null> {
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

export function utf8Offset(s: string, u16: number): number { return encoder.encode(s.slice(0, u16)).length; }
export function utf16Offset(s: string, u8: number): number {
    const b = encoder.encode(s);
    return decoder.decode(b.subarray(0, u8)).length;
}
