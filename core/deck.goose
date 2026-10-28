// Slide decks, as the app's SlideComposer and TakahashiFormatter.
//
// A Normal slide is a group of top-level body events between thematic
// breaks; the renderer turns the group into elements and counts the reveal
// steps. A Takahashi slide holds one element: a statement, a block, math,
// a plot, or a chart.

import sentence;

let SK_TITLE = 0;
let SK_SECTION = 1;
let SK_CONTENT = 2;

// Slide content (the `el` of a slide).
let EL_GROUP = 0;      // top-level events lo..hi
let EL_STATEMENT = 1;  // inline events lo..hi
let EL_BLOCK = 2;      // the block event lo
let EL_MATH = 3;       // display math: LaTeX in S at lo, length hi
let EL_PLOT = 4;       // the plot division event lo
let EL_CHART = 5;      // the chart division event lo
let EL_NONE = 6;

struct Slide {
    kind: i64,
    frame: i64,
    num: i64,        // the section number
    el: i64,
    lo: i64,
    hi: i64,
    n: i64,          // 0 for the first slide of a frame; the id suffix is n + 1
    cont: bool,      // continues the content of the slide before it
    steps: i64,      // set by the renderer
    s0: i64,
    s1: i64,
}

var SL: Slide[>..] = [];
var TAKAHASHI = false;

// Takahashi warnings: kind 1 overlong sentence (n = words), 2 out of
// profile (name in a), with the source range.
struct TWarn { kind: i64, n: i64, a: const u8[:], s0: i64, s1: i64 }
var TW: TWarn[>..] = [];

let TK_MAX_WORDS = 12;
let TK_MAX_CHARS = 90;

// True when the event belongs in slides (or in the article, with `article`).
fn in_scope(e: Ev, article: bool) -> bool {
    if article { return e.scope != SC_SLIDES; }
    return e.scope != SC_ARTICLE;
}

// Notes, narration, public notes, and explanations are not body content.
fn is_extracted(e: Ev) -> bool {
    e.k == K_DIV && (e.n == D_NOTES || e.n == D_NARRATION || e.n == D_PUBLIC || e.n == D_EXPLAIN)
}

fn frame_title_empty(f: Frame) -> bool { f.title.n == 0 }

fn add_slide(kind: i64, fi: i64, num: i64, el: i64, lo: i64, hi: i64, n: i64, cont: bool, s0: i64, s1: i64) {
    SL.push(Slide { kind: kind, frame: fi, num: num, el: el, lo: lo, hi: hi, n: n, cont: cont, steps: 1, s0: s0, s1: s1 });
}

// --- Normal slides -----------------------------------------------------

fn normal_slides() {
    SL.clear();
    TAKAHASHI = false;
    var section = 0;
    for f, fi in FR {
        if f.scope == SC_ARTICLE { continue; }
        // Groups between thematic breaks, without empty groups.
        var glo: i64[>..] = [];
        var ghi: i64[>..] = [];
        var cur = -1;
        var last = -1;
        var i = f.lo;
        while i < f.hi {
            let e = EV[i];
            if in_scope(e, false) && !is_extracted(e) {
                if e.k == K_RULE {
                    if cur >= 0 { glo.push(cur); ghi.push(last); cur = -1; }
                } else {
                    if cur < 0 { cur = i; }
                    last = e.end;
                }
            }
            i = e.end;
        }
        if cur >= 0 { glo.push(cur); ghi.push(last); }
        let kind = if f.kind == F_TITLE { SK_TITLE } else if f.kind == F_SECTION { SK_SECTION } else { SK_CONTENT };
        if kind == SK_SECTION { section++; }
        if glo.len == 0 {
            add_slide(kind, fi, section, EL_GROUP, f.lo, f.lo, 0, false, f.s0, f.s1);
            continue;
        }
        add_slide(kind, fi, section, EL_GROUP, glo[0], ghi[0], 0, false, f.s0, f.s1);
        for k in 1..glo.len {
            let s0 = EV[glo[k]].s0;
            var s1 = s0;
            var j = glo[k];
            while j < ghi[k] { s1 = EV[j].s1; j = EV[j].end; }
            add_slide(SK_CONTENT, fi, section, EL_GROUP, glo[k], ghi[k], k, true, s0, s1);
        }
    }
}

