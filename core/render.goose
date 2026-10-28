// HTML for slides and the article, as the app's HTMLWriter, HTMLExporter
// and ArticleExporter.
//
// The renderer writes into `H`. It also composes slide elements as it goes:
// a pause adds a reveal step, and each element gets the current step.

import deck;
import texmath;
import plot;
import highlight;
import narr;
import pack;

var H: u8[>..] = [];
var STEP = 0;
// Article mode: article scope, and no reveal steps.
var ART = false;
// XHTML for EPUB: closed empty elements and no scripted controls.
var XHTML = false;
var FIGS = 0;
// The label of the first element of a slide.
var LABEL: u8[>..] = [];
var DEPTH = 0;

// Assets: "path\tsource\n" lines from JavaScript. The source is a data URL
// or a blob URL. With LINK_PREFIX, media are links (for EPUB) instead.
var ASSETS: u8[>..] = [];
struct Asset { k: Line, v: Line }
var AS: Asset[>..] = [];
var LINK_PREFIX: u8[>..] = [];
var LINKED: u8[>..] = [];

fn load_assets(t: u8[:]) {
    ASSETS.clear();
    ASSETS.append(t);
    AS.clear();
    var i = 0;
    while i < ASSETS.len {
        var e = index_of_byte(ASSETS, '\n', i);
        if e < 0 { e = ASSETS.len; }
        let tab = index_of_byte(ASSETS[..e], '\t', i);
        if tab > i { AS.push(Asset { Line { i, tab }, Line { tab + 1, e } }); }
        i = e + 1;
    }
}

fn norm_path(p: u8[:]) -> u8[:] {
    var t = trim_sp(p);
    while has_prefix(t, "./") { t = t[2..]; }
    return t;
}

fn asset_index(path: u8[:]) -> i64 {
    let p = norm_path(path);
    for a, i in AS { if ASSETS[a.k.s..a.k.e] == p { return i; } }
    return -1;
}

fn url_path_allowed(c: u8) -> bool { is_alnum(c) || contains_byte("-._~!$&'()*+,;=:@/", c) }

// "%XX" with upper-case hex digits, as Foundation's percent encoding.
fn pct_byte(out: u8[>..]&, c: u8) {
    out.push('%');
    out.push("0123456789ABCDEF"[(c >> 4) as i64]);
    out.push("0123456789ABCDEF"[(c & 15) as i64]);
}

// Writes the source of an asset: a link for EPUB, or the given URL.
fn asset_source(i: i64) {
    let a = AS[i];
    if LINK_PREFIX.len > 0 {
        let p = ASSETS[a.k.s..a.k.e];
        // Remember the path once, for the EPUB manifest.
        var seen = false;
        var j = 0;
        while j < LINKED.len {
            var e = index_of_byte(LINKED, '\n', j);
            if e < 0 { e = LINKED.len; }
            if LINKED[j..e] == p { seen = true; }
            j = e + 1;
        }
        if !seen { LINKED.append(p); LINKED.push('\n'); }
        H.append(LINK_PREFIX);
        for c in p {
            if url_path_allowed(c) { H.push(c); } else { pct_byte(H, c); }
        }
        return;
    }
    esc(H, ASSETS[a.v.s..a.v.e]);
}

fn br() { H.append(if XHTML { "<br/>" } else { "<br>" }); }
fn end_tag() { H.append(if XHTML { "/>" } else { ">" }); }
fn flag(name: const u8[:]) {
    H.push(' ');
    H.append(name);
    if XHTML { H.append("=\""); H.append(name); H.push('"'); }
}

fn step_attr(out: u8[>..]&, step: i64) {
    if step > 0 && !ART { format(out, " data-step=\"", step, "\""); }
}

fn hs(step: i64) { step_attr(H, step); }

fn safe_url(url: u8[:]) -> bool {
    let t = trim_sp(url);
    var low: u8[..16] = [];
    for c in t { if low.len < 16 { low.push(lower(c)); } }
    if has_prefix(low, "http://") || has_prefix(low, "https://") || has_prefix(low, "mailto:") || has_prefix(low, "#") { return true; }
    return !contains_byte(t, ':');
}

fn math(latex: u8[:], display: bool) { math_html(H, latex, display); }

// --- inlines -------------------------------------------------------------

fn r_inline(lo: i64, hi: i64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        let k = e.k;
        if e.close {
            if k == I_EM { H.append("</em>"); }
            else if k == I_STRONG { H.append("</strong>"); }
            else if k == I_DEL { H.append("</del>"); }
            else if k == I_LINK { H.append("</a>"); }
            i++;
            continue;
        }
        if k == I_TEXT { esc(H, sp_text(e.a)); }
        else if k == I_EM { H.append("<em>"); }
        else if k == I_STRONG { H.append("<strong>"); }
        else if k == I_DEL { H.append("<del>"); }
        else if k == I_CODE { H.append("<code>"); esc(H, sp_text(e.a)); H.append("</code>"); }
        else if k == I_MATH { math(sp_text(e.a), false); }
        else if k == I_LINK {
            H.append("<a href=\"");
            if safe_url(sp_text(e.b)) { esc(H, sp_text(e.b)); } else { H.push('#'); }
            H.push('"');
            if e.c.n > 0 { H.append(" title=\""); esc(H, sp_text(e.c)); H.push('"'); }
            H.append(" rel=\"noopener noreferrer\">");
        }
        else if k == I_IMG {
            let ai = asset_index(sp_text(e.b));
            if ai >= 0 {
                H.append("<img src=\"");
                asset_source(ai);
                H.append("\" alt=\"");
                esc(H, sp_text(e.a));
                H.append("\" style=\"height:1.2em;vertical-align:middle\"");
                end_tag();
            } else {
                H.append("<span class=\"missing\">");
                esc(H, sp_text(e.a));
                H.append("</span>");
            }
        }
        else if k == I_SOFT { H.push(' '); }
        else if k == I_HARD { br(); }
        else if k == I_HTML { H.append("<code>"); esc(H, sp_text(e.a)); H.append("</code>"); }
        i++;
    }
}

// Inline Markdown text that is not in the source, such as a box title.
fn r_inline_text(t: u8[:]) {
    let mark = EV.len;
    let lo, hi = inline_text(t);
    r_inline(lo, hi);
    EV.resize(mark);
}

fn capitalized(out: u8[>..]&, s: u8[:]) {
    for c, i in s { out.push(if i == 0 { upper(c) } else { lower(c) }); }
}

// --- blocks --------------------------------------------------------------

