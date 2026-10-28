// Laid-out pages as SVG (PageRenderer and GraphicsRenderer). The browser
// draws these pages for PNG images, video frames and print (PDF). For the
// SVG export, the boxes that are not simple shapes are drawn alone at a
// high resolution and traced (trace.goose), as SlideImageExporter does.
//
// The text uses the line breaks of layout.goose, and each piece of a line
// has its own x position, so that the browser does not break lines again.
// Equations are MathML in a foreignObject. Images are "asset:N" links that
// JavaScript replaces with data: URLs, and the style sheet has a
// "/*ml-fonts*/" mark for the @font-face rules.

import layout;
import plot;

// The palette colors, in the order of TPal from bg to violet.
var PC: TC[>..] = [];

fn set_palette(p: TPal) {
    var cs: TC[>..] = [];
    for c in [p.bg, p.surface, p.border, p.dim, p.text, p.strong, p.accent, p.red, p.green, p.yellow, p.blue, p.magenta, p.cyan, p.orange, p.violet] { cs.push(c); }
    PC.clear();
    PC.append(cs);
}

fn pc(i: i64) -> TC { if i < PC.len { PC[i] } else { TC { 0.5, 0.5, 0.5 } } }

// The handout draws images in gray.
var GRAY = false;

fn role_color(role: i64) -> TC {
    if role == CR_STRONG { return pc(5); }
    if role == CR_DIM { return pc(3); }
    if role == CR_ACCENT { return pc(6); }
    if role == CR_BG { return pc(0); }
    if role == CR_SURFACE { return pc(1); }
    if role == CR_BORDER { return pc(2); }
    if role >= CR_HL {
        let r = role - CR_HL;
        if r == HR_KEYWORD { return pc(8); }
        if r == HR_STRING { return pc(12); }
        if r == HR_NUMBER { return pc(11); }
        if r == HR_CODE_COMMENT { return pc(3); }
        if r == HR_TYPE { return pc(9); }
        if r == HR_FUNCTION { return pc(10); }
        if r == HR_ATTRIBUTE { return pc(13); }
        return pc(4);
    }
    if role >= CR_SERIES {
        let k = (role - CR_SERIES) % 6;
        if k == 0 { return pc(6); }
        if k == 1 { return pc(13); }
        if k == 2 { return pc(8); }
        if k == 3 { return pc(11); }
        if k == 4 { return pc(12); }
        return pc(14);
    }
    return pc(4);
}

fn col(out: u8[>..]&, role: i64) { th_hex(out, role_color(role)); }

// RasterTracer.num: at most one decimal place.
fn num(out: u8[>..]&, v: f64) {
    let r = round(v * 10.0) / 10.0;
    if r == round(r) { format(out, r as! i64); return; }
    fmt_fixed(out, r, 1);
}

fn attr(out: u8[>..]&, name: u8[:], v: f64) {
    out.push(' ');
    out.append(name);
    out.append("=\"");
    num(out, v);
    out.push('"');
}

fn rect_attrs(out: u8[>..]&, x: f64, y: f64, w: f64, h: f64) {
    attr(out, "x", x);
    attr(out, "y", y);
    attr(out, "width", w);
    attr(out, "height", h);
}

let STEP_ALL = 1 << 40;

fn visible(b: Box, step: i64) -> bool { b.first <= step && (b.last < 0 || step <= b.last) }

// --- text ---------------------------------------------------------------------

fn font_attrs(out: u8[>..]&, fam: i64, size: f64, bold: bool, italic: bool) {
    out.append(" font-family='");
    out.append(family_css(fam));
    out.push('\'');
    attr(out, "font-size", size);
    if bold { out.append(" font-weight=\"700\""); }
    if italic { out.append(" font-style=\"italic\""); }
}

