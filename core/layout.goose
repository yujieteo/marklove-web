// Fixed pages, as the app's layout model (MarkloveCore/Layout): slides on a
// 960 × 540 canvas, the article on A4 or Letter pages, the handout, and the
// conference poster. Slide PDF, slide images, video frames, the article PDF,
// the handout and the poster all use these pages.
//
// The browser is the TextMeasurer: io.h asks it for the advance of a piece
// of text in a CSS font and for the size of an equation. The line breaks
// are made here, and the page renderer (pagesvg.goose) uses the same breaks.
// Coordinates are points, with the origin at the top left.
//
// The app builds flow items with closures. Here an item is data: a kind and
// its values, and `make` places the boxes for each kind.

import render;
import theme;
import extras;

extern fn ml_measure(text: const u8[:], font: const u8[:]) -> f64;
extern fn ml_math_metric(latex: const u8[:], display: i32, which: i32) -> f64;

// --- styled text -------------------------------------------------------------

let FA_BODY = 0;
let FA_HEAD = 1;
let FA_CODE = 2;

let AL_LEFT = 0;
let AL_CENTER = 1;
let AL_RIGHT = 2;
let AL_JUST = 3;

// Color roles. CR_SERIES + k is the series color k; CR_HL + a highlight role.
let CR_NONE = -1;
let CR_TEXT = 0;
let CR_STRONG = 1;
let CR_DIM = 2;
let CR_ACCENT = 3;
let CR_BG = 4;
let CR_SURFACE = 5;
let CR_BORDER = 6;
let CR_SERIES = 10;
let CR_HL = 40;

// Run styles.
let RF_BOLD = 1;
let RF_ITALIC = 2;
let RF_CODE = 4;
let RF_STRIKE = 8;
// Inline LaTeX: the run text is the LaTeX, and the run is one unit.
let RF_MATH = 16;

// The text of every run, link, equation and path of the current layout.
var TB: u8[>..] = [];

struct Run { a: i64, b: i64, fl: i64, color: i64, link: Line }
var RUNS: Run[>..] = [];

// A paragraph of styled text: runs r0..r1, and the text window lo..hi in TB.
// A slice of a paragraph is the same runs with a smaller window.
struct Txt {
    r0: i64, r1: i64, lo: i64, hi: i64,
    fam: i64, size: f64, bold: bool, italic: bool,
    lh: f64, align: i64, color: i64, indent: f64,
}
var TXTS: Txt[>..] = [];

fn tb_line(t: u8[:]) -> Line {
    let a = TB.len;
    TB.append(t);
    return Line { a, TB.len };
}

fn tb(l: Line) -> u8[:] { TB[l.s..l.e] }

fn add_run(t: u8[:], fl: i64, color: i64, link: Line) {
    let a = TB.len;
    TB.append(t);
    RUNS.push(Run { a, TB.len, fl, color, link });
}

fn lk0() -> Line { Line { 0, 0 } }

// Inline math that the browser renders, or the LaTeX as code.
fn math_run(latex: u8[:], fl: i64, color: i64, link: Line) {
    if math_ok(latex, false) { add_run(latex, fl | RF_MATH, color, link); return; }
    var t: u8[>..] = [];
    t.push('$');
    t.append(latex);
    t.push('$');
    add_run(t, fl | RF_CODE, color, link);
}

// RunBuilder.runs: the inline events lo..hi as runs.
fn inline_runs(lo: i64, hi: i64) {
    var fl: i64[>..] = [0];
    var col: i64[>..] = [CR_NONE];
    var lk: Line[>..] = [lk0()];
    for i in lo..hi {
        let e = EV[i];
        let k = e.k;
        if e.close {
            if (k == I_EM || k == I_STRONG || k == I_DEL || k == I_LINK) && fl.len > 1 {
                fl.resize(fl.len - 1);
                col.resize(col.len - 1);
                lk.resize(lk.len - 1);
            }
            continue;
        }
        let top = fl.len - 1;
        let f = fl[top];
        let c = col[top];
        let l = lk[top];
        if k == I_TEXT { add_run(sp_text(e.a), f, c, l); }
        else if k == I_EM { fl.push(f ^ RF_ITALIC); col.push(c); lk.push(l); }
        else if k == I_STRONG { fl.push(f | RF_BOLD); col.push(c); lk.push(l); }
        else if k == I_DEL { fl.push(f | RF_STRIKE); col.push(c); lk.push(l); }
        else if k == I_LINK { fl.push(f); col.push(CR_ACCENT); lk.push(tb_line(sp_text(e.b))); }
        else if k == I_CODE { add_run(sp_text(e.a), f | RF_CODE, c, l); }
        else if k == I_MATH { math_run(sp_text(e.a), f, c, l); }
        else if k == I_IMG {
            var t: u8[>..] = [];
            t.push('[');
            t.append(sp_text(e.a));
            t.push(']');
            add_run(t, f ^ RF_ITALIC, c, l);
        }
        else if k == I_SOFT { add_run(" ", f, c, l); }
        else if k == I_HARD { add_run("\n", f, c, l); }
        else if k == I_HTML { add_run(sp_text(e.a), f | RF_CODE, c, l); }
    }
}

// Inline Markdown that is not in the source (a box title, public notes).
fn markdown_runs(t: u8[:]) {
    var copy: u8[>..] = [];
    copy.append(t);
    let mark = EV.len;
    let lo, hi = inline_text(copy);
    inline_runs(lo, hi);
    EV.resize(mark);
}

// A paragraph of the runs from r0 to the last run.
fn new_txt(r0: i64, fam: i64, size: f64) -> i64 {
    let r1 = RUNS.len;
    let lo = if r0 < r1 { RUNS[r0].a } else { TB.len };
    let hi = if r0 < r1 { RUNS[r1 - 1].b } else { TB.len };
    TXTS.push(Txt { r0, r1, lo, hi, fam, size, false, false, ST.lh, if ST.just { AL_JUST } else { AL_LEFT }, CR_TEXT, 0.0 });
    return TXTS.len - 1;
}

fn plain_txt(t: u8[:], fam: i64, size: f64) -> i64 {
    let r0 = RUNS.len;
    add_run(t, 0, CR_NONE, lk0());
    return new_txt(r0, fam, size);
}

// FlowLayouter.body: inline events as a paragraph.
fn body_txt(lo: i64, hi: i64, size: f64) -> i64 {
    let r0 = RUNS.len;
    inline_runs(lo, hi);
    return new_txt(r0, FA_BODY, size);
}

fn set_txt(ti: i64, fam: i64, bold: bool, italic: bool, color: i64, align: i64) {
    TXTS[ti].fam = fam;
    TXTS[ti].bold = bold;
    TXTS[ti].italic = italic;
    TXTS[ti].color = color;
    TXTS[ti].align = align;
}

fn slice_txt(ti: i64, lo: i64, hi: i64) -> i64 {
    var t = TXTS[ti];
    if lo > t.lo { t.indent = 0.0; }
    t.lo = lo;
    t.hi = hi;
    TXTS.push(t);
    return TXTS.len - 1;
}

// --- typography and metrics -------------------------------------------------

// Typography (Theme.swift): the fonts of each output.
let TY_SLIDES = 0;
let TY_ARTICLE = 1;
let TY_HANDOUT = 2;
let TY_VIDEO = 3;
var TYPO = 0;

let FONT_BASK = "\"Libre Baskerville\",Baskerville,serif";
let FONT_PALA = "Palatino,\"Palatino Linotype\",\"TeX Gyre Pagella\",\"Book Antiqua\",serif";
let FONT_CP = "\"Courier Prime\",Courier,monospace";
let FONT_CPS = "\"Courier Prime Sans\",\"Courier Prime\",Courier,monospace";

fn family_css(fam: i64) -> const u8[:] {
    if TYPO == TY_HANDOUT { return FONT_CP; }
    if fam == FA_CODE { return FONT_CPS; }
    if TYPO == TY_SLIDES { return FONT_BASK; }
    return FONT_PALA;
}

// The font of a run (TextStyler.attributedString).
fn run_fam(t: Txt, r: Run) -> i64 { if (r.fl & RF_CODE) != 0 { FA_CODE } else { t.fam } }
fn run_size(t: Txt, r: Run) -> f64 { if (r.fl & RF_CODE) != 0 && t.fam != FA_CODE { t.size * 0.92 } else { t.size } }
fn run_bold(t: Txt, r: Run) -> bool { t.bold || (r.fl & RF_BOLD) != 0 }
fn run_italic(t: Txt, r: Run) -> bool { t.italic != ((r.fl & RF_ITALIC) != 0) }

var FONT: u8[>..] = [];

// The CSS font at 100 px, for ml_measure.
fn font_100(t: Txt, r: Run) {
    FONT.clear();
    if run_italic(t, r) { FONT.append("italic "); }
    FONT.append(if run_bold(t, r) { "700 " } else { "400 " });
    FONT.append("100px ");
    FONT.append(family_css(run_fam(t, r)));
}

fn text_width(text: u8[:], t: Txt, r: Run) -> f64 {
    if text.len == 0 { return 0.0; }
    font_100(t, r);
    return ml_measure(text, FONT) * run_size(t, r) / 100.0;
}

// The distance from a line's bottom to its baseline: the font descent.
fn descent(size: f64) -> f64 {
    if TYPO == TY_HANDOUT { return size * 0.25; }
    return size * 0.27;
}

// Equation metrics for a font size of 1 point: width, ascent, descent.
fn math_metrics(latex: u8[:], display: bool) -> f64, f64, f64 {
    let d: i32 = if display { 1 } else { 0 };
    return ml_math_metric(latex, d, 0), ml_math_metric(latex, d, 1), ml_math_metric(latex, d, 2);
}

// MathSupport, then the browser: true when the equation renders.
fn math_ok(latex: u8[:], display: bool) -> bool {
    if math_check(latex).len > 0 || unbalanced_brace(latex) { return false; }
    let w, a, d = math_metrics(latex, display);
    return w >= 0.0 && a >= 0.0 && d >= 0.0;
}

// --- line breaks -----------------------------------------------------------

// A piece of a line: bytes a..b of run r. w is the advance without the
// trailing spaces, ws with them. A line break can follow each piece.
struct Piece { a: i64, b: i64, r: i64, w: f64, ws: f64, nl: bool }
var PCS: Piece[>..] = [];

// A line: pieces p0..p1, bytes a..b, the width without trailing spaces,
// and true when it ends with a line break.
struct LineI { p0: i64, p1: i64, a: i64, b: i64, w: f64, hard: bool }
var LNS: LineI[>..] = [];

