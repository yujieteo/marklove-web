// The narration script, as the app's NarrationComposer: the exact text that
// narration speaks. Transcripts and subtitles use the same text.
//
// - A `::: narration` block replaces the spoken text for its frame.
// - Otherwise shared prose is spoken: the frame title, paragraphs, list
//   items, quotes, and `::: explain` blocks, in source order.
// - Slide-only and article-only passages are not spoken.
// - Equations, images, tables, plots, and charts need an authored
//   explanation. Paragraphs with inline math are not read aloud.

import sentence;

let NO_TITLE = 1;
let NO_SECTION = 2;
let NO_HEADING = 3;
let NO_PROSE = 4;
let NO_EXPLANATION = 5;
let NO_OVERRIDE = 6;

// Visual content that needs an explanation.
let NV_EQUATION = 1;
let NV_IMAGE = 2;
let NV_VIDEO = 3;
let NV_TABLE = 4;
let NV_PLOT = 5;
let NV_CHART = 6;
let NV_STEPS = 7;
let NV_INLINE_MATH = 8;

struct NSeg { frame: i64, text: Span, origin: i64, s0: i64, s1: i64, sent_lo: i64, sent_hi: i64 }
struct NMiss { kind: i64, frame: i64, s0: i64, s1: i64 }
var NSEG: NSeg[>..] = [];
var NMISS: NMiss[>..] = [];
// The sentences of all segments, as spans in S.
var NSENT: Span[>..] = [];

// The items of one frame, before sorting.
struct NItem { s0: i64, s1: i64, text: Span, has_text: bool, origin: i64, visual: i64 }
var NITEMS: NItem[>..] = [];

fn narr_has_frame(fi: i64) -> bool {
    for g in NSEG { if g.frame == fi { return true; } }
    return false;
}

// The plain spoken text of authored Markdown, into S.
fn spoken(t: u8[:]) -> Span {
    var copy: u8[>..] = [];
    copy.append(t);
    let mark = EV.len;
    let lo, hi = inline_text(copy);
    let o = S.len;
    plain_inline(S, lo, hi);
    EV.resize(mark);
    return Span { o, S.len - o };
}

// A title with a full stop, so that it reads as a sentence.
fn sentence_end(out: u8[>..]&, t0: u8[:]) {
    let t = trim_all(t0);
    out.append(t);
    if t.len == 0 { return; }
    if !contains_byte(".!?:", t[t.len - 1]) { out.push('.'); }
}

fn segment(text: u8[:], fi: i64, origin: i64, s0: i64, s1: i64) {
    var clean: u8[>..] = [];
    collapse_ws(clean, text);
    if clean.len == 0 { return; }
    let o = S.len;
    S.append(clean);
    let lo = NSENT.len;
    split_plain(clean);
    for r in SENT {
        let so = S.len;
        S.append(STX[r.s..r.e]);
        NSENT.push(Span { so, r.e - r.s });
    }
    NSEG.push(NSeg { fi, Span { o, clean.len }, origin, s0, s1, lo, NSENT.len });
}

fn contains_math(lo: i64, hi: i64) -> bool {
    for i in lo..hi { if EV[i].k == I_MATH { return true; } }
    return false;
}

fn item(s0: i64, s1: i64, text: Span, has_text: bool, origin: i64, visual: i64) {
    NITEMS.push(NItem { s0, s1, text, has_text, origin, visual });
}