// The style of the equations. layout.goose measures them in the same box
// (see web/pages.js), so that the baseline is in the same place.
fn math_div(out: u8[>..]&, latex: u8[:], display: bool, size: f64, color: TC) {
    out.append("<div xmlns=\"http://www.w3.org/1999/xhtml\" style=\"font-family:KpMath,math;line-height:0;white-space:nowrap;width:max-content;font-size:");
    num(out, size);
    out.append("px;color:");
    th_hex(out, color);
    out.append("\">");
    let at = out.len;
    math_html(out, latex, display);
    // The math element needs its namespace outside HTML.
    let m = index_of(out, "<math", at);
    if m >= 0 && index_of(out, "xmlns", m) < 0 {
        var rest: u8[>..] = [];
        rest.append(out[m + 5..]);
        out.resize(m + 5);
        out.append(" xmlns=\"http://www.w3.org/1998/Math/MathML\"");
        out.append(rest);
    }
    out.append("</div>");
}

fn math_object(out: u8[>..]&, latex: u8[:], display: bool, size: f64, x: f64, baseline: f64, color: TC) {
    let w, a, d = math_metrics(latex, display);
    let top = ml_math_metric(latex, if display { 1 } else { 0 }, 3);
    out.append("<foreignObject");
    rect_attrs(out, x, baseline - top * size, w * size + 2.0, (top + d) * size + 2.0);
    out.append(" overflow=\"visible\">");
    math_div(out, latex, display, size, color);
    out.append("</foreignObject>\n");
}

fn is_link_target(t: u8[:]) -> bool {
    let s = trim_sp(t);
    return has_prefix(s, "http://") || has_prefix(s, "https://") || has_prefix(s, "mailto:") || has_prefix(s, "tel:") || has_prefix(s, "www.");
}

// PageRenderer.drawText: a paragraph in a frame.
fn draw_text(out: u8[>..]&, ti: i64, x: f64, y: f64, w: f64) {
    break_lines(ti, w);
    let t = TXTS[ti];
    let lh = t.size * t.lh;
    var lines: LineI[>..] = [];
    lines.append(LNS);
    var pcs: Piece[>..] = [];
    pcs.append(PCS);
    let base = role_color(t.color);
    for l, k in lines {
        let indent = if k == 0 { t.indent } else { 0.0 };
        var x0 = x + indent;
        let avail = w - indent;
        var extra = 0.0;
        if t.align == AL_CENTER { x0 = x + indent + (avail - l.w) / 2.0; }
        else if t.align == AL_RIGHT { x0 = x + w - l.w; }
        else if t.align == AL_JUST && k < lines.len - 1 && !l.hard {
            var gaps = 0;
            for p in l.p0..l.p1 - 1 { if pcs[p].ws > pcs[p].w { gaps++; } }
            if gaps > 0 { extra = max(0.0, avail - l.w) / (gaps as f64); }
        }
        let baseline = y + (k as f64) * lh + lh - descent(t.size);
        var px = x0;
        var opened = false;
        for p in l.p0..l.p1 {
            let pc = pcs[p];
            let run = RUNS[pc.r];
            if pc.nl { continue; }
            if (run.fl & RF_MATH) != 0 {
                if opened { out.append("</text>\n"); opened = false; }
                math_object(out, TB[run.a..run.b], false, t.size, px, baseline, base);
                px += pc.ws;
                continue;
            }
            var e = pc.b;
            while e > pc.a && TB[e - 1] == ' ' { e--; }
            if e > pc.a {
                if !opened {
                    out.append("<text");
                    attr(out, "y", baseline);
                    font_attrs(out, t.fam, t.size, t.bold, t.italic);
                    out.append(" fill=\"");
                    th_hex(out, base);
                    out.append("\" xml:space=\"preserve\">");
                    opened = true;
                }
                let link = run.link.e > run.link.s && is_link_target(tb(run.link));
                if link {
                    out.append("<a href=\"");
                    let target = trim_sp(tb(run.link));
                    if has_prefix(target, "www.") { out.append("https://"); }
                    esc(out, target);
                    out.append("\">");
                }
                out.append("<tspan");
                attr(out, "x", px);
                let fam = run_fam(t, run);
                let size = run_size(t, run);
                let bold = run_bold(t, run);
                let italic = run_italic(t, run);
                if fam != t.fam || size != t.size || bold != t.bold || italic != t.italic {
                    font_attrs(out, fam, size, bold, italic);
                    if !bold && t.bold { out.append(" font-weight=\"400\""); }
                    if !italic && t.italic { out.append(" font-style=\"normal\""); }
                }
                if run.color != CR_NONE { out.append(" fill=\""); col(out, run.color); out.push('"'); }
                if run.link.e > run.link.s { out.append(" text-decoration=\"underline\""); }
                else if (run.fl & RF_STRIKE) != 0 { out.append(" text-decoration=\"line-through\""); }
                out.push('>');
                esc(out, TB[pc.a..e]);
                out.append("</tspan>");
                if link { out.append("</a>"); }
            }
            px += pc.ws;
            if pc.ws > pc.w { px += extra; }
        }
        if opened { out.append("</text>\n"); }
    }
}

