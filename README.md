# marklove-web

Marklove for the web turns one Markdown file into slides, an article, an EPUB book, subtitles, narration text and packages.

This is a port of the Marklove app for iPhone, iPad and Mac. The core is in [Goose](https://aardappel.github.io/), compiled to C and then to WebAssembly. The core does the parse, the checks, the render to HTML and MathML, the plots and the themes. It also does find and replace, sam and Vim, the ZIP files and the Git history. The core lays out the PDF pages, the slide images and the video frames as SVG. It traces the SVG slides, makes the video timeline and writes the MP4 file. JavaScript does only the page, the browser storage and the browser APIs: canvas, WebCodecs, MediaRecorder and the speech model.

![Block diagram. A Markdown file of at most 512 KB goes into the core, which is Goose compiled to C and then to WebAssembly. The core does the parse and checks, HTML and MathML, plots and themes, Find, sam and Vim, the Git history, the page and frame SVG, the ZIP entries and the MP4 header. JavaScript calls the core through the ml_* functions: it sends text and text widths, and gets HTML, SVG and bytes back. JavaScript does the page and editor, IndexedDB, text measurement, canvas, print to PDF, the Kokoro voice, WebCodecs and MediaRecorder. Photos, videos and audio stay in JavaScript as Blobs. The outputs are web pages, EPUB, PDF, PNG and SVG, MP4 and WebM, and the ZIP with .git.](docs/figures/architecture.svg)

*The core makes each output. JavaScript gives it the browser APIs and adds the media bytes, which never go into the core.*

All features are free. The web version has no subscription, no purchase and no Pro features.

## Use

The `web/` folder is a static site. It needs no server code and no network after it loads. The Kokoro voice is the exception: Settings downloads it (about 90 MB), and the browser keeps it. Narration also needs the network to get kokoro-js from jsDelivr. Copy the folder to any path on a web server, for example `/play/marklove/`. Then open `index.html`. The app chrome needs the shared stylesheet `/shared/kowalski.css` at the root of the same server. On teoyujie.org it is there.

To try it on your computer:

```sh
bun run serve
```

Then open <http://localhost:8000/>. This server has no `/shared/kowalski.css`. For local work, serve the `public/` folder of the site repository with this app in it, or accept chrome with no styles. Projects stay in the storage of your browser (IndexedDB). To move a project to another browser, export the project ZIP and import it there.

## Build

The app is TypeScript in `src/`. [Bun](https://bun.sh) installs the packages, bundles the code and runs the tests. Run `bun install` once.

Use Bun 1.4.4. The `packageManager` field in `package.json` pins this version. Another Bun version gives different bundles, so `bun run build:web` and `bun run check` stop when the version is different.

The repository contains the built files `web/app.js`, `web/runtime.js` and `web/article.js`. Build them again after you change a file in `src/`:

```sh
bun run build:web
```

The repository also contains the built files `web/marklove.mjs` and `web/marklove.wasm`. Build them again after you change a file in `core/`.

You need:

- The Goose compiler.
- Emscripten (`emcc`).

Run:

```sh
GOOSE=/path/to/goose EMCC=/path/to/emcc sh build.sh
```

The script does 2 steps:

1. Goose writes `build/marklove.c` and `build/marklove.h` from `core/marklove.goose`.
2. `emcc` compiles the C to `web/marklove.mjs` and `web/marklove.wasm`. It exports each `ml_*` function in the header.

## Test

```sh
bun run test
```

The tests use the built core through `src/core.ts`. The project ZIP test also runs `git fsck` on the exported history when Git is on your computer.

Before a review, run all local checks:

```sh
bun run check
```

The checks are:

- The type check (`tsc --noEmit`).
- The lint rules (no comments, no `any`, no type assertions).
- The dead-code check (knip).
- The state model hashes.
- The web bundles.
- The tests.
- The page size budget.
- A build of the generated C with the address and undefined-behavior sanitizers.
- A compile of the generated C with `-Wall -Wextra -Wpedantic -Werror`, with the code-generator warnings off (unused variables, functions, parameters, unused-but-set variables, unterminated string initializers, unused labels, and extraneous parentheses around equality), and the analyser with its dead-store check off. The analyser findings must match `scripts/c-analyzer-known.txt` exactly: a new finding fails, and a listed finding that no longer occurs also fails, so the list only shrinks. Run `sh scripts/c-warnings.sh --print` to see the current findings.
- The process replay.

The process replay (`bun run replay`) runs the tests with a capture switch. Then it gives each captured call to the base commit and to your working tree, in separate copies. It also compiles `core/marklove.goose` in both. It fails on each difference. When a change must change an output, run `bun run replay -- --accept` after you read the printed diff.

## Files

| Path | Contents |
| --- | --- |
| `core/marklove.goose` | The functions that JavaScript calls (`ml_*`). |
| `core/parse.goose` | The Markdown parser and the document model. |
| `core/render.goose` | The slides page, the article page and the EPUB book. |
| `core/deck.goose`, `core/sentence.goose` | The Normal and Takahashi slides, sentences and words. |
| `core/narr.goose` | The narration script, the transcript and the subtitles. |
| `core/texmath.goose`, `core/mathtable.goose` | LaTeX to MathML. |
| `core/plot.goose` | Plots as SVG. |
| `core/lint.goose` | The source checks. |
| `core/highlight.goose`, `core/theme.goose` | Source and code colors, and the themes. |
| `core/edit.goose`, `core/vim.goose` | Find and replace, sam commands, the line difference, commit messages, and Vim mode. |
| `core/pack.goose`, `core/gitexport.goose` | ZIP files, the project import, and the Git history. |
| `core/extras.goose` | The equation at the cursor, spoken math, the tour, the prompts and the listener text. |
| `core/layout.goose`, `core/pagesvg.goose` | The page layout of the slides, the video, the article, the handout and the poster, and each page as SVG. |
| `core/trace.goose` | Raster pixels to SVG shapes, for the SVG slide export. |
| `core/video.goose` | The video timeline, the podcast timing and the MP4 file. |
| `core/io.h` | The input buffers, the memory for the Goose data stacks, and the text and math measurement in the browser. |
| `src/core.ts` | The TypeScript interface to the core. |
| `web/index.html`, `src/app.ts`, `web/app.css` | The app page, its start and its styles. `web/app.js` is the bundle of `src/app.ts`. |
| `src/store.ts`, `src/ui.ts`, `src/editor.ts`, `src/find.ts`, `src/preview.ts`, `src/export.ts`, `src/panels.ts` | The app parts: storage and settings, controls, the editor, Find and Vim, the preview and presentation, export, and the other panels. |
| `src/pages.ts`, `src/video.ts`, `src/voice.ts` | The PDF pages, the PNG and SVG slides, the video and audio encoders, and the Kokoro voice. |
| `web/demo-peafowl.png` | The photo of the tour project. |
| `web/style.css`, `src/runtime.ts`, `web/article.css`, `src/article.ts` | The parts of the exported pages, based on Marklove. `web/style.css` and `web/article.css` add the shared interaction rules: press scale, a hover fade only on a fine pointer, and no tap highlight. Thus they differ from the native app. |
| `scripts/` | The local checks, the bundler and the process replay. |
| `docs/state/` | The state machines of the voice and the project save, with the tests of their fixed bugs. |
| `web/fonts/` | Courier Prime, Courier Prime Sans, Libre Baskerville and KpMath, with their licenses (SIL Open Font License). |

The Kokoro voice uses the web version of [kokoro-js](https://github.com/hexgrad/kokoro/tree/main/kokoro.js) 1.2.1 from jsDelivr. It runs the Kokoro-82M ONNX model (`onnx-community/Kokoro-82M-v1.0-ONNX`, q8) from Hugging Face. Both are under the Apache License 2.0.

## Limits

- The Markdown file can have a maximum size of 512 KB. Each Goose data stack has a fixed 8 MB in WebAssembly, and WebAssembly has no guard pages. Thus the core refuses a larger source. No stack can then overwrite other data. The same limit applies to each text that goes into the core, and to each result of Find, Replace, sam, Vim substitution and Vim put. Find and sam keep a maximum of 100000 matches. Marklove does not keep a text that is larger than 512 KB as a version. With Vim mode on and a text larger than 512 KB, Vim goes to Insert mode. Each key goes to the browser until the text is smaller. A long talk is less than 100 KB.
- Photos, videos and audio stay in JavaScript as Blobs. They never go into the core. The core writes the ZIP and Git entries for them, and JavaScript adds the bytes. The same applies to the encoded video and audio samples: the core writes the MP4 header, and JavaScript adds the samples.
- The SVG export traces regions with millions of pixels. The core keeps the arrays for these pixels in the C heap, not in a data stack.
- Encoders: browsers encode AAC only at 44.1 or 48 kHz, so the encoder encodes the 24 kHz voice at 48 kHz. Without AAC, the audio is Opus in the MP4 file. Without WebCodecs, MediaRecorder records the video or the podcast in real time as WebM.

## Feature parity

| Marklove feature | Web status |
| --- | --- |
| Projects: make, rename, duplicate, delete | Yes. The projects are in the browser storage. |
| Markdown editor with Courier Prime, line count and wrap | Yes. |
| Source colors in the editor | Yes. |
| Save each change at once, recovery of unsaved text | Yes. Each change goes to the browser storage. |
| Insert menu (Slide, Photo or Video, Equation, Speaker Notes, Pause, Title and Details) | Yes. |
| Equation preview with spoken text | Yes. |
| Find and Replace: Sam, Vim and plain text, the sam command line | Yes. |
| Sam Tutorial | Yes. |
| Vim mode | Yes. |
| Source checks with Go to Source | Yes. |
| Preview in the Normal and the Takahashi style | Yes. The preview is the interactive web page. |
| Speaker Ready (current and next slide, notes, timer) | Yes, in a second window. |
| Listener Preview | Yes. |
| Themes and accent colors | Yes. |
| Versions: automatic commits with commit messages, changes, restore | Yes. The versions are in the browser storage. The project ZIP holds them as a real `.git` history. |
| Import a project ZIP | Yes. The app does not import the `.git` history in the ZIP: the project starts with a new history. |
| The tour and the welcome | Yes. |
| Export: interactive web page, article web page, EPUB | Yes. |
| Export: article Markdown, revised Markdown, narration script, transcript, subtitles, prompt text | Yes. |
| Export: presenter ZIP, listener ZIP, project ZIP with `.git` | Yes. |
| Export: slides PDF, article PDF, handout, poster | Yes. The core lays out the pages as the app does, and the browser print dialog saves them as PDF. The browser measures the text with the same fonts. |
| Export: slides as PNG images or SVG files | Yes. A canvas draws the PNG images. For SVG, the core traces the text, photos, equations and plots into vector shapes, as the app does. |
| Export: video, narrated video, math animation video, podcast | Yes. WebCodecs encodes H.264 and AAC, and the core writes the MP4 file. Without WebCodecs, MediaRecorder makes a WebM file. |
| Narration voice (Kokoro on the device) | Yes. The voice is the kokoro-js web version of Kokoro-82M. It runs in the browser. The web version has 28 English voices. For a voice that it does not have, it uses `af_heart`. |
| iCloud sync and merge between devices | Not possible on the web. iCloud Drive is available only to apps on Apple platforms. |
| Command line tool and Shortcuts actions | Not possible on the web. A web page cannot add a command to Terminal or to the Shortcuts app. |
| VoiceOver rotors, Dynamic Type, Bold Text | Not possible on the web. These are Apple system features. The web page uses the zoom, the screen reader and the reduced motion setting of the browser. |
| Languages other than English | Not yet. The app text is in Xcode string catalogs, and the web version has only the English text. |
| Marklove Pro purchase (StoreKit) | Removed. All features are free. |
