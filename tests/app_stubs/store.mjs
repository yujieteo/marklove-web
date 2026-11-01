// A memory store for app.js: two writable projects. `log` records every save.
export const log = [];
const db = {
    a: { id: "a", name: "A", markdown: "alpha\n", isListener: false },
    b: { id: "b", name: "B", markdown: "beta\n", isListener: false },
};
export const settings = { vimEnabled: true, themeID: "", appearance: "light", editorTextScale: 1, editorLineSpacing: 1, wrapLines: true, showLineCount: false, gitEnabled: false, slideStyle: "normal", onboardingSeen: true, lastProject: "a" };
export const open = async () => {};
export const projects = async () => Object.values(db);
export const project = async (id) => ({ ...db[id] });
export const saveProject = async (p) => { log.push(p.id + ":" + p.markdown); db[p.id] = { ...p }; };
export const assetBlobs = async () => ({});
export const setSetting = (k, v) => { settings[k] = v; };
export const editorState = () => null;
export const setEditorState = () => {};
export const versions = async () => [];
export const addVersion = async () => {};
export const addAsset = async () => {};
export const assetName = (n) => n;
export const createProject = async () => { throw new Error("unused"); };
export const deleteProject = async () => {};
export const duplicateProject = async () => { throw new Error("unused"); };
export const safeFileName = (n) => n;
