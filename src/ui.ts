import { queryAll, query } from "./dom.ts";

type Child = Node | string | number | boolean | null | undefined;
export type Children = Child | readonly Child[];
type StyleObject = Record<string, string>;
type Handler = { handle(e: Event): unknown }["handle"];
type AttrValue = string | number | boolean | null | undefined | Handler | StyleObject;
export type Attrs = Record<string, AttrValue>;

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs?: Attrs | null, ...children: Children[]): HTMLElementTagNameMap[K] {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
        if (v === undefined || v === null || v === false) continue;
        if (k === "class") el.className = String(v);
        else if (k === "text") el.textContent = String(v);
        else if (k === "html") el.innerHTML = String(v);
        else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
        else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
        else if (v === true) el.setAttribute(k, "");
        else el.setAttribute(k, String(v));
    }
    for (const c of children.flat()) {
        if (c === null || c === undefined || c === false) continue;
        el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
}

const ANNOUNCE_DELAY_MS = 30;

export function announce(text: string | null | undefined): void {
    const live = document.getElementById("live");
    if (!live || !text) return;
    live.textContent = "";
    setTimeout(() => { live.textContent = text; }, ANNOUNCE_DELAY_MS);
}

export interface MenuItem {
    label?: string | undefined;
    action?: (() => unknown) | undefined;
    checked?: boolean | undefined;
    disabled?: boolean | undefined;
    danger?: boolean | undefined;
    header?: string | undefined;
    separator?: boolean | undefined;
    hint?: string | undefined;
    shortcut?: string | undefined;
}

export type MenuItems = MenuItem[] | (() => MenuItem[]);

interface OpenMenu {
    el: HTMLElement;
    button: HTMLElement;
}

let openMenuEl: OpenMenu | null = null;

export function closeMenu(): void {
    if (!openMenuEl) return;
    const { el, button } = openMenuEl;
    openMenuEl = null;
    el.remove();
    button.setAttribute("aria-expanded", "false");
}

const ENABLED_ITEMS = ".menu-item:not([disabled])";

export function attachMenu(button: HTMLElement, items: MenuItems, { align = "start" }: { align?: "start" | "end" } = {}): void {
    button.setAttribute("aria-haspopup", "menu");
    button.setAttribute("aria-expanded", "false");
    const show = (focusLast: boolean) => {
        if (openMenuEl && openMenuEl.button === button) { closeMenu(); return; }
        closeMenu();
        const list = typeof items === "function" ? items() : items;
        const el = h("div", { class: "menu", role: "menu", "aria-label": button.getAttribute("aria-label") || button.textContent });
        for (const it of list) {
            if (it.separator) { el.append(h("div", { class: "menu-sep", role: "separator" })); continue; }
            if (it.header) { el.append(h("div", { class: "menu-header", role: "presentation", text: it.header })); continue; }
            const role = it.checked === undefined ? "menuitem" : "menuitemcheckbox";
            const item = h("button", {
                type: "button", role, class: "menu-item" + (it.danger ? " danger" : ""), tabindex: "-1",
                "aria-checked": it.checked === undefined ? null : String(!!it.checked),
                disabled: it.disabled, title: it.hint,
                onclick: () => { closeMenu(); button.focus(); if (it.action) it.action(); },
            }, h("span", { class: "menu-check", "aria-hidden": "true", text: it.checked ? "✓" : "" }), h("span", { text: it.label }),
                it.shortcut ? h("span", { class: "menu-key", "aria-hidden": "true", text: it.shortcut }) : null);
            el.append(item);
        }
        document.body.append(el);
        const r = button.getBoundingClientRect();
        const w = el.offsetWidth, hgt = el.offsetHeight;
        let left = align === "end" ? r.right - w : r.left;
        left = Math.max(8, Math.min(left, innerWidth - w - 8));
        let top = r.bottom + 4;
        if (top + hgt > innerHeight - 8) top = Math.max(8, innerHeight - hgt - 8);
        el.style.left = left + "px";
        el.style.top = top + "px";
        openMenuEl = { el, button };
        button.setAttribute("aria-expanded", "true");
        const enabled = queryAll(el, ENABLED_ITEMS, HTMLElement);
        (focusLast ? enabled[enabled.length - 1] : enabled[0])?.focus();
        el.addEventListener("keydown", (e) => {
            const all = queryAll(el, ENABLED_ITEMS, HTMLElement);
            const i = all.findIndex((x) => x === document.activeElement);
            if (e.key === "ArrowDown") { all[(i + 1) % all.length]?.focus(); e.preventDefault(); }
            else if (e.key === "ArrowUp") { all[(i - 1 + all.length) % all.length]?.focus(); e.preventDefault(); }
            else if (e.key === "Home") { all[0]?.focus(); e.preventDefault(); }
            else if (e.key === "End") { all[all.length - 1]?.focus(); e.preventDefault(); }
            else if (e.key === "Escape") { closeMenu(); button.focus(); e.preventDefault(); e.stopPropagation(); }
            else if (e.key === "Tab") { closeMenu(); }
            else if (e.key.length === 1 && /\S/.test(e.key)) {
                const k = e.key.toLowerCase();
                const next = all.slice(i + 1).concat(all.slice(0, i + 1)).find((b) => (b.textContent ?? "").trim().toLowerCase().startsWith(k));
                next?.focus();
            }
        });
    };
    button.addEventListener("click", () => show(false));
    button.addEventListener("keydown", (e) => {
        if (e.key === "ArrowDown") { e.preventDefault(); show(false); }
        if (e.key === "ArrowUp") { e.preventDefault(); show(true); }
    });
}

