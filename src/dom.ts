export function must<T>(value: T | null | undefined, what: string): T {
    if (value === null || value === undefined) throw new Error("Missing " + what);
    return value;
}

export function byId<T extends Element>(id: string, kind: abstract new (...args: never[]) => T): T {
    const el = document.getElementById(id);
    if (!(el instanceof kind)) throw new Error("Missing element #" + id + " of type " + kind.name);
    return el;
}

export function query<T extends Element>(root: ParentNode, selector: string, kind: abstract new (...args: never[]) => T): T {
    const el = root.querySelector(selector);
    if (!(el instanceof kind)) throw new Error("Missing element " + selector + " of type " + kind.name);
    return el;
}

export function queryAll<T extends Element>(root: ParentNode, selector: string, kind: abstract new (...args: never[]) => T): T[] {
    return [...root.querySelectorAll(selector)].filter((el): el is T => el instanceof kind);
}

export function isRecord(v: unknown): v is Record<string, unknown> {
    return typeof v === "object" && v !== null && !Array.isArray(v);
}