// A label of the graphics: one line of plain text in a frame.
fn label(out: u8[>..]&, s: u8[:], x: f64, y: f64, w: f64, size: f64, color: i64, align: i64, bold: bool) {
    let ti = plain_txt(s, FA_BODY, size);
    set_txt(ti, FA_BODY, bold, false, color, align);
    TXTS[ti].lh = 1.3;
    draw_text(out, ti, x, y, w);
}

// --- plots and charts (GraphicsRenderer) ---------------------------------------

fn plot_svg(out: u8[>..]&, d: i64, fs: f64, rx: f64, ry: f64, rw: f64, rh: f64, progress: f64) {
    pl_parse(sp_text(EV[d].c));
    let label_h = fs * 1.6;
    let px = rx + fs * 3.0;
    let pw = rw - fs * 3.0;
    let ptop = ry + label_h;
    let ph = rh - 2.0 * label_h;
    let y0, y1 = pl_y_range();
    let x0 = PX0;
    let x1 = PX1;
    fn sx(x: f64) -> f64 { px + (x - x0) / max(x1 - x0, 1e-12) * pw }
    fn sy(y: f64) -> f64 { ptop + ph - (y - y0) / max(y1 - y0, 1e-12) * ph }
    // Axes through zero, or at the edges.
    let zy = sy(min(max(0.0, y0), y1));
    let zx = sx(min(max(0.0, x0), x1));
    out.append("<path d=\"M");
    num(out, px); out.push(' '); num(out, zy); out.push('H'); num(out, px + pw);
    out.push('M'); num(out, zx); out.push(' '); num(out, ptop); out.push('V'); num(out, ptop + ph);
    out.append("\" fill=\"none\" stroke=\"");
    col(out, CR_DIM);
    out.append("\" stroke-width=\"1.25\"/>\n");
    // Curves, clipped to the plot.
    out.append("<svg overflow=\"hidden\"");
    rect_attrs(out, px - 2.0, ptop - 2.0, pw + 4.0, ph + 4.0);
    out.append(" viewBox=\"");
    num(out, px - 2.0); out.push(' '); num(out, ptop - 2.0); out.push(' '); num(out, pw + 4.0); out.push(' '); num(out, ph + 4.0);
    out.append("\">");
    let init = pl_init_values();
    let limit = ((241 as f64) * min(max(progress, 0.0), 1.0)) as i64;
    for c, i in PCURS {
        out.append("<path fill=\"none\" stroke=\"");
        col(out, CR_SERIES + i);
        out.append("\"");
        attr(out, "stroke-width", max(2.0, fs * 0.18));
        out.append(" stroke-linejoin=\"round\" stroke-linecap=\"round\" d=\"");
        var pen = false;
        for k in limit {
            let x = pl_sample_x(k, 240);
            let y = pl_eval(c.root, x, init);
            if is_nan(y) || is_inf(y) { pen = false; continue; }
            out.push(if pen { 'L' } else { 'M' });
            fmt_fixed(out, sx(x), 2);
            out.push(' ');
            fmt_fixed(out, sy(y), 2);
            pen = true;
        }
        out.append("\"/>");
    }
    out.append("</svg>\n");
    // Labels.
    var t: u8[>..] = [];
    let bottom = ry + rh - label_h;
    pl_fmt(t, x0);
    label(out, t, px, bottom, pw, fs, CR_DIM, AL_LEFT, false);
    label(out, PSRC[PXL_O..PXL_O + PXL_N], px, bottom, pw, fs, CR_DIM, AL_CENTER, false);
    t.clear();
    pl_fmt(t, x1);
    label(out, t, px, bottom, pw, fs, CR_DIM, AL_RIGHT, false);
    label(out, PSRC[PYL_O..PYL_O + PYL_N], rx, ry - 2.0, rw, fs, CR_DIM, AL_LEFT, false);
    t.clear();
    pl_fmt(t, y0);
    t.append(" to ");
    pl_fmt(t, y1);
    label(out, t, rx, ry - 2.0, rw, fs, CR_DIM, AL_RIGHT, false);
    if PPARS.len > 0 {
        t.clear();
        for p, i in PPARS {
            if i > 0 { t.append(", "); }
            t.append(PSRC[p.lo_o..p.lo_o + p.lo_n]);
            t.append(" = ");
            pl_fmt(t, p.init);
        }
        label(out, t, px, ptop, pw, fs, CR_DIM, AL_RIGHT, false);
    }
}

