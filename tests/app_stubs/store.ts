import type * as Real from "../../src/store.ts";

export const log: string[] = [];
export const failSaves = { remaining: 0 };

const db: Record<string, Real.Project> = {
    a: { id: "a", name: "A", markdown: "alpha\n", modified: 0, isDemo: false, isListener: false },
    b: { id: "b", name: "B", markdown: "beta\n", modified: 0, isDemo: false, isListener: false },
};

function stored(id: string): Real.Project | undefined {
    return db[id];
}

const settings: Real.Settings = {
    themeID: "", appearance: "light", editorTextScale: 1, editorLineSpacing: 1, vimEnabled: true,
    slideStyle: "normal", showLineCount: false, wrapLines: true, gitEnabled: false, gitName: "", gitEmail: "",
    findSyntax: "sam", onboardingSeen: true, lastProject: "a", increaseContrast: false,
};

export const storeStub = {
    settings,
    open: async (): Promise<void> => {},
    projects: async (): Promise<Real.Project[]> => Object.values(db),
    project: async (id: string): Promise<Real.Project | undefined> => {
        const p = stored(id);
        return p ? { ...p } : undefined;
    },
    saveProject: async (p: Real.Project): Promise<void> => {
        if (failSaves.remaining > 0) {
            failSaves.remaining--;
            throw new Error("The storage is full.");
        }
        log.push(p.id + ":" + p.markdown);
        db[p.id] = { ...p };
    },
    assetBlobs: async (): Promise<Record<string, Blob>> => ({}),
    setSetting: <K extends keyof Real.Settings>(k: K, v: Real.Settings[K]): void => { settings[k] = v; },
    editorState: (): Real.EditorState | null => null,
    setEditorState: (): void => {},
    versions: async (): Promise<Real.Version[]> => [],
    addVersion: async (): Promise<void> => {},
    addAsset: async (): Promise<void> => {},
    assetName: (_existing: Record<string, unknown>, _folder: string, fileName: string): string => fileName,
    createProject: async ({ name = "Untitled", markdown = "" }: Real.NewProject): Promise<Real.Project> => {
        const id = "p" + Object.keys(db).length;
        db[id] = { id, name, markdown, modified: 0, isDemo: false, isListener: false };
        return { ...db[id] };
    },
    deleteProject: async (): Promise<void> => {},
    duplicateProject: async (): Promise<Real.Project> => { throw new Error("unused"); },
    safeFileName: (n: string): string => n,
} satisfies Partial<typeof Real>;
