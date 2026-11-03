import { isRecord } from "./dom.ts";

const KOKORO = "https://cdn.jsdelivr.net/npm/kokoro-js@1.2.1/dist/kokoro.web.js";
const MODEL = "onnx-community/Kokoro-82M-v1.0-ONNX";
const CACHE = "transformers-cache";
const QUANTIZED_MODEL_SUFFIX = "/onnx/model_quantized.onnx";
export const DEFAULT_VOICE = "af_heart";
export const SAMPLE_RATE = 24000;
export const SIZE_TEXT = "about 90 MB";
const SAMPLE_TEXT = "This is the voice of your narration. It speaks the text of your slides.";
const MIX_TAIL_SECONDS = 0.5;

export interface Narrator {
    voices: Record<string, unknown>;
    generate(text: string, voice: string): Promise<Float32Array<ArrayBuffer>>;
}

export interface Cue {
    text: string;
    start: number;
}

export interface Clips {
    clips: Map<string, Float32Array<ArrayBuffer>>;
    durations: string;
}

function method(owner: object, name: string): (...args: unknown[]) => unknown {
    const fn: unknown = Reflect.get(owner, name);
    if (typeof fn !== "function") throw new Error("The voice library has no " + name + ".");
    return (...args) => Reflect.apply(fn, owner, args);
}

function toNarrator(v: unknown): Narrator {
    if (!isRecord(v) || !isRecord(v["voices"])) throw new Error("The voice library gave an unknown voice model.");
    const voices = v["voices"];
    const generate = method(v, "generate");
    return {
        voices,
        async generate(text, voice) {
            const out = await generate(text, { voice });
            if (!isRecord(out) || !(out["audio"] instanceof Float32Array)) throw new Error("The voice gave no audio.");
            return Float32Array.from(out["audio"]);
        },
    };
}

let tts: Narrator | null = null;
let loading: Promise<Narrator> | null = null;

export function load(progress?: (fraction: number) => void): Promise<Narrator> {
    if (tts) return Promise.resolve(tts);
    if (!loading) {
        loading = (async () => {
            const lib: unknown = await import(KOKORO);
            if (!isRecord(lib) || typeof lib["KokoroTTS"] !== "function") throw new Error("The voice library did not load.");
            const files = new Map<string, [number, number]>();
            const model = await method(lib["KokoroTTS"], "from_pretrained")(MODEL, {
                dtype: "q8", device: "wasm",
                progress_callback: (e: unknown) => {
                    if (!isRecord(e) || e["status"] !== "progress") return;
                    const { file, loaded, total } = e;
                    if (typeof file !== "string" || typeof loaded !== "number" || typeof total !== "number" || !total) return;
                    files.set(file, [loaded, total]);
                    let a = 0, b = 0;
                    for (const [l, t] of files.values()) { a += l; b += t; }
                    if (progress) progress(a / b);
                },
            });
            tts = toNarrator(model);
            return tts;
        })().catch((e: unknown) => { loading = null; throw e; });
    }
    return loading;
}

export async function installed(): Promise<boolean> {
    if (tts) return true;
    try {
        const c = await caches.open(CACHE);
        return (await c.keys()).some((r) => r.url.includes(MODEL + "/") && r.url.endsWith(QUANTIZED_MODEL_SUFFIX));
    } catch { return false; }
}

export async function remove(): Promise<void> {
    tts = null;
    loading = null;
    try { await caches.delete(CACHE); } catch { return; }
}

export function voiceFor(name: string | null | undefined): string {
    return tts && name && tts.voices[name] ? name : DEFAULT_VOICE;
}

async function synthesize(text: string, voice: string | null | undefined): Promise<Float32Array<ArrayBuffer>> {
    const t = await load();
    return t.generate(text, voiceFor(voice));
}

let spoken = new Map<string, Float32Array<ArrayBuffer>>();
export function forget(): void { spoken = new Map(); }

export async function clips(sentences: string[], voice: string | null | undefined, progress?: (fraction: number) => void): Promise<Clips> {
    const out = new Map<string, Float32Array<ArrayBuffer>>();
    const unique = [...new Set(sentences)];
    for (const [k, sentence] of unique.entries()) {
        const key = voiceFor(voice) + "\n" + sentence;
        let audio = spoken.get(key);
        if (!audio) {
            audio = await synthesize(sentence, voice);
            spoken.set(key, audio);
        }
        out.set(sentence, audio);
        if (progress) progress((k + 1) / unique.length);
    }
    const durations = [...out].map(([s, a]) => `${s}\t${(a.length / SAMPLE_RATE).toFixed(4)}\n`).join("");
    return { clips: out, durations };
}

export function mix(cues: readonly Cue[], clips: Map<string, Float32Array>, duration: number): Float32Array {
    const out = new Float32Array(Math.floor((duration + MIX_TAIL_SECONDS) * SAMPLE_RATE));
    for (const c of cues) {
        const clip = clips.get(c.text);
        if (!clip) continue;
        const start = Math.max(0, Math.floor(c.start * SAMPLE_RATE));
        for (let i = 0; i < clip.length && start + i < out.length; i++) out[start + i] = (out[start + i] ?? 0) + (clip[i] ?? 0);
    }
    for (let i = 0; i < out.length; i++) out[i] = Math.max(-1, Math.min(1, out[i] ?? 0));
    return out;
}

export async function playSample(voice: string | null | undefined): Promise<void> {
    const a = await synthesize(SAMPLE_TEXT, voice);
    const ctx = new AudioContext({ sampleRate: SAMPLE_RATE });
    const buf = ctx.createBuffer(1, a.length, SAMPLE_RATE);
    buf.copyToChannel(a, 0);
    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.connect(ctx.destination);
    await new Promise<void>((res) => { src.onended = () => res(); src.start(); });
    await ctx.close();
}
