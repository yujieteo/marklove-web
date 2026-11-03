import { join, resolve } from "node:path";

const webDir = resolve(import.meta.dir, "../web");
const PORT = 8000;

Bun.serve({
    port: PORT,
    async fetch(req) {
        const path = new URL(req.url).pathname;
        const target = resolve(join(webDir, path.endsWith("/") ? path + "index.html" : path));
        if (!target.startsWith(webDir)) return new Response("Not found", { status: 404 });
        const file = Bun.file(target);
        if (!(await file.exists())) return new Response("Not found", { status: 404 });
        return new Response(file);
    },
});
console.log("http://localhost:" + String(PORT) + "/");