fn chart_svg(out: u8[>..]&, d: i64, fs: f64, rx: f64, ry: f64, rw: f64, rh: f64, progress: f64) {
    chart_spec(d);
    let label_h = fs * 1.8;
    let atop = ry + label_h;
    let ah = rh - 2.0 * label_h;
    var maxv = 1.0;
    var minv = 0.0;
    if CH_VALUES.len > 0 {
        maxv = CH_VALUES[0];
        minv = CH_VALUES[0];
        for v in CH_VALUES { maxv = max(maxv, v); minv = min(minv, v); }
    }
    maxv = max(maxv, 0.0);
    minv = min(minv, 0.0);
    let span = max(maxv - minv, 1e-9);
    fn y(v: f64) -> f64 { atop + ah - (v - minv) / span * ah }
    let groups = max(CH_ROWS, 1);
    let gw = rw / (groups as f64);
    let nser = CH_NAMES.len;
    let bw = gw * 0.7 / (max(nser, 1) as f64);
    let p = min(max(progress, 0.0), 1.0);
    var t: u8[>..] = [];
    for g in CH_ROWS {
        for k in nser {
            let v = ch_value(k, g) * p;
            let x = rx + (g as f64) * gw + gw * 0.15 + (k as f64) * bw;
            let top = y(max(v, 0.0));
            let bottom = y(min(v, 0.0));
            out.append("<rect");
            rect_attrs(out, x, top, bw * 0.92, max(bottom - top, 1.0));
            out.append(" fill=\"");
            col(out, CR_SERIES + k);
            out.append("\"/>\n");
            // The value above the bar, so that color is not the only signal.
            t.clear();
            pl_fmt(t, ch_value(k, g));
            label(out, t, x - 20.0, top - 2.0 - label_h, bw * 0.92 + 40.0, fs * 0.85, CR_TEXT, AL_CENTER, false);
        }
        label(out, ch_text(CH_LABELS[g]), rx + (g as f64) * gw, ry + rh - label_h, gw, fs, CR_DIM, AL_CENTER, false);
    }
    out.append("<path d=\"M");
    num(out, rx); out.push(' '); num(out, y(0.0)); out.push('H'); num(out, rx + rw);
    out.append("\" stroke=\"");
    col(out, CR_DIM);
    out.append("\" stroke-width=\"1.25\"/>\n");
    if nser > 1 {
        let r0 = RUNS.len;
        for k in nser {
            add_run("■ ", RF_BOLD, CR_SERIES + k, lk0());
            t.clear();
            t.append(ch_text(CH_NAMES[k]));
            t.append("   ");
            add_run(t, 0, CR_NONE, lk0());
        }
        let ti = new_txt(r0, FA_BODY, fs);
        set_txt(ti, FA_BODY, false, false, CR_TEXT, AL_LEFT);
        TXTS[ti].lh = 1.3;
        draw_text(out, ti, rx, ry - 4.0, rw);
    } else if nser == 1 {
        label(out, ch_text(CH_NAMES[0]), rx, ry - 4.0, rw, fs, CR_DIM, AL_LEFT, false);
    }
}