fn r_table(t: i64) {
    H.append("<table><thead><tr>");
    var head = true;
    var r = t + 1;
    while r < EV[t].end - 1 {
        let row = EV[r];
        if row.k != K_ROW || row.close { r = row.end; continue; }
        if row.fl != 1 && head { H.append("</tr></thead><tbody>"); head = false; }
        if row.fl != 1 { H.append("<tr>"); }
        var c = r + 1;
        while c < row.end - 1 {
            let cell = EV[c];
            if cell.k == K_CELL && !cell.close {
                let cls = if cell.fl == 3 { " class=\"right\"" } else if cell.fl == 2 { " class=\"center\"" } else { "" };
                H.append(if row.fl == 1 { "<th scope=\"col\"" } else { "<td" });
                H.append(cls);
                H.push('>');
                r_inline(c + 1, cell.end - 1);
                H.append(if row.fl == 1 { "</th>" } else { "</td>" });
            }
            c = cell.end;
        }
        if row.fl != 1 { H.append("</tr>"); }
        r = row.end;
    }
    if head { H.append("</tr></thead><tbody>"); }
    H.append("</tbody></table>");
}

fn is_remote(p: u8[:]) -> bool {
    var low: u8[..16] = [];
    for c in p { if low.len < 16 { low.push(lower(c)); } }
    return has_prefix(low, "http://") || has_prefix(low, "https://") || has_prefix(low, "//");
}

fn r_figure(i: i64, step: i64) {
    let f = EV[i];
    FIGS++;
    let desc = sp_text(f.a);
    let path = sp_text(f.b);
    let deco = f.fl == 1;
    let remote = is_remote(path);
    let ai = if remote { -1 } else { asset_index(path) };
    let m = H.len;
    if ai >= 0 {
        if f.n == M_IMAGE {
            H.append("<img src=\"");
            asset_source(ai);
            H.append("\" alt=\"");
            if !deco { esc(H, desc); }
            H.push('"');
            if deco { H.append(" role=\"presentation\""); }
            end_tag();
        } else {
            H.append(if f.n == M_VIDEO { "<video" } else { "<audio" });
            flag("controls");
            H.append(" preload=\"metadata\" src=\"");
            asset_source(ai);
            H.append("\" aria-label=\"");
            if !deco { esc(H, desc); }
            H.append(if f.n == M_VIDEO { "\"></video>" } else { "\"></audio>" });
        }
    } else {
        var reason: u8[>..] = [];
        if remote { reason.append("Image not included: Marklove does not download images."); }
        else { reason.append("Image not found: "); reason.append(path); }
        H.append("<div class=\"missing\" role=\"img\" aria-label=\"");
        if deco || desc.len == 0 { esc(H, reason); } else { esc(H, desc); }
        H.append("\">");
        esc(H, reason);
        br();
        esc(H, desc);
        H.append("</div>");
    }
    // The media markup goes inside the figure element.
    var media: u8[>..] = [];
    media.append(H[m..]);
    H.resize(m);
    if f.c.n > 0 {
        format(H, "<figure class=\"fig\" tabindex=\"0\"");
        flag("data-caption");
        format(H, " aria-describedby=\"cap-", FIGS, "\"");
        hs(step);
        H.push('>');
        H.append(media);
        format(H, "<div class=\"cap\" role=\"tooltip\" id=\"cap-", FIGS, "\">");
        esc(H, sp_text(f.c));
        H.append("</div></figure>");
        return;
    }
    H.append("<figure class=\"fig\"");
    hs(step);
    H.push('>');
    H.append(media);
    H.append("</figure>");
}

recursive fn r_block(i: i64, step: i64) {
    let e = EV[i];
    let k = e.k;
    if k == K_PARA {
        H.append("<p"); hs(step); H.push('>');
        r_inline(i + 1, e.end - 1);
        H.append("</p>");
    } else if k == K_HEAD {
        let l = min(max(e.n + 1, 3), 6);
        format(H, "<h", l); hs(step); H.push('>');
        r_inline(i + 1, e.end - 1);
        format(H, "</h", l, ">");
    } else if k == K_LIST {
        let ordered = (e.fl & 1) != 0;
        H.append(if ordered { "<ol" } else { "<ul" });
        if ordered && e.n != 1 { format(H, " start=\"", e.n, "\""); }
        hs(step);
        H.push('>');
        var j = i + 1;
        while j < e.end - 1 {
            let it = EV[j];
            if it.k == K_ITEM && !it.close {
                H.append("<li>");
                if it.fl > 0 {
                    H.append("<input type=\"checkbox\"");
                    flag("disabled");
                    if it.fl == 2 { flag("checked"); }
                    H.append(if it.fl == 2 { " aria-label=\"Done\"" } else { " aria-label=\"Not done\"" });
                    end_tag();
                    H.push(' ');
                }
                var c = j + 1;
                var first = true;
                while c < it.end - 1 {
                    let ch = EV[c];
                    if !first { H.push(' '); }
                    first = false;
                    if ch.k == K_PARA { r_inline(c + 1, ch.end - 1); } else { r_block(c, 0); }
                    c = ch.end;
                }
                H.append("</li>");
            }
            j = it.end;
        }
        H.append(if ordered { "</ol>" } else { "</ul>" });
    } else if k == K_QUOTE {
        H.append("<blockquote"); hs(step); H.push('>');
        var c = i + 1;
        while c < e.end - 1 { r_block(c, 0); c = EV[c].end; }
        H.append("</blockquote>");
    } else if k == K_CODE {
        H.append("<pre"); hs(step); H.append("><code");
        if e.b.n > 0 { H.append(" class=\"language-"); esc(H, sp_text(e.b)); H.push('"'); }
        H.push('>');
        highlight_html(H, sp_text(e.a), sp_text(e.b));
        H.append("</code></pre>");
    } else if k == K_MATH {
        H.append("<div class=\"math-display\""); hs(step); H.push('>');
        math(sp_text(e.a), true);
        H.append("</div>");
    } else if k == K_TABLE {
        H.append("<div"); hs(step); H.push('>');
        r_table(i);
        H.append("</div>");
    } else if k == K_FIG {
        r_figure(i, step);
    } else if k == K_RAW {
        H.append("<pre class=\"raw-html\""); hs(step); H.push('>');
        esc(H, sp_text(e.a));
        H.append("</pre>");
    } else if k == K_DIV {
        H.append("<div"); hs(step); H.push('>');
        var c = i + 1;
        while c < e.end - 1 { r_block(c, 0); c = EV[c].end; }
        H.append("</div>");
    }
}

// --- charts --------------------------------------------------------------

// A bar chart from the first table of a `::: chart` division.
var CH_LABELS: Line[>..] = [];
var CH_NAMES: Line[>..] = [];
var CH_VALUES: f64[>..] = [];
var CH_COLS = 0;
var CH_ROWS = 0;
var CH_TEXT: u8[>..] = [];
var CH_ERRORS: u8[>..] = [];