document.addEventListener("pointerdown", (e) => {
    const target = e.target;
    if (openMenuEl && target instanceof Node && !openMenuEl.el.contains(target) && !openMenuEl.button.contains(target)) closeMenu();
});
window.addEventListener("resize", closeMenu);

interface DialogButton {
    label: string;
    action?: (() => unknown) | undefined;
    primary?: boolean | undefined;
    cancel?: boolean | undefined;
    danger?: boolean | undefined;
    disabled?: boolean | undefined;
}

export interface DialogOptions {
    title: string;
    body?: Node | null | undefined;
    buttons?: DialogButton[] | undefined;
    wide?: boolean | undefined;
    onClose?: (() => void) | undefined;
}

export interface DialogHandle {
    dlg: HTMLDialogElement;
    body: HTMLDivElement;
    close: () => void;
    buttons: HTMLButtonElement[];
    setTitle: (t: string) => void;
}

export function dialog({ title, body, buttons = [{ label: "Done", primary: true }], wide = false, onClose }: DialogOptions): DialogHandle {
    const titleId = "dlg-" + Math.random().toString(36).slice(2);
    const bar = h("div", { class: "sheet-bar" });
    const left = h("div", { class: "sheet-bar-side" });
    const right = h("div", { class: "sheet-bar-side end" });
    const dlg = h("dialog", { class: "sheet" + (wide ? " wide" : ""), "aria-labelledby": titleId });
    const close = () => { if (dlg.open) dlg.close(); };
    const made: HTMLButtonElement[] = [];
    for (const b of buttons) {
        const el = h("button", {
            type: "button", class: "button" + (b.primary ? " primary" : "") + (b.danger ? " danger" : ""), disabled: b.disabled,
            onclick: async () => { const r = b.action ? await b.action() : undefined; if (r !== false) close(); },
        }, b.label);
        made.push(el);
        (b.cancel ? left : right).append(el);
    }
    bar.append(left, h("h2", { id: titleId, class: "sheet-title", text: title }), right);
    const content = h("div", { class: "sheet-body" });
    if (body) content.append(body);
    dlg.append(bar, content);
    dlg.addEventListener("close", () => { dlg.remove(); if (onClose) onClose(); });
    dlg.addEventListener("click", (e) => { if (e.target === dlg) close(); });
    document.body.append(dlg);
    dlg.showModal();
    const first = content.querySelector("input, textarea, select, button, [tabindex='0']");
    if (first instanceof HTMLElement && first.tagName !== "BUTTON") first.focus();
    return { dlg, body: content, close, buttons: made, setTitle: (t) => { query(dlg, ".sheet-title", HTMLElement).textContent = t; } };
}

export function alertBox(message: string, title = "Marklove"): Promise<void> {
    return new Promise((resolve) => {
        dialog({ title, body: h("p", { class: "alert-text", text: message }), buttons: [{ label: "OK", primary: true }], onClose: () => resolve() });
    });
}

export interface Choice<T> {
    label: string;
    value: T;
    danger?: boolean | undefined;
    primary?: boolean | undefined;
}

export function confirmBox<T>({ title, message, choices }: { title: string; message: string; choices: Choice<T>[] }): Promise<T | null> {
    return new Promise((resolve) => {
        let value: T | null = null;
        const body = h("div", {}, h("p", { class: "alert-text", text: message }));
        const row = h("div", { class: "confirm-row" });
        for (const c of choices) {
            row.append(h("button", {
                type: "button", class: "button" + (c.danger ? " danger" : "") + (c.primary ? " primary" : ""),
                onclick: () => { value = c.value; d.close(); },
            }, c.label));
        }
        row.append(h("button", { type: "button", class: "button", onclick: () => d.close() }, "Cancel"));
        body.append(row);
        const d = dialog({ title, body, buttons: [], onClose: () => resolve(value) });
        row.querySelector("button")?.focus();
    });
}

