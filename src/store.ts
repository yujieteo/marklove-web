import { isRecord, must } from "./dom.ts";

const DB_NAME = "marklove";
const DB_VERSION = 1;
const SETTINGS_KEY = "marklove.settings";
const EDITOR_STATE_KEY = "marklove.editorState";

export interface Project {
    id: string;
    name: string;
    markdown: string;
    modified: number;
    isDemo: boolean;
    isListener: boolean;
}

export interface NewVersion {
    project: string;
    time: number;
    message: string;
    markdown: string;
    assets: string[];
}

export interface Version extends NewVersion {
    id: number;
}

export interface NewProject {
    name?: string | undefined;
    markdown?: string | undefined;
    assets?: Record<string, Blob> | undefined;
    demo?: boolean | undefined;
    listener?: boolean | undefined;
}

export interface EditorState {
    s: number;
    e: number;
    top: number;
}

export type Appearance = "system" | "light" | "dark";
export type SlideStyle = "normal" | "takahashi";
export type FindSyntax = "sam" | "vim" | "plain";

export interface Settings {
    themeID: string;
    appearance: Appearance;
    editorTextScale: number;
    editorLineSpacing: number;
    vimEnabled: boolean;
    slideStyle: SlideStyle;
    showLineCount: boolean;
    wrapLines: boolean;
    gitEnabled: boolean;
    gitName: string;
    gitEmail: string;
    findSyntax: FindSyntax;
    onboardingSeen: boolean;
    lastProject: string;
    increaseContrast: boolean;
}

let db: IDBDatabase | null = null;

function req(r: IDBRequest): Promise<unknown> {
    return new Promise((resolve, reject) => {
        r.onsuccess = () => resolve(r.result);
        r.onerror = () => reject(r.error);
    });
}

export async function open(): Promise<void> {
    if (db) return;
    const r = indexedDB.open(DB_NAME, DB_VERSION);
    r.onupgradeneeded = () => {
        const d = r.result;
        d.createObjectStore("projects", { keyPath: "id" });
        const a = d.createObjectStore("assets", { keyPath: ["project", "path"] });
        a.createIndex("project", "project");
        const v = d.createObjectStore("versions", { keyPath: "id", autoIncrement: true });
        v.createIndex("project", "project");
    };
    const opened = await req(r);
    if (!(opened instanceof IDBDatabase)) throw new Error("The database did not open.");
    db = opened;
}

function tx(stores: string[], mode: IDBTransactionMode = "readonly") {
    const t = must(db, "open database").transaction(stores, mode);
    const done = new Promise<void>((resolve, reject) => {
        t.oncomplete = () => resolve();
        t.onerror = () => reject(t.error);
        t.onabort = () => reject(t.error || new Error("The change was not saved."));
    });
    return { t, done, s: (n: string) => t.objectStore(n) };
}

function isProject(v: unknown): v is Project {
    return isRecord(v) && typeof v["id"] === "string" && typeof v["name"] === "string" && typeof v["markdown"] === "string"
        && typeof v["modified"] === "number" && typeof v["isDemo"] === "boolean" && typeof v["isListener"] === "boolean";
}

function isVersion(v: unknown): v is Version {
    return isRecord(v) && typeof v["id"] === "number" && typeof v["project"] === "string" && typeof v["time"] === "number"
        && typeof v["message"] === "string" && typeof v["markdown"] === "string"
        && Array.isArray(v["assets"]) && v["assets"].every((x) => typeof x === "string");
}

interface AssetRow {
    project: string;
    path: string;
    blob: Blob;
}

function isAssetRow(v: unknown): v is AssetRow {
    return isRecord(v) && typeof v["project"] === "string" && typeof v["path"] === "string" && v["blob"] instanceof Blob;
}

function rows<T>(v: unknown, guard: (x: unknown) => x is T): T[] {
    if (!Array.isArray(v)) throw new Error("The database gave no list.");
    return v.map((x): T => {
        if (!guard(x)) throw new Error("The database gave a damaged row.");
        return x;
    });
}

