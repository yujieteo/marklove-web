interface KeyMods {
    ctrlKey?: boolean;
    metaKey?: boolean;
    altKey?: boolean;
    shiftKey?: boolean;
    isComposing?: boolean;
}

type Handler = (ev: FakeKeyEvent) => void;

interface FakeKeyEvent {
    key: string;
    ctrlKey: boolean;
    metaKey: boolean;
    altKey: boolean;
    shiftKey: boolean;
    isComposing: boolean;
    preventDefault(): void;
    stopPropagation(): void;
}

const EDITOR_HEIGHT = 400;
const EDITOR_WIDTH = 800;

export class FakeElement {
    tag: string;
    id = "";
    childNodes: unknown[] = [];
    style = { setProperty(): void {} };
    classList = { toggle(): void {} };
    hidden = false;
    offsetTop = 0;
    offsetLeft = 0;
    offsetHeight = 0;
    scrollTop = 0;
    scrollLeft = 0;
    clientHeight = EDITOR_HEIGHT;
    clientWidth = EDITOR_WIDTH;
    handlers: Record<string, Handler[]> = {};

    constructor(tag = "div") { this.tag = tag; }

    set textContent(v: unknown) { this.childNodes = [String(v)]; }
    get textContent(): string { return this.childNodes.join(""); }
    append(...n: unknown[]): void { this.childNodes.push(...n); }
    replaceChildren(...n: unknown[]): void { this.childNodes = n; }
    addEventListener(type: string, fn: Handler): void { (this.handlers[type] ??= []).push(fn); }
    setAttribute(): void {}
    remove(): void {}
    focus(): void { fakeDocument.activeElement = this; }
}

class TextArea extends FakeElement {
    value = "";
    selectionStart = 0;
    selectionEnd = 0;
    wrap = "soft";
    readOnly = false;

    constructor() { super("textarea"); }

    setSelectionRange(s: number, e: number): void { this.selectionStart = s; this.selectionEnd = e; }
    setRangeText(t: string, s: number, e: number): void {
        this.value = this.value.slice(0, s) + t + this.value.slice(e);
        this.selectionStart = this.selectionEnd = s + t.length;
    }
    key(key: string, mods: KeyMods = {}): boolean {
        let prevented = false;
        const ev: FakeKeyEvent = {
            key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, isComposing: false, ...mods,
            preventDefault() { prevented = true; },
            stopPropagation() {},
        };
        for (const fn of this.handlers["keydown"] ?? []) fn(ev);
        return prevented;
    }
}

const docHandlers: Record<string, Handler[]> = {};

function nullElement(): FakeElement | null {
    return null;
}

export const fakeDocument = {
    activeElement: nullElement(),
    documentElement: new FakeElement("html"),
    head: new FakeElement("head"),
    title: "",
    createElement: (t: string): FakeElement => new FakeElement(t),
    createDocumentFragment: (): FakeElement => new FakeElement("#fragment"),
    getElementById: (_id: string): FakeElement | null => null,
    addEventListener: (t: string, fn: Handler): void => { (docHandlers[t] ??= []).push(fn); },
    execCommand: (): boolean => false,
};

function defineKind(name: string, accepts: (x: unknown) => boolean): void {
    class Kind {
        static [Symbol.hasInstance](x: unknown): boolean { return accepts(x); }
    }
    Reflect.set(globalThis, name, Kind);
}

export function installDom() {
    const anyElement = (x: unknown): boolean => x instanceof FakeElement;
    for (const name of ["Node", "Element", "HTMLElement", "HTMLDivElement", "HTMLPreElement", "HTMLButtonElement", "HTMLInputElement", "HTMLSpanElement"])
        defineKind(name, anyElement);
    defineKind("HTMLTextAreaElement", (x) => x instanceof TextArea);
    Reflect.set(globalThis, "document", fakeDocument);
    Reflect.set(globalThis, "window", { addEventListener() {} });
    Reflect.set(globalThis, "ResizeObserver", class { observe(): void {} });
    Reflect.set(globalThis, "requestAnimationFrame", () => 0);
    Reflect.set(globalThis, "cancelAnimationFrame", () => {});

    const textarea = new TextArea();
    const highlight = new FakeElement("pre");
    const box = new FakeElement("div");
    const placeholder = new FakeElement("div");
    if (!(textarea instanceof HTMLTextAreaElement)) throw new Error("fake textarea");
    if (!(highlight instanceof HTMLElement) || !(box instanceof HTMLElement) || !(placeholder instanceof HTMLElement))
        throw new Error("fake element");
    return { textarea, highlight, box, placeholder };
}
