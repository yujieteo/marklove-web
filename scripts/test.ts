import { readdirSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const files = readdirSync(join(root, "tests")).filter((f) => f.endsWith(".test.ts")).sort();
let failed = 0;
for (const f of files) {
    const r = Bun.spawnSync(["bun", "test", join("tests", f)], { cwd: root, stdout: "inherit", stderr: "inherit" });
    if (r.exitCode !== 0) failed++;
}
if (failed > 0) {
    console.log(String(failed) + " test file(s) failed");
    process.exit(1);
}
