import * as G from "./pages.ts";
import * as V from "./voice.ts";
import * as P from "./preview.ts";
import { must } from "./dom.ts";

const W = 1920, H = 1080, FPS = 30, TRANSITION = 0.6, PLOT_DRAW = 1.4;
const BITRATE = 6_000_000, AUDIO_BITRATE = 64_000;
const SCALE = 600;
const A_NONE = 0, A_AAC = 1, A_OPUS = 2;
const RATE = 48000;

interface DrawTarget {
    globalAlpha: number;
    drawImage(image: CanvasImageSource, dx: number, dy: number): void;
}

type Draw = (ctx: DrawTarget) => Promise<void>;
type Frame = [time: number, draw: Draw];
type Progress = (p: number) => void;

interface VideoTrack {
    chunks: Uint8Array<ArrayBuffer>[];
    sizes: number[];
    keys: number[];
    times: number[];
    avcC: Uint8Array | null;
}

interface AudioTrack {
    chunks: Uint8Array<ArrayBuffer>[];
    sizes: number[];
    durs: number[];
    desc: Uint8Array;
    codec: number;
    rate: number;
}

export interface VideoResult {
    files: [string, Blob][];
    notes: string[];
}

interface FrameTrack {
    requestFrame(): void;
}

function isFrameTrack(t: MediaStreamTrack): t is MediaStreamTrack & FrameTrack {
    return "requestFrame" in t && typeof t.requestFrame === "function";
}

function hold(frames: Frame[], start: number, end: number, draw: Draw): void {
    let t = start, last = -1;
    const final = end - 1 / 30;
    while (t < final - 0.001) { frames.push([t, draw]); last = t; t += 1; }
    if (final - last > 0.5 / 30) frames.push([Math.max(start, final), draw]);
}

function frameList(pages: G.PageInfo[], timeline: G.Timeline, animated: boolean, m: G.Media, fonts: string): Frame[] {
    const cache = new Map<string, Promise<HTMLCanvasElement>>();
    const layer = (page: number, step: number, ly: number, progress = 1): Promise<HTMLCanvasElement> => {
        const key = [page, step, ly, progress].join(" ");
        let drawn = cache.get(key);
        if (!drawn) {
            if (cache.size > 64) cache.clear();
            const info = must(pages[page], "page " + page);
            drawn = G.raster(G.resolve(G.pageSVG(page, step, ly, progress, W / info.width), m, fonts), W, H);
            cache.set(key, drawn);
        }
        return drawn;
    };
    const frames: Frame[] = [];
    const segs = timeline.segments;
    segs.forEach((seg, k) => {
        const end = seg.start + seg.duration;
        const all: Draw = async (ctx) => ctx.drawImage(await layer(seg.page, seg.step, G.LY_ALL), 0, 0);
        if (!animated) { hold(frames, seg.start, end, all); return; }
        const fade = seg.step > 0 || k === 0 || segs[k - 1]?.page !== seg.page;
        const hasPlot = G.pageSVG(seg.page, seg.step, G.LY_GROW).replace(/^[\s\S]*?<\/style>\n(<filter[\s\S]*?<\/filter>\n)?/, "") !== "</svg>\n";
        const n = Math.round(TRANSITION * FPS), drawN = hasPlot ? Math.round(PLOT_DRAW * FPS) : n;
        const total = Math.min(Math.max(n, drawN), Math.floor(seg.duration * FPS) - 1);
        for (let f = 0; f < Math.max(total, 0); f++) {
            const t = f / Math.max(n, 1), plotT = Math.min(f / Math.max(drawN, 1), 1);
            const ease = t < 1 ? 0.5 - Math.cos(Math.min(t, 1) * Math.PI) / 2 : 1;
            frames.push([seg.start + f / FPS, async (ctx) => {
                ctx.drawImage(await layer(seg.page, seg.step, G.LY_BASE), 0, 0);
                ctx.globalAlpha = fade ? ease : 1;
                ctx.drawImage(await layer(seg.page, seg.step, G.LY_NEW), 0, 0);
                if (plotT >= 1) ctx.drawImage(await layer(seg.page, seg.step, G.LY_GROW), 0, 0);
                ctx.globalAlpha = 1;
                if (plotT < 1) ctx.drawImage(await layer(seg.page, seg.step, G.LY_GROW, Math.round(plotT * 1000) / 1000), 0, 0);
                if (seg.step > 0 && ease < 1) {
                    ctx.globalAlpha = 1 - ease;
                    ctx.drawImage(await layer(seg.page, seg.step, G.LY_LEAVE), 0, 0);
                    ctx.globalAlpha = 1;
                }
            }]);
        }
        hold(frames, seg.start + Math.max(total, 0) / FPS, end, all);
    });
    return frames;
}

