import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const SELF = "scripts/state-models.ts";

interface Model {
    machine: string;
    covers: readonly string[];
    hash: string;
}

const MODELS: readonly Model[] = [
    { machine: "docs/state/voice.sm.md", covers: ["src/voice.ts"], hash: "48369cb4eb17277e6bec63a4c5cd358645f2f4ff30c049a037539b5fe4bc96e7" },
    { machine: "docs/state/project-save.sm.md", covers: ["src/app.ts"], hash: "20f770a99515b3bb7b8069ab3fa21f057b010a9df2b5b27ade8033b215c3d760" },
];

function hashOf(model: Model): string {
    const h = createHash("sha256");
    for (const f of [model.machine, ...model.covers]) h.update(f + "\0").update(readFileSync(resolve(root, f)));
    return h.digest("hex");
}

if (process.argv.includes("--update")) {
    let text = readFileSync(resolve(root, SELF), "utf8");
    for (const m of MODELS) {
        const next = hashOf(m);
        const entry = `machine: "${m.machine}", covers: ${JSON.stringify(m.covers)}, hash: "${m.hash}"`;
        text = text.replace(entry, `machine: "${m.machine}", covers: ${JSON.stringify(m.covers)}, hash: "${next}"`);
    }
    writeFileSync(resolve(root, SELF), text);
    console.log("state model hashes updated");
    process.exit(0);
}

let stale = 0;
for (const m of MODELS) {
    if (hashOf(m) !== m.hash) {
        stale++;
        console.log(m.machine + " is out of date for " + m.covers.join(", ") + ": run sm-axi check " + m.machine + ", then bun scripts/state-models.ts --update");
    }
}
if (stale > 0) process.exit(1);
console.log("state models: " + String(MODELS.length) + " current");
