function isRecord(v: unknown): v is Record<string, unknown> {
    return typeof v === "object" && v !== null && !Array.isArray(v);
}

export function parse(text: string): unknown {
    return JSON.parse(text);
}

export function get(v: unknown, ...path: (string | number)[]): unknown {
    let cur: unknown = v;
    for (const key of path) {
        if (Array.isArray(cur) && typeof key === "number") cur = cur[key];
        else if (isRecord(cur) && typeof key === "string") cur = cur[key];
        else throw new Error("No " + String(key) + " in " + JSON.stringify(cur));
    }
    return cur;
}

export function list(v: unknown): unknown[] {
    if (!Array.isArray(v)) throw new Error("Not a list: " + JSON.stringify(v));
    return v;
}

export function str(v: unknown): string {
    if (typeof v !== "string") throw new Error("Not a string: " + JSON.stringify(v));
    return v;
}

export function num(v: unknown): number {
    if (typeof v !== "number") throw new Error("Not a number: " + JSON.stringify(v));
    return v;
}

export function failure(r: object): string {
    if ("error" in r && typeof r.error === "string") return r.error;
    throw new Error("Not an error result: " + JSON.stringify(r));
}

export function blobOf(parts: (Uint8Array | Blob)[]): Blob {
    return new Blob(parts.map((p) => (p instanceof Uint8Array ? new Uint8Array(p) : p)));
}