// --- boxes --------------------------------------------------------------------

fn play_mark(out: u8[>..]&, b: Box) {
    let d = min(b.w, b.h) * 0.18;
    let cx = b.x + b.w / 2.0;
    let cy = b.y + b.h / 2.0;
    out.append("<circle");
    attr(out, "cx", cx);
    attr(out, "cy", cy);
    attr(out, "r", d / 2.0);
    out.append(" fill=\"#000\" fill-opacity=\"0.45\"/><path d=\"M");
    num(out, cx - d * 0.15); out.push(' '); num(out, cy + d * 0.22);
    out.push('L'); num(out, cx + d * 0.25); out.push(' '); num(out, cy);
    out.push('L'); num(out, cx - d * 0.15); out.push(' '); num(out, cy - d * 0.22);
    out.append("Z\" fill=\"#fff\" fill-opacity=\"0.95\"/>\n");
}

fn missing_frame(out: u8[>..]&, b: Box) {
    out.append("<rect");
    rect_attrs(out, b.x + 1.0, b.y + 1.0, b.w - 2.0, b.h - 2.0);
    out.append(" fill=\"none\" stroke=\"");
    col(out, CR_BORDER);
    out.append("\" stroke-width=\"1.5\" stroke-dasharray=\"6 4\"/>\n");
}

fn shape(out: u8[>..]&, b: Box) {
    let k = b.kind;
    if k == BX_FILL {
        out.append("<rect");
        rect_attrs(out, b.x, b.y, b.w, b.h);
        attr(out, "rx", b.c);
        out.append(" fill=\"");
        col(out, b.color);
        out.append("\"/>\n");
    } else if k == BX_STROKE {
        out.append("<rect");
        rect_attrs(out, b.x, b.y, b.w, b.h);
        out.append(" fill=\"none\" stroke=\"");
        col(out, b.color);
        out.push('"');
        attr(out, "stroke-width", b.c);
        out.append("/>\n");
    } else if k == BX_ACCENT {
        out.append("<rect");
        rect_attrs(out, b.x, b.y, b.w, b.h);
        out.append(" fill=\"");
        col(out, b.color);
        out.append("\"/>\n");
    } else if k == BX_RULE {
        out.append("<path d=\"M");
        num(out, b.x); out.push(' '); num(out, b.y + b.h / 2.0); out.push('H'); num(out, b.x + b.w);
        out.append("\" stroke=\"");
        col(out, b.color);
        out.push('"');
        attr(out, "stroke-width", b.c);
        out.append("/>\n");
    }
}

fn is_shape(k: i64) -> bool { k == BX_FILL || k == BX_STROKE || k == BX_ACCENT || k == BX_RULE }

fn page_bg(out: u8[>..]&, p: Page) {
    out.append("<rect");
    attr(out, "width", p.w);
    attr(out, "height", p.h);
    out.append(" fill=\"");
    col(out, CR_BG);
    out.append("\"/>\n");
}