const u32 = (values: number[]): Uint8Array => new Uint8Array(new Uint32Array(values).buffer);

function bytesOf(d: AllowSharedBufferSource): Uint8Array<ArrayBuffer> {
    return Uint8Array.from(ArrayBuffer.isView(d) ? new Uint8Array(d.buffer, d.byteOffset, d.byteLength) : new Uint8Array(d));
}

async function videoConfig(): Promise<VideoEncoderConfig | null> {
    if (typeof VideoEncoder === "undefined") return null;
    for (const codec of ["avc1.640028", "avc1.4d0028", "avc1.42e028"]) {
        const c: VideoEncoderConfig = { codec, width: W, height: H, bitrate: BITRATE, framerate: FPS, avc: { format: "avc" } };
        try { if ((await VideoEncoder.isConfigSupported(c)).supported) return c; } catch { }
    }
    return null;
}

async function encodeVideo(config: VideoEncoderConfig, frames: Frame[], progress?: Progress): Promise<VideoTrack> {
    const chunks: Uint8Array<ArrayBuffer>[] = [], sizes: number[] = [], keys: number[] = [], times: number[] = [];
    const state: { avcC: Uint8Array | null; error: unknown } = { avcC: null, error: null };
    const enc = new VideoEncoder({
        output: (chunk, meta) => {
            const b = new Uint8Array(chunk.byteLength);
            chunk.copyTo(b);
            chunks.push(b); sizes.push(b.length); keys.push(chunk.type === "key" ? 1 : 0);
            times.push(chunk.timestamp);
            const description = meta?.decoderConfig?.description;
            if (description) state.avcC = bytesOf(description);
        },
        error: (e) => { state.error = e; },
    });
    enc.configure(config);
    const canvas = new OffscreenCanvas(W, H), ctx = must(canvas.getContext("2d"), "2D canvas");
    let last = -1, lastKey = -10;
    const used: number[] = [];
    for (const [i, [time, draw]] of frames.entries()) {
        if (time <= last + 0.001) continue;
        last = time;
        await draw(ctx);
        const frame = new VideoFrame(canvas, { timestamp: Math.round(time * 1e6) });
        const key = time - lastKey >= 2;
        if (key) lastKey = time;
        enc.encode(frame, { keyFrame: key });
        frame.close();
        used.push(time);
        while (enc.encodeQueueSize > 4) await new Promise<void>((r) => enc.addEventListener("dequeue", () => r(), { once: true }));
        if (state.error) throw state.error;
        if (i % 10 === 0) progress?.(i / frames.length);
    }
    await enc.flush();
    enc.close();
    if (state.error) throw state.error;
    return { chunks, sizes, keys, times: used, avcC: state.avcC };
}

async function audioConfig(): Promise<[AudioEncoderConfig, number] | null> {
    if (typeof AudioEncoder === "undefined") return null;
    for (const [codec, id] of [["mp4a.40.2", A_AAC], ["opus", A_OPUS]] as const) {
        const c: AudioEncoderConfig = { codec, sampleRate: RATE, numberOfChannels: 1, bitrate: AUDIO_BITRATE };
        try { if ((await AudioEncoder.isConfigSupported(c)).supported) return [c, id]; } catch { }
    }
    return null;
}

function upsample(a: Float32Array): Float32Array<ArrayBuffer> {
    const out = new Float32Array(a.length * 2);
    for (let i = 0; i < a.length; i++) {
        const cur = a[i] ?? 0;
        out[2 * i] = cur;
        out[2 * i + 1] = i + 1 < a.length ? (cur + (a[i + 1] ?? 0)) / 2 : cur;
    }
    return out;
}

