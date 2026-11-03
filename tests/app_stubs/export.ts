import type * as Real from "../../src/export.ts";

export const exportStub = {
    exportSheet: (): void => {},
    projectZip: async (): Promise<Blob> => new Blob(),
} satisfies Partial<typeof Real>;
