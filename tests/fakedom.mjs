// A minimal DOM for web/editor.js in Node: a textarea, the highlight mirror and
// the editor box. Only what editor.js touches. Keys go to the keydown handler.

class El {
    constructor(tag = "div") { this.tag = tag; this.childNodes = []; this.style = { setProperty() {} }; this.classList = { toggle() {} }; this.hidden = false; this.offsetTop = 0; this.offsetLeft = 0; this.offsetHeight = 0; this.scrollTop = 0; this.scrollLeft = 0; this.clientHeight = 400; this.clientWidth = 800; this.handlers = {}; }
    set textContent(v) { this.childNodes = [String(v)]; }
    get textContent() { return this.childNodes.join(""); }
    append(...n) { this.childNodes.push(...n); }
    replaceChildren(...n) { this.childNodes = n; }
    addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); }
    focus() { globalThis.document.activeElement = this; }
}

class TextArea extends El {
    constructor() { super("textarea"); this.value = ""; this.selectionStart = 0; this.selectionEnd = 0; this.wrap = "soft"; this.readOnly = false; }
    setSelectionRange(s, e) { this.selectionStart = s; this.selectionEnd = e; }
    setRangeText(t, s, e) { this.value = this.value.slice(0, s) + t + this.value.slice(e); this.selectionStart = this.selectionEnd = s + t.length; }
    // A key press: returns true when editor.js prevented the browser's default action.
    key(key, mods = {}) {
        let prevented = false;
        const ev = { key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, isComposing: false, ...mods,
            preventDefault() { prevented = true; }, stopPropagation() {} };
        for (const fn of this.handlers.keydown || []) fn(ev);
        return prevented;
    }
}

export function installDom() {
    const docHandlers = {};
    globalThis.document = {
        activeElement: null,
        documentElement: new El("html"),
        head: new El("head"),
        createElement: (t) => new El(t),
        createDocumentFragment: () => new El("#fragment"),
        getElementById: () => null,
        addEventListener: (t, fn) => { (docHandlers[t] ||= []).push(fn); },
        // No browser editing in Node: replaceRange uses setRangeText.
        execCommand: () => false,
    };
    globalThis.window = { addEventListener() {} };
    globalThis.ResizeObserver = class { observe() {} };
    globalThis.requestAnimationFrame = () => 0;
    globalThis.cancelAnimationFrame = () => {};
    return { textarea: new TextArea(), highlight: new El("pre"), box: new El("div"), placeholder: new El("div") };
}