fn pieces(ti: i64) {
    PCS.clear();
    let t = TXTS[ti];
    for r in t.r0..t.r1 {
        let run = RUNS[r];
        let s = max(run.a, t.lo);
        let e = min(run.b, t.hi);
        if s >= e { continue; }
        if (run.fl & RF_MATH) != 0 {
            let w, a, d = math_metrics(TB[run.a..run.b], false);
            let mw = max(w, 0.0) * t.size;
            PCS.push(Piece { s, e, r, mw, mw, false });
            continue;
        }
        var i = s;
        while i < e {
            if TB[i] == '\n' {
                PCS.push(Piece { i, i + 1, r, 0.0, 0.0, true });
                i++;
                continue;
            }
            var j = i;
            while j < e && TB[j] != '\n' {
                let c = TB[j];
                j++;
                if c == ' ' {
                    while j < e && TB[j] == ' ' { j++; }
                    break;
                }
                if c == '-' && j < e && TB[j] != ' ' && j - 1 > i { break; }
            }
            var k = j;
            while k > i && TB[k - 1] == ' ' { k--; }
            let w = text_width(TB[i..k], t, run);
            let ws = if k < j { text_width(TB[i..j], t, run) } else { w };
            PCS.push(Piece { i, j, r, w, ws, false });
            i = j;
        }
    }
}

fn next_char(i: i64) -> i64 {
    var j = i + 1;
    while j < TB.len && (TB[j] & 0xC0) == 0x80 { j++; }
    return j;
}

// Splits piece k at the longest start that fits in `avail` (at least one
// character), for a word that is wider than the line.
fn split_piece(ti: i64, k: i64, avail: f64) {
    let t = TXTS[ti];
    let p = PCS[k];
    let run = RUNS[p.r];
    var cut = next_char(p.a);
    var j = cut;
    while j < p.b {
        let n = next_char(j);
        if text_width(TB[p.a..n], t, run) > avail { break; }
        cut = n;
        j = n;
    }
    if cut >= p.b { return; }
    let w = text_width(TB[p.a..cut], t, run);
    var rest = p;
    rest.a = cut;
    var k2 = cut;
    while k2 < p.b && TB[k2] != ' ' { k2++; }
    var e = p.b;
    while e > cut && TB[e - 1] == ' ' { e--; }
    rest.w = text_width(TB[cut..e], t, run);
    rest.ws = if e < p.b { text_width(TB[cut..p.b], t, run) } else { rest.w };
    PCS[k] = Piece { p.a, cut, p.r, w, w, false };
    PCS.insert_at(k + 1, rest);
}

fn push_line(p0: i64, p1: i64, a: i64, w: f64, hard: bool) {
    let b = if p1 > p0 { PCS[p1 - 1].b } else { a };
    LNS.push(LineI { p0, p1, if p1 > p0 { PCS[p0].a } else { a }, b, w, hard });
}

// The lines of a paragraph at a width (CoreTextMeasurer.measure).
fn break_lines(ti: i64, width: f64) {
    pieces(ti);
    LNS.clear();
    let t = TXTS[ti];
    var start = 0;
    var x = 0.0;
    var wcore = 0.0;
    var k = 0;
    while k < PCS.len {
        let p = PCS[k];
        let avail = width - (if LNS.len == 0 { t.indent } else { 0.0 });
        if p.nl {
            push_line(start, k + 1, p.a, wcore, true);
            start = k + 1;
            x = 0.0;
            wcore = 0.0;
            k++;
            continue;
        }
        if k > start && x + p.w > avail + 0.01 {
            push_line(start, k, p.a, wcore, false);
            start = k;
            x = 0.0;
            wcore = 0.0;
            continue;
        }
        if k == start && p.w > avail + 0.01 && (RUNS[p.r].fl & RF_MATH) == 0 && next_char(p.a) < p.b {
            split_piece(ti, k, avail);
            let q = PCS[k];
            if q.b < p.b {
                push_line(start, k + 1, q.a, q.w, false);
                start = k + 1;
                x = 0.0;
                wcore = 0.0;
                k++;
                continue;
            }
        }
        wcore = x + p.w;
        x += p.ws;
        k++;
    }
    if start < PCS.len || LNS.len == 0 { push_line(start, PCS.len, t.hi, wcore, false); }
}

fn line_h(ti: i64) -> f64 { TXTS[ti].size * TXTS[ti].lh }

// TextMeasure: the height and the widest line.
fn measure(ti: i64, width: f64) -> f64, f64 {
    break_lines(ti, width);
    var w = 0.0;
    for l in LNS { w = max(w, l.w); }
    return (LNS.len as f64) * line_h(ti), w;
}

fn measure_h(ti: i64, width: f64) -> f64 {
    let h, w = measure(ti, width);
    return h;
}

// --- layout style ----------------------------------------------------------

struct LStyle {
    body: f64, code: f64, caption: f64,
    h1: f64, h2: f64, h3: f64, h4: f64, h5: f64, h6: f64,
    lh: f64, gap: f64, li: f64, bpad: f64, dms: f64, shrink: f64,
    pind: f64, just: bool, mff: f64,
}

fn style_slides() -> LStyle {
    LStyle { 22.0, 16.0, 14.0, 30.0, 26.0, 22.0, 20.0, 19.0, 18.0, 1.3, 12.0, 26.0, 12.0, 1.2, 0.7, 0.0, false, 0.45 }
}

fn style_article() -> LStyle {
    LStyle { 11.0, 9.0, 9.5, 17.0, 14.0, 12.0, 11.0, 11.0, 11.0, 1.28, 7.0, 18.0, 8.0, 1.1, 0.7, 16.0, true, 0.42 }
}

fn scaled(s0: LStyle, f: f64) -> LStyle {
    var s = s0;
    s.body *= f; s.code *= f; s.caption *= f;
    s.h1 *= f; s.h2 *= f; s.h3 *= f; s.h4 *= f; s.h5 *= f; s.h6 *= f;
    s.gap *= f; s.li *= f; s.bpad *= f; s.pind *= f;
    return s;
}

fn head_size(level: i64) -> f64 {
    let l = min(max(level, 1), 6);
    if l == 1 { return ST.h1; }
    if l == 2 { return ST.h2; }
    if l == 3 { return ST.h3; }
    if l == 4 { return ST.h4; }
    if l == 5 { return ST.h5; }
    return ST.h6;
}

var ST = LStyle { 22.0, 16.0, 14.0, 30.0, 26.0, 22.0, 20.0, 19.0, 18.0, 1.3, 12.0, 26.0, 12.0, 1.2, 0.7, 0.0, false, 0.45 };
// True for flowing pages (the article and the poster): figures have a fixed height.
var FLOWING = false;
// Static outputs (PDF, images, handout) show every equation step.
var STACK_EQ = false;
var PAGE_H = 0.0;
// Article scope and no reveal steps.
var LART = false;
var LSTEP = 0;
var LDEPTH = 0;
// The article: the first paragraph after a heading has no indent.
var AFTER_HEAD = false;

// --- boxes and pages --------------------------------------------------------

let BX_TEXT = 0;
let BX_LABEL = 1;
let BX_MATH = 2;
let BX_TEXFB = 3;
let BX_MEDIA = 4;
let BX_MISSING = 5;
let BX_FILL = 6;
let BX_STROKE = 7;
let BX_ACCENT = 8;
let BX_RULE = 9;
let BX_PLOT = 10;
let BX_CHART = 11;
let BX_THUMB = 12;

// LayoutBox. Text kinds: a = paragraph. Math: p = LaTeX, c = font size.
// Media: p = path, a = media kind, q = description (empty when
// decorative). Missing media: a = paragraph, q = description. Fill: c =
// corner radius. Stroke and rule: c = line width. Plot and chart: a = the
// division event, c = font size. Thumbnail: a = the slide page.
struct Box {
    x: f64, y: f64, w: f64, h: f64,
    kind: i64, first: i64, last: i64,
    a: i64, c: f64, color: i64, p: Line, q: Line,
}
var BOXES: Box[>..] = [];

fn add_box(x: f64, y: f64, w: f64, h: f64, kind: i64, step: i64) -> i64 {
    BOXES.push(Box { x, y, w, h, kind, step, -1, 0, 0.0, CR_NONE, lk0(), lk0() });
    return BOXES.len - 1;
}

fn text_box(x: f64, y: f64, w: f64, h: f64, ti: i64, step: i64) {
    let b = add_box(x, y, w, h, BX_TEXT, step);
    BOXES[b].a = ti;
}

fn shape_box(x: f64, y: f64, w: f64, h: f64, kind: i64, color: i64, c: f64, step: i64) {
    let b = add_box(x, y, w, h, kind, step);
    BOXES[b].color = color;
    BOXES[b].c = c;
}

// PageLayout: boxes b0..b1, the reveal steps, the slide (or -1) and the
// frame of the slide.
struct Page { w: f64, h: f64, b0: i64, b1: i64, steps: i64, slide: i64, frame: i64, title: Line }
var PAGES: Page[>..] = [];
// The pages of the output start here (the handout puts its slides first).
var OUT0 = 0;
// Layout warnings for the export notes, one on each line.
var LWARN: u8[>..] = [];

fn add_page(w: f64, h: f64, b0: i64, steps: i64, slide: i64, frame: i64, title: Line) {
    PAGES.push(Page { w, h, b0, BOXES.len, steps, slide, frame, title });
}

// --- flow items ------------------------------------------------------------

let IT_TEXT = 0;
let IT_CODE = 1;
let IT_MATH = 2;
let IT_TEXFB = 3;
let IT_EQSTEPS = 4;
let IT_GRAPHIC = 5;
let IT_MEDIA = 6;
let IT_MISSING = 7;
let IT_TABLE = 8;
let IT_BOX = 9;
let IT_COLUMNS = 10;
let IT_SPACER = 11;

// FlowItem. x0 and w place the content in the item. Text and code: a =
// paragraph (code: f = padding). Math: p = LaTeX, f = font size, g =
// equation height, e = equation width; last = the last step or -1.
// Equation steps: children c0..c1 in CH, b = 1 to stack them. Graphic: a =
// division, b = 1 for a chart, f = font size. Media: p = path, q =
// description, b = media kind. Missing: a = paragraph, q = description.
// Table: a = table (TBLS), rows c0..c1, b = 1 with the header row. Box:
// children c0..c1, f = padding, g = content height, e = gap, color =
// accent. Columns: CH from c0 holds, for each column, its count and its
// children; f = column width, g = column gap, e = stack gap, b = columns.
// A list marker (paragraph `marker` at x `mx`) and quote bars (x positions
// bar1 and bar2, or -1) are drawn with the first item.
struct Item {
    kind: i64, h: f64, flex: bool, minh: f64, maxh: f64, keep: bool, split: bool,
    step: i64, last: i64, x0: f64, w: f64,
    a: i64, b: i64, c0: i64, c1: i64,
    f: f64, g: f64, e: f64, color: i64,
    p: Line, q: Line,
    marker: i64, mx: f64, bar1: f64, bar2: f64,
}
var ITEMS: Item[>..] = [];
var CH: i64[>..] = [];
// Items that a conversion makes, in order.
var OUTL: i64[>..] = [];

fn new_item(kind: i64, h: f64, step: i64, x0: f64, w: f64) -> i64 {
    ITEMS.push(Item { kind, h, false, 0.0, h, false, false, step, -1, x0, w, 0, 0, 0, 0, 0.0, 0.0, 0.0, CR_NONE,
                      lk0(), lk0(), -1, 0.0, -1.0, -1.0 });
    return ITEMS.len - 1;
}