// One box. `progress` draws a plot or a chart partly.
recursive fn box_svg(out: u8[>..]&, bi: i64, progress: f64) {
    let b = BOXES[bi];
    let k = b.kind;
    if k == BX_TEXT || k == BX_LABEL || k == BX_TEXFB { draw_text(out, b.a, b.x, b.y, b.w); }
    else if is_shape(k) { shape(out, b); }
    else if k == BX_MATH {
        // Center the equation in the frame.
        let l = tb(b.p);
        let w, a, d = math_metrics(l, true);
        math_object(out, l, true, b.c, b.x + (b.w - w * b.c) / 2.0, b.y + (b.h - (a + d) * b.c) / 2.0 + a * b.c, role_color(b.color));
    }
    else if k == BX_MEDIA {
        let ai = asset_index(tb(b.p));
        out.append("<image");
        rect_attrs(out, b.x, b.y, b.w, b.h);
        out.append(" preserveAspectRatio=\"none\"");
        if GRAY { out.append(" filter=\"url(#ml-gray)\""); }
        format(out, " href=\"", if b.a == M_VIDEO { "poster:" } else { "asset:" }, ai, "\"/>\n");
        if b.a == M_VIDEO { play_mark(out, b); }
    }
    else if k == BX_MISSING {
        missing_frame(out, b);
        draw_text(out, b.a, b.x + 8.0, b.y + 8.0, b.w - 16.0);
    }
    else if k == BX_PLOT { plot_svg(out, b.a, b.c, b.x, b.y, b.w, b.h, progress); }
    else if k == BX_CHART { chart_svg(out, b.a, b.c, b.x, b.y, b.w, b.h, progress); }
    else if k == BX_THUMB {
        let s = PAGES[b.a];
        out.append("<svg");
        rect_attrs(out, b.x, b.y, b.w, b.h);
        out.append(" viewBox=\"0 0 ");
        num(out, s.w); out.push(' '); num(out, s.h);
        out.append("\" preserveAspectRatio=\"none\">\n");
        page_bg(out, s);
        for c in s.b0..s.b1 { if visible(BOXES[c], STEP_ALL) { box_svg(out, c, 1.0); } }
        out.append("</svg>\n");
    }
}

// --- pages ----------------------------------------------------------------------

// The boxes of a page state. Video frames are made of these layers.
let LY_ALL = 0;
// The background and the boxes that were there before this step.
let LY_BASE = 1;
// The boxes that come in at this step, except plots and charts.
let LY_NEW = 2;
// The boxes that leave after the previous step.
let LY_LEAVE = 3;
// The plots and charts that come in at this step, at `progress`.
let LY_GROW = 4;
let LY_BG = 5;

fn is_graphic(k: i64) -> bool { k == BX_PLOT || k == BX_CHART }

fn in_layer(b: Box, step: i64, layer: i64) -> bool {
    if layer == LY_ALL { return visible(b, step); }
    if layer == LY_BASE { return visible(b, step) && b.first < step; }
    if layer == LY_NEW { return visible(b, step) && b.first == step && !is_graphic(b.kind); }
    if layer == LY_LEAVE { return step > 0 && b.last == step - 1 && visible(b, step - 1); }
    if layer == LY_GROW { return visible(b, step) && b.first == step && is_graphic(b.kind); }
    return false;
}

fn svg_open(out: u8[>..]&, w: f64, h: f64, vx: f64, vy: f64, vw: f64, vh: f64) {
    out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"");
    attr(out, "width", w);
    attr(out, "height", h);
    out.append(" viewBox=\"");
    num(out, vx); out.push(' '); num(out, vy); out.push(' '); num(out, vw); out.push(' '); num(out, vh);
    out.append("\">\n<style>/*ml-fonts*/ text{white-space:pre}</style>\n");
    if GRAY {
        out.append("<filter id=\"ml-gray\"><feColorMatrix type=\"saturate\" values=\"0\"/></filter>\n");
    }
}