fn ch_cell_text(cell: i64) -> Line {
    let o = CH_TEXT.len;
    var tmp: u8[>..] = [];
    plain_inline(tmp, cell + 1, EV[cell].end - 1);
    CH_TEXT.append(trim_sp(tmp));
    return Line { o, CH_TEXT.len };
}

fn ch_text(l: Line) -> u8[:] { CH_TEXT[l.s..l.e] }

fn chart_spec(d: i64) {
    CH_LABELS.clear();
    CH_NAMES.clear();
    CH_VALUES.clear();
    CH_TEXT.clear();
    CH_ERRORS.clear();
    CH_COLS = 0;
    CH_ROWS = 0;
    let t = div_table(d);
    if t < 0 { return; }
    let kind = trim_sp(sp_text(EV[d].a));
    if kind.len > 0 && !eq_nocase(kind, "bar") { CH_ERRORS.append("Marklove makes bar charts only. It shows this chart as a bar chart.\n"); }
    // Cells by row, as text.
    var cells: Line[>..] = [];
    var row_start: i64[>..] = [];
    var header: Line[>..] = [];
    var r = t + 1;
    while r < EV[t].end - 1 {
        let row = EV[r];
        if row.k == K_ROW && !row.close {
            if row.fl != 1 { row_start.push(cells.len); }
            var c = r + 1;
            while c < row.end - 1 {
                if EV[c].k == K_CELL && !EV[c].close {
                    let l = ch_cell_text(c);
                    if row.fl == 1 { header.push(l); } else { cells.push(l); }
                }
                c = EV[c].end;
            }
        }
        r = row.end;
    }
    row_start.push(cells.len);
    CH_COLS = header.len;
    CH_ROWS = row_start.len - 1;
    for ri in CH_ROWS {
        let a = row_start[ri];
        CH_LABELS.push(if row_start[ri + 1] > a { cells[a] } else { Line { 0, 0 } });
    }
    if CH_COLS < 2 { CH_ERRORS.append("A chart table needs a label column and at least one value column.\n"); }
    for c in 1..max(CH_COLS, 1) {
        if c < header.len { CH_NAMES.push(header[c]); }
        else {
            let o = CH_TEXT.len;
            format(CH_TEXT, "Series ", c);
            CH_NAMES.push(Line { o, CH_TEXT.len });
        }
        for ri in CH_ROWS {
            let a = row_start[ri];
            let n = row_start[ri + 1] - a;
            var raw: u8[>..] = [];
            if c < n { raw.append(ch_text(cells[a + c])); }
            var cleaned: u8[>..] = [];
            for b in raw { if b != ',' && b != '%' { cleaned.push(b); } }
            let v, ok = parse_flt(cleaned);
            if ok && cleaned.len > 0 { CH_VALUES.push(v); }
            else {
                CH_VALUES.push(0.0);
                format(CH_ERRORS, "Row ", ri + 1, ", column \"", ch_text(CH_NAMES[c - 1]), "\": \"", raw, "\" is not a number.\n");
            }
        }
    }
    // Duplicate and empty labels.
    var dup = false;
    var empty = false;
    for l, i in CH_LABELS {
        if l.e == l.s { empty = true; }
        for j in i { if ch_text(CH_LABELS[j]) == ch_text(l) { dup = true; } }
    }
    if dup { CH_ERRORS.append("Two or more rows have the same label.\n"); }
    if empty { CH_ERRORS.append("A row has no label.\n"); }
}

fn ch_value(series: i64, row: i64) -> f64 { CH_VALUES[series * CH_ROWS + row] }

let COLORS: (const u8[:])[] = ["var(--s1)", "var(--s2)", "var(--s3)", "var(--s4)", "var(--s5)", "var(--s6)"];

fn r_chart(d: i64, step: i64) {
    chart_spec(d);
    let t = div_table(d);
    let nser = CH_NAMES.len;
    var maxv = 1.0;
    var minv = 0.0;
    if CH_VALUES.len > 0 {
        maxv = CH_VALUES[0];
        minv = CH_VALUES[0];
        for v in CH_VALUES { maxv = max(maxv, v); minv = min(minv, v); }
    }
    maxv = max(maxv, 0.0);
    minv = min(minv, 0.0);
    let W = 1000.0;
    let Hh = 480.0;
    let L = 20.0;
    let R = 20.0;
    let T = 20.0;
    let B = 60.0;
    let span = max(maxv - minv, 1e-9);
    fn y(v: f64) -> f64 { T + (maxv - v) / span * (Hh - T - B) }
    let groups = max(CH_ROWS, 1);
    let gw = (W - L - R) / (groups as f64);
    let bw = gw * 0.7 / (max(nser, 1) as f64);
    H.append("<div class=\"chart\"");
    hs(step);
    H.push('>');
    if nser > 1 {
        H.append("<p class=\"labels\">");
        for k in nser {
            if k > 0 { H.push(' '); }
            format(H, "<span style=\"color:", COLORS[k % 6], "\">");
            esc(H, ch_text(CH_NAMES[k]));
            H.append("</span>");
        }
        H.append("</p>");
    } else {
        H.append("<p class=\"labels\"><span>");
        if nser > 0 { esc(H, ch_text(CH_NAMES[0])); }
        H.append("</span></p>");
    }
    H.append("<svg viewBox=\"0 0 1000 480\" role=\"group\" aria-label=\"");
    var sum: u8[>..] = [];
    sum.append("Bar chart. ");
    for g in CH_ROWS {
        if g > 0 { sum.append("; "); }
        sum.append(ch_text(CH_LABELS[g]));
        sum.append(": ");
        for k in nser {
            if k > 0 { sum.append(", "); }
            pl_fmt(sum, ch_value(k, g));
        }
    }
    sum.push('.');
    esc(H, sum);
    H.append("\">");
    H.append("<path d=\"M");
    fmt_fixed(H, L, 1); H.push(' '); fmt_fixed(H, y(0.0), 1); H.push('H'); fmt_fixed(H, W - R, 1);
    H.append("\" stroke=\"currentColor\" stroke-width=\"2\"/>");
    for g in CH_ROWS {
        let label = ch_text(CH_LABELS[g]);
        for k in nser {
            let v = ch_value(k, g);
            let x = L + (g as f64) * gw + gw * 0.15 + (k as f64) * bw;
            let top = y(max(v, 0.0));
            let bottom = y(min(v, 0.0));
            var name: u8[>..] = [];
            name.append(label);
            if nser > 1 { name.append(", "); name.append(ch_text(CH_NAMES[k])); }
            name.append(": ");
            pl_fmt(name, v);
            H.append("<rect class=\"bar-rect\" tabindex=\"0\" role=\"img\" aria-label=\"");
            esc(H, name);
            H.append("\" x=\""); fmt_fixed(H, x, 1);
            H.append("\" y=\""); fmt_fixed(H, top, 1);
            H.append("\" width=\""); fmt_fixed(H, bw * 0.92, 1);
            H.append("\" height=\""); fmt_fixed(H, max(bottom - top, 1.0), 1);
            format(H, "\" fill=\"", COLORS[k % 6], "\"><title>");
            esc(H, name);
            H.append("</title></rect>");
        }
        H.append("<text class=\"tick\" x=\""); fmt_fixed(H, L + ((g as f64) + 0.5) * gw, 1);
        H.append("\" y=\""); fmt_fixed(H, Hh - B + 36.0, 1);
        H.append("\" text-anchor=\"middle\" font-size=\"26\">");
        esc(H, label);
        H.append("</text>");
    }
    H.append("</svg><p class=\"readout\" aria-live=\"polite\"></p><details><summary>Data table</summary>");
    if t >= 0 { r_table(t); }
    H.append("</details></div>");
}