fn text_item(ti: i64, width: f64, step: i64, x0: f64, keep: bool) -> i64 {
    break_lines(ti, width);
    let n = LNS.len;
    let it = new_item(IT_TEXT, (n as f64) * line_h(ti), step, x0, width);
    ITEMS[it].a = ti;
    ITEMS[it].keep = keep;
    ITEMS[it].split = n >= 2;
    return it;
}

// Table data: column widths in TF from w0, cell paragraphs in TI from c0
// (the header row first), row heights in TF from rh0.
struct Tbl { cols: i64, rows: i64, w0: i64, c0: i64, rh0: i64, bpad: f64, tw: f64 }
var TBLS: Tbl[>..] = [];
var TF: f64[>..] = [];
var TI: i64[>..] = [];

// The arena sizes, to take back a layout attempt.
struct Mark { items: i64, ch: i64, txts: i64, runs: i64, tb: i64, outl: i64, tbls: i64, tf: i64, ti: i64 }

fn mark() -> Mark { Mark { ITEMS.len, CH.len, TXTS.len, RUNS.len, TB.len, OUTL.len, TBLS.len, TF.len, TI.len } }

fn rewind(m: Mark) {
    ITEMS.resize(m.items);
    CH.resize(m.ch);
    TXTS.resize(m.txts);
    RUNS.resize(m.runs);
    TB.resize(m.tb);
    OUTL.resize(m.outl);
    TBLS.resize(m.tbls);
    TF.resize(m.tf);
    TI.resize(m.ti);
}

// --- making boxes ----------------------------------------------------------

fn make_table(it: Item, x: f64, y: f64) {
    let t = TBLS[it.a];
    var yy = y;
    var r = if it.b == 1 { -1 } else { it.c0 };
    while r < it.c1 {
        let row = r + 1;
        let rh = TF[t.rh0 + row];
        if r == -1 { shape_box(x + it.x0, yy, t.tw, rh, BX_FILL, CR_SURFACE, 0.0, it.step); }
        var xx = x + it.x0;
        for c in t.cols {
            let cw = TF[t.w0 + c];
            text_box(xx + t.bpad, yy + t.bpad, cw - 2.0 * t.bpad, rh - 2.0 * t.bpad, TI[t.c0 + row * t.cols + c], it.step);
            xx += cw;
        }
        yy += rh;
        shape_box(x + it.x0, yy - 0.5, t.tw, 1.0, BX_RULE, CR_BORDER, 1.0, it.step);
        r = if r == -1 { it.c0 } else { r + 1 };
    }
}

recursive fn make_stack(c0: i64, c1: i64, x: f64, y: f64, gap: f64) {
    var yy = y;
    for k in c0..c1 {
        let ci = CH[k];
        make(ci, x, yy, ITEMS[ci].h);
        yy += ITEMS[ci].h + gap;
    }
}

// FlowItem.make: the boxes of an item at a position, with its final height.
recursive fn make(ii: i64, x: f64, y: f64, h: f64) {
    let it = ITEMS[ii];
    if it.bar2 >= 0.0 { shape_box(x + it.bar2, y, 3.0, h, BX_ACCENT, CR_BORDER, 0.0, it.step); }
    if it.bar1 >= 0.0 { shape_box(x + it.bar1, y, 3.0, h, BX_ACCENT, CR_BORDER, 0.0, it.step); }
    if it.marker >= 0 {
        let b = add_box(x + it.mx, y, ST.li, line_h(it.marker), BX_LABEL, it.step);
        BOXES[b].a = it.marker;
    }
    let k = it.kind;
    if k == IT_TEXT { text_box(x + it.x0, y, it.w, h, it.a, it.step); }
    else if k == IT_CODE {
        shape_box(x + it.x0, y, it.w, h, BX_FILL, CR_SURFACE, 4.0, it.step);
        text_box(x + it.x0 + it.f, y + it.f, it.w - 2.0 * it.f, h - 2.0 * it.f, it.a, it.step);
    }
    else if k == IT_MATH {
        let b = add_box(x + it.x0 + (it.w - it.e) / 2.0, y + (h - it.g) / 2.0, it.e, it.g, BX_MATH, it.step);
        BOXES[b].last = it.last;
        BOXES[b].p = it.p;
        BOXES[b].c = it.f;
        BOXES[b].color = CR_TEXT;
    }
    else if k == IT_TEXFB {
        let b = add_box(x + it.x0, y, it.w, h, BX_TEXFB, it.step);
        BOXES[b].a = it.a;
        BOXES[b].last = it.last;
    }
    else if k == IT_EQSTEPS {
        var yy = y;
        for c in it.c0..it.c1 {
            let ci = CH[c];
            let ch = ITEMS[ci].h;
            if it.b == 1 {
                let b0 = BOXES.len;
                make(ci, x, yy, ch);
                for b in b0..BOXES.len { BOXES[b].first = it.step; BOXES[b].last = -1; }
                yy += ch;
            } else {
                make(ci, x, y, h);
            }
        }
    }
    else if k == IT_GRAPHIC {
        let b = add_box(x + it.x0, y, it.w, h, if it.b == 1 { BX_CHART } else { BX_PLOT }, it.step);
        BOXES[b].a = it.a;
        BOXES[b].c = it.f;
    }
    else if k == IT_MEDIA {
        // Fit the whole image, keep its proportions, and center it.
        let aspect = it.f;
        let w = min(it.w, h / aspect);
        let mh = w * aspect;
        let b = add_box(x + it.x0 + (it.w - w) / 2.0, y + (h - mh) / 2.0, w, mh, BX_MEDIA, it.step);
        BOXES[b].p = it.p;
        BOXES[b].q = it.q;
        BOXES[b].a = it.b;
    }
    else if k == IT_MISSING {
        let b = add_box(x + it.x0, y, it.w, h, BX_MISSING, it.step);
        BOXES[b].a = it.a;
        BOXES[b].q = it.q;
        BOXES[b].c = it.f;
    }
    else if k == IT_TABLE { make_table(it, x, y); }
    else if k == IT_BOX {
        shape_box(x + it.x0, y, it.w, h, BX_FILL, CR_SURFACE, 4.0, it.step);
        shape_box(x + it.x0, y, 4.0, h, BX_ACCENT, it.color, 0.0, it.step);
        make_stack(it.c0, it.c1, x + it.x0 + it.f + 4.0, y + it.f, it.e);
    }
    else if k == IT_COLUMNS {
        var at = it.c0;
        for col in it.b {
            let n = CH[at];
            make_stack(at + 1, at + 1 + n, x + it.x0 + (col as f64) * (it.f + it.g), y, it.e);
            at += 1 + n;
        }
    }
}

// --- splitting --------------------------------------------------------------

// FlowItem.split: two items, the first of which fits in `avail`, or -1.
fn split_item(ii: i64, avail: f64) -> i64, i64 {
    let it = ITEMS[ii];
    if !it.split { return -1, -1; }
    if it.kind == IT_TEXT || it.kind == IT_CODE {
        let code = it.kind == IT_CODE;
        let bpad = if code { it.f } else { 0.0 };
        let inner = if code { it.w - 2.0 * bpad } else { it.w };
        break_lines(it.a, inner);
        let n = LNS.len;
        let lh = line_h(it.a);
        var acc = 2.0 * bpad;
        var count = 0;
        for l in LNS {
            if acc + lh > avail { break; }
            acc += lh;
            count++;
        }
        // Keep at least two lines on each side when possible.
        if !code && count < n && n >= 4 {
            count = min(count, n - 2);
            if count < 2 { return -1, -1; }
        }
        if count < 1 || count >= n { return -1, -1; }
        let cut = LNS[count - 1].b;
        let t = TXTS[it.a];
        let first = slice_txt(it.a, t.lo, cut);
        let rest = slice_txt(it.a, cut, t.hi);
        if code { return code_item_txt(first, it.w, it.x0, bpad, it.step), code_item_txt(rest, it.w, it.x0, bpad, it.step); }
        return text_item(first, it.w, it.step, it.x0, false), text_item(rest, it.w, it.step, it.x0, it.keep);
    }
    if it.kind == IT_TABLE {
        let t = TBLS[it.a];
        var acc = if it.b == 1 { TF[t.rh0] } else { 0.0 };
        var count = 0;
        for r in it.c0..it.c1 {
            let rh = TF[t.rh0 + r + 1];
            if acc + rh > avail { break; }
            acc += rh;
            count++;
        }
        if count < 1 || count >= it.c1 - it.c0 { return -1, -1; }
        let mid = it.c0 + count;
        return table_part(it.a, it.c0, mid, it.b == 1, it), table_part(it.a, mid, it.c1, true, it);
    }
    return -1, -1;
}

fn table_part(tbl: i64, r0: i64, r1: i64, header: bool, like: Item) -> i64 {
    let t = TBLS[tbl];
    var h = if header { TF[t.rh0] } else { 0.0 };
    for r in r0..r1 { h += TF[t.rh0 + r + 1]; }
    let it = new_item(IT_TABLE, h, like.step, like.x0, like.w);
    ITEMS[it].a = tbl;
    ITEMS[it].c0 = r0;
    ITEMS[it].c1 = r1;
    ITEMS[it].b = if header { 1 } else { 0 };
    ITEMS[it].split = r1 - r0 >= 2;
    return it;
}

// --- elements to items (FlowLayouter.items) ---------------------------------

fn code_item_txt(ti: i64, width: f64, x0: f64, bpad: f64, step: i64) -> i64 {
    break_lines(ti, width - 2.0 * bpad);
    let n = LNS.len;
    let it = new_item(IT_CODE, (n as f64) * line_h(ti) + 2.0 * bpad, step, x0, width);
    ITEMS[it].a = ti;
    ITEMS[it].f = bpad;
    ITEMS[it].split = n >= 2;
    return it;
}

fn code_item(code: u8[:], lang: u8[:], width: f64, x0: f64, step: i64) -> i64 {
    let r0 = RUNS.len;
    var start = 0;
    var spans: HSpan[>..] = [];
    while start <= code.len {
        var end = index_of_byte(code, '\n', start);
        let last = end < 0;
        if last { end = code.len; }
        let line = code[start..end];
        spans.clear();
        hl_code_line(line, lang, 0, spans);
        sort(spans) { a, b => a.a < b.a };
        var cursor = 0;
        for s in spans {
            if s.a < cursor { continue; }
            if s.a > cursor { add_run(line[cursor..s.a], RF_CODE, CR_NONE, lk0()); }
            let e = min(line.len, s.b);
            add_run(line[s.a..e], RF_CODE, CR_HL + s.r, lk0());
            cursor = e;
        }
        if cursor < line.len { add_run(line[cursor..], RF_CODE, CR_NONE, lk0()); }
        if last { break; }
        add_run("\n", RF_CODE, CR_NONE, lk0());
        start = end + 1;
    }
    let ti = new_txt(r0, FA_CODE, ST.code);
    TXTS[ti].lh = 1.35;
    TXTS[ti].align = AL_LEFT;
    return code_item_txt(ti, width, x0, ST.bpad * 0.75, step);
}