export function section(title: string | null | undefined, ...children: Children[]): HTMLElement {
    const id = "sec-" + Math.random().toString(36).slice(2);
    return h("section", { class: "form-section", "aria-labelledby": title ? id : null },
        title ? h("h3", { id, class: "form-section-title", text: title }) : null, ...children);
}

export function footnote(text: string): HTMLParagraphElement { return h("p", { class: "footnote", text }); }

export function toggleRow(label: string, checked: boolean, onchange: (v: boolean) => void, hint?: string): HTMLDivElement {
    const id = "t-" + Math.random().toString(36).slice(2);
    const input = h("input", {
        type: "checkbox", id, role: "switch", checked,
        onchange: (e) => { if (e.target instanceof HTMLInputElement) onchange(e.target.checked); },
    });
    return h("div", { class: "row" }, h("label", { for: id, class: "row-label" }, label, hint ? h("span", { class: "row-hint", text: hint }) : null), input);
}

export function selectRow(label: string, options: readonly (readonly [string, string])[], value: string, onchange: (v: string) => void): HTMLDivElement {
    const id = "s-" + Math.random().toString(36).slice(2);
    const sel = h("select", { id, onchange: (e) => { if (e.target instanceof HTMLSelectElement) onchange(e.target.value); } },
        options.map(([v, t]) => h("option", { value: v, selected: v === value }, t)));
    return h("div", { class: "row" }, h("label", { for: id, class: "row-label", text: label }), sel);
}

export function segmented(label: string, options: readonly (readonly [string, string])[], value: string, onchange: (v: string) => void): HTMLDivElement & { setValue: (v: string) => void } {
    const group = h("div", { class: "segmented", role: "radiogroup", "aria-label": label });
    const set = (v: string) => {
        for (const b of queryAll(group, "button", HTMLElement)) {
            const on = b.dataset["value"] === v;
            b.setAttribute("aria-checked", String(on));
            b.dataset["active"] = String(on);
            b.tabIndex = on ? 0 : -1;
        }
    };
    for (const [v, t] of options) {
        group.append(h("button", { type: "button", class: "button", role: "radio", "data-value": v, onclick: () => { set(v); onchange(v); } }, t));
    }
    group.addEventListener("keydown", (e) => {
        const all = queryAll(group, "button", HTMLElement);
        const i = all.findIndex((x) => x === document.activeElement);
        if (i < 0) return;
        let j = -1;
        if (e.key === "ArrowRight" || e.key === "ArrowDown") j = (i + 1) % all.length;
        if (e.key === "ArrowLeft" || e.key === "ArrowUp") j = (i - 1 + all.length) % all.length;
        const target = all[j];
        if (target) { e.preventDefault(); target.focus(); target.click(); }
    });
    set(value);
    return Object.assign(group, { setValue: set });
}

const REVOKE_DELAY_MS = 60000;

export function download(blob: Blob, name: string): void {
    const url = URL.createObjectURL(blob);
    const a = h("a", { href: url, download: name, hidden: true });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), REVOKE_DELAY_MS);
}

export function pickFile(accept: string, multiple = false): Promise<File[]> {
    return new Promise((resolve) => {
        const input = h("input", { type: "file", accept, multiple, hidden: true });
        input.addEventListener("change", () => { resolve([...(input.files ?? [])]); input.remove(); });
        input.addEventListener("cancel", () => { resolve([]); input.remove(); });
        document.body.append(input);
        input.click();
    });
}

export async function copyText(text: string): Promise<boolean> {
    try { await navigator.clipboard.writeText(text); return true; }
    catch {
        const t = h("textarea", { style: { position: "fixed", opacity: "0" } });
        t.value = text;
        document.body.append(t);
        t.select();
        const ok = document.execCommand("copy");
        t.remove();
        return ok;
    }
}

export function blobToDataURL(blob: Blob): Promise<string> {
    return new Promise((resolve, reject) => {
        const r = new FileReader();
        r.onload = () => {
            if (typeof r.result === "string") resolve(r.result);
            else reject(new Error("The file did not read as text."));
        };
        r.onerror = () => reject(r.error);
        r.readAsDataURL(blob);
    });
}

export const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
export const cmdKey = isMac ? "⌘" : "Ctrl+";