// --- Takahashi slides --------------------------------------------------

var TK_FRAME = 0;
var TK_N = 0;

fn tk_add(el: i64, lo: i64, hi: i64, s0: i64, s1: i64, cont: bool) {
    add_slide(SK_CONTENT, TK_FRAME, 0, el, lo, hi, TK_N, cont, s0, s1);
    TK_N++;
}

fn tk_warn(name: const u8[:], e: Ev) { TW.push(TWarn { 2, 0, name, e.s0, e.s1 }); }

fn tk_statement_text(t: u8[:], s0: i64, s1: i64, cont: bool) {
    let lo, hi = inline_text(t);
    tk_add(EL_STATEMENT, lo, hi, s0, s1, cont);
}

// The display equations in a block, for equation steps: display math, or
// the inline math at the top level of a paragraph.
fn each_equation<F>(b: i64) {
    let e = EV[b];
    if e.k == K_MATH { F(e.a); return; }
    if e.k != K_PARA { return; }
    var i = b + 1;
    while i < e.end - 1 {
        let x = EV[i];
        if !x.close && x.k == I_MATH { F(x.a); }
        i = x.end;
    }
}

// Sentence groups of a paragraph's source: ranges into STX, which holds the
// paragraph source. fl = 1 for an overlong group.
struct Group { s: i64, e: i64, over: bool }
var GROUPS: Group[>..] = [];

fn collapsed_chars(t: u8[:]) -> i64 {
    var n = 0;
    var i = 0;
    var first = true;
    while i < t.len {
        while i < t.len && is_ws(t[i]) { i++; }
        if i >= t.len { break; }
        if !first { n++; }
        first = false;
        while i < t.len && !is_ws(t[i]) { if (t[i] & 0xC0) != 0x80 { n++; } i++; }
    }
    return n;
}

fn tk_fits(a: i64, b: i64) -> bool {
    word_count(STX[a..b]) <= TK_MAX_WORDS && collapsed_chars(STX[a..b]) <= TK_MAX_CHARS
}

fn sentence_groups(source: u8[:]) {
    split_markdown(source);
    GROUPS.clear();
    var cs = -1;
    var ce = -1;
    fn close() {
        if cs >= 0 {
            var a = cs;
            var b = ce;
            while a < b && is_ws(STX[a]) { a++; }
            while b > a && is_ws(STX[b - 1]) { b--; }
            GROUPS.push(Group { a, b, !tk_fits(cs, ce) });
        }
        cs = -1;
        ce = -1;
    }
    for r in SENT {
        if cs >= 0 {
            if tk_fits(cs, r.e) { ce = r.e; continue; }
            close();
        }
        cs = r.s;
        ce = r.e;
    }
    close();
}

fn tk_prose(b: i64) {
    let e = EV[b];
    sentence_groups(SRC[e.s0..e.s1]);
    // The groups are ranges into STX, which the statements below replace.
    var gs: Group[>..] = [];
    gs.append(GROUPS);
    var text: u8[>..] = [];
    text.append(STX);
    for g in gs {
        let s0 = e.s0 + g.s;
        let s1 = e.s0 + g.e;
        let t = text[g.s..g.e];
        if g.over {
            TW.push(TWarn { 1, word_count(t), "", s0, s1 });
            STX.clear();
            STX.append(t);
            var cuts: i64[>..] = [];
            word_chunks(cuts, TK_MAX_WORDS, TK_MAX_CHARS);
            var parts: u8[>..] = [];
            var ends: i64[>..] = [];
            var start = 0;
            for c in cuts {
                for k in start..c {
                    if k > start { parts.push(' '); }
                    parts.append(wtok(k));
                }
                ends.push(parts.len);
                start = c;
            }
            var a = 0;
            for p, k in ends {
                tk_statement_text(parts[a..p], s0, s1, k > 0);
                a = p;
            }
        } else {
            tk_statement_text(t, s0, s1, false);
        }
    }
}