fn math_item(latex: Line, width: f64, x0: f64, step: i64, last: i64) -> i64 {
    var size = ST.body * ST.dms;
    let l = tb(latex);
    if math_ok(l, true) {
        var w, a, d = math_metrics(l, true);
        // Shrink a wide equation to fit, down to the shrink limit.
        if w * size > width {
            size *= max(ST.shrink, width / (w * size));
        }
        let mw = min(w * size, width);
        let mh = (a + d) * size;
        let it = new_item(IT_MATH, mh + ST.gap * 0.5, step, x0, width);
        ITEMS[it].p = latex;
        ITEMS[it].f = size;
        ITEMS[it].g = mh;
        ITEMS[it].e = mw;
        ITEMS[it].last = last;
        return it;
    }
    // Fallback: the LaTeX source as text.
    var t: u8[>..] = [];
    t.append("$$ ");
    t.append(l);
    t.append(" $$");
    let r0 = RUNS.len;
    add_run(t, RF_CODE, CR_NONE, lk0());
    let ti = new_txt(r0, FA_CODE, ST.code);
    TXTS[ti].align = AL_CENTER;
    let it = new_item(IT_TEXFB, measure_h(ti, width), step, x0, width);
    ITEMS[it].a = ti;
    ITEMS[it].last = last;
    return it;
}

fn eqsteps_item(d: i64, width: f64, x0: f64, step: i64) -> i64, i64 {
    var lat: Line[>..] = [];
    var j = d + 1;
    while j < EV[d].end - 1 {
        each_equation(j) { lat.push(tb_line(sp_text(it))); };
        j = EV[j].end;
    }
    let n = lat.len;
    var parts: i64[>..] = [];
    for l, k in lat {
        parts.push(math_item(l, width, x0, step + k, if k == n - 1 { -1 } else { step + k }));
    }
    let stacked = FLOWING || STACK_EQ;
    var h = 0.0;
    for p in parts { if stacked { h += ITEMS[p].h; } else { h = max(h, ITEMS[p].h); } }
    let c0 = CH.len;
    CH.append(parts);
    let it = new_item(IT_EQSTEPS, h, step, 0.0, width);
    ITEMS[it].c0 = c0;
    ITEMS[it].c1 = CH.len;
    ITEMS[it].b = if stacked { 1 } else { 0 };
    return it, max(n, 1);
}

fn graphic_item(d: i64, chart: bool, width: f64, x0: f64, step: i64) -> i64 {
    let natural = width * (if chart { 0.5 } else { 0.52 });
    if FLOWING {
        let it = new_item(IT_GRAPHIC, min(natural, PAGE_H * ST.mff), step, x0, width);
        ITEMS[it].a = d;
        ITEMS[it].b = if chart { 1 } else { 0 };
        ITEMS[it].f = ST.caption;
        return it;
    }
    let it = new_item(IT_GRAPHIC, natural, step, x0, width);
    ITEMS[it].flex = true;
    ITEMS[it].minh = ST.body * 6.0;
    ITEMS[it].maxh = natural;
    ITEMS[it].a = d;
    ITEMS[it].b = if chart { 1 } else { 0 };
    ITEMS[it].f = ST.caption;
    return it;
}

// Media sizes from JavaScript: "path\twidth\theight" lines (argument 6).
// A video's size is the size of its first frame.
var MEDIA: u8[>..] = [];

fn media_size(path: u8[:]) -> f64, f64, bool {
    let ai = asset_index(path);
    if ai < 0 { return 0.0, 0.0, false; }
    let key = ASSETS[AS[ai].k.s..AS[ai].k.e];
    var i = 0;
    while i < MEDIA.len {
        var e = index_of_byte(MEDIA, '\n', i);
        if e < 0 { e = MEDIA.len; }
        let line = MEDIA[i..e];
        let t1 = index_of_byte(line, '\t');
        if t1 >= 0 && line[..t1] == key {
            let t2 = index_of_byte(line, '\t', t1 + 1);
            if t2 > t1 {
                let w, ok1 = parse_number(line[t1 + 1..t2]);
                let h, ok2 = parse_number(line[t2 + 1..]);
                if ok1 && ok2 && w > 0.0 && h > 0.0 { return w, h, true; }
            }
        }
        i = e + 1;
    }
    return 0.0, 0.0, false;
}

// FlowLayouter.figureItems: the image (or a frame with the reason) and the caption.
fn figure_items(i: i64, width: f64, x0: f64, step: i64) {
    let f = EV[i];
    let path = sp_text(f.b);
    let desc = sp_text(f.a);
    let remote = is_remote(path);
    let mw, mh, found = media_size(path);
    if !remote && f.n != M_AUDIO && found {
        let aspect = mh / mw;
        // Articles keep small images small; slides fit the whole image to the space.
        let natural_w = if FLOWING { min(width, max(mw, width * 0.4)) } else { width };
        let natural = natural_w * aspect;
        var it = 0;
        if FLOWING {
            it = new_item(IT_MEDIA, min(natural, PAGE_H * ST.mff), step, x0, width);
        } else {
            it = new_item(IT_MEDIA, natural, step, x0, width);
            ITEMS[it].flex = true;
            ITEMS[it].minh = min(natural, ST.body * 5.0);
            ITEMS[it].maxh = natural;
        }
        ITEMS[it].p = tb_line(path);
        ITEMS[it].q = tb_line(if f.fl == 1 { "" } else { desc });
        ITEMS[it].b = f.n;
        ITEMS[it].f = aspect;
        OUTL.push(it);
    } else {
        var reason: u8[>..] = [];
        if f.n == M_AUDIO { reason.append("Audio: "); reason.append(path); }
        else if remote { reason.append("Marklove does not download images. Add a local copy."); }
        else { reason.append("Cannot find the file: "); reason.append(path); }
        if desc.len > 0 { reason.push('\n'); reason.append(desc); }
        let size = ST.caption;
        let ti = plain_txt(reason, FA_BODY, size);
        set_txt(ti, FA_BODY, false, false, CR_DIM, AL_CENTER);
        let it = new_item(IT_MISSING, size * 5.0, step, x0, width);
        ITEMS[it].a = ti;
        ITEMS[it].q = tb_line(desc);
        ITEMS[it].f = size;
        OUTL.push(it);
    }
    // Static outputs show the embedded caption beneath the image.
    if f.c.n > 0 {
        let ti = plain_txt(sp_text(f.c), FA_BODY, ST.caption);
        set_txt(ti, FA_BODY, false, true, CR_DIM, AL_CENTER);
        TXTS[ti].lh = 1.25;
        let c = text_item(ti, width, step, x0, false);
        ITEMS[c].split = false;
        OUTL.push(c);
    }
}

fn table_item(t: i64, width: f64, x0: f64, step: i64) -> i64 {
    let size = ST.body * 0.85;
    let bpad = size * 0.35;
    // The rows: the header row first.
    var rows: i64[>..] = [];
    var r = t + 1;
    while r < EV[t].end - 1 {
        let row = EV[r];
        if row.k == K_ROW && !row.close {
            if row.fl == 1 { rows.insert_at(0, r); } else { rows.push(r); }
        }
        r = row.end;
    }
    if rows.len == 0 || EV[rows[0]].fl != 1 { rows.insert_at(0, -1); }
    var cols = 0;
    for ri in rows {
        if ri < 0 { continue; }
        var n = 0;
        var c = ri + 1;
        while c < EV[ri].end - 1 { if EV[c].k == K_CELL && !EV[c].close { n++; } c = EV[c].end; }
        cols = max(cols, n);
    }
    if cols == 0 { return new_item(IT_SPACER, 0.0, step, x0, width); }
    let c0 = TI.len;
    var nat: f64[>..] = [];
    for k in cols { nat.push(0.0); }
    for ri, rk in rows {
        var n = 0;
        if ri >= 0 {
            var c = ri + 1;
            while c < EV[ri].end - 1 {
                let cell = EV[c];
                if cell.k == K_CELL && !cell.close && n < cols {
                    let ti = body_txt(c + 1, cell.end - 1, size);
                    let align = if cell.fl == 3 { AL_RIGHT } else if cell.fl == 2 { AL_CENTER } else { AL_LEFT };
                    TXTS[ti].lh = 1.2;
                    TXTS[ti].align = align;
                    // Natural widths use the plain cell style.
                    let h, w = measure(ti, 10000.0);
                    nat[n] = max(nat[n], w + 2.0 * bpad);
                    if rk == 0 { TXTS[ti].bold = true; TXTS[ti].color = CR_STRONG; }
                    TI.push(ti);
                    n++;
                }
                c = cell.end;
            }
        }
        while n < cols {
            let r0 = RUNS.len;
            let ti = new_txt(r0, FA_BODY, size);
            TXTS[ti].lh = 1.2;
            TXTS[ti].align = AL_LEFT;
            if rk == 0 { TXTS[ti].bold = true; TXTS[ti].color = CR_STRONG; }
            TI.push(ti);
            n++;
        }
    }
    var total = 0.0;
    for v in nat { total += v; }
    let w0 = TF.len;
    var tw = 0.0;
    for v in nat {
        let cw = if total > width { max(v * width / total, size * 3.0) } else { v };
        TF.push(cw);
        tw += cw;
    }
    tw = min(width, tw);
    let rh0 = TF.len;
    for rk in rows.len {
        var h = size;
        var any = false;
        for c in cols {
            let ch = measure_h(TI[c0 + rk * cols + c], TF[w0 + c] - 2.0 * bpad);
            h = if any { max(h, ch) } else { ch };
            any = true;
        }
        TF.push(h + 2.0 * bpad);
    }
    TBLS.push(Tbl { cols, rows.len, w0, c0, rh0, bpad, tw });
    let ti = TBLS.len - 1;
    let li = new_item(IT_SPACER, 0.0, step, x0, width);
    let like = ITEMS[li];
    ITEMS.resize(ITEMS.len - 1);
    return table_part(ti, 0, rows.len - 1, true, like);
}

fn box_accent(style: u8[:]) -> i64 {
    if style == "alert" { return CR_SERIES + 1; }
    if style == "theorem" || style == "definition" || style == "lemma" || style == "proof" { return CR_SERIES + 5; }
    if style == "example" { return CR_SERIES + 2; }
    return CR_ACCENT;
}

fn box_title_item(e: Ev, width: f64, step: i64) -> i64 {
    let r0 = RUNS.len;
    var label: u8[>..] = [];
    let style = sp_text(e.b);
    for c, i in style { label.push(if i == 0 { upper(c) } else { c }); }
    label.append(": ");
    add_run(label, 0, CR_NONE, lk0());
    markdown_runs(sp_text(e.a));
    let ti = new_txt(r0, FA_BODY, ST.body);
    set_txt(ti, FA_BODY, true, false, CR_STRONG, AL_LEFT);
    return text_item(ti, width, step, 0.0, false);
}

fn stack_h(c0: i64, c1: i64, gap: f64) -> f64 {
    var h = 0.0;
    for k in c0..c1 { h += ITEMS[CH[k]].h; }
    return h + gap * (max(c1 - c0 - 1, 0) as f64);
}

// Moves the items made since `from` into CH and returns their range.
fn take_items(from: i64) -> i64, i64 {
    let c0 = CH.len;
    CH.append(OUTL[from..]);
    OUTL.resize(from);
    return c0, CH.len;
}