// --- elements --------------------------------------------------------------

fn r_plot(d: i64, step: i64) {
    var s: u8[>..] = [];
    step_attr(s, step);
    let mark = H.len;
    plot_html(H, sp_text(EV[d].c), s, "");
    // EPUB readers do not run scripts: the plot is a picture without sliders.
    if XHTML {
        let c = index_of(H, "<div class=\"controls\">", mark);
        if c >= 0 { H.resize(c); H.append("</div>"); }
    }
}

fn set_label(t: u8[:]) {
    if DEPTH > 0 || LABEL.len > 0 { return; }
    // At most 60 characters.
    var n = 0;
    for c in t {
        if (c & 0xC0) != 0x80 { n++; if n > 60 { break; } }
        LABEL.push(c);
    }
    if LABEL.len == 0 { LABEL.append("Slide"); }
}

fn label_block(i: i64) {
    if DEPTH > 0 || LABEL.len > 0 { return; }
    let e = EV[i];
    var t: u8[>..] = [];
    if e.k == K_FIG { t.append(if e.a.n == 0 { "Image" } else { sp_text(e.a) }); }
    else if e.k == K_MATH { t.append("Equation"); }
    else if e.k == K_PARA { plain_block(t, i); }
    else { t.append("Slide"); }
    set_label(t);
}

// Equation steps: display equations that replace each other.
fn r_eqsteps(d: i64) -> i64 {
    var count = 0;
    let at = STEP;
    var items: u8[>..] = [];
    let mark = H.len;
    var j = d + 1;
    while j < EV[d].end - 1 {
        each_equation(j) {
            H.append(if count == 0 { "<div class=\"eq math-display shown\">" } else { "<div class=\"eq math-display\">" });
            math(sp_text(it), true);
            H.append("</div>");
            count++;
        };
        j = EV[j].end;
    }
    items.append(H[mark..]);
    H.resize(mark);
    format(H, "<div class=\"eqsteps\" data-first=\"", if ART { 0 } else { at }, "\" aria-live=\"polite\" role=\"group\" aria-label=\"Equation steps\"");
    hs(at);
    H.push('>');
    H.append(items);
    H.append("</div>");
    return max(count, 1);
}

// Converts and writes the top-level events lo..hi as slide or article elements.
recursive fn r_elements(lo: i64, hi: i64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        let next = e.end;
        if e.close || !in_scope(e, ART) { i = next; continue; }
        let k = e.k;
        if k == K_PAUSE { if !ART { STEP++; } i = next; continue; }
        if k == K_RULE || (k == K_HEAD && e.n <= 2) { i = next; continue; }
        if k != K_DIV {
            label_block(i);
            r_block(i, STEP);
            i = next;
            continue;
        }
        let d = e.n;
        if d == D_NOTES || d == D_NARRATION || d == D_PUBLIC || d == D_EXPLAIN { i = next; continue; }
        set_label("Slide");
        let start = STEP;
        if d == D_BOX {
            let style = sp_text(e.b);
            H.append("<div class=\"box ");
            esc(H, style);
            H.append("\" role=\"group\" aria-label=\"");
            {
                var lab: u8[>..] = [];
                capitalized(lab, style);
                if e.a.n > 0 { lab.append(": "); lab.append(sp_text(e.a)); }
                esc(H, lab);
            }
            H.push('"');
            hs(start);
            H.push('>');
            if e.a.n > 0 {
                H.append("<div class=\"box-title\">");
                var title: u8[>..] = [];
                title.append(sp_text(e.a));
                r_inline_text(title);
                H.append("</div>");
            }
            DEPTH++;
            r_elements(i + 1, e.end - 1);
            DEPTH--;
            H.append("</div>");
        } else if d == D_COLUMNS {
            H.append("<div class=\"columns\"");
            hs(start);
            H.push('>');
            var any = false;
            var max_step = STEP;
            DEPTH++;
            var j = i + 1;
            while j < e.end - 1 {
                let c = EV[j];
                if c.k == K_DIV && !c.close && c.n == D_COLUMN {
                    any = true;
                    STEP = start;
                    H.append("<div>");
                    r_elements(j + 1, c.end - 1);
                    H.append("</div>");
                    max_step = max(max_step, STEP);
                }
                j = c.end;
            }
            if !any {
                H.append("<div>");
                r_elements(i + 1, e.end - 1);
                H.append("</div>");
                max_step = STEP;
            }
            DEPTH--;
            STEP = max_step;
            H.append("</div>");
        } else if d == D_MORPH {
            let count = r_eqsteps(i);
            if !ART { STEP += count - 1; }
        } else if d == D_PLOT {
            r_plot(i, start);
        } else if d == D_CHART && div_table(i) >= 0 {
            r_chart(i, start);
        } else {
            // A column outside columns, a chart without a table, or an unknown name.
            H.append("<div");
            hs(start);
            H.push('>');
            DEPTH++;
            r_elements(i + 1, e.end - 1);
            DEPTH--;
            H.append("</div>");
        }
        i = next;
    }
}

// --- slides --------------------------------------------------------------

fn slide_id(out: u8[>..]&, s: Slide) {
    out.append(sp_text(FR[s.frame].id));
    if s.n > 0 { format(out, "-", s.n + 1); }
}

