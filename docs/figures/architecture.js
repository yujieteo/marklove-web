// Source of architecture.svg: schematic-figure skill with the schematic-emil style.
// To render: put this file at <dir>/figure/figure.js, with emil.js and fonts/ from schematic-emil
// in <dir>/figure/, then run node tools/render.mjs --root <dir> --fig <dir>/figure/figure.js
// from the schematic-figure foundation, and copy figure/out/architecture.svg here.
// marklove-web architecture: which part does what, and what passes between the
// WebAssembly core and JavaScript. Style: schematic-emil (venue web), drawn with
// the schematic-figure skill. Every label comes from README.md or the code
// (web/core.js, core/io.h, web/store.js, web/video.js, web/export.js).
// Hero: none, a software block diagram has no physical object.
// Layout in site px (1 px = 0.5 pt). The figure is 400 px wide, so that the README
// can show it at 400 px: 14 px labels on a desktop, 12 px on a 375 px phone.
import * as E from './emil.js';

const WPX = 400, HPX = 748;
export const figure = { width: WPX * 0.5 / 2.834645669, height: HPX * 0.5 / 2.834645669, name: 'architecture', format: 'journal' };

export default function draw(F, L) {
  const { s, r, line } = E.useEmil(F, L, 'web');
  const G = E.gray, H = E.hue, W = E.weight;
  const p = (v) => v * s;                                   // site px to pt
  const T = (x, y, str, o = {}) => L.text(F.root, p(x), p(y), str, { size: p(14), anchor: 'middle', valign: 'middle', color: G[1200], weight: W.text, ...o });
  const small = (x, y, str, o = {}) => T(x, y, str, { size: p(12), color: G[1100], ...o });
  const rect = (x, y, w, h, st) => L.rect(F.root, p(x), p(y), p(w), p(h), { width: line.thin, ...st });
  const arrow = (x, y0, y1) => L.arrow(F.root, [p(x), p(y0)], [p(x), p(y1)], { stroke: G[1100], width: line.bold, head: p(10), headWidth: p(9) });
  const chip = (x, y, w, h, hue, str) => {
    rect(x, y, w, h, { fill: G[100], stroke: hue ? hue[7] : G[400], r: r.chip });
    T(x + w / 2, y + h / 2, str, { weight: W.name });
  };
  const M = 16, PAD = 12, GW = WPX - 2 * M, ROW = 32, GAP = 8;
  const colW = (GW - 2 * PAD - GAP) / 2;
  const grid = (y0, hue, items) => items.forEach((str, i) =>
    chip(M + PAD + (i % 2) * (colW + GAP), y0 + Math.floor(i / 2) * (ROW + GAP), colW, ROW, hue, str));
  const group = (y, hue, title, note, items, extra = 0) => {
    const rows = Math.ceil(items.length / 2);
    const h = 44 + rows * ROW + (rows - 1) * GAP + extra + PAD;
    rect(M, y, GW, h, { fill: hue[3], stroke: hue[7], r: r.card });
    T(M + PAD + 4, y + 22, title, { anchor: 'start', weight: W.title, color: hue[11] });
    small(WPX - M - PAD - 4, y + 22, note, { anchor: 'end', color: hue[11] });
    grid(y + 44, hue, items);
    return y + h;
  };

  // 1. the source
  rect(80, 16, 240, 52, { ...E.card(r.card), stroke: G[400] });
  T(200, 35, 'Markdown file', { weight: W.name });
  small(200, 54, 'max. 512 KB');
  arrow(200, 68, 108);
  small(210, 88, 'source text', { anchor: 'start' });

  // 2. the core
  const coreB = group(108, H.orange, 'Core', 'Goose → C → WebAssembly',
    ['Parse, checks', 'HTML, MathML', 'Plots, themes', 'Find, sam, Vim', 'Git history', 'Page, frame SVG', 'ZIP entries', 'MP4 header']);

  // 3. the calls between the core and JavaScript
  const jsY = coreB + 64;
  arrow(130, coreB, jsY);
  L.arrow(F.root, [p(270), p(jsY)], [p(270), p(coreB)], { stroke: G[1100], width: line.bold, head: p(10), headWidth: p(9) });
  small(120, coreB + 24, 'HTML, SVG,', { anchor: 'end' });
  small(120, coreB + 41, 'bytes', { anchor: 'end' });
  small(280, coreB + 24, 'text,', { anchor: 'start' });
  small(280, coreB + 41, 'text widths', { anchor: 'start' });
  T(200, coreB + 32, 'ml\\_\\* calls', { weight: W.name });

  // 4. JavaScript, with the media that never goes into the core
  const jsItems = ['Page, editor', 'IndexedDB', 'Measure text', 'Canvas', 'Print to PDF', 'Kokoro voice', 'WebCodecs', 'MediaRecorder'];
  const blobY = jsY + 44 + 4 * (ROW + GAP);
  const jsB = group(jsY, H.blue, 'JavaScript', 'browser APIs', jsItems, ROW + GAP);
  rect(M + PAD, blobY, GW - 2 * PAD, ROW, { fill: H.tomato[3], stroke: H.tomato[7], r: r.chip });
  T(WPX / 2, blobY + ROW / 2, 'Photos, videos, audio (Blobs)', { weight: W.name, color: H.tomato[11] });

  // 5. the outputs
  const outY = jsB + 32;
  arrow(200, jsB, outY);
  const ow = (GW - 2 * GAP) / 3;
  ['Web pages', 'EPUB', 'PDF', 'PNG, SVG', 'MP4, WebM', 'ZIP, .git'].forEach((str, i) =>
    chip(M + (i % 3) * (ow + GAP), outY + Math.floor(i / 3) * (ROW + GAP), ow, ROW, null, str));
  E.emilTheme(F);
}