// Converts the top-level events lo..hi to items (SlideComposer.convert and
// FlowLayouter.items), with the reveal steps in LSTEP.
recursive fn el_items(lo: i64, hi: i64, width: f64, indent: f64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        let next = e.end;
        if e.close || !in_scope(e, LART) { i = next; continue; }
        let k = e.k;
        if k == K_PAUSE { if !LART { LSTEP++; } i = next; continue; }
        if k == K_RULE || (k == K_HEAD && e.n <= 2) { i = next; continue; }
        if k != K_DIV {
            let top = LART && LDEPTH == 0;
            let flat = top && k == K_PARA && AFTER_HEAD;
            if flat { AFTER_HEAD = false; }
            LDEPTH++;
            block_items(i, width, indent, LSTEP, flat);
            LDEPTH--;
            if top { AFTER_HEAD = k == K_HEAD; }
            i = next;
            continue;
        }
        let d = e.n;
        if d == D_NOTES || d == D_NARRATION || d == D_PUBLIC || d == D_EXPLAIN { i = next; continue; }
        if LDEPTH == 0 { AFTER_HEAD = false; }
        let start = LSTEP;
        let w = width - indent;
        if d == D_BOX {
            let bpad = ST.bpad;
            let inner = w - 2.0 * bpad - 4.0;
            let from = OUTL.len;
            if e.a.n > 0 { OUTL.push(box_title_item(e, inner, start)); }
            LDEPTH++;
            el_items(i + 1, e.end - 1, inner, 0.0);
            LDEPTH--;
            let c0, c1 = take_items(from);
            let gap = ST.gap * 0.6;
            let ch = stack_h(c0, c1, gap);
            let it = new_item(IT_BOX, ch + 2.0 * bpad, start, indent, w);
            ITEMS[it].c0 = c0;
            ITEMS[it].c1 = c1;
            ITEMS[it].f = bpad;
            ITEMS[it].g = ch;
            ITEMS[it].e = gap;
            ITEMS[it].color = box_accent(sp_text(e.b));
            OUTL.push(it);
        } else if d == D_COLUMNS {
            // Columns: each column starts at the same step.
            var ncols = 0;
            var j = i + 1;
            while j < e.end - 1 {
                if EV[j].k == K_DIV && !EV[j].close && EV[j].n == D_COLUMN { ncols++; }
                j = EV[j].end;
            }
            let n = max(ncols, 1);
            let gap = ST.gap * 2.0;
            let cw = (w - gap * ((n - 1) as f64)) / (n as f64);
            var max_step = LSTEP;
            let from = OUTL.len;
            // OUTL holds each column's count, then its items.
            if ncols == 0 {
                OUTL.push(0);
                let at = OUTL.len;
                LDEPTH++;
                el_items(i + 1, e.end - 1, cw, 0.0);
                LDEPTH--;
                OUTL[at - 1] = OUTL.len - at;
                max_step = LSTEP;
            } else {
                j = i + 1;
                while j < e.end - 1 {
                    let c = EV[j];
                    if c.k == K_DIV && !c.close && c.n == D_COLUMN {
                        LSTEP = start;
                        OUTL.push(0);
                        let at = OUTL.len;
                        LDEPTH++;
                        el_items(j + 1, c.end - 1, cw, 0.0);
                        LDEPTH--;
                        OUTL[at - 1] = OUTL.len - at;
                        max_step = max(max_step, LSTEP);
                    }
                    j = c.end;
                }
            }
            LSTEP = max_step;
            let c0, c1 = take_items(from);
            var h = 0.0;
            var at = c0;
            while at < c1 {
                let cnt = CH[at];
                h = max(h, stack_h(at + 1, at + 1 + cnt, ST.gap));
                at += 1 + cnt;
            }
            let it = new_item(IT_COLUMNS, h, start, indent, w);
            ITEMS[it].c0 = c0;
            ITEMS[it].c1 = c1;
            ITEMS[it].b = n;
            ITEMS[it].f = cw;
            ITEMS[it].g = gap;
            ITEMS[it].e = ST.gap;
            OUTL.push(it);
        } else if d == D_MORPH {
            let it, count = eqsteps_item(i, w, indent, start);
            ITEMS[it].x0 = 0.0;
            OUTL.push(it);
            if !LART { LSTEP += count - 1; }
        } else if d == D_PLOT {
            OUTL.push(graphic_item(i, false, w, indent, start));
        } else if d == D_CHART && div_table(i) >= 0 {
            OUTL.push(graphic_item(i, true, w, indent, start));
        } else {
            // A column outside columns, a chart without a table, or an unknown name.
            LDEPTH++;
            el_items(i + 1, e.end - 1, width, indent);
            LDEPTH--;
        }
        i = next;
    }
}

fn list_marker(ordered: bool, number: i64, fl: i64) -> i64 {
    var label: u8[>..] = [];
    if ordered { format(label, number, "."); }
    else if fl == 2 { label.append("☑"); }
    else if fl == 1 { label.append("☐"); }
    else { label.append("•"); }
    let mt = plain_txt(label, FA_BODY, ST.body);
    set_txt(mt, FA_BODY, false, false, CR_DIM, AL_LEFT);
    return mt;
}

// FlowLayouter.blockItems.
recursive fn block_items(i: i64, width: f64, indent: f64, step: i64, flat: bool) {
    let e = EV[i];
    let k = e.k;
    let w = width - indent;
    if k == K_PARA {
        let ti = body_txt(i + 1, e.end - 1, ST.body);
        // Only top-level paragraphs get the first-line indent.
        TXTS[ti].indent = if indent == 0.0 && !flat { ST.pind } else { 0.0 };
        OUTL.push(text_item(ti, w, step, indent, false));
    } else if k == K_HEAD {
        let ti = body_txt(i + 1, e.end - 1, head_size(e.n));
        set_txt(ti, FA_HEAD, true, false, CR_STRONG, AL_LEFT);
        TXTS[ti].lh = 1.2;
        OUTL.push(text_item(ti, w, step, indent, true));
    } else if k == K_LIST {
        let ordered = (e.fl & 1) != 0;
        var n = 0;
        var j = i + 1;
        while j < e.end - 1 {
            let item = EV[j];
            if item.k == K_ITEM && !item.close {
                let mt = list_marker(ordered, e.n + n, item.fl);
                var first = true;
                var c = j + 1;
                while c < item.end - 1 {
                    let from = OUTL.len;
                    block_items(c, width, indent + ST.li, step, false);
                    if first && OUTL.len > from {
                        let it = OUTL[from];
                        ITEMS[it].marker = mt;
                        ITEMS[it].mx = indent;
                        ITEMS[it].split = false;
                        first = false;
                    }
                    c = EV[c].end;
                }
                n++;
            }
            j = item.end;
        }
    } else if k == K_QUOTE {
        var c = i + 1;
        while c < e.end - 1 {
            let from = OUTL.len;
            block_items(c, width, indent + ST.li * 0.7, step, false);
            for q in from..OUTL.len {
                let it = OUTL[q];
                if ITEMS[it].bar1 < 0.0 { ITEMS[it].bar1 = indent; } else { ITEMS[it].bar2 = indent; }
                ITEMS[it].split = false;
            }
            c = EV[c].end;
        }
    } else if k == K_CODE {
        OUTL.push(code_item(sp_text(e.a), sp_text(e.b), w, indent, step));
    } else if k == K_MATH {
        OUTL.push(math_item(tb_line(sp_text(e.a)), w, indent, step, -1));
    } else if k == K_TABLE {
        OUTL.push(table_item(i, w, indent, step));
    } else if k == K_FIG {
        figure_items(i, w, indent, step);
    } else if k == K_RAW {
        let r0 = RUNS.len;
        add_run(sp_text(e.a), RF_CODE, CR_NONE, lk0());
        let ti = new_txt(r0, FA_CODE, ST.code);
        TXTS[ti].color = CR_DIM;
        OUTL.push(text_item(ti, w, step, indent, false));
    } else if k == K_DIV {
        var c = i + 1;
        while c < e.end - 1 {
            if !EV[c].close { block_items(c, width, indent, step, false); }
            c = EV[c].end;
        }
    }
}

// --- placement ----------------------------------------------------------------

fn sum_fixed(c0: i64, c1: i64) -> f64 {
    var h = 0.0;
    for k in c0..c1 { let it = ITEMS[OUTL[k]]; if !it.flex { h += it.h; } }
    return h;
}

fn sum_flex_min(c0: i64, c1: i64) -> f64 {
    var h = 0.0;
    for k in c0..c1 { let it = ITEMS[OUTL[k]]; if it.flex { h += it.minh; } }
    return h;
}

// Places the items in OUTL c0..c1 top to bottom. Flexible items share the
// free space (SlideLayoutEngine.place).
fn place(c0: i64, c1: i64, x: f64, top: f64, available: f64, gap: f64) {
    let n = c1 - c0;
    let gaps = gap * (max(n - 1, 0) as f64);
    var free = max(0.0, available - sum_fixed(c0, c1) - gaps);
    var heights: f64[>..] = [];
    var grow: i64[>..] = [];
    for k in n {
        let it = ITEMS[OUTL[c0 + k]];
        heights.push(if it.flex { it.minh } else { it.h });
        if it.flex { grow.push(k); }
    }
    free -= sum_flex_min(c0, c1);
    // Grow flexible items toward their natural size, evenly.
    while free > 0.5 && grow.len > 0 {
        let share = free / (grow.len as f64);
        var next: i64[>..] = [];
        for k in grow {
            let room = ITEMS[OUTL[c0 + k]].maxh - heights[k];
            let add = min(room, share);
            heights[k] += add;
            free -= add;
            if room > share { next.push(k); }
        }
        if next.len == grow.len { break; }
        grow = copy(next);
    }
    var y = top;
    for k in n {
        make(OUTL[c0 + k], x, y, heights[k]);
        y += heights[k] + gap;
    }
}

// --- slides (SlideLayoutEngine) ----------------------------------------------

let SW = 960.0;
let SH = 540.0;
let MIN_SCALE = 0.73;
var STATIC = false;

fn margin_x() -> f64 { SW * 0.06 }
fn margin_top() -> f64 { SH * 0.075 }
fn margin_bottom() -> f64 { SH * 0.075 }

// Reduces the font size until the text fits, down to a minimum.
fn fit(ti: i64, width: f64, max_h: f64, minimum: f64) {
    while TXTS[ti].size > minimum && measure_h(ti, width) > max_h {
        TXTS[ti].size = max(minimum, TXTS[ti].size * 0.92);
    }
}

// True when a line break falls inside a word: the size is too large.
fn breaks_inside_word(ti: i64) -> bool {
    let t = TXTS[ti];
    fn space(c: u8) -> bool { c == ' ' || c == '\n' || c == '-' }
    for l, k in LNS {
        if k == LNS.len - 1 { break; }
        let end = l.b;
        if end <= t.lo || end >= t.hi { continue; }
        if !space(TB[end - 1]) && !space(TB[end]) { return true; }
    }
    return false;
}

// The largest size that fits the box without a line break inside a word.
fn largest(ti: i64, minimum: f64, maximum: f64, bw: f64, bh: f64) {
    var lo = minimum;
    var hi = maximum;
    for k in 14 {
        let mid = (lo + hi) / 2.0;
        TXTS[ti].size = mid;
        let h, w = measure(ti, bw);
        if h <= bh && w <= bw + 0.5 && !breaks_inside_word(ti) { lo = mid; } else { hi = mid; }
    }
    TXTS[ti].size = lo;
}

