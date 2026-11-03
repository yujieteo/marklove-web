import { test, expect, mock } from "bun:test";

const KOKORO_URL = "https://cdn.jsdelivr.net/npm/kokoro-js@1.2.1/dist/kokoro.web.js";

let releaseModel: () => void = () => {};
const modelReady = new Promise<void>((resolve) => { releaseModel = resolve; });

mock.module(KOKORO_URL, () => ({
    KokoroTTS: class KokoroTTS {
        static async from_pretrained(): Promise<unknown> {
            await modelReady;
            return { voices: { af_heart: {} }, generate: async () => ({ audio: new Float32Array(1) }) };
        }
    },
}));

const Voice = await import("../src/voice.ts");

test("load gives a narrator when KokoroTTS is a class", async () => {
    const loading = Voice.load();
    releaseModel();
    const narrator = await loading;
    expect(await narrator.generate("Hello.", Voice.DEFAULT_VOICE)).toBeInstanceOf(Float32Array);
    await Voice.remove();
});

test.failing("voice.sm.md row loading/remove: the voice stays removed when remove runs during the download", async () => {
    const loading = Voice.load();
    await Voice.remove();
    releaseModel();
    await loading;
    expect(await Voice.installed()).toBe(false);
});
