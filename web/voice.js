// The Kokoro voice (KokoroNarration): the upstream web build of kokoro-js
// runs the Kokoro-82M ONNX model in the browser. The browser keeps the
// model files in its cache after the first download.

const KOKORO = "https://cdn.jsdelivr.net/npm/kokoro-js@1.2.1/dist/kokoro.web.js";
const MODEL = "onnx-community/Kokoro-82M-v1.0-ONNX";
const CACHE = "transformers-cache";
export const DEFAULT_VOICE = "af_heart";
export const SAMPLE_RATE = 24000;
export const SIZE_TEXT = "about 90 MB";

let tts = null;
let loading = null;

// Loads the model. progress receives values from 0 to 1 while it downloads.
export function load(progress) {
    if (tts) return Promise.resolve(tts);
    if (!loading) {
        loading = (async () => {
            const { KokoroTTS } = await import(KOKORO);
            const files = new Map();
            tts = await KokoroTTS.from_pretrained(MODEL, {
                dtype: "q8", device: "wasm",
                progress_callback: (e) => {
                    if (e.status !== "progress" || !e.total) return;
                    files.set(e.file, [e.loaded, e.total]);
                    let a = 0, b = 0;
                    for (const [l, t] of files.values()) { a += l; b += t; }
                    progress?.(a / b);
                },
            });
            return tts;
        })().catch((e) => { loading = null; throw e; });
    }
    return loading;
}

// True when the browser has the model files.
export async function installed() {
    if (tts) return true;
    try {
        const c = await caches.open(CACHE);
        return (await c.keys()).some((r) => r.url.includes("Kokoro-82M"));
    } catch { return false; }
}

export async function remove() {
    tts = null;
    loading = null;
    try { await caches.delete(CACHE); } catch { /* no cache */ }
}

// The voice of the project, if the web build has it.
export function voiceFor(name) {
    return tts && name && tts.voices[name] ? name : DEFAULT_VOICE;
}

// Speaks one sentence: mono samples at SAMPLE_RATE.
export async function synthesize(text, voice) {
    const t = await load();
    const audio = await t.generate(text, { voice: voiceFor(voice) });
    return audio.audio;
}

// The clips of one export run: the narrated video and the podcast speak the
// same sentences. Export calls forget at the end of each run.
let spoken = new Map();
export function forget() { spoken = new Map(); }

// Speaks each sentence once (NarrationAudio.clips). Returns a Map from the
// sentence to its samples, and the "sentence\tseconds" lines for the core.
export async function clips(sentences, voice, progress) {
    const out = new Map();
    const unique = [...new Set(sentences)];
    for (let k = 0; k < unique.length; k++) {
        const key = voiceFor(voice) + "\n" + unique[k];
        if (!spoken.has(key)) spoken.set(key, await synthesize(unique[k], voice));
        out.set(unique[k], spoken.get(key));
        progress?.((k + 1) / unique.length);
    }
    const durations = [...out].map(([s, a]) => `${s}\t${(a.length / SAMPLE_RATE).toFixed(4)}\n`).join("");
    return { clips: out, durations };
}

// Places each clip at the start of its cue (NarrationAudio.mix).
export function mix(cues, clips, duration) {
    const out = new Float32Array(Math.floor((duration + 0.5) * SAMPLE_RATE));
    for (const c of cues) {
        const clip = clips.get(c.text);
        if (!clip) continue;
        const start = Math.max(0, Math.floor(c.start * SAMPLE_RATE));
        for (let i = 0; i < clip.length && start + i < out.length; i++) out[start + i] += clip[i];
    }
    for (let i = 0; i < out.length; i++) out[i] = Math.max(-1, Math.min(1, out[i]));
    return out;
}

// Plays one sentence (Play a Sample).
export async function playSample(voice) {
    const a = await synthesize("This is the voice of your narration. It speaks the text of your slides.", voice);
    const ctx = new AudioContext({ sampleRate: SAMPLE_RATE });
    const buf = ctx.createBuffer(1, a.length, SAMPLE_RATE);
    buf.copyToChannel(a, 0);
    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.connect(ctx.destination);
    await new Promise((res) => { src.onended = res; src.start(); });
    await ctx.close();
}
