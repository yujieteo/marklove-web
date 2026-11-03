import type * as Real from "../../src/panels.ts";

const none = (): void => {};

export const panelsStub = {
    customizePanel: none,
    helpPanel: none,
    historyPanel: async (): Promise<void> => {},
    outlinePanel: none,
    projectsPanel: async (): Promise<void> => {},
    renamePanel: none,
    settingsPanel: none,
    welcome: none,
} satisfies Partial<typeof Real>;