fn slide_title_line(si: i64) -> Line {
    let s = SL[si];
    let f = FR[s.frame];
    if s.kind == SK_TITLE {
        if has_meta("title") { return tb_line(meta("title")); }
        if TAKAHASHI { return tb_line(doc_title()); }
        return tb_line("");
    }
    if s.kind == SK_SECTION || (s.n == 0 && !TAKAHASHI) { return tb_line(sp_text(f.title)); }
    return tb_line("");
}

fn slide_page(si: i64, b0: i64, steps: i64) {
    let s = SL[si];
    add_page(SW, SH, b0, steps, si, s.frame, slide_title_line(si));
}

// The slide's elements as items in OUTL; returns the step count.
fn slide_items(si: i64, width: f64) -> i64 {
    let s = SL[si];
    LSTEP = 0;
    LDEPTH = 0;
    if s.el == EL_GROUP { el_items(s.lo, s.hi, width, 0.0); }
    else if s.el == EL_STATEMENT {
        let ti = body_txt(s.lo, s.hi, ST.body);
        set_txt(ti, FA_BODY, true, false, CR_STRONG, AL_CENTER);
        OUTL.push(text_item(ti, width, 0, 0.0, false));
    }
    else if s.el == EL_BLOCK { block_items(s.lo, width, 0.0, 0, false); }
    else if s.el == EL_MATH { OUTL.push(math_item(tb_line(S[s.lo..s.lo + s.hi]), width, 0.0, 0, -1)); }
    else if s.el == EL_PLOT { OUTL.push(graphic_item(s.lo, false, width, 0.0, 0)); }
    else if s.el == EL_CHART { OUTL.push(graphic_item(s.lo, true, width, 0.0, 0)); }
    return LSTEP + 1;
}

// A stack in the middle of the page. Images, plots, and charts shrink so
// that the whole stack fits between the margins.
fn centered_stack(c0: i64, c1: i64, gap: f64) {
    let available = SH - margin_top() - margin_bottom();
    let n = c1 - c0;
    let gaps = gap * (max(n - 1, 0) as f64);
    var heights: f64[>..] = [];
    var grow: i64[>..] = [];
    for k in n {
        let it = ITEMS[OUTL[c0 + k]];
        heights.push(if it.flex { 0.0 } else { it.h });
        if it.flex { grow.push(k); }
    }
    var free = max(0.0, available - sum_fixed(c0, c1) - gaps);
    while free > 0.5 && grow.len > 0 {
        let share = free / (grow.len as f64);
        var next: i64[>..] = [];
        for k in grow {
            let it = ITEMS[OUTL[c0 + k]];
            let add = min(it.maxh - heights[k], share);
            heights[k] += add;
            free -= add;
            if it.maxh - heights[k] > 0.5 { next.push(k); }
        }
        if next.len == grow.len && share * (grow.len as f64) <= 0.5 { break; }
        grow = copy(next);
    }
    var total = gaps;
    for v in heights { total += v; }
    var y = max(margin_top(), (SH - total) / 2.0);
    for k in n {
        make(OUTL[c0 + k], margin_x(), y, heights[k]);
        y += heights[k] + gap;
    }
}

fn byline_text(out: u8[>..]&, sep: u8[:]) {
    var n = 0;
    for key in ["author", "institute", "date"] {
        let v = meta(key);
        if v.len == 0 { continue; }
        if n > 0 { out.append(sep); }
        out.append(v);
        n++;
    }
}

fn title_runs(si: i64) {
    let s = SL[si];
    let f = FR[s.frame];
    if s.kind == SK_TITLE {
        if has_meta("title") { add_run(meta("title"), 0, CR_NONE, lk0()); }
        else if TAKAHASHI { add_run(doc_title(), 0, CR_NONE, lk0()); }
        else if f.head >= 0 { inline_runs(f.head + 1, EV[f.head].end - 1); }
    } else if f.head >= 0 { inline_runs(f.head + 1, EV[f.head].end - 1); }
}

fn title_page(si: i64) {
    let w = SW - 2.0 * margin_x();
    let b0 = BOXES.len;
    let from = OUTL.len;
    let r0 = RUNS.len;
    title_runs(si);
    let title = new_txt(r0, FA_HEAD, 44.0);
    set_txt(title, FA_HEAD, true, false, CR_STRONG, AL_LEFT);
    TXTS[title].lh = 1.15;
    fit(title, w, SH * 0.4, 28.0);
    OUTL.push(text_item(title, w, 0, 0.0, false));
    let sub = meta("subtitle");
    if sub.len > 0 {
        let t = plain_txt(sub, FA_BODY, 24.0);
        TXTS[t].align = AL_LEFT;
        OUTL.push(text_item(t, w, 0, 0.0, false));
    }
    var by: u8[>..] = [];
    byline_text(by, "\n");
    if by.len > 0 {
        let t = plain_txt(by, FA_BODY, 18.0);
        set_txt(t, FA_BODY, false, false, CR_DIM, AL_LEFT);
        TXTS[t].lh = 1.4;
        OUTL.push(text_item(t, w, 0, 0.0, false));
    }
    let steps = slide_items(si, w);
    centered_stack(from, OUTL.len, 14.0);
    OUTL.resize(from);
    slide_page(si, b0, steps);
}

fn section_page(si: i64) {
    let w = SW - 2.0 * margin_x();
    let b0 = BOXES.len;
    let from = OUTL.len;
    var part: u8[>..] = [];
    format(part, "Part ", SL[si].num);
    let label = plain_txt(part, FA_BODY, 18.0);
    set_txt(label, FA_BODY, false, false, CR_DIM, AL_LEFT);
    TXTS[label].lh = 1.2;
    OUTL.push(text_item(label, w, 0, 0.0, false));
    let r0 = RUNS.len;
    title_runs(si);
    let title = new_txt(r0, FA_HEAD, 40.0);
    set_txt(title, FA_HEAD, true, false, CR_STRONG, AL_LEFT);
    TXTS[title].lh = 1.15;
    fit(title, w, SH * 0.4, 26.0);
    OUTL.push(text_item(title, w, 0, 0.0, false));
    let steps = slide_items(si, w);
    centered_stack(from, OUTL.len, 10.0);
    OUTL.resize(from);
    slide_page(si, b0, steps);
}

// A Takahashi title or section slide: large text, centered.
fn tk_title_page(si: i64) {
    let s = SL[si];
    let bw = SW * 0.85;
    let b0 = BOXES.len;
    var parts: i64[>..] = [];
    let section = s.kind == SK_SECTION;
    if section {
        var part: u8[>..] = [];
        format(part, "Part ", s.num);
        let l = plain_txt(part, FA_BODY, 28.0);
        set_txt(l, FA_BODY, false, false, CR_DIM, AL_CENTER);
        TXTS[l].lh = 1.3;
        parts.push(l);
    }
    let sub = if section { "" } else { meta("subtitle") };
    var by: u8[>..] = [];
    if !section { byline_text(by, " · "); }
    let r0 = RUNS.len;
    title_runs(si);
    let title = new_txt(r0, FA_HEAD, 96.0);
    set_txt(title, FA_HEAD, true, false, CR_STRONG, AL_CENTER);
    TXTS[title].lh = 1.12;
    // As large as a Takahashi statement: the title is the one thing to read.
    let room = if !section && (has_meta("subtitle") || by.len > 0) { 0.48 } else { 0.62 };
    largest(title, 36.0, 120.0, bw, SH * room);
    parts.push(title);
    if !section && has_meta("subtitle") {
        let t = plain_txt(sub, FA_HEAD, 40.0);
        set_txt(t, FA_HEAD, false, false, CR_TEXT, AL_CENTER);
        TXTS[t].lh = 1.3;
        fit(t, bw, SH * 0.2, 24.0);
        parts.push(t);
    }
    if by.len > 0 {
        let t = plain_txt(by, FA_BODY, 24.0);
        set_txt(t, FA_BODY, false, false, CR_DIM, AL_CENTER);
        TXTS[t].lh = 1.3;
        parts.push(t);
    }
    let gap = 18.0;
    var total = gap * (max(parts.len - 1, 0) as f64);
    var hs: f64[>..] = [];
    for t in parts { let h = measure_h(t, bw); hs.push(h); total += h; }
    var y = max(margin_top(), (SH - total) / 2.0);
    for t, k in parts {
        text_box((SW - bw) / 2.0, y, bw, hs[k], t, 0);
        y += hs[k] + gap;
    }
    slide_page(si, b0, 1);
}

// One main element, as large as fits. Returns false for other elements.
fn tk_page(si: i64) -> bool {
    let s = SL[si];
    let bw = SW * 0.85;
    let bh = SH * 0.75;
    let x0 = (SW - bw) / 2.0;
    let y0 = (SH - bh) / 2.0;
    let b0 = BOXES.len;
    if s.el == EL_STATEMENT {
        let ti = body_txt(s.lo, s.hi, 110.0);
        set_txt(ti, FA_HEAD, true, false, CR_STRONG, AL_CENTER);
        TXTS[ti].lh = 1.15;
        // The minimum keeps text readable on a phone.
        largest(ti, 34.0, 120.0, bw, bh);
        let h = measure_h(ti, bw);
        text_box(x0, (SH - h) / 2.0, bw, h, ti, 0);
        slide_page(si, b0, 1);
        return true;
    }
    var latex = lk0();
    if s.el == EL_MATH { latex = tb_line(S[s.lo..s.lo + s.hi]); }
    else if s.el == EL_BLOCK && EV[s.lo].k == K_MATH { latex = tb_line(sp_text(EV[s.lo].a)); }
    else if s.el == EL_BLOCK && EV[s.lo].k == K_FIG && EV[s.lo].n == M_IMAGE {
        // A larger caption: on a Takahashi slide it is the only text.
        let saved = ST;
        ST = scaled(ST, 1.6);
        let saved_flow = FLOWING;
        FLOWING = false;
        let from = OUTL.len;
        figure_items(s.lo, bw, 0.0, 0);
        var caption_h = 0.0;
        for k in from + 1..OUTL.len { caption_h += ITEMS[OUTL[k]].h + 8.0; }
        let image = ITEMS[OUTL[from]];
        let image_h = if image.flex { min(bh - caption_h, image.maxh * 4.0) } else { image.h };
        let top = y0 + (bh - image_h - caption_h) / 2.0;
        make(OUTL[from], x0, top, image_h);
        var y = top + image_h + 8.0;
        for k in from + 1..OUTL.len {
            let c = OUTL[k];
            make(c, x0, y, ITEMS[c].h);
            y += ITEMS[c].h + 8.0;
        }
        OUTL.resize(from);
        ST = saved;
        FLOWING = saved_flow;
        slide_page(si, b0, 1);
        return true;
    }
    if latex.e == latex.s { return false; }
    // One equation fills the slide, as a statement does. Very short
    // equations stop at a size that still looks like mathematics.
    let l = tb(latex);
    if !math_ok(l, true) { return false; }
    var size = 64.0;
    let w, a, d = math_metrics(l, true);
    if w > 0.0 && a + d > 0.0 {
        size = min(150.0, max(26.0, size * min(bw / (w * size), bh * 0.7 / ((a + d) * size))));
        if w * size > bw { size *= bw / (w * size); }
    }
    let mw = w * size;
    let mh = (a + d) * size;
    let b = add_box((SW - mw) / 2.0, (SH - mh) / 2.0, mw, mh, BX_MATH, 0);
    BOXES[b].p = latex;
    BOXES[b].c = size;
    BOXES[b].color = CR_STRONG;
    slide_page(si, b0, 1);
    return true;
}

