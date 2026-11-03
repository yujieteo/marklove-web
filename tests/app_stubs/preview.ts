import type * as Real from "../../src/preview.ts";

const previewStub = {
    loadParts: async (): Promise<void> => {},
    doc: (): Real.PageDoc => ({ source: "", assets: {}, fonts: "", style: "", script: "", appearance: "" }),
    slideAt: <T extends { s0: number; s1: number }>(outline: readonly T[]): T | undefined => outline[0],
    slideOptions: (): number => 0,
    speakerReady: (): ReturnType<typeof Real.speakerReady> => ({ error: "unused" }),
    listenerPreview: (): ReturnType<typeof Real.listenerPreview> => ({ error: "unused" }),
} satisfies Partial<typeof Real>;

class PageFrame {
    clear(): void {}
}

export const previewModule = { ...previewStub, PageFrame };
