// Storage: projects, media and versions in IndexedDB, and settings in
// localStorage. Media stay Blobs; the core gets blob: URLs for them.

const DB_NAME = "marklove";
let db = null;

function req(r) {
    return new Promise((resolve, reject) => {
        r.onsuccess = () => resolve(r.result);
        r.onerror = () => reject(r.error);
    });
}

export async function open() {
    if (db) return;
    const r = indexedDB.open(DB_NAME, 1);
    r.onupgradeneeded = () => {
        const d = r.result;
        d.createObjectStore("projects", { keyPath: "id" });
        const a = d.createObjectStore("assets", { keyPath: ["project", "path"] });
        a.createIndex("project", "project");
        const v = d.createObjectStore("versions", { keyPath: "id", autoIncrement: true });
        v.createIndex("project", "project");
    };
    db = await req(r);
}

function tx(stores, mode = "readonly") {
    const t = db.transaction(stores, mode);
    const done = new Promise((resolve, reject) => {
        t.oncomplete = () => resolve();
        t.onerror = () => reject(t.error);
        t.onabort = () => reject(t.error || new Error("The change was not saved."));
    });
    return { t, done, s: (n) => t.objectStore(n) };
}

// --- projects -------------------------------------------------------------

export async function projects() {
    const { s } = tx(["projects"]);
    const all = await req(s("projects").getAll());
    return all.sort((a, b) => b.modified - a.modified);
}

export async function project(id) {
    const { s } = tx(["projects"]);
    return req(s("projects").get(id));
}

export function safeFileName(title) {
    const cleaned = String(title).replace(/[\/\\:*?"<>|\n\r\t]/g, "-").trim().slice(0, 80);
    return !cleaned || cleaned.startsWith(".") ? "Marklove" : cleaned;
}

export async function uniqueName(base) {
    const clean = safeFileName(base);
    const names = new Set((await projects()).map((p) => p.name.toLowerCase()));
    let name = clean, n = 2;
    while (names.has(name.toLowerCase())) name = clean + " " + n++;
    return name;
}

export async function createProject({ name, markdown = "", assets = {}, demo = false, listener = false }) {
    const unique = await uniqueName(name || "Untitled");
    const p = { id: crypto.randomUUID(), name: unique, markdown, modified: Date.now(), isDemo: demo, isListener: listener };
    const { s, done } = tx(["projects", "assets"], "readwrite");
    s("projects").put(p);
    for (const [path, blob] of Object.entries(assets)) {
        const clean = normalizePath(path);
        if (clean) s("assets").put({ project: p.id, path: clean, blob });
    }
    await done;
    return p;
}

export async function saveProject(p) {
    p.modified = Date.now();
    const { s, done } = tx(["projects"], "readwrite");
    s("projects").put(p);
    await done;
}

export async function deleteProject(id) {
    const { s, done } = tx(["projects", "assets", "versions"], "readwrite");
    s("projects").delete(id);
    for (const store of ["assets", "versions"]) {
        const keys = await req(s(store).index("project").getAllKeys(id));
        for (const k of keys) s(store).delete(k);
    }
    await done;
}

export async function duplicateProject(p) {
    const assets = await assetBlobs(p.id);
    return createProject({ name: p.name + " copy", markdown: p.markdown, assets });
}

// --- media ------------------------------------------------------------------

// A project path such as images/x.png: no "..", no leading "/", no hidden parts.
export function normalizePath(path) {
    const parts = String(path).replace(/\\/g, "/").split("/").filter((x) => x && x !== ".");
    if (!parts.length || parts.some((x) => x === ".." || x.startsWith("."))) return null;
    return parts.join("/");
}

export async function assetBlobs(projectId) {
    const { s } = tx(["assets"]);
    const rows = await req(s("assets").index("project").getAll(projectId));
    const out = {};
    for (const r of rows) out[r.path] = r.blob;
    return out;
}

export async function addAsset(projectId, path, blob) {
    const { s, done } = tx(["assets"], "readwrite");
    s("assets").put({ project: projectId, path, blob });
    await done;
}

// A new file name in a folder of the project, as ProjectStore.addAsset.
export function assetName(existing, folder, fileName, ext) {
    let base = fileName.replace(/\.[^.]*$/, "").replace(/ /g, "-").replace(/[^\p{L}\p{N}_-]/gu, "") || "file";
    let name = folder + "/" + base + "." + ext, n = 2;
    while (existing[name]) name = folder + "/" + base + "-" + n++ + "." + ext;
    return name;
}

// --- versions ---------------------------------------------------------------

// Newest first.
export async function versions(projectId) {
    const { s } = tx(["versions"]);
    const rows = await req(s("versions").index("project").getAll(projectId));
    return rows.sort((a, b) => b.time - a.time || b.id - a.id);
}

export async function addVersion(v) {
    const { s, done } = tx(["versions"], "readwrite");
    s("versions").add(v);
    await done;
}

// --- settings ---------------------------------------------------------------

const DEFAULTS = {
    themeID: "selenized", appearance: "system", editorTextScale: 1, editorLineSpacing: 1.4,
    vimEnabled: false, slideStyle: "normal", showLineCount: true, wrapLines: true,
    gitEnabled: true, gitName: "", gitEmail: "", findSyntax: "sam", onboardingSeen: false,
    lastProject: "", increaseContrast: false,
};

function readSettings() {
    try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem("marklove.settings") || "{}") }; }
    catch { return { ...DEFAULTS }; }
}

export const settings = readSettings();

export function setSetting(key, value) {
    settings[key] = value;
    try { localStorage.setItem("marklove.settings", JSON.stringify(settings)); } catch { /* private window */ }
}

export function editorState(id) {
    try { return JSON.parse(localStorage.getItem("marklove.editorState") || "{}")[id] || null; } catch { return null; }
}

export function setEditorState(id, value) {
    try {
        const all = JSON.parse(localStorage.getItem("marklove.editorState") || "{}");
        if (value) all[id] = value; else delete all[id];
        localStorage.setItem("marklove.editorState", JSON.stringify(all));
    } catch { /* private window */ }
}