// True when the slide shows only display equations.
fn is_math_only(si: i64) -> bool {
    let s = SL[si];
    if s.el == EL_MATH { return true; }
    if s.el == EL_BLOCK { return EV[s.lo].k == K_MATH; }
    if s.el != EL_GROUP { return false; }
    var any = false;
    var i = s.lo;
    while i < s.hi {
        let e = EV[i];
        let next = e.end;
        if e.close || !in_scope(e, false) || e.k == K_PAUSE || e.k == K_RULE || (e.k == K_HEAD && e.n <= 2) { i = next; continue; }
        if e.k == K_DIV && (e.n == D_NOTES || e.n == D_NARRATION || e.n == D_PUBLIC || e.n == D_EXPLAIN) { i = next; continue; }
        if e.k == K_MATH || (e.k == K_DIV && e.n == D_MORPH) { any = true; } else { return false; }
        i = next;
    }
    return any;
}

fn content_pages(si: i64, max_scale: f64) {
    let s = SL[si];
    let w = SW - 2.0 * margin_x();
    var scale = max_scale;
    let math_only = is_math_only(si);
    let has_title = s.kind == SK_CONTENT && s.n == 0 && !TAKAHASHI && FR[s.frame].head >= 0;
    let base = style_slides();
    while true {
        let m = mark();
        ST = scaled(base, scale);
        if math_only { ST.dms = 2.0; ST.shrink = 0.42; }
        STACK_EQ = STATIC;
        var title = -1;
        if has_title {
            let r0 = RUNS.len;
            title_runs(si);
            let ti = new_txt(r0, FA_HEAD, ST.h1);
            set_txt(ti, FA_HEAD, true, false, CR_STRONG, AL_LEFT);
            TXTS[ti].lh = 1.15;
            fit(ti, w, SH * 0.22, ST.h1 * 0.7);
            title = text_item(ti, w, 0, 0.0, false);
        }
        let title_h = if title >= 0 { ITEMS[title].h + ST.gap * 1.2 } else { 0.0 };
        let available = SH - margin_top() - margin_bottom() - title_h;
        let from = OUTL.len;
        let steps = slide_items(si, w);
        let c1 = OUTL.len;
        let fixed = sum_fixed(from, c1);
        let flex_min = sum_flex_min(from, c1);
        let gaps = ST.gap * (max(c1 - from - 1, 0) as f64);
        let fits = fixed + flex_min + gaps <= available;
        if fits || scale <= MIN_SCALE {
            if fits {
                let b0 = BOXES.len;
                if title >= 0 { make(title, margin_x(), margin_top(), ITEMS[title].h); }
                // Equations alone sit a little above the middle of the free space.
                let lift = if math_only { max(0.0, (available - fixed - gaps) * 0.42) } else { 0.0 };
                place(from, c1, margin_x(), margin_top() + title_h + lift, available - lift, ST.gap);
                slide_page(si, b0, steps);
            } else {
                continuation(si, from, c1, title, title_h, available, ST.gap);
            }
            OUTL.resize(from);
            return;
        }
        rewind(m);
        scale = if scale > 1.0 { max(1.0, scale - 0.1) } else { max(MIN_SCALE, scale - 0.07) };
    }
}

// Too much content at the smallest readable size: the content continues on
// more slides.
fn continuation(si: i64, c0: i64, c1: i64, title: i64, title_h: f64, available: f64, gap: f64) {
    var queue: i64[>..] = [];
    queue.append(OUTL[c0..c1]);
    // Each page is a count and its items.
    var groups: i64[>..] = [0];
    var at = 0;
    var used = 0.0;
    var q = 0;
    fn new_group() { groups.push(0); at = groups.len - 1; used = 0.0; }
    fn add(it: i64) { groups.push(it); groups[at] += 1; }
    while q < queue.len {
        let ii = queue[q];
        q++;
        let item = ITEMS[ii];
        let empty = groups[at] == 0;
        let h = if item.flex { item.minh } else { item.h };
        let need = (if empty { 0.0 } else { gap }) + h;
        if used + need <= available {
            add(ii);
            used += need;
            continue;
        }
        if !item.flex {
            let a, b = split_item(ii, available - used - (if empty { 0.0 } else { gap }));
            if a >= 0 {
                add(a);
                new_group();
                q--;
                queue[q] = b;
                continue;
            }
        }
        if empty {
            // One item taller than the slide: show it alone.
            if item.flex { ITEMS[ii].minh = min(item.minh, available); }
            add(ii);
            new_group();
            continue;
        }
        new_group();
        q--;
    }
    var k = 0;
    var g = 0;
    var pages = 0;
    while g < groups.len {
        let n = groups[g];
        if n == 0 { g++; continue; }
        let b0 = BOXES.len;
        if title >= 0 { make(title, margin_x(), margin_top(), ITEMS[title].h); }
        let o0 = OUTL.len;
        var min_step = 1 << 40;
        for j in g + 1..g + 1 + n { OUTL.push(groups[j]); min_step = min(min_step, ITEMS[groups[j]].step); }
        let p0 = BOXES.len;
        place(o0, OUTL.len, margin_x(), margin_top() + title_h, available, gap);
        OUTL.resize(o0);
        // Each continuation page has its own reveal steps.
        var max_step = 0;
        for b in p0..BOXES.len {
            if k > 0 {
                BOXES[b].first -= min_step;
                if BOXES[b].last >= 0 { BOXES[b].last -= min_step; }
            }
            max_step = max(max_step, max(BOXES[b].first, BOXES[b].last));
        }
        slide_page(si, b0, max_step + 1);
        k++;
        pages++;
        g += 1 + n;
    }
    format(LWARN, "This slide has too much content. Marklove continues the content on more slides (", pages - 1, ") and keeps every word.\n");
}

fn layout_slide(si: i64) {
    let s = SL[si];
    ST = style_slides();
    STACK_EQ = STATIC;
    if s.kind == SK_TITLE || s.kind == SK_SECTION {
        if TAKAHASHI { tk_title_page(si); }
        else if s.kind == SK_TITLE { title_page(si); }
        else { section_page(si); }
        return;
    }
    if TAKAHASHI && tk_page(si) { return; }
    let p0 = PAGES.len;
    // Outside the phone profile, Takahashi slides still use large type when it fits.
    content_pages(si, if TAKAHASHI { 1.8 } else { 1.0 });
    if TAKAHASHI {
        // Center the standard-slide fallback.
        for p in p0..PAGES.len {
            let pg = PAGES[p];
            if pg.b1 <= pg.b0 { continue; }
            var top = BOXES[pg.b0].y;
            var bottom = BOXES[pg.b0].y + BOXES[pg.b0].h;
            for b in pg.b0..pg.b1 { top = min(top, BOXES[b].y); bottom = max(bottom, BOXES[b].y + BOXES[b].h); }
            let shift = max(0.0, (pg.h - (bottom - top)) / 2.0 - top);
            for b in pg.b0..pg.b1 { BOXES[b].y += shift; }
        }
    }
}

fn reset_layout() {
    TB.clear();
    RUNS.clear();
    TXTS.clear();
    BOXES.clear();
    PAGES.clear();
    ITEMS.clear();
    CH.clear();
    OUTL.clear();
    TBLS.clear();
    TF.clear();
    TI.clear();
    LWARN.clear();
    OUT0 = 0;
    LART = false;
    FLOWING = false;
    LDEPTH = 0;
    LSTEP = 0;
}

fn layout_slides(takahashi: bool, typo: i64, static_output: bool) {
    reset_layout();
    TYPO = typo;
    STATIC = static_output;
    build_deck(takahashi);
    for si in SL.len { layout_slide(si); }
}

// --- the article (ArticleLayoutEngine) ---------------------------------------

fn frame_heading_item(fi: i64, level: i64, width: f64) -> i64 {
    let f = FR[fi];
    let r0 = RUNS.len;
    if f.head >= 0 { inline_runs(f.head + 1, EV[f.head].end - 1); }
    let ti = new_txt(r0, FA_HEAD, head_size(level));
    set_txt(ti, FA_HEAD, true, false, CR_STRONG, AL_LEFT);
    TXTS[ti].lh = 1.2;
    return text_item(ti, width, 0, 0.0, true);
}

// The article elements as items in OUTL: frame headings and content.
fn article_items(width: f64) {
    LART = true;
    LSTEP = 0;
    AFTER_HEAD = true;
    for f, fi in FR {
        if f.scope == SC_SLIDES { continue; }
        if f.kind != F_TITLE {
            OUTL.push(frame_heading_item(fi, if f.kind == F_SECTION { 1 } else { 2 }, width));
            AFTER_HEAD = true;
        }
        LDEPTH = 0;
        el_items(f.lo, f.hi, width, 0.0);
    }
}

fn article_title_items(width: f64, size: f64, sub: f64, by: f64) {
    let title = plain_txt(doc_title(), FA_HEAD, size);
    set_txt(title, FA_HEAD, true, false, CR_STRONG, AL_CENTER);
    TXTS[title].lh = 1.2;
    OUTL.push(text_item(title, width, 0, 0.0, false));
    let s = meta("subtitle");
    if s.len > 0 {
        let t = plain_txt(s, FA_BODY, sub);
        set_txt(t, FA_BODY, false, true, CR_TEXT, AL_CENTER);
        OUTL.push(text_item(t, width, 0, 0.0, false));
    }
    var b: u8[>..] = [];
    byline_text(b, " · ");
    if b.len > 0 {
        let t = plain_txt(b, FA_BODY, by);
        set_txt(t, FA_BODY, false, false, CR_DIM, AL_CENTER);
        OUTL.push(text_item(t, width, 0, 0.0, false));
    }
}

// Paper sizes in points.
fn paper_size(letter: bool) -> f64, f64 {
    if letter { return 612.0, 792.0; }
    return 595.28, 841.89;
}

