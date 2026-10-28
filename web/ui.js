// Small DOM helpers: elements, menus, dialogs, announcements, downloads.

export function h(tag, attrs, ...children) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
        if (v === undefined || v === null || v === false) continue;
        if (k === "class") el.className = v;
        else if (k === "text") el.textContent = v;
        else if (k === "html") el.innerHTML = v;
        else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
        else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
        else if (v === true) el.setAttribute(k, "");
        else el.setAttribute(k, v);
    }
    for (const c of children.flat()) {
        if (c === null || c === undefined || c === false) continue;
        el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
}

// --- announcements ------------------------------------------------------------

export function announce(text) {
    const live = document.getElementById("live");
    if (!live || !text) return;
    live.textContent = "";
    setTimeout(() => { live.textContent = text; }, 30);
}

// --- menus ------------------------------------------------------------------

// items: [{label, action, checked, disabled, danger, header, separator, hint}]
// A function gives fresh items each time the menu opens.
let openMenuEl = null;

export function closeMenu() {
    if (!openMenuEl) return;
    const { el, button } = openMenuEl;
    openMenuEl = null;
    el.remove();
    button.setAttribute("aria-expanded", "false");
}

export function attachMenu(button, items, { align = "start" } = {}) {
    button.setAttribute("aria-haspopup", "menu");
    button.setAttribute("aria-expanded", "false");
    const show = (focusLast) => {
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
                onclick: () => { closeMenu(); button.focus(); it.action && it.action(); },
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
        const enabled = [...el.querySelectorAll(".menu-item:not([disabled])")];
        (focusLast ? enabled[enabled.length - 1] : enabled[0])?.focus();
        el.addEventListener("keydown", (e) => {
            const all = [...el.querySelectorAll(".menu-item:not([disabled])")];
            const i = all.indexOf(document.activeElement);
            if (e.key === "ArrowDown") { all[(i + 1) % all.length]?.focus(); e.preventDefault(); }
            else if (e.key === "ArrowUp") { all[(i - 1 + all.length) % all.length]?.focus(); e.preventDefault(); }
            else if (e.key === "Home") { all[0]?.focus(); e.preventDefault(); }
            else if (e.key === "End") { all[all.length - 1]?.focus(); e.preventDefault(); }
            else if (e.key === "Escape") { closeMenu(); button.focus(); e.preventDefault(); e.stopPropagation(); }
            else if (e.key === "Tab") { closeMenu(); }
            else if (e.key.length === 1 && /\S/.test(e.key)) {
                const k = e.key.toLowerCase();
                const next = all.slice(i + 1).concat(all.slice(0, i + 1)).find((b) => b.textContent.trim().toLowerCase().startsWith(k));
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
    if (openMenuEl && !openMenuEl.el.contains(e.target) && !openMenuEl.button.contains(e.target)) closeMenu();
});
window.addEventListener("resize", closeMenu);

// --- dialogs ----------------------------------------------------------------

// Opens a modal sheet. buttons: [{label, action, primary, cancel, danger, disabled}]
// An action that returns false keeps the dialog open.
export function dialog({ title, body, buttons = [{ label: "Done", primary: true }], wide = false, onClose, label }) {
    const titleId = "dlg-" + Math.random().toString(36).slice(2);
    const bar = h("div", { class: "sheet-bar" });
    const left = h("div", { class: "sheet-bar-side" });
    const right = h("div", { class: "sheet-bar-side end" });
    const dlg = h("dialog", { class: "sheet" + (wide ? " wide" : ""), "aria-labelledby": titleId });
    const close = () => { if (dlg.open) dlg.close(); };
    const made = [];
    for (const b of buttons) {
        const el = h("button", {
            type: "button", class: "btn" + (b.primary ? " primary" : "") + (b.danger ? " danger" : ""), disabled: b.disabled,
            onclick: async () => { const r = b.action ? await b.action() : undefined; if (r !== false) close(); },
        }, b.label);
        made.push(el);
        (b.cancel ? left : right).append(el);
    }
    bar.append(left, h("h2", { id: titleId, class: "sheet-title", text: title }), right);
    const content = h("div", { class: "sheet-body" });
    if (body) content.append(body);
    dlg.append(bar, content);
    dlg.addEventListener("close", () => { dlg.remove(); onClose && onClose(); });
    dlg.addEventListener("click", (e) => { if (e.target === dlg) close(); });
    document.body.append(dlg);
    dlg.showModal();
    const first = content.querySelector("input, textarea, select, button, [tabindex='0']");
    if (first && first.tagName !== "BUTTON") first.focus();
    return { dlg, body: content, close, buttons: made, setTitle: (t) => { dlg.querySelector(".sheet-title").textContent = t; } };
}

export function alertBox(message, title = "Marklove") {
    return new Promise((resolve) => {
        dialog({ title, body: h("p", { class: "alert-text", text: message }), buttons: [{ label: "OK", primary: true }], onClose: resolve });
    });
}

// A choice with a destructive or other button. Resolves to the chosen value or null.
export function confirmBox({ title, message, choices }) {
    return new Promise((resolve) => {
        let value = null;
        const body = h("div", {}, h("p", { class: "alert-text", text: message }));
        const row = h("div", { class: "confirm-row" });
        for (const c of choices) {
            row.append(h("button", {
                type: "button", class: "btn" + (c.danger ? " danger" : "") + (c.primary ? " primary" : ""),
                onclick: () => { value = c.value; d.close(); },
            }, c.label));
        }
        row.append(h("button", { type: "button", class: "btn", onclick: () => d.close() }, "Cancel"));
        body.append(row);
        const d = dialog({ title, body, buttons: [], onClose: () => resolve(value) });
        row.querySelector("button")?.focus();
    });
}

// --- form rows -----------------------------------------------------------------

export function section(title, ...children) {
    const id = "sec-" + Math.random().toString(36).slice(2);
    return h("section", { class: "form-section", "aria-labelledby": title ? id : null },
        title ? h("h3", { id, class: "form-section-title", text: title }) : null, ...children);
}

export function footnote(text) { return h("p", { class: "footnote", text }); }

export function toggleRow(label, checked, onchange, hint) {
    const id = "t-" + Math.random().toString(36).slice(2);
    const input = h("input", { type: "checkbox", id, role: "switch", checked, onchange: (e) => onchange(e.target.checked) });
    return h("div", { class: "row" }, h("label", { for: id, class: "row-label" }, label, hint ? h("span", { class: "row-hint", text: hint }) : null), input);
}

export function selectRow(label, options, value, onchange) {
    const id = "s-" + Math.random().toString(36).slice(2);
    const sel = h("select", { id, onchange: (e) => onchange(e.target.value) },
        options.map(([v, t]) => h("option", { value: v, selected: v === value }, t)));
    return h("div", { class: "row" }, h("label", { for: id, class: "row-label", text: label }), sel);
}

export function segmented(label, options, value, onchange) {
    const group = h("div", { class: "segmented", role: "radiogroup", "aria-label": label });
    const set = (v) => {
        for (const b of group.children) {
            const on = b.dataset.value === v;
            b.setAttribute("aria-checked", String(on));
            b.tabIndex = on ? 0 : -1;
        }
    };
    for (const [v, t] of options) {
        group.append(h("button", { type: "button", role: "radio", "data-value": v, onclick: () => { set(v); onchange(v); } }, t));
    }
    group.addEventListener("keydown", (e) => {
        const all = [...group.children];
        const i = all.indexOf(document.activeElement);
        if (i < 0) return;
        let j = -1;
        if (e.key === "ArrowRight" || e.key === "ArrowDown") j = (i + 1) % all.length;
        if (e.key === "ArrowLeft" || e.key === "ArrowUp") j = (i - 1 + all.length) % all.length;
        if (j >= 0) { e.preventDefault(); all[j].focus(); all[j].click(); }
    });
    set(value);
    group.setValue = set;
    return group;
}

// --- files ------------------------------------------------------------------

export function download(blob, name) {
    const url = URL.createObjectURL(blob);
    const a = h("a", { href: url, download: name, hidden: true });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
}

export function pickFile(accept, multiple = false) {
    return new Promise((resolve) => {
        const input = h("input", { type: "file", accept, multiple, hidden: true });
        input.addEventListener("change", () => { resolve([...input.files]); input.remove(); });
        input.addEventListener("cancel", () => { resolve([]); input.remove(); });
        document.body.append(input);
        input.click();
    });
}

export async function copyText(text) {
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

export function blobToDataURL(blob) {
    return new Promise((resolve, reject) => {
        const r = new FileReader();
        r.onload = () => resolve(r.result);
        r.onerror = () => reject(r.error);
        r.readAsDataURL(blob);
    });
}

export const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
export const cmdKey = isMac ? "⌘" : "Ctrl+";
