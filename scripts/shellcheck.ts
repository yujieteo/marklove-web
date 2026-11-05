import { resolve } from "node:path";

const VERSION = "0.11.0.1";
const root = resolve(import.meta.dir, "..");
const SHELL_LINE = /^#!\s*(?:\S*\/)?(?:env\s+(?:-\S+\s+)*)?(?:sh|bash|ksh)(?:\s|$)/;

const listed = Bun.spawnSync(["git", "ls-files", "-z"], { cwd: root });
if (listed.exitCode !== 0) {
    console.error("git ls-files failed");
    process.exit(1);
}
const files: string[] = [];
for (const f of listed.stdout.toString().split("\0")) {
    if (f === "") continue;
    if (f.endsWith(".sh")) {
        files.push(f);
        continue;
    }
    const head = await Bun.file(resolve(root, f)).slice(0, 256).text();
    if (SHELL_LINE.test(head.split("\n", 1)[0] ?? "")) files.push(f);
}

if (files.length === 0) {
    console.log("no shell files");
    process.exit(0);
}
console.log(files.join("\n"));
const r = Bun.spawnSync(
    ["uvx", `--from=shellcheck-py==${VERSION}`, "shellcheck", "-o", "all", ...files],
    { cwd: root, stdout: "inherit", stderr: "inherit" },
);
process.exit(r.exitCode);
