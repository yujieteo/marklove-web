import { mock } from "bun:test";
import { appendFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterAll } from "bun:test";
import { CLOSURE_MARK, encode, type CallRecord, type Wire } from "./replay-codec.ts";

const outFile = process.env["MARKLOVE_CAPTURE_FILE"];
if (outFile === undefined) throw new Error("MARKLOVE_CAPTURE_FILE is not set");

const corePath = resolve(import.meta.dir, "../src/core.ts");
const real: Record<string, unknown> = await import(corePath);
const pending: Promise<CallRecord>[] = [];

function record(fn: string, args: unknown[], run: () => unknown): unknown {
    const index = pending.length;
    const encodedArgs = Promise.all(args.map(encode));
    let value: unknown;
    let failure: unknown;
    let failed = false;
    try {
        value = run();
    } catch (e) {
        failed = true;
        failure = e;
    }
    const finish = async (result: unknown): Promise<CallRecord> => ({ fn, args: await encodedArgs, result: await encode(result) });
    if (failed) {
        pending.push(finish(failure));
        throw failure;
    }
    if (value instanceof Promise) {
        const settled: Promise<unknown> = value.then((v: unknown) => adopt(fn, index, v), (e: unknown) => e);
        pending.push(settled.then(finish));
        return settled.then((v) => {
            if (v instanceof Error) throw v;
            return v;
        });
    }
    const adopted = adopt(fn, index, value);
    pending.push(finish(adopted));
    return adopted;
}

function adopt(fn: string, index: number, value: unknown): unknown {
    if (typeof value !== "function") return value;
    const inner = value;
    return (...args: unknown[]) => record(fn + CLOSURE_MARK + String(index), args, () => Reflect.apply(inner, undefined, args));
}

const wrapped: Record<string, unknown> = {};
for (const [name, member] of Object.entries(real)) {
    wrapped[name] = typeof member === "function" && !/^[A-Z]/.test(name)
        ? (...args: unknown[]) => record(name, args, () => Reflect.apply(member, undefined, args))
        : member;
}

mock.module(corePath, () => wrapped);

afterAll(async () => {
    const records: CallRecord[] = await Promise.all(pending);
    const wire: Wire = records.map((r) => ({ fn: r.fn, args: r.args, result: r.result }));
    appendFileSync(outFile, JSON.stringify(wire) + "\n");
});