// A page state as SVG, `scale` × the page size in pixels.
fn page_svg(out: u8[>..]&, pi: i64, step: i64, layer: i64, progress: f64, scale: f64) {
    let p = PAGES[pi];
    let m = mark();
    svg_open(out, p.w * scale, p.h * scale, 0.0, 0.0, p.w, p.h);
    if layer == LY_ALL || layer == LY_BASE || layer == LY_BG { page_bg(out, p); }
    for bi in p.b0..p.b1 {
        let b = BOXES[bi];
        if !in_layer(b, step, layer) { continue; }
        let grow = (layer == LY_ALL || layer == LY_GROW) && b.first == step;
        box_svg(out, bi, if grow { progress } else { 1.0 });
    }
    out.append("</svg>\n");
    rewind(m);
}

// --- SVG export -----------------------------------------------------------------

// A region to draw and trace: the box, the padding, the scale and the
// tracer options (SlideImageExporter.traced).
struct Region { box: i64, x: f64, y: f64, w: f64, h: f64, scale: f64, colors: i64, min_area: f64, tol: f64 }
var REGIONS: Region[>..] = [];

fn add_region(bi: i64, padding: f64, scale: f64, colors: i64, min_area: f64, tol: f64) {
    let b = BOXES[bi];
    var x = b.x - padding;
    var y = b.y - padding;
    var w = b.w + 2.0 * padding;
    var h = b.h + 2.0 * padding;
    if b.kind == BX_MISSING { x = b.x + 5.0; y = b.y + 5.0; w = b.w - 10.0; h = b.h - 10.0; }
    // Text can reach a little out of its frame (italic, descenders).
    if b.kind == BX_TEXT || b.kind == BX_LABEL || b.kind == BX_TEXFB || b.kind == BX_MISSING { y -= 2.0; h += 4.0; x -= 2.0; w += 4.0; }
    REGIONS.push(Region { bi, x, y, w, h, scale, colors, min_area, tol });
}

// The text of a page in reading order (SlideImageExporter.pageText).
fn page_text(out: u8[>..]&, pi: i64) {
    let p = PAGES[pi];
    var n = 0;
    for bi in p.b0..p.b1 {
        let b = BOXES[bi];
        let start = out.len;
        if n > 0 { out.push('\n'); }
        let at = out.len;
        if b.kind == BX_TEXT || b.kind == BX_TEXFB { txt_spoken(out, b.a); }
        else if b.kind == BX_MATH { math_speech(out, tb(b.p)); }
        else if b.kind == BX_MEDIA { out.append(tb(b.q)); }
        else if b.kind == BX_MISSING { out.append(tb(b.q)); }
        else if b.kind == BX_PLOT { plot_text(out, b.a); }
        else if b.kind == BX_CHART { chart_summary(out, b.a); }
        // Trim the white space.
        while out.len > at && is_ws(out[out.len - 1]) { out.resize(out.len - 1); }
        if out.len == at { out.resize(start); } else { n++; }
    }
}

// StyledText.spokenString: the text, with equations spoken.
fn txt_spoken(out: u8[>..]&, ti: i64) {
    let t = TXTS[ti];
    let at = out.len;
    for r in t.r0..t.r1 {
        let run = RUNS[r];
        let s = max(run.a, t.lo);
        let e = min(run.b, t.hi);
        if s >= e { continue; }
        if (run.fl & RF_MATH) != 0 { math_speech(out, TB[run.a..run.b]); }
        else { out.append(TB[s..e]); }
    }
    var k = at;
    while k < out.len && is_ws(out[k]) { k++; }
    if k > at {
        var rest: u8[>..] = [];
        rest.append(out[k..]);
        out.resize(at);
        out.append(rest);
    }
}

fn chart_summary(out: u8[>..]&, d: i64) {
    chart_spec(d);
    out.append("Bar chart. ");
    for g in CH_ROWS {
        if g > 0 { out.append("; "); }
        out.append(ch_text(CH_LABELS[g]));
        out.append(": ");
        for k in CH_NAMES.len {
            if k > 0 { out.append(", "); }
            pl_fmt(out, ch_value(k, g));
        }
    }
    out.push('.');
}