export async function projects(): Promise<Project[]> {
    const { s } = tx(["projects"]);
    const all = rows(await req(s("projects").getAll()), isProject);
    return all.sort((a, b) => b.modified - a.modified);
}

export async function project(id: string): Promise<Project | undefined> {
    const { s } = tx(["projects"]);
    const row = await req(s("projects").get(id));
    if (row === undefined) return undefined;
    if (!isProject(row)) throw new Error("The database gave a damaged project.");
    return row;
}

export function safeFileName(title: string): string {
    const cleaned = String(title).replace(/[\/\\:*?"<>|\n\r\t]/g, "-").trim().slice(0, 80);
    return !cleaned || cleaned.startsWith(".") ? "Marklove" : cleaned;
}

async function uniqueName(base: string): Promise<string> {
    const clean = safeFileName(base);
    const names = new Set((await projects()).map((p) => p.name.toLowerCase()));
    let name = clean, n = 2;
    while (names.has(name.toLowerCase())) name = clean + " " + n++;
    return name;
}

export async function createProject({ name, markdown = "", assets = {}, demo = false, listener = false }: NewProject): Promise<Project> {
    const unique = await uniqueName(name || "Untitled");
    const p: Project = { id: crypto.randomUUID(), name: unique, markdown, modified: Date.now(), isDemo: demo, isListener: listener };
    const { s, done } = tx(["projects", "assets"], "readwrite");
    s("projects").put(p);
    for (const [path, blob] of Object.entries(assets)) {
        const clean = normalizePath(path);
        if (clean) s("assets").put({ project: p.id, path: clean, blob });
    }
    await done;
    return p;
}

export async function saveProject(p: Project): Promise<void> {
    p.modified = Date.now();
    const { s, done } = tx(["projects"], "readwrite");
    s("projects").put(p);
    await done;
}

export async function deleteProject(id: string): Promise<void> {
    const { s, done } = tx(["projects", "assets", "versions"], "readwrite");
    s("projects").delete(id);
    for (const store of ["assets", "versions"]) {
        const keys = await req(s(store).index("project").getAllKeys(id));
        if (!Array.isArray(keys)) throw new Error("The database gave no list.");
        for (const k of keys) s(store).delete(k);
    }
    await done;
}

export async function duplicateProject(p: Project): Promise<Project> {
    const assets = await assetBlobs(p.id);
    return createProject({ name: p.name + " copy", markdown: p.markdown, assets });
}

function normalizePath(path: string): string | null {
    const parts = String(path).replace(/\\/g, "/").split("/").filter((x) => x && x !== ".");
    if (!parts.length || parts.some((x) => x === ".." || x.startsWith("."))) return null;
    return parts.join("/");
}

export async function assetBlobs(projectId: string): Promise<Record<string, Blob>> {
    const { s } = tx(["assets"]);
    const found = rows(await req(s("assets").index("project").getAll(projectId)), isAssetRow);
    const out: Record<string, Blob> = {};
    for (const r of found) out[r.path] = r.blob;
    return out;
}

export async function addAsset(projectId: string, path: string, blob: Blob): Promise<void> {
    const { s, done } = tx(["assets"], "readwrite");
    s("assets").put({ project: projectId, path, blob });
    await done;
}

export function assetName(existing: Record<string, unknown>, folder: string, fileName: string, ext: string): string {
    const base = fileName.replace(/\.[^.]*$/, "").replace(/ /g, "-").replace(/[^\p{L}\p{N}_-]/gu, "") || "file";
    let name = folder + "/" + base + "." + ext, n = 2;
    while (existing[name]) name = folder + "/" + base + "-" + n++ + "." + ext;
    return name;
}

export async function versions(projectId: string): Promise<Version[]> {
    const { s } = tx(["versions"]);
    const found = rows(await req(s("versions").index("project").getAll(projectId)), isVersion);
    return found.sort((a, b) => b.time - a.time || b.id - a.id);
}

export async function addVersion(v: NewVersion): Promise<void> {
    const { s, done } = tx(["versions"], "readwrite");
    s("versions").add(v);
    await done;
}

const DEFAULTS: Settings = {
    themeID: "selenized", appearance: "system", editorTextScale: 1, editorLineSpacing: 1.4,
    vimEnabled: false, slideStyle: "normal", showLineCount: true, wrapLines: true,
    gitEnabled: true, gitName: "", gitEmail: "", findSyntax: "sam", onboardingSeen: false,
    lastProject: "", increaseContrast: false,
};

function readStorage(key: string): unknown {
    try {
        const raw = localStorage.getItem(key);
        return raw === null ? {} : JSON.parse(raw);
    } catch { return {}; }
}

function pickString(o: Record<string, unknown>, key: string, fallback: string): string {
    const v = o[key];
    return typeof v === "string" ? v : fallback;
}

function pickNumber(o: Record<string, unknown>, key: string, fallback: number): number {
    const v = o[key];
    return typeof v === "number" ? v : fallback;
}

function pickBool(o: Record<string, unknown>, key: string, fallback: boolean): boolean {
    const v = o[key];
    return typeof v === "boolean" ? v : fallback;
}

function readSettings(): Settings {
    const stored = readStorage(SETTINGS_KEY);
    const o = isRecord(stored) ? stored : {};
    const appearance = o["appearance"];
    const slideStyle = o["slideStyle"];
    const findSyntax = o["findSyntax"];
    return {
        themeID: pickString(o, "themeID", DEFAULTS.themeID),
        appearance: appearance === "system" || appearance === "light" || appearance === "dark" ? appearance : DEFAULTS.appearance,
        editorTextScale: pickNumber(o, "editorTextScale", DEFAULTS.editorTextScale),
        editorLineSpacing: pickNumber(o, "editorLineSpacing", DEFAULTS.editorLineSpacing),
        vimEnabled: pickBool(o, "vimEnabled", DEFAULTS.vimEnabled),
        slideStyle: slideStyle === "normal" || slideStyle === "takahashi" ? slideStyle : DEFAULTS.slideStyle,
        showLineCount: pickBool(o, "showLineCount", DEFAULTS.showLineCount),
        wrapLines: pickBool(o, "wrapLines", DEFAULTS.wrapLines),
        gitEnabled: pickBool(o, "gitEnabled", DEFAULTS.gitEnabled),
        gitName: pickString(o, "gitName", DEFAULTS.gitName),
        gitEmail: pickString(o, "gitEmail", DEFAULTS.gitEmail),
        findSyntax: findSyntax === "sam" || findSyntax === "vim" || findSyntax === "plain" ? findSyntax : DEFAULTS.findSyntax,
        onboardingSeen: pickBool(o, "onboardingSeen", DEFAULTS.onboardingSeen),
        lastProject: pickString(o, "lastProject", DEFAULTS.lastProject),
        increaseContrast: pickBool(o, "increaseContrast", DEFAULTS.increaseContrast),
    };
}

export const settings: Settings = readSettings();

export function setSetting<K extends keyof Settings>(key: K, value: Settings[K]): void {
    settings[key] = value;
    try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch { return; }
}

function isEditorState(v: unknown): v is EditorState {
    return isRecord(v) && typeof v["s"] === "number" && typeof v["e"] === "number" && typeof v["top"] === "number";
}

export function editorState(id: string): EditorState | null {
    const all = readStorage(EDITOR_STATE_KEY);
    if (!isRecord(all)) return null;
    const v = all[id];
    return isEditorState(v) ? v : null;
}

export function setEditorState(id: string, value: EditorState | null): void {
    try {
        const stored = readStorage(EDITOR_STATE_KEY);
        const all: Record<string, unknown> = isRecord(stored) ? stored : {};
        if (value) all[id] = value; else delete all[id];
        localStorage.setItem(EDITOR_STATE_KEY, JSON.stringify(all));
    } catch { return; }
}