// The slide content: elements for Normal, one element for Takahashi.
fn r_slide_content(s: Slide) {
    STEP = 0;
    if s.el == EL_GROUP { r_elements(s.lo, s.hi); }
    else if s.el == EL_STATEMENT {
        var t: u8[>..] = [];
        plain_inline(t, s.lo, s.hi);
        set_label(t);
        H.append("<p class=\"statement\">");
        r_inline(s.lo, s.hi);
        H.append("</p>");
    }
    else if s.el == EL_BLOCK { label_block(s.lo); r_block(s.lo, 0); }
    else if s.el == EL_MATH {
        set_label("Equation");
        H.append("<div class=\"math-display\">");
        var t: u8[>..] = [];
        t.append(S[s.lo..s.lo + s.hi]);
        math(t, true);
        H.append("</div>");
    }
    else if s.el == EL_PLOT { set_label("Slide"); r_plot(s.lo, 0); }
    else if s.el == EL_CHART { set_label("Slide"); r_chart(s.lo, 0); }
}

fn byline(out: u8[>..]&, sep: u8[:]) -> bool {
    var n = 0;
    for key in ["author", "institute", "date"] {
        let v = meta(key);
        if v.len == 0 { continue; }
        if n > 0 { out.append(sep); }
        esc(out, v);
        n++;
    }
    return n > 0;
}

// The text of a frame's notes or public notes (kind D_NOTES or D_PUBLIC).
fn notes_text(out: u8[>..]&, fi: i64, kind: i64) { frame_raw(out, FR[fi], kind); }

var INCLUDE_NARRATION = true;
var INCLUDE_PUBLIC_NOTES = true;

fn r_slide(si: i64, total: i64) {
    let s = SL[si];
    let f = FR[s.frame];
    LABEL.clear();
    DEPTH = 0;
    // The content first: it gives the step count and the label.
    let mark = H.len;
    r_slide_content(s);
    var content: u8[>..] = [];
    content.append(H[mark..]);
    H.resize(mark);
    SL[si].steps = STEP + 1;
    var label: u8[>..] = [];
    // As Swift: the title slide's title is the "title" key, else none (the
    // title frame has no heading). Takahashi's h1 then shows doc.title.
    if s.kind == SK_TITLE { if has_meta("title") { label.append(meta("title")); } }
    else if (s.kind == SK_SECTION || s.n == 0) && f.title.n > 0 && !(TAKAHASHI && s.kind == SK_CONTENT) { label.append(sp_text(f.title)); }
    if label.len == 0 { label.append(if LABEL.len > 0 { LABEL } else { "Slide" }); }
    let kc = if s.kind == SK_TITLE { "kind-title" } else if s.kind == SK_SECTION { "kind-section" } else { "kind-content" };
    format(H, "<section class=\"slide ", kc, "\" id=\"");
    var id: u8[>..] = [];
    slide_id(id, s);
    esc(H, id);
    format(H, "\" data-steps=\"", STEP + 1, "\" aria-roledescription=\"slide\" aria-label=\"", si + 1, " of ", total, ": ");
    esc(H, label);
    H.append("\"><div class=\"frame\">");
    if s.kind == SK_TITLE {
        H.append("<h1>");
        if has_meta("title") { esc(H, meta("title")); }
        else if TAKAHASHI { esc(H, doc_title()); }
        H.append("</h1>");
        let sub = meta("subtitle");
        if sub.len > 0 { H.append("<p class=\"subtitle\">"); esc(H, sub); H.append("</p>"); }
        var b: u8[>..] = [];
        if byline(b, if XHTML { "<br/>" } else { "<br>" }) { H.append("<p class=\"byline\">"); H.append(b); H.append("</p>"); }
    } else if s.kind == SK_SECTION {
        format(H, "<p class=\"number\">Part ", s.num, "</p><h1>");
        if f.head >= 0 { r_inline(f.head + 1, EV[f.head].end - 1); }
        H.append("</h1>");
    } else if s.n == 0 && !TAKAHASHI && f.head >= 0 && f.title.n > 0 {
        H.append("<h2 class=\"slide-title\">");
        r_inline(f.head + 1, EV[f.head].end - 1);
        H.append("</h2>");
    }
    H.append(content);
    H.append("</div>");
    // Public notes and narration text, on the first slide of the frame.
    var pub: u8[>..] = [];
    if INCLUDE_PUBLIC_NOTES && s.n == 0 { notes_text(pub, s.frame, D_PUBLIC); }
    let has_narr = INCLUDE_NARRATION && s.n == 0 && narr_has_frame(s.frame);
    if pub.len > 0 || has_narr {
        H.append("<div class=\"extras\">");
        if pub.len > 0 {
            H.append("<details");
            flag("open");
            H.append("><summary>Notes</summary><p>");
            r_inline_text(pub);
            H.append("</p></details>");
        }
        if has_narr {
            H.append("<details><summary>Narration text</summary>");
            for g in NSEG {
                if g.frame != s.frame { continue; }
                H.append("<p>");
                esc(H, sp_text(g.text));
                H.append("</p>");
            }
            H.append("</details>");
        }
        H.append("</div>");
    }
    H.append("</section>\n");
}

// Writes all slides of the current deck.
fn r_slides() {
    FIGS = 0;
    plot_reset();
    for i in SL.len { r_slide(i, SL.len); }
}

// --- pages ----------------------------------------------------------------

// Page parts that JavaScript supplies: fonts, style sheets, the runtime.
var PART_FONTS: u8[>..] = [];
var PART_STYLE: u8[>..] = [];
var PART_THEME: u8[>..] = [];
var PART_RUNTIME: u8[>..] = [];
// "dark", "light", or empty to follow the reader's setting.
var FIXED_THEME: u8[>..] = [];

fn theme_attr() {
    if FIXED_THEME.len > 0 { H.append(" data-theme=\""); H.append(FIXED_THEME); H.push('"'); }
}

// The interactive presentation: one HTML file that works offline.
fn interactive_page(takahashi: bool) {
    build_deck(takahashi);
    narration_script();
    H.clear();
    XHTML = false;
    ART = false;
    LINK_PREFIX.clear();
    H.append("<!doctype html>\n<html lang=\"");
    esc(H, meta_lang());
    H.push('"');
    theme_attr();
    H.append(">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n<meta name=\"generator\" content=\"Marklove\">\n<title>");
    esc(H, doc_title());
    H.append("</title>\n<style>");
    H.append(PART_FONTS);
    H.append("</style>\n<style>");
    H.append(PART_STYLE);
    H.append("</style>\n<style>");
    H.append(PART_THEME);
    H.append("</style>\n</head>\n<body>\n<a class=\"skip\" href=\"#deck\">Skip to the presentation</a>\n<main id=\"deck\" class=\"deck ");
    H.append(if takahashi { "takahashi" } else { "normal" });
    H.append("\" aria-label=\"");
    esc(H, doc_title());
    H.append("\">\n");
    r_slides();
    H.append("</main>\n<nav class=\"bar\" aria-label=\"Presentation controls\">\n<button id=\"prev\" type=\"button\" aria-label=\"Previous\">Previous</button>\n<span id=\"counter\" class=\"counter\"></span>\n<button id=\"next\" type=\"button\" aria-label=\"Next\">Next</button>\n<button id=\"view\" type=\"button\" aria-pressed=\"false\">Reading view</button>\n</nav>\n<div id=\"live\" class=\"visually-hidden\" aria-live=\"polite\"></div>\n<script>");
    H.append(PART_RUNTIME);
    H.append("</script>\n</body>\n</html>\n");
}

