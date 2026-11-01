// A module loader for the app test: web/app.js gets stub modules for the
// browser-only parts (storage, preview, find, export, panels and ui).
const stubs = ["store", "preview", "find", "export", "panels", "ui"];
export async function resolve(specifier, context, next) {
    const m = /^\.\/(\w+)\.js$/.exec(specifier);
    if (m && stubs.includes(m[1]) && context.parentURL && context.parentURL.includes("/web/")) {
        return { url: new URL(`./${m[1]}.mjs`, import.meta.url).href, shortCircuit: true };
    }
    return next(specifier, context);
}
