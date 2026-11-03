import type * as Real from "../../src/find.ts";

const idle: Real.FindState = {
    open: false, showsReplace: false, showsCommand: false, matchCase: false,
    query: "", replacement: "", command: "",
    matches: [], current: -1, error: "", lastCount: null,
    commandOutput: [], commandStatus: "", commandError: "",
};

export const findStub = {
    find: idle,
    initFind: (): void => {},
    next: (): void => {},
    openFind: (): void => {},
    refresh: (): void => {},
    syntaxChanged: (): void => {},
    textChanged: (): void => {},
} satisfies Partial<typeof Real>;