// --- the article ---------------------------------------------------------

struct Heading { level: i64, ev: i64, frame: i64, text: Line, id: Line }
var HEADS: Heading[>..] = [];
var HTEXT: u8[>..] = [];

fn h_text(l: Line) -> u8[:] { HTEXT[l.s..l.e] }

// The article slug, as Swift's ArticleExporter.slug: the lowercased text,
// letters and digits of any script, other runs as one "-", "s-" in front.
// Swift works on Characters: combining marks, variation selectors, emoji
// modifiers and joined emoji stay with the character before them.
fn article_slug(out: u8[>..]&, t: u8[:]) {
    let start = out.len;
    out.append("s-");
    let body = out.len;
    var dash = false;
    var i = 0;
    while i < t.len {
        let cp, n = uni_decode(t, i);
        // The whole Character: the base and what extends it.
        var j = i + n;
        var joined = false;
        while j < t.len {
            let c2, n2 = uni_decode(t, j);
            if joined || uni_extends(c2) { joined = c2 == 0x200D; j += n2; continue; }
            if (cp >= 0x1F1E6 && cp <= 0x1F1FF) && (c2 >= 0x1F1E6 && c2 <= 0x1F1FF) && j == i + n { j += n2; continue; }
            break;
        }
        if uni_alnum(cp) {
            push_utf8(out, uni_lower(cp));
            out.append(t[i + n..j]);
            dash = false;
        } else if !dash && out.len > body { out.push('-'); dash = true; }
        i = j;
    }
    while out.len > body && out[out.len - 1] == '-' { out.pop(); }
    if out.len == body { out.resize(start); out.append("section"); }
}

fn article_headings() {
    HEADS.clear();
    HTEXT.clear();
    for f, fi in FR {
        if f.scope == SC_SLIDES || f.kind == F_TITLE { continue; }
        let a = HTEXT.len;
        HTEXT.append(sp_text(f.title));
        let text = Line { a, HTEXT.len };
        let b = HTEXT.len;
        var tmp: u8[>..] = [];
        article_slug(tmp, h_text(text));
        // As Swift: the count of earlier headings with the same slug.
        var n = 0;
        for h in HEADS {
            var other: u8[>..] = [];
            article_slug(other, h_text(h.text));
            if other == tmp { n++; }
        }
        HTEXT.append(tmp);
        if n > 0 { format(HTEXT, "-", n + 1); }
        HEADS.push(Heading { if f.kind == F_SECTION { 1 } else { 2 }, f.head, fi, text, Line { b, HTEXT.len } });
    }
}

fn article_header() {
    H.append("<header><h1>");
    esc(H, doc_title());
    H.append("</h1>");
    let sub = meta("subtitle");
    if sub.len > 0 { H.append("<p class=\"subtitle\">"); esc(H, sub); H.append("</p>"); }
    var b: u8[>..] = [];
    if byline(b, if XHTML { "<br/>" } else { "<br>" }) { H.append("<p class=\"byline\">"); H.append(b); H.append("</p>"); }
    H.append("</header>\n");
}

fn article_frame_body(fi: i64) {
    let f = FR[fi];
    var i = f.lo;
    while i < f.hi {
        let e = EV[i];
        let mark = H.len;
        STEP = 0;
        DEPTH = 1;
        r_elements(i, e.end);
        if H.len > mark { H.push('\n'); }
        i = e.end;
    }
}

fn article_heading(h: Heading) {
    let tag = if h.level == 1 { "h2" } else { "h3" };
    format(H, "<", tag, " id=\"");
    esc(H, h_text(h.id));
    H.append("\">");
    if h.ev >= 0 { r_inline(h.ev + 1, EV[h.ev].end - 1); }
    format(H, "</", tag, ">\n");
}

// The article as a web page.
fn article_page(toc: bool) {
    H.clear();
    XHTML = false;
    ART = true;
    LINK_PREFIX.clear();
    FIGS = 0;
    plot_reset();
    article_headings();
    H.append("<!doctype html>\n<html lang=\"");
    esc(H, meta_lang());
    H.push('"');
    theme_attr();
    H.append(">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n<meta name=\"generator\" content=\"Marklove\">\n");
    let author = meta("author");
    if author.len > 0 { H.append("<meta name=\"author\" content=\""); esc(H, author); H.append("\">"); }
    H.append("\n<title>");
    esc(H, doc_title());
    H.append("</title>\n<style>");
    H.append(PART_STYLE);
    H.append("</style>\n<style>");
    H.append(PART_THEME);
    H.append("</style>\n</head>\n<body>\n<a class=\"skip\" href=\"#text\">Skip to the text</a>\n<article id=\"text\">\n");
    article_header();
    H.push('\n');
    if toc && HEADS.len > 3 {
        var any1 = false;
        for h in HEADS { if h.level == 1 { any1 = true; } }
        H.append("<nav class=\"toc\" aria-labelledby=\"toc-title\"><h2 id=\"toc-title\">Contents</h2><ol>");
        for h in HEADS {
            if any1 && h.level != 1 { continue; }
            H.append("<li><a href=\"#");
            H.append(h_text(h.id));
            H.append("\">");
            esc(H, h_text(h.text));
            H.append("</a></li>");
        }
        H.append("</ol></nav>");
    }
    H.push('\n');
    var hk = 0;
    for f, fi in FR {
        if f.scope == SC_SLIDES { continue; }
        if f.kind != F_TITLE { article_heading(HEADS[hk]); hk++; }
        article_frame_body(fi);
    }
    H.append("\n</article>\n<script>");
    H.append(PART_RUNTIME);
    H.append("</script>\n</body>\n</html>\n");
    ART = false;
}

// The article Markdown export: the article prose and relative asset
// references, without presentation structure and private material.
fn yaml_quote(out: u8[>..]&, s: u8[:]) {
    if contains_byte(s, ':') || contains_byte(s, '#') || has_prefix(s, "\"") || has_prefix(s, "'") {
        out.push('"');
        for c in s {
            if c == '\\' { out.append("\\\\"); } else if c == '"' { out.append("\\\""); } else { out.push(c); }
        }
        out.push('"');
        return;
    }
    out.append(s);
}