async function encodeAudio([config, codec]: [AudioEncoderConfig, number], samples: Float32Array): Promise<AudioTrack> {
    const rate = config.sampleRate;
    const pcm = upsample(samples);
    const chunks: Uint8Array<ArrayBuffer>[] = [], sizes: number[] = [], durs: number[] = [];
    const state: { desc: Uint8Array | null; error: unknown } = { desc: null, error: null };
    const enc = new AudioEncoder({
        output: (chunk, meta) => {
            const b = new Uint8Array(chunk.byteLength);
            chunk.copyTo(b);
            chunks.push(b); sizes.push(b.length);
            durs.push(chunk.duration ? Math.round(chunk.duration * rate / 1e6) : codec === A_AAC ? 1024 : 960);
            const description = meta?.decoderConfig?.description;
            if (description) state.desc = bytesOf(description);
        },
        error: (e) => { state.error = e; },
    });
    enc.configure(config);
    const step = rate;
    for (let i = 0; i < pcm.length; i += step) {
        const part = pcm.slice(i, i + step);
        const data = new AudioData({ format: "f32-planar", sampleRate: rate, numberOfFrames: part.length, numberOfChannels: 1, timestamp: Math.round(i * 1e6 / rate), data: part });
        enc.encode(data);
        data.close();
    }
    await enc.flush();
    enc.close();
    if (state.error) throw state.error;
    return { chunks, sizes, durs, desc: state.desc || new Uint8Array(0), codec, rate };
}

function mp4(video: VideoTrack | null, audio: AudioTrack | null, end: number): Blob {
    const v: VideoTrack = video || { chunks: [], sizes: [], keys: [], times: [], avcC: new Uint8Array(0) };
    const ticks = v.times.map((t) => Math.round(t * SCALE));
    const vdurs = ticks.map((t, i) => Math.max(1, (i + 1 < ticks.length ? (ticks[i + 1] ?? 0) : Math.round(end * SCALE)) - t));
    const a: AudioTrack = audio || { chunks: [], sizes: [], durs: [], desc: new Uint8Array(0), codec: A_NONE, rate: V.SAMPLE_RATE };
    const head = G.mp4Head([u32(v.sizes), u32(vdurs), new Uint8Array(v.keys), v.avcC || new Uint8Array(0), u32(a.sizes), u32(a.durs), a.desc],
        W, H, SCALE, a.codec, a.rate, a.rate, 1);
    return new Blob([Uint8Array.from(head), ...v.chunks, ...a.chunks], { type: video ? "video/mp4" : "audio/mp4" });
}

async function record(frames: Frame[] | null, samples: Float32Array | null, end: number, progress?: Progress): Promise<Blob> {
    const canvas = document.createElement("canvas");
    canvas.width = W; canvas.height = H;
    const ctx = must(canvas.getContext("2d"), "2D canvas");
    const tracks: MediaStreamTrack[] = [];
    let track: (MediaStreamTrack & FrameTrack) | null = null;
    if (frames) {
        const videoTrack = must(canvas.captureStream(0).getVideoTracks()[0], "video track");
        if (!isFrameTrack(videoTrack)) throw new Error("The canvas track cannot request frames.");
        track = videoTrack;
        tracks.push(videoTrack);
    }
    let ac: AudioContext | null = null, src: AudioBufferSourceNode | null = null;
    if (samples) {
        ac = new AudioContext({ sampleRate: V.SAMPLE_RATE });
        const buf = ac.createBuffer(1, samples.length, V.SAMPLE_RATE);
        buf.copyToChannel(samples.slice(), 0);
        src = ac.createBufferSource();
        src.buffer = buf;
        const dest = ac.createMediaStreamDestination();
        src.connect(dest);
        tracks.push(must(dest.stream.getAudioTracks()[0], "audio track"));
    }
    const type = frames ? "video/webm" : "audio/webm";
    const rec = new MediaRecorder(new MediaStream(tracks), { mimeType: MediaRecorder.isTypeSupported(type) ? type : "", videoBitsPerSecond: BITRATE, audioBitsPerSecond: AUDIO_BITRATE });
    const parts: Blob[] = [];
    rec.ondataavailable = (e) => { parts.push(e.data); };
    const stopped = new Promise<void>((r) => { rec.onstop = () => r(); });
    if (frames && track) { await frames[0]?.[1](ctx); track.requestFrame(); }
    rec.start(1000);
    src?.start();
    const t0 = performance.now();
    const wait = (t: number): Promise<void> => new Promise((r) => setTimeout(r, Math.max(0, t * 1000 - (performance.now() - t0))));
    for (let i = 1; frames && track && i < frames.length; i++) {
        const [time, draw] = must(frames[i], "frame " + i);
        await draw(ctx);
        await wait(time);
        track.requestFrame();
        progress?.(time / end);
    }
    await wait(end);
    rec.stop();
    await stopped;
    await ac?.close();
    return new Blob(parts, { type: rec.mimeType || type });
}

