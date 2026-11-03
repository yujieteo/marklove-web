export type Wire =
    | null
    | boolean
    | number
    | string
    | { u8: string }
    | { blob: string }
    | { undef: true }
    | { big: string }
    | { error: string }
    | { closure: true }
    | Wire[]
    | { [key: string]: Wire };

export const CLOSURE_MARK = "#";

export interface CallRecord {
    fn: string;
    args: Wire[];
    result: Wire;
}

function toBase64(bytes: Uint8Array): string {
    return Buffer.from(bytes).toString("base64");
}

function isPlainObject(v: object): v is Record<string, unknown> {
    const proto: unknown = Object.getPrototypeOf(v);
    return proto === Object.prototype || proto === null;
}

export async function encode(value: unknown): Promise<Wire> {
    if (value === undefined) return { undef: true };
    if (value === null || typeof value === "boolean" || typeof value === "string") return value;
    if (typeof value === "number") return Number.isFinite(value) ? value : { error: "number:" + String(value) };
    if (typeof value === "bigint") return { big: value.toString() };
    if (typeof value === "function") return { closure: true };
    if (value instanceof Uint8Array) return { u8: toBase64(value) };
    if (value instanceof Blob) return { blob: toBase64(new Uint8Array(await value.arrayBuffer())) };
    if (Array.isArray(value)) return Promise.all(value.map(encode));
    if (value instanceof Set) return encode([...value]);
    if (value instanceof Map) return encode([...value]);
    if (value instanceof Error) return { error: value.name + ": " + value.message };
    if (typeof value === "object" && isPlainObject(value)) {
        const out: { [key: string]: Wire } = {};
        for (const key of Object.keys(value).sort()) out[key] = await encode(value[key]);
        return out;
    }
    return { error: "unsupported:" + typeof value };
}

function isUndef(w: object): w is { undef: true } {
    return "undef" in w;
}

export function decode(wire: Wire): unknown {
    if (wire === null || typeof wire !== "object") return wire;
    if (Array.isArray(wire)) return wire.map(decode);
    if ("u8" in wire && typeof wire.u8 === "string") return new Uint8Array(Buffer.from(wire.u8, "base64"));
    if ("blob" in wire && typeof wire.blob === "string") return new Blob([new Uint8Array(Buffer.from(wire.blob, "base64"))]);
    if (isUndef(wire)) return undefined;
    if ("big" in wire && typeof wire.big === "string") return BigInt(wire.big);
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(wire)) out[k] = decode(v);
    return out;
}