var MD_PARTS = 0;

fn md_part(out: u8[>..]&) {
    if MD_PARTS > 0 { out.append("\n\n"); }
    MD_PARTS++;
}

recursive fn md_block(out: u8[>..]&, i: i64) {
    let e = EV[i];
    if e.k == K_PAUSE || e.k == K_RULE { return; }
    if e.k != K_DIV {
        md_part(out);
        out.append(SRC[e.s0..e.s1]);
        return;
    }
    let d = e.n;
    if d == D_NOTES || d == D_NARRATION || d == D_PUBLIC || d == D_EXPLAIN { return; }
    if d == D_PLOT || d == D_CHART { md_part(out); out.append(SRC[e.s0..e.s1]); return; }
    if d == D_BOX {
        md_part(out);
        out.append("**");
        capitalized(out, sp_text(e.b));
        if e.a.n > 0 { out.append(": "); out.append(sp_text(e.a)); }
        out.append(".**");
    }
    var j = i + 1;
    while j < e.end - 1 {
        if in_scope(EV[j], true) { md_block(out, j); }
        j = EV[j].end;
    }
}

fn article_markdown(out: u8[>..]&) {
    MD_PARTS = 0;
    var front: u8[>..] = [];
    for key in ["title", "subtitle", "author", "institute", "date", "lang"] {
        if !has_meta(key) { continue; }
        front.append(key);
        front.append(": ");
        yaml_quote(front, meta(key));
        front.push('\n');
    }
    if front.len > 0 { md_part(out); out.append("---\n"); out.append(front); out.append("---"); }
    for f in FR {
        if f.scope == SC_SLIDES { continue; }
        if f.kind != F_TITLE {
            md_part(out);
            out.append(if f.kind == F_SECTION { "# " } else { "## " });
            var h = SRC[f.hs0..f.hs1];
            var a = 0;
            while a < h.len && (h[a] == '#' || h[a] == ' ') { a++; }
            out.append(trim_sp(h[a..]));
        }
        var i = f.lo;
        while i < f.hi {
            if in_scope(EV[i], true) { md_block(out, i); }
            i = EV[i].end;
        }
    }
    out.push('\n');
}

// --- EPUB ------------------------------------------------------------------

// Replaces each `from` in H[mark..] with `to`.
fn h_replace(mark: i64, from: u8[:], to: u8[:]) {
    var tmp: u8[>..] = [];
    format_replaced(tmp, H[mark..], from, to);
    H.resize(mark);
    H.append(tmp);
}

// MathML and SVG need their namespaces in XHTML.
fn xml_namespaces(mark: i64) {
    h_replace(mark, "<math ", "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" ");
    h_replace(mark, "<math>", "<math xmlns=\"http://www.w3.org/1998/Math/MathML\">");
    h_replace(mark, "<svg ", "<svg xmlns=\"http://www.w3.org/2000/svg\" ");
}

fn xhtml_head(out: u8[>..]&, title: u8[:], css: u8[:]) {
    out.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"");
    esc(out, meta_lang());
    out.append("\" xml:lang=\"");
    esc(out, meta_lang());
    out.append("\">\n<head><meta charset=\"utf-8\"/><title>");
    esc(out, title);
    out.append("</title><link rel=\"stylesheet\" href=\"");
    out.append(css);
    out.append("\"/></head>\n");
}

fn iso_date(out: u8[>..]&, unix: i64) {
    // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
    let days = unix / 86400;
    let secs = unix % 86400;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (if m <= 2 { 1 } else { 0 });
    format_int(out, y, 10, 4, '0'); out.push('-');
    format_int(out, m, 10, 2, '0'); out.push('-');
    format_int(out, d, 10, 2, '0'); out.push('T');
    format_int(out, secs / 3600, 10, 2, '0'); out.push(':');
    format_int(out, (secs / 60) % 60, 10, 2, '0'); out.push(':');
    format_int(out, secs % 60, 10, 2, '0'); out.push('Z');
}

let EPUB_CSS = "\nbody { background: none; color: inherit; }\narticle { max-width: none; padding: 0; }\n.skip, .controls { display: none; }\n";

fn mime_type(path: u8[:]) -> const u8[:] {
    let dot = rfind(path, ".");
    var ext: u8[..8] = [];
    if dot >= 0 { for c in path[dot + 1..] { if ext.len < 8 { ext.push(lower(c)); } } }
    if ext == "png" { return "image/png"; }
    if ext == "jpg" || ext == "jpeg" { return "image/jpeg"; }
    if ext == "gif" { return "image/gif"; }
    if ext == "webp" { return "image/webp"; }
    if ext == "svg" { return "image/svg+xml"; }
    if ext == "heic" { return "image/heic"; }
    if ext == "mp4" || ext == "m4v" { return "video/mp4"; }
    if ext == "mov" { return "video/quicktime"; }
    if ext == "webm" { return "video/webm"; }
    if ext == "mp3" { return "audio/mpeg"; }
    if ext == "m4a" || ext == "aac" { return "audio/mp4"; }
    if ext == "wav" { return "audio/wav"; }
    return "application/octet-stream";
}