recursive fn collect(lo: i64, hi: i64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        let next = e.end;
        if e.close || e.scope != SC_NONE { i = next; continue; }
        let k = e.k;
        let none = Span { 0, 0 };
        if k == K_PARA {
            if contains_math(i + 1, e.end - 1) { item(e.s0, e.s1, none, false, NO_PROSE, NV_INLINE_MATH); }
            else {
                let o = S.len;
                plain_block(S, i);
                item(e.s0, e.s1, Span { o, S.len - o }, true, NO_PROSE, 0);
            }
        } else if k == K_HEAD {
            var t: u8[>..] = [];
            plain_block(t, i);
            let o = S.len;
            sentence_end(S, t);
            item(e.s0, e.s1, Span { o, S.len - o }, true, NO_HEADING, 0);
        } else if k == K_LIST {
            var j = i + 1;
            while j < e.end - 1 {
                if EV[j].k == K_ITEM && !EV[j].close { collect(j + 1, EV[j].end - 1); }
                j = EV[j].end;
            }
        } else if k == K_QUOTE {
            collect(i + 1, e.end - 1);
        } else if k == K_MATH {
            item(e.s0, e.s1, none, false, NO_PROSE, NV_EQUATION);
        } else if k == K_FIG {
            if e.fl != 1 && e.n != M_AUDIO { item(e.s0, e.s1, none, false, NO_PROSE, if e.n == M_VIDEO { NV_VIDEO } else { NV_IMAGE }); }
        } else if k == K_TABLE {
            item(e.s0, e.s1, none, false, NO_PROSE, NV_TABLE);
        } else if k == K_DIV {
            let d = e.n;
            if d == D_PLOT { item(e.s0, e.s1, none, false, NO_PROSE, NV_PLOT); }
            else if d == D_CHART { item(e.s0, e.s1, none, false, NO_PROSE, NV_CHART); }
            else if d == D_MORPH { item(e.s0, e.s1, none, false, NO_PROSE, NV_STEPS); }
            else if d == D_BOX || d == D_COLUMNS || d == D_COLUMN || d == D_UNKNOWN { collect(i + 1, e.end - 1); }
        }
        i = next;
    }
}

// Explanations in a frame at any depth of divisions, in any scope, as the
// app extracts them from the body.
recursive fn collect_explain(lo: i64, hi: i64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        if !e.close && e.k == K_DIV {
            if e.n == D_EXPLAIN {
                let sp = spoken(sp_text(e.c));
                item(e.s0, e.s1, sp, true, NO_EXPLANATION, 0);
            } else {
                collect_explain(i + 1, e.end - 1);
            }
        }
        i = e.end;
    }
}

fn first_div(lo: i64, hi: i64, kind: i64) -> i64 {
    for i in lo..hi { if EV[i].k == K_DIV && !EV[i].close && EV[i].n == kind { return i; } }
    return -1;
}

fn narration_script() {
    NSEG.clear();
    NMISS.clear();
    NSENT.clear();
    var section = 0;
    for f, fi in FR {
        if f.scope != SC_NONE { continue; }
        if f.kind == F_SECTION { section++; }
        var over: u8[>..] = [];
        frame_raw(over, f, D_NARRATION);
        if over.len > 0 {
            let d = first_div(f.lo, f.hi, D_NARRATION);
            let s0 = if d >= 0 { EV[d].s0 } else { f.s0 };
            let s1 = if d >= 0 { EV[d].s1 } else { f.s1 };
            let sp = spoken(over);
            var t: u8[>..] = [];
            t.append(sp_text(sp));
            segment(t, fi, NO_OVERRIDE, s0, s1);
            continue;
        }
        var head: u8[>..] = [];
        if f.kind == F_TITLE {
            let a = meta("title");
            let b = meta("subtitle");
            if a.len > 0 { sentence_end(head, a); }
            if b.len > 0 { if head.len > 0 { head.push(' '); } sentence_end(head, b); }
            if head.len > 0 { segment(head, fi, NO_TITLE, f.hs0, f.hs1); }
        } else if f.kind == F_SECTION {
            format(head, "Part ", section, ". ");
            sentence_end(head, sp_text(f.title));
            segment(head, fi, NO_SECTION, f.hs0, f.hs1);
        } else if f.title.n > 0 {
            sentence_end(head, sp_text(f.title));
            segment(head, fi, NO_HEADING, f.hs0, f.hs1);
        }
        NITEMS.clear();
        collect(f.lo, f.hi);
        collect_explain(f.lo, f.hi);
        stable_sort(NITEMS) { a, b => a.s0 < b.s0 };
        var unc: NMiss[>..] = [];
        var items: NItem[>..] = [];
        items.append(NITEMS);
        for it in items {
            if it.visual > 0 { unc.push(NMiss { it.visual, fi, it.s0, it.s1 }); continue; }
            if it.origin == NO_EXPLANATION { unc.clear(); }
            if it.has_text {
                var t: u8[>..] = [];
                t.append(sp_text(it.text));
                segment(t, fi, it.origin, it.s0, it.s1);
            }
        }
        NMISS.append(unc);
    }
}

