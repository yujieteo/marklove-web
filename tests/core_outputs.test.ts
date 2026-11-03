import { test, expect } from "bun:test";
import * as C from "../src/core.ts";

await C.load();

const source = `---
title: Waves
subtitle: Sound and light
author: A. Writer
---

# Sound

## Speed

Speed is $v = f\\lambda$.

. . .

::: plot
x: 0, 6.28
y: -2, 2
y = sin(x)
:::

::: chart bar
| Material | Speed (m/s) |
| --- | ---: |
| Air | 343 |
| Water | 1480 |
:::

::: notes
Say hello.
:::

::: public-notes
Thank you.
:::
`;
const doc: C.Doc = { source, assets: {} };

test("slides page output stays readable and stable", () => {
    expect(C.page(doc, C.PAGE_SLIDES, C.O_TAKAHASHI)).toMatchSnapshot();
});

test("article page output stays readable and stable", () => {
    expect(C.page(doc, C.PAGE_ARTICLE, C.O_TOC)).toMatchSnapshot();
});

test("narration, transcript, SRT and revised Markdown stay stable", () => {
    for (const kind of [C.TEXT_REVISED_MD, C.TEXT_NARRATION, C.TEXT_TRANSCRIPT, C.TEXT_SRT]) {
        expect(C.textOutput(doc, kind, C.O_NARRATION)).toMatchSnapshot();
    }
});

test("listener Markdown, asset lists and revision prompt stay stable", () => {
    expect(C.listener(source, C.LIST_LISTENER_MD)).toMatchSnapshot();
    expect(C.listener(source, C.LIST_PUBLIC_ASSETS)).toMatchSnapshot();
    expect(C.listener(source, C.LIST_PRIVATE_ASSETS)).toMatchSnapshot();
    expect(C.listener(source, C.LIST_REVISION_PROMPT)).toMatchSnapshot();
});

test("authoring prompt keeps its rules", () => {
    expect(C.authoringPrompt("A talk about waves")).toMatchSnapshot();
});

test("tour project is the same", () => {
    const t = C.tour();
    expect({ name: t.name, markdown: t.markdown, assets: Object.keys(t.assets).sort() }).toMatchSnapshot();
});

test("equation at the cursor, spoken math and the check", () => {
    const at = source.indexOf("f\\lambda");
    expect(C.mathAt(source, at)).toMatchSnapshot();
    expect(C.mathAt(source, 0)).toBeNull();
    expect(C.mathSpeech("\\frac{a}{b}^2")).toMatchSnapshot();
    expect(C.mathCheck("\\frac{a}{b")).toMatchSnapshot();
    expect(C.mathCheck("x^2")).toMatchSnapshot();
});

test("theme resolve for each theme", () => {
    for (const t of C.themes()) expect(C.themeResolve(t.id, "")).toMatchSnapshot();
});

test("commit message from two versions", () => {
    expect(C.commitMessage("alpha\nbeta\n", "alpha\ngamma\ndelta\n")).toMatchSnapshot();
});

test("source checks give stable issues", () => {
    expect(C.lint("# Title\n\n![](missing.png)\n\nA very long sentence that goes on and on, and on, and then it still does not end for a long time.\n", {})).toMatchSnapshot();
});