recursive fn tk_blocks(lo: i64, hi: i64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        let next = e.end;
        if !in_scope(e, false) || e.close { i = next; continue; }
        let k = e.k;
        if k == K_PARA { tk_prose(i); }
        else if k == K_HEAD { tk_add(EL_STATEMENT, i + 1, e.end - 1, e.s0, e.s1, false); }
        else if k == K_LIST {
            var j = i + 1;
            while j < e.end - 1 {
                let it = EV[j];
                if it.k == K_ITEM && !it.close { tk_blocks(j + 1, it.end - 1); }
                j = it.end;
            }
        }
        else if k == K_QUOTE { tk_blocks(i + 1, e.end - 1); }
        else if k == K_MATH { tk_add(EL_BLOCK, i, i, e.s0, e.s1, false); }
        else if k == K_FIG {
            if e.n == M_VIDEO { tk_warn("video", e); }
            else if e.n == M_AUDIO { tk_warn("audio", e); }
            tk_add(EL_BLOCK, i, i, e.s0, e.s1, false);
        }
        else if k == K_CODE { tk_warn("code", e); tk_add(EL_BLOCK, i, i, e.s0, e.s1, false); }
        else if k == K_TABLE { tk_warn("table", e); tk_add(EL_BLOCK, i, i, e.s0, e.s1, false); }
        else if k == K_RAW { tk_add(EL_BLOCK, i, i, e.s0, e.s1, false); }
        else if k == K_DIV {
            let d = e.n;
            if d == D_BOX {
                if e.a.n > 0 {
                    var title: u8[>..] = [];
                    title.append(sp_text(e.a));
                    tk_statement_text(title, e.s0, e.s1, false);
                }
                tk_blocks(i + 1, e.end - 1);
            } else if d == D_COLUMNS || d == D_COLUMN || d == D_UNKNOWN {
                tk_blocks(i + 1, e.end - 1);
            } else if d == D_MORPH {
                var j = i + 1;
                while j < e.end - 1 {
                    each_equation(j) { tk_add(EL_MATH, it.o, it.n, e.s0, e.s1, false); };
                    j = EV[j].end;
                }
            } else if d == D_PLOT {
                tk_warn("plot", e);
                tk_add(EL_PLOT, i, i, e.s0, e.s1, false);
            } else if d == D_CHART {
                tk_warn("chart", e);
                if div_table(i) >= 0 { tk_add(EL_CHART, i, i, e.s0, e.s1, false); }
            }
        }
        i = next;
    }
}

// The first table at the top level of a division, or -1.
fn div_table(d: i64) -> i64 {
    var j = d + 1;
    while j < EV[d].end - 1 {
        if EV[j].k == K_TABLE && !EV[j].close { return j; }
        j = EV[j].end;
    }
    return -1;
}

fn takahashi_slides() {
    SL.clear();
    TW.clear();
    TAKAHASHI = true;
    var section = 0;
    for f, fi in FR {
        if f.scope == SC_ARTICLE { continue; }
        TK_FRAME = fi;
        TK_N = 0;
        if f.kind == F_TITLE {
            if has_meta("title") || has_meta("subtitle") {
                add_slide(SK_TITLE, fi, 0, EL_NONE, 0, 0, 0, false, f.hs0, f.hs1);
                TK_N++;
            }
        } else if f.kind == F_SECTION {
            section++;
            add_slide(SK_SECTION, fi, section, EL_NONE, 0, 0, 0, false, f.hs0, f.hs1);
            TK_N++;
        } else if f.title.n > 0 {
            tk_add(EL_STATEMENT, f.head + 1, EV[f.head].end - 1, f.hs0, f.hs1, false);
        }
        tk_blocks(f.lo, f.hi);
    }
}

fn build_deck(takahashi: bool) {
    if takahashi { takahashi_slides(); } else { normal_slides(); }
}

// The revised Markdown copy: top-level slide paragraphs split into one
// paragraph per Takahashi slide. All other text stays byte for byte.
fn revised_markdown(out: u8[>..]&) {
    var cursor = 0;
    for f in FR {
        if f.scope == SC_ARTICLE { continue; }
        var i = f.lo;
        while i < f.hi {
            let e = EV[i];
            if e.k == K_PARA && in_scope(e, false) {
                sentence_groups(SRC[e.s0..e.s1]);
                if GROUPS.len > 1 {
                    out.append(SRC[cursor..e.s0]);
                    for g, k in GROUPS {
                        if k > 0 { out.append("\n\n"); }
                        out.append(STX[g.s..g.e]);
                    }
                    cursor = e.s1;
                }
            }
            i = e.end;
        }
    }
    out.append(SRC[cursor..]);
}