// The SVG of a page for the SVG export. Shapes are SVG shapes. Each other
// box is a "<!--ml-region N-->" mark for its traced shapes: REGIONS[N]
// gives the part of the page to draw (region_svg) and the tracer options.
fn export_svg(out: u8[>..]&, pi: i64, number: i64) {
    let p = PAGES[pi];
    REGIONS.clear();
    out.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" viewBox=\"0 0 ");
    num(out, p.w); out.push(' '); num(out, p.h);
    out.push('"');
    attr(out, "width", p.w);
    attr(out, "height", p.h);
    out.append(" role=\"img\" aria-labelledby=\"title desc\">\n<title id=\"title\">");
    if p.title.e > p.title.s { esc(out, tb(p.title)); } else { format(out, "Slide ", number); }
    out.append("</title>\n<desc id=\"desc\">");
    var d: u8[>..] = [];
    page_text(d, pi);
    esc(out, d);
    out.append("</desc>\n");
    page_bg(out, p);
    for bi in p.b0..p.b1 {
        let b = BOXES[bi];
        if !visible(b, STEP_ALL) { continue; }
        let k = b.kind;
        if is_shape(k) { shape(out, b); continue; }
        if k == BX_MISSING { missing_frame(out, b); }
        format(out, "<!--ml-region ", REGIONS.len, "-->\n");
        if k == BX_MEDIA {
            // A photo: at most 480 pixels on the long edge, at most 24 colors.
            add_region(bi, 0.0, min(3.0, 480.0 / max(max(b.w, b.h), 1.0)), 24, 3.0, 0.9);
            if b.a == M_VIDEO { play_mark(out, b); }
        }
        else if k == BX_MATH { add_region(bi, 4.0, 4.0, 2, 2.0, 0.6); }
        else if k == BX_PLOT || k == BX_CHART { add_region(bi, 2.0, 2.0, 10, 2.0, 0.6); }
        else if k == BX_THUMB { add_region(bi, 0.0, 1.0, 16, 2.0, 0.75); }
        // Text: the browser has no glyph outlines, so the text is traced too.
        else { add_region(bi, 0.0, 4.0, 8, 1.0, 0.5); }
    }
    out.append("</svg>\n");
}

// One region of the page, alone and without the background, in pixels.
fn region_svg(out: u8[>..]&, ri: i64) {
    let r = REGIONS[ri];
    let m = mark();
    svg_open(out, ceil(r.w * r.scale), ceil(r.h * r.scale), r.x, r.y, ceil(r.w * r.scale) / r.scale, ceil(r.h * r.scale) / r.scale);
    let b = BOXES[r.box];
    if b.kind == BX_MISSING { draw_text(out, b.a, b.x + 8.0, b.y + 8.0, b.w - 16.0); }
    else { box_svg(out, r.box, 1.0); }
    out.append("</svg>\n");
    rewind(m);
}

// The label of a traced region, for screen readers.
fn region_label(out: u8[>..]&, ri: i64) {
    let b = BOXES[REGIONS[ri].box];
    if b.kind == BX_MEDIA || b.kind == BX_MISSING { out.append(tb(b.q)); }
    else if b.kind == BX_MATH { math_speech(out, tb(b.p)); }
    else if b.kind == BX_PLOT { plot_text(out, b.a); }
    else if b.kind == BX_CHART { chart_summary(out, b.a); }
}

// The plot description as plain text (pl_description writes HTML).
fn plot_text(out: u8[>..]&, d: i64) {
    pl_parse(sp_text(EV[d].c));
    var h: u8[>..] = [];
    pl_description(h);
    var i = 0;
    while i < h.len {
        if has_prefix(h[i..], "&amp;") { out.push('&'); i += 5; }
        else if has_prefix(h[i..], "&lt;") { out.push('<'); i += 4; }
        else if has_prefix(h[i..], "&gt;") { out.push('>'); i += 4; }
        else if has_prefix(h[i..], "&quot;") { out.push('"'); i += 6; }
        else { out.push(h[i]); i++; }
    }
}