fn layout_article(letter: bool) {
    reset_layout();
    TYPO = TY_ARTICLE;
    ST = style_article();
    FLOWING = true;
    let pw, ph = paper_size(letter);
    PAGE_H = ph;
    // About 66 characters per line at 11 point Palatino.
    let tw = min(360.0, pw - 144.0);
    let mx = (pw - tw) / 2.0;
    let top = 84.0;
    let bottom = 90.0;
    article_title_items(tw, 20.0, 13.0, 11.0);
    OUTL.push(new_item(IT_SPACER, 14.0, 0, 0.0, tw));
    article_items(tw);
    let available = ph - top - bottom;
    let gap = ST.gap;
    // Pages: for each, a count and the items with their offsets.
    var queue: i64[>..] = [];
    queue.append(OUTL);
    OUTL.clear();
    var items: i64[>..] = [];
    var offs: f64[>..] = [];
    var page_of: i64[>..] = [];
    var page = 0;
    var y = 0.0;
    var on_page = 0;
    var q = 0;
    fn new_page() { page++; y = 0.0; on_page = 0; }
    fn put(it: i64, at: f64) { items.push(it); offs.push(at); page_of.push(page); on_page++; }
    while q < queue.len {
        let ii = queue[q];
        q++;
        let item = ITEMS[ii];
        let lead = if on_page == 0 { 0.0 } else { gap };
        // Keep a heading with the start of the next item.
        var need = item.h;
        if item.keep && on_page > 0 && q < queue.len {
            let next = ITEMS[queue[q]];
            need += gap + (if next.split { min(next.h, ST.body * ST.lh * 2.0) } else { next.h });
        }
        if y + lead + need <= available {
            put(ii, y + lead);
            y += lead + item.h;
            continue;
        }
        if !item.keep {
            let a, b = split_item(ii, available - y - lead);
            if a >= 0 && y + lead + ITEMS[a].h <= available {
                put(a, y + lead);
                new_page();
                q--;
                queue[q] = b;
                continue;
            }
        }
        if on_page == 0 {
            // Taller than a page: place it alone.
            put(ii, 0.0);
            new_page();
            continue;
        }
        new_page();
        q--;
    }
    var k = 0;
    var p = 0;
    let title = tb_line(doc_title());
    while k < items.len {
        let b0 = BOXES.len;
        let pg = page_of[k];
        while k < items.len && page_of[k] == pg {
            make(items[k], mx, top + offs[k], ITEMS[items[k]].h);
            k++;
        }
        var num: u8[>..] = [];
        format(num, p + 1);
        let nt = plain_txt(num, FA_BODY, 9.0);
        set_txt(nt, FA_BODY, false, false, CR_DIM, AL_CENTER);
        text_box(mx, ph - bottom + 34.0, tw, 12.0, nt, 0);
        var pt = title;
        if p > 0 {
            var t: u8[>..] = [];
            format(t, "Page ", p + 1);
            pt = tb_line(t);
        }
        add_page(pw, ph, b0, 1, -1, -1, pt);
        p++;
    }
}

// --- the handout (HandoutLayoutEngine) ----------------------------------------

fn layout_handout(takahashi: bool, letter: bool) {
    layout_slides(takahashi, TY_HANDOUT, true);
    let nslides = PAGES.len;
    OUT0 = nslides;
    let pw, ph = paper_size(letter);
    let margin = 42.0;
    let gap = 18.0;
    let per = 3;
    let row_h = (ph - 2.0 * margin - 30.0 - gap * ((per - 1) as f64)) / (per as f64);
    let thumb_w = min((pw - 2.0 * margin) * 0.52, row_h * 16.0 / 9.0);
    let thumb_h = thumb_w * 9.0 / 16.0;
    let notes_x = margin + thumb_w + 16.0;
    let notes_w = pw - margin - notes_x;
    let title = doc_title();
    var row = 0;
    var b0 = BOXES.len;
    var count = 0;
    fn finish() {
        if row == 0 { return; }
        let ht = plain_txt(title, FA_BODY, 9.0);
        set_txt(ht, FA_BODY, false, false, CR_DIM, AL_LEFT);
        var num: u8[>..] = [];
        format(num, count + 1);
        let nt = plain_txt(num, FA_BODY, 9.0);
        set_txt(nt, FA_BODY, false, false, CR_DIM, AL_RIGHT);
        text_box(margin, margin - 18.0, pw - 2.0 * margin - 40.0, 12.0, ht, 0);
        text_box(pw - margin - 40.0, margin - 18.0, 40.0, 12.0, nt, 0);
        var t: u8[>..] = [];
        format(t, "Handout page ", count + 1);
        add_page(pw, ph, b0, 1, -1, -1, tb_line(t));
        count++;
        b0 = BOXES.len;
        row = 0;
    }
    for k in nslides {
        let sp = PAGES[k];
        let y = margin + 12.0 + (row as f64) * (row_h + gap);
        let tb0 = add_box(margin, y, thumb_w, thumb_h, BX_THUMB, 0);
        BOXES[tb0].a = k;
        shape_box(margin, y, thumb_w, thumb_h, BX_STROKE, CR_BORDER, 0.75, 0);
        // Public notes for the first page of each slide. Private notes never appear here.
        let first = k == 0 || PAGES[k - 1].slide != sp.slide;
        var notes: u8[>..] = [];
        if first && SL[sp.slide].n == 0 { notes_text(notes, sp.frame, D_PUBLIC); }
        if notes.len > 0 {
            let r0 = RUNS.len;
            markdown_runs(notes);
            let ti = new_txt(r0, FA_BODY, 10.0);
            TXTS[ti].lh = 1.35;
            TXTS[ti].align = AL_LEFT;
            text_box(notes_x, y, notes_w, min(measure_h(ti, notes_w), row_h), ti, 0);
        } else {
            // Lines for handwritten notes.
            var ly = y + 18.0;
            while ly < y + row_h - 4.0 {
                shape_box(notes_x, ly, notes_w, 0.5, BX_RULE, CR_BORDER, 0.5, 0);
                ly += 22.0;
            }
        }
        row++;
        if row == per { finish(); }
    }
    finish();
}

// --- the poster (PosterLayoutEngine) -----------------------------------------

var POSTER_BODY = 0.0;

fn poster_style(body: f64) -> LStyle {
    var s = scaled(style_article(), body / 11.0);
    s.just = false;
    s.pind = 0.0;
    s.gap = body * 0.7;
    s.mff = 0.5;
    return s;
}

// Sizes: 0 A0, 1 A1, 2 48 × 36 in, 3 42 × 42 in.
fn poster_portrait(size: i64) -> f64, f64 {
    let mm = 72.0 / 25.4;
    if size == 1 { return 594.0 * mm, 841.0 * mm; }
    if size == 2 { return 36.0 * 72.0, 48.0 * 72.0; }
    if size == 3 { return 42.0 * 72.0, 42.0 * 72.0; }
    return 841.0 * mm, 1189.0 * mm;
}

fn poster_build(width: f64, height: f64, columns: i64, body: f64) -> bool {
    ST = poster_style(body);
    FLOWING = true;
    let margin = max(54.0, min(width, height) * 0.03);
    let gutter = margin * 0.7;
    let cw = (width - 2.0 * margin - gutter * ((columns - 1) as f64)) / (columns as f64);
    let content = width - 2.0 * margin;
    let b0 = BOXES.len;
    // The title band.
    var y = margin;
    let title = plain_txt(doc_title(), FA_HEAD, body * 3.1);
    set_txt(title, FA_HEAD, true, false, CR_STRONG, AL_CENTER);
    TXTS[title].lh = 1.12;
    let th = measure_h(title, content);
    text_box(margin, y, content, th, title, 0);
    y += th + body * 0.5;
    let sub = meta("subtitle");
    if sub.len > 0 {
        let t = plain_txt(sub, FA_BODY, body * 1.6);
        set_txt(t, FA_BODY, false, true, CR_TEXT, AL_CENTER);
        let h = measure_h(t, content);
        text_box(margin, y, content, h, t, 0);
        y += h + body * 0.4;
    }
    var by: u8[>..] = [];
    byline_text(by, " · ");
    if by.len > 0 {
        let t = plain_txt(by, FA_BODY, body * 1.15);
        set_txt(t, FA_BODY, false, false, CR_DIM, AL_CENTER);
        let h = measure_h(t, content);
        text_box(margin, y, content, h, t, 0);
        y += h;
    }
    y += body * 0.8;
    shape_box(margin, y, content, max(3.0, body * 0.18), BX_ACCENT, CR_ACCENT, 0.0, 0);
    y += body * 1.4;
    let top = y;
    let available = height - margin - top;
    PAGE_H = available;
    let from = OUTL.len;
    article_items(cw);
    var queue: i64[>..] = [];
    queue.append(OUTL[from..]);
    OUTL.resize(from);
    // Fill the columns in order.
    var col = 0;
    var cy = 0.0;
    var on_col = 0;
    var fits = true;
    var q = 0;
    let gap = ST.gap;
    fn next_col() { col++; cy = 0.0; on_col = 0; }
    fn put(it: i64, at: f64) {
        if col < columns { make(it, margin + (col as f64) * (cw + gutter), top + at, ITEMS[it].h); }
        on_col++;
    }
    while q < queue.len {
        let ii = queue[q];
        q++;
        let item = ITEMS[ii];
        let lead = if on_col == 0 { 0.0 } else { gap };
        var need = item.h;
        if item.keep && on_col > 0 && q < queue.len {
            let next = ITEMS[queue[q]];
            need += gap + (if next.split { min(next.h, ST.body * ST.lh * 2.0) } else { next.h });
        }
        if cy + lead + need <= available {
            put(ii, cy + lead);
            cy += lead + item.h;
            continue;
        }
        if !item.keep {
            let a, b = split_item(ii, available - cy - lead);
            if a >= 0 && cy + lead + ITEMS[a].h <= available {
                put(a, cy + lead);
                next_col();
                q--;
                queue[q] = b;
                continue;
            }
        }
        if on_col == 0 {
            // Taller than a column: it does not fit at this size.
            fits = false;
            put(ii, 0.0);
            next_col();
            continue;
        }
        next_col();
        q--;
    }
    let used = if on_col > 0 { col + 1 } else { col };
    if used > columns { fits = false; }
    add_page(width, height, b0, 1, -1, -1, tb_line(doc_title()));
    return fits;
}

fn layout_poster(size: i64, landscape: bool) {
    reset_layout();
    TYPO = TY_ARTICLE;
    let pw, ph = poster_portrait(size);
    let square = size == 3;
    let width = if landscape && !square { ph } else { pw };
    let height = if landscape && !square { pw } else { ph };
    let columns = if square { 3 } else if landscape { if size == 1 { 3 } else { 4 } } else { if size == 1 { 2 } else { 3 } };
    let a0w, a0h = poster_portrait(0);
    let base = 32.0 * sqrt(width * height / (a0w * a0h));
    let minimum = max(20.0, base * 0.62);
    // Try large type first. Make it smaller until all columns fit.
    var scales: f64[>..] = [];
    var s = 1.35;
    while s >= minimum / base - 0.0001 { scales.push(s); s -= 0.05; }
    if scales.len == 0 { scales.push(minimum / base); }
    for sc, k in scales {
        let m = mark();
        let b0 = BOXES.len;
        let p0 = PAGES.len;
        POSTER_BODY = base * sc;
        if poster_build(width, height, columns, POSTER_BODY) { return; }
        if k == scales.len - 1 { break; }
        rewind(m);
        BOXES.resize(b0);
        PAGES.resize(p0);
    }
    let name = if size == 1 { "A1" } else if size == 2 { "48 × 36 in" } else if size == 3 { "42 × 42 in" } else { "A0" };
    format(LWARN, "The poster content does not fit on ", name, ". Make the text shorter, remove a figure, or choose a larger size. Marklove left out the content that does not fit.\n");
}