// --- text outputs ----------------------------------------------------------

// The script as readable text, one paragraph per segment, grouped by frame.
fn narration_text(out: u8[>..]&) {
    var last = -1;
    var n = 0;
    for g in NSEG {
        if g.frame != last {
            if n > 0 { out.append("\n\n"); }
            n++;
            out.push('[');
            if FR[g.frame].kind == F_TITLE { out.append("Title"); } else { out.append(sp_text(FR[g.frame].title)); }
            out.push(']');
            last = g.frame;
        }
        if n > 0 { out.append("\n\n"); }
        n++;
        out.append(sp_text(g.text));
    }
    out.push('\n');
}

fn repeat(out: u8[>..]&, c: u8, n: i64) { for k in n { out.push(c); } }

fn transcript(out: u8[>..]&) {
    let title = doc_title();
    out.append(title);
    out.push('\n');
    repeat(out, '=', min(char_count(title), 60));
    out.append("\n");
    var last = -1;
    for g in NSEG {
        let f = FR[g.frame];
        if g.frame != last && f.kind != F_TITLE {
            out.append("\n\n");
            out.append(sp_text(f.title));
            out.push('\n');
            repeat(out, '-', min(char_count(sp_text(f.title)), 60));
            last = g.frame;
        }
        out.push('\n');
        out.append(sp_text(g.text));
    }
    out.push('\n');
}

// Subtitle cues, as VideoTimeline: each frame's sentences are shared out
// across its reveal steps (`frame_steps` gives the steps of each frame).
struct Cue { start: f64, end: f64, text: Span }
var CUES: Cue[>..] = [];

let MIN_STEP = 2.5;
let SILENT_STEP = 4.0;
let SENTENCE_GAP = 0.3;

fn timeline(frame_steps: i64[:]) {
    CUES.clear();
    var t = 0.0;
    for fi in frame_steps.len {
        let total = frame_steps[fi];
        if total <= 0 { continue; }
        var sents: Span[>..] = [];
        for g in NSEG { if g.frame == fi { for k in g.sent_lo..g.sent_hi { sents.push(NSENT[k]); } } }
        var bucket: i64[>..] = [];
        for k in sents.len { bucket.push(max(0, min(total - 1, k * total / max(sents.len, 1)))); }
        for step in total {
            var speech = 0.0;
            var any = false;
            for k in sents.len { if bucket[k] == step { any = true; speech += estimated_seconds(sp_text(sents[k])) + SENTENCE_GAP; } }
            let d = if any { max(MIN_STEP, speech + 0.6) } else { SILENT_STEP };
            var ct = t + 0.3;
            for k in sents.len {
                if bucket[k] != step { continue; }
                let sd = estimated_seconds(sp_text(sents[k]));
                CUES.push(Cue { ct, ct + sd, sents[k] });
                ct += sd + SENTENCE_GAP;
            }
            t += d;
        }
    }
}

fn timestamp(out: u8[>..]&, seconds: f64, comma: bool) {
    let ms = round(seconds * 1000.0) as i64;
    format_int(out, ms / 3600000, 10, 2, '0');
    out.push(':');
    format_int(out, (ms / 60000) % 60, 10, 2, '0');
    out.push(':');
    format_int(out, (ms / 1000) % 60, 10, 2, '0');
    out.push(if comma { ',' } else { '.' });
    format_int(out, ms % 1000, 10, 3, '0');
}

fn cues_text(out: u8[>..]&, srt: bool) {
    if !srt { out.append("WEBVTT\n\n"); }
    for c, i in CUES {
        format(out, i + 1, "\n");
        timestamp(out, c.start, srt);
        out.append(" --> ");
        timestamp(out, c.end, srt);
        out.push('\n');
        out.append(sp_text(c.text));
        out.append("\n\n");
    }
}