// Starts an EPUB 3 book in the ZIP builder: every text file. JavaScript then
// adds the media files that `LINKED` lists, under "OEBPS/media/", and
// finishes the ZIP. Each `#` section is a chapter.
fn epub_begin(date: i64) {
    ART = true;
    XHTML = true;
    LINK_PREFIX.clear();
    LINK_PREFIX.append("../media/");
    LINKED.clear();
    FIGS = 0;
    plot_reset();
    article_headings();
    // Chapters: the start, then one for each section. Each chapter is a
    // range of frames; the heading of a section frame starts a chapter.
    var ch_first: i64[>..] = [0];
    for f, fi in FR {
        if f.scope == SC_SLIDES { continue; }
        if f.kind == F_SECTION { ch_first.push(fi); }
    }
    ch_first.push(FR.len);
    var pages: u8[>..] = [];
    var page_end: i64[>..] = [];
    var has_math: bool[>..] = [];
    var has_svg: bool[>..] = [];
    var titles: Line[>..] = [];
    var hk = 0;
    for c in ch_first.len - 1 {
        H.clear();
        if c == 0 { article_header(); }
        for fi in ch_first[c]..ch_first[c + 1] {
            let f = FR[fi];
            if f.scope == SC_SLIDES { continue; }
            if f.kind != F_TITLE { article_heading(HEADS[hk]); hk++; }
            article_frame_body(fi);
        }
        xml_namespaces(0);
        has_math.push(index_of(H, "<math") >= 0);
        has_svg.push(index_of(H, "<svg") >= 0);
        let t0 = HTEXT.len;
        if c == 0 { HTEXT.append(doc_title()); } else { HTEXT.append(sp_text(FR[ch_first[c]].title)); }
        titles.push(Line { t0, HTEXT.len });
        xhtml_head(pages, h_text(titles[c]), "../style.css");
        pages.append("<body><article>\n");
        pages.append(H);
        pages.append("\n</article></body>\n</html>\n");
        page_end.push(pages.len);
    }
    let nch = page_end.len;
    // The identifier: a name-based UUID from the title and byline.
    var idsrc: u8[>..] = [];
    // As Swift: title + "\n" + the byline joined with "\n" (the "\n" stays when the byline is empty).
    idsrc.append(doc_title());
    idsrc.push('\n');
    var nb = 0;
    for key in ["author", "institute", "date"] {
        let v = meta(key);
        if v.len > 0 { if nb > 0 { idsrc.push('\n'); } idsrc.append(v); nb++; }
    }
    var hex: u8[>..] = [];
    sha1_hex(idsrc, hex);
    hex[12] = '5';
    let v16 = if is_digit(hex[16]) { hex[16] - '0' } else { hex[16] - 'a' + 10 };
    hex[16] = "89ab"[v16 % 4];
    var uuid: u8[>..] = [];
    uuid.append(hex[0..8]); uuid.push('-'); uuid.append(hex[8..12]); uuid.push('-');
    uuid.append(hex[12..16]); uuid.push('-'); uuid.append(hex[16..20]); uuid.push('-'); uuid.append(hex[20..32]);
    var opf: u8[>..] = [];
    opf.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" xml:lang=\"");
    esc(opf, meta_lang());
    opf.append("\">\n<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n<dc:identifier id=\"book-id\">urn:uuid:");
    opf.append(uuid);
    opf.append("</dc:identifier>\n<dc:title>");
    esc(opf, doc_title());
    opf.append("</dc:title>\n<dc:language>");
    esc(opf, meta_lang());
    opf.append("</dc:language>\n");
    let author = meta("author");
    if author.len > 0 { opf.append("<dc:creator>"); esc(opf, author); opf.append("</dc:creator>"); }
    opf.append("\n");
    let sub = meta("subtitle");
    if sub.len > 0 { opf.append("<dc:description>"); esc(opf, sub); opf.append("</dc:description>"); }
    opf.append("\n<meta property=\"dcterms:modified\">");
    iso_date(opf, date);
    opf.append("</meta>\n<meta property=\"schema:accessMode\">textual</meta>\n<meta property=\"schema:accessMode\">visual</meta>\n<meta property=\"schema:accessModeSufficient\">textual</meta>\n<meta property=\"schema:accessibilityFeature\">alternativeText</meta>\n<meta property=\"schema:accessibilityFeature\">MathML</meta>\n<meta property=\"schema:accessibilityFeature\">tableOfContents</meta>\n<meta property=\"schema:accessibilityHazard\">none</meta>\n<meta property=\"schema:accessibilitySummary\">Images have text descriptions. Equations are MathML.</meta>\n<meta name=\"generator\" content=\"Marklove\"/>\n</metadata>\n<manifest>\n");
    opf.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n");
    for i in nch {
        format(opf, "<item id=\"c", i, "\" href=\"text/chapter-");
        format_int(opf, i, 10, 3, '0');
        opf.append(".xhtml\" media-type=\"application/xhtml+xml\"");
        if has_math[i] || has_svg[i] {
            opf.append(" properties=\"");
            if has_math[i] { opf.append("mathml"); }
            if has_math[i] && has_svg[i] { opf.push(' '); }
            if has_svg[i] { opf.append("svg"); }
            opf.push('"');
        }
        opf.append("/>\n");
    }
    var k = 0;
    var j = 0;
    while j < LINKED.len {
        var e = index_of_byte(LINKED, '\n', j);
        if e < 0 { e = LINKED.len; }
        let p = LINKED[j..e];
        format(opf, "<item id=\"m", k, "\" href=\"media/");
        var enc: u8[>..] = [];
        for c in p { if url_path_allowed(c) { enc.push(c); } else { pct_byte(enc, c); } }
        esc(opf, enc);
        format(opf, "\" media-type=\"", mime_type(p), "\"/>\n");
        k++;
        j = e + 1;
    }
    opf.append("</manifest>\n<spine>\n");
    for i in nch { format(opf, "<itemref idref=\"c", i, "\"/>\n"); }
    opf.append("</spine>\n</package>\n");
    // The table of contents: chapters, with the ## headings inside them.
    var nav: u8[>..] = [];
    xhtml_head(nav, "Contents", "style.css");
    nav.append("<body><nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>");
    var hi = 0;
    for i in nch {
        var name: u8[>..] = [];
        name.append("chapter-");
        format_int(name, i, 10, 3, '0');
        name.append(".xhtml");
        nav.append("<li><a href=\"text/");
        nav.append(name);
        nav.append("\">");
        esc(nav, h_text(titles[i]));
        nav.append("</a>");
        var inside = false;
        while hi < HEADS.len {
            let h = HEADS[hi];
            let fi = h.frame;
            if fi >= ch_first[i + 1] { break; }
            if h.level == 2 {
                if !inside { nav.append("<ol>"); inside = true; }
                nav.append("<li><a href=\"text/");
                nav.append(name);
                nav.push('#');
                nav.append(h_text(h.id));
                nav.append("\">");
                esc(nav, h_text(h.text));
                nav.append("</a></li>");
            }
            hi++;
        }
        if inside { nav.append("</ol>"); }
        nav.append("</li>");
    }
    nav.append("</ol></nav></body>\n</html>\n");
    let container = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n<rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles>\n</container>\n";
    var css: u8[>..] = [];
    css.append(PART_STYLE);
    css.append(EPUB_CSS);
    zip_begin();
    zip_add("mimetype", "application/epub+zip", date);
    zip_add("META-INF/container.xml", container, date);
    zip_add("OEBPS/content.opf", opf, date);
    zip_add("OEBPS/nav.xhtml", nav, date);
    zip_add("OEBPS/style.css", css, date);
    var a = 0;
    for i in nch {
        var name: u8[>..] = [];
        name.append("OEBPS/text/chapter-");
        format_int(name, i, 10, 3, '0');
        name.append(".xhtml");
        zip_add(name, pages[a..page_end[i]], date);
        a = page_end[i];
    }
    ART = false;
    XHTML = false;
    LINK_PREFIX.clear();
}