const length = (s: number): string => `${Math.floor(s / 60)}:${String(Math.floor(s) % 60).padStart(2, "0")}`;
const endOf = (timeline: G.Timeline): number => timeline.segments.reduce((e, s) => Math.max(e, s.start + s.duration), 0);
const timelineOf = (lay: G.Layout): G.Timeline => must(lay.timeline, "video timeline");

export type VideoKind = "video" | "manim" | "narrated";

export async function video(ctx: G.PageCtx, opt: G.LayoutOptions, kind: VideoKind, progress?: Progress): Promise<VideoResult> {
    const m = await G.media(ctx);
    const fonts = await P.embeddedFonts(P.PAGE_FACES);
    let lay = G.layout(ctx, m, G.LAYOUT_VIDEO, opt);
    let durations = "", samples: Float32Array | null = null, notes: string[] = [];
    if (kind === "narrated") {
        await V.load();
        const first = timelineOf(lay);
        const c = await V.clips(first.cues.map((q) => q.text), first.voice, (p) => progress?.(p * 0.6));
        durations = c.durations;
        lay = G.layout(ctx, m, G.LAYOUT_VIDEO, { ...opt, durations });
        const timeline = timelineOf(lay);
        samples = V.mix(timeline.cues, c.clips, endOf(timeline));
        notes = [`Voice ${V.voiceFor(timeline.voice)}. Length ${length(endOf(timeline))}.`];
    }
    notes.push(...lay.warnings);
    const share = kind === "narrated" ? 0.6 : 0;
    const p = (x: number): void => progress?.(share + x * (1 - share));
    const animated = kind === "manim" && !matchMedia("(prefers-reduced-motion: reduce)").matches;
    const timeline = timelineOf(lay);
    const frames = frameList(lay.pages, timeline, animated, m, fonts);
    const e = endOf(timeline);
    const vc = await videoConfig();
    const ac = samples ? await audioConfig() : null;
    let blob: Blob;
    if (vc && (!samples || ac)) {
        const v = await encodeVideo(vc, frames, p);
        blob = mp4(v, samples && ac ? await encodeAudio(ac, samples) : null, e);
    } else {
        blob = await record(frames, samples, e, p);
    }
    const ext = blob.type.includes("webm") ? "webm" : "mp4";
    const files: [string, Blob][] = [[ext, blob]];
    if (timeline.cues.length) files.push(["vtt", new Blob([G.captions(ctx, m, { ...opt, durations })], { type: "text/vtt;charset=utf-8" })]);
    return { files, notes };
}

export async function podcast(ctx: G.PageCtx, progress?: Progress): Promise<VideoResult> {
    await V.load();
    const first = G.podcast(ctx, "");
    const c = await V.clips(first.cues.map((q) => q.text), first.voice, (p) => progress?.(p * 0.9));
    const t = G.podcast(ctx, c.durations);
    const len = (t.cues.at(-1)?.end ?? 0) + 0.6;
    const samples = V.mix(t.cues, c.clips, len);
    const ac = await audioConfig();
    const blob = ac ? mp4(null, await encodeAudio(ac, samples), len) : await record(null, samples, len, progress);
    return { files: [[blob.type.includes("webm") ? "webm" : "m4a", blob]], notes: [`Voice ${V.voiceFor(first.voice)}. Length ${length(len)}.`] };
}
