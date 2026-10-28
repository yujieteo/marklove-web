// RasterTracer: raster pixels as SVG shapes, for the SVG slide export.
//
// The process is deterministic: the same pixels always give the same SVG.
// 1. Color reduction: median cut makes a palette of at most `colors` colors.
//    Each pixel gets the nearest palette color. Pixels with alpha below 50%
//    are empty.
// 2. Layers: the most common color is the bottom layer. Layer k covers each
//    pixel with a color of rank k or higher, so each layer is under the
//    layers above it, and no gaps show between shapes.
// 3. Outlines: the edges between covered and empty pixels join into closed
//    paths. The even-odd fill rule makes holes from inner paths.
// 4. Simplification: straight runs join, and the Ramer-Douglas-Peucker
//    method removes the small steps of the pixel grid.
//
// The pixels are RGBA (8 bits each, not premultiplied, rows from the top).

import base;

struct RGB { r: i64, g: i64, b: i64 }

struct TP { x: i64, y: i64 }
var TR_LOOP: TP[>..] = [];
var TR_PTS: TP[>..] = [];
struct FP { x: f64, y: f64 }
var TR_KEEP: bool[>..] = [];

fn tr_channel(px: u8[:], i: i64, c: i64) -> i64 { px[i * 4 + c] as i64 }

// The channel with the largest range of a box of pixels, and the range.
fn tr_range(px: u8[:], items: i64[:]) -> i64, i64 {
    var lo: i64[3] = [255, 255, 255];
    var hi: i64[3] = [0, 0, 0];
    for i in items {
        for c in 3 {
            let v = tr_channel(px, i, c);
            if v < lo[c] { lo[c] = v; }
            if v > hi[c] { hi[c] = v; }
        }
    }
    var best = 0;
    for c in 3 { if hi[c] - lo[c] > hi[best] - lo[best] { best = c; } }
    return best, hi[best] - lo[best];
}

fn tr_median_cut(px: u8[:], count: i64, opaque: i64, max_colors: i64, palette: RGB[>..]&) {
    // A sample keeps large images fast: each step-th opaque pixel. The step
    // is fixed, so the result stays the same.
    let step = max(1, opaque / 60000);
    // Boxes are ranges of `items`; each split sorts one range.
    var items: i64[>..] = [];
    var k = 0;
    for i in count {
        if px[i * 4 + 3] < 128 { continue; }
        if k % step == 0 { items.push(i); }
        k++;
    }
    var lo: i64[>..] = [0];
    var hi: i64[>..] = [items.len];
    while lo.len < max_colors {
        var best = -1;
        var best_score = 0;
        for b in lo.len {
            let n = hi[b] - lo[b];
            if n <= 1 { continue; }
            let c, size = tr_range(px, items[lo[b]..hi[b]]);
            let score = size * n;
            if score > best_score { best_score = score; best = b; }
        }
        if best < 0 { break; }
        let c, size = tr_range(px, items[lo[best]..hi[best]]);
        var part: i64[>..] = [];
        part.append(items[lo[best]..hi[best]]);
        sort(part) { a, b => tr_channel(px, a, c) < tr_channel(px, b, c) || (tr_channel(px, a, c) == tr_channel(px, b, c) && a < b) };
        for v, j in part { items[lo[best] + j] = v; }
        let mid = lo[best] + part.len / 2;
        lo.push(mid);
        hi.push(hi[best]);
        hi[best] = mid;
    }
    for b in lo.len {
        var s: i64[3] = [0, 0, 0];
        for i in items[lo[b]..hi[b]] { for c in 3 { s[c] += tr_channel(px, i, c); } }
        let n = max(1, hi[b] - lo[b]);
        palette.push(RGB { s[0] / n, s[1] / n, s[2] / n });
    }
}

fn tr_nearest(palette: RGB[:], r: i64, g: i64, b: i64) -> i64 {
    var best = 0;
    var best_d = 1 << 62;
    for c, k in palette {
        let dr = c.r - r;
        let dg = c.g - g;
        let db = c.b - b;
        // Weighted for the eye: green counts most.
        let d = 3 * dr * dr + 4 * dg * dg + 2 * db * db;
        if d < best_d { best_d = d; best = k; }
    }
    return best;
}

fn tr_area(lp: TP[:]) -> f64 {
    var s = 0;
    for p, i in lp {
        let q = lp[(i + 1) % lp.len];
        s += p.x * q.y - q.x * p.y;
    }
    return (s as f64) / 2.0;
}

// Removes points in the middle of straight runs.
fn tr_merge_straight(lp: TP[:], out: TP[>..]&) {
    out.clear();
    let n = lp.len;
    if n <= 3 { out.append(lp); return; }
    for i in n {
        let a = lp[(i + n - 1) % n];
        let b = lp[i];
        let c = lp[(i + 1) % n];
        let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
        if cross != 0 { out.push(b); }
    }
    if out.len < 3 { out.clear(); out.append(lp); }
}

fn tr_rdp(pts: FP[:], eps: f64, out: FP[>..]&) {
    if pts.len <= 2 { out.append(pts); return; }
    TR_KEEP.clear();
    for p in pts { TR_KEEP.push(false); }
    TR_KEEP[0] = true;
    TR_KEEP[pts.len - 1] = true;
    var stack: i64[>..] = [0, pts.len - 1];
    while stack.len > 0 {
        let e = stack[stack.len - 1];
        let s = stack[stack.len - 2];
        stack.resize(stack.len - 2);
        if e <= s + 1 { continue; }
        let a = pts[s];
        let b = pts[e];
        let dx = b.x - a.x;
        let dy = b.y - a.y;
        let len = sqrt(dx * dx + dy * dy);
        var best = -1.0;
        var idx = -1;
        for i in s + 1..e {
            let p = pts[i];
            let d = if len > 0.0 { abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len }
                    else { sqrt((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)) };
            if d > best { best = d; idx = i; }
        }
        if best > eps {
            TR_KEEP[idx] = true;
            stack.push(s);
            stack.push(idx);
            stack.push(idx);
            stack.push(e);
        }
    }
    for p, i in pts { if TR_KEEP[i] { out.push(p); } }
}

fn tr_simplify(lp: TP[:], tol: f64, out: FP[>..]&) {
    out.clear();
    var pts: FP[>..] = [];
    for p in lp { pts.push(FP { p.x as f64, p.y as f64 }); }
    if pts.len <= 4 { out.append(pts); return; }
    // Split at the point farthest from the first point.
    var far = 0;
    var far_d = -1.0;
    for p, i in pts {
        let d = (p.x - pts[0].x) * (p.x - pts[0].x) + (p.y - pts[0].y) * (p.y - pts[0].y);
        if d > far_d { far_d = d; far = i; }
    }
    var a: FP[>..] = [];
    tr_rdp(pts[0..far + 1], tol, a);
    var second: FP[>..] = [];
    second.append(pts[far..]);
    second.push(pts[0]);
    var b: FP[>..] = [];
    tr_rdp(second, tol, b);
    out.append(a[..a.len - 1]);
    out.append(b[..b.len - 1]);
}

fn tr_num(out: u8[>..]&, v: f64) {
    let r = round(v * 10.0) / 10.0;
    if r == round(r) { format(out, r as! i64); return; }
    fmt_fixed(out, r, 1);
}

// One outline set for layer `rank`: path data in `d`. rk holds the rank
// of each pixel (255: empty). taken counts the edges that each grid point
// has used.
fn tr_layer(rk: u8[:], taken: u8[:], w: i64, h: i64, rank: i64, min_area: f64, tol: f64, d: u8[>..]&) {
    let gw = w + 1;
    let points = gw * (h + 1);
    for v in points { taken[v] = 0; }
    fn inside(x: i64, y: i64) -> bool {
        x >= 0 && y >= 0 && x < w && y < h && rk[y * w + x] != 255 && (rk[y * w + x] as i64) >= rank
    }
    // Directed edges with the covered pixel on the right (y down). The
    // outgoing edges of a grid point, in the order of a scan of the pixels
    // (rows, then columns): at most two. Gives the end of edge t, or -1.
    fn edge_to(v: i64, t: i64) -> i64 {
        let x = v % gw;
        let y = v / gw;
        var n = 0;
        // The bottom edge of the pixel above and to the left.
        if inside(x - 1, y - 1) && !inside(x - 1, y) { if n == t { return y * gw + x - 1; } n++; }
        // The left edge of the pixel above.
        if inside(x, y - 1) && !inside(x - 1, y - 1) { if n == t { return (y - 1) * gw + x; } n++; }
        // The right edge of the pixel to the left.
        if inside(x - 1, y) && !inside(x, y) { if n == t { return (y + 1) * gw + x; } n++; }
        // The top edge of the pixel.
        if inside(x, y) && !inside(x, y - 1) { if n == t { return y * gw + x + 1; } }
        return -1;
    }
    var edges = 0;
    for y in h {
        for x in w {
            if !inside(x, y) { continue; }
            if !inside(x, y - 1) { edges++; }
            if !inside(x + 1, y) { edges++; }
            if !inside(x, y + 1) { edges++; }
            if !inside(x - 1, y) { edges++; }
        }
    }
    var simple: FP[>..] = [];
    // Start points in a fixed order, so that the output is the same each time.
    for start in points {
        while edge_to(start, taken[start] as i64) >= 0 {
            TR_LOOP.clear();
            TR_LOOP.push(TP { start % gw, start / gw });
            var current = start;
            var count = 0;
            while count <= edges {
                count++;
                let t = taken[current] as i64;
                let to = edge_to(current, t);
                if to < 0 { break; }
                taken[current] = (t + 1) as u8;
                if to == start { break; }
                TR_LOOP.push(TP { to % gw, to / gw });
                current = to;
            }
            if TR_LOOP.len < 3 { continue; }
            tr_merge_straight(TR_LOOP, TR_PTS);
            if abs(tr_area(TR_PTS)) < min_area { continue; }
            tr_simplify(TR_PTS, tol, simple);
            if simple.len < 3 { continue; }
            for p, i in simple {
                d.push(if i == 0 { 'M' } else { 'L' });
                tr_num(d, p.x);
                d.push(' ');
                tr_num(d, p.y);
            }
            d.push('Z');
        }
    }
}

// The traced shapes of a region as an SVG group at (x, y) in the page.
// label: alternative text, or empty for a decorative group. A region can
// have millions of pixels, so the arrays with one byte for each pixel (rk)
// and each grid point (taken) come from the heap (see io.h).
fn trace(out: u8[>..]&, px: u8[:], rk: u8[:], taken: u8[:], w: i64, h: i64, max_colors: i64, min_area: f64, tol: f64,
         x: f64, y: f64, scale: f64, label: u8[:]) {
    let count = w * h;
    if w <= 0 || h <= 0 || px.len < count * 4 { return; }
    // 1. Palette.
    var opaque = 0;
    for i in count { if px[i * 4 + 3] >= 128 { opaque++; } }
    if opaque == 0 { return; }
    var palette: RGB[>..] = [];
    tr_median_cut(px, count, opaque, max(1, max_colors), palette);
    var counts: i64[>..] = [];
    for c in palette { counts.push(0); }
    // The palette index of each pixel, then its rank.
    for i in count {
        if px[i * 4 + 3] < 128 { rk[i] = 255; continue; }
        let k = tr_nearest(palette, tr_channel(px, i, 0), tr_channel(px, i, 1), tr_channel(px, i, 2));
        rk[i] = k as u8;
        counts[k] += 1;
    }
    // 2. Rank colors: the most common first. Ties keep the palette order.
    var order: i64[>..] = [];
    for k in palette.len { if counts[k] > 0 { order.push(k); } }
    stable_sort(order) { a, b => counts[a] > counts[b] };
    var rank: i64[>..] = [];
    for k in palette.len { rank.push(-1); }
    for k, r in order { rank[k] = r; }
    for i in count { if rk[i] != 255 { rk[i] = rank[rk[i] as i64] as u8; } }
    // 3 and 4. One outline set for each layer.
    var body: u8[>..] = [];
    var d: u8[>..] = [];
    for k, r in order {
        d.clear();
        tr_layer(rk, taken, w, h, r, min_area, tol, d);
        if d.len == 0 { continue; }
        let c = palette[k];
        body.append("<path fill=\"#");
        for v in [c.r, c.g, c.b] { format_int(body, v, 16, 2, '0'); }
        body.append("\" d=\"");
        body.append(d);
        body.append("\"/>\n");
    }
    if body.len == 0 { return; }
    out.append("<g transform=\"translate(");
    tr_num(out, x);
    out.push(' ');
    tr_num(out, y);
    out.append(") scale(");
    fmt_fixed(out, 1.0 / scale, 4);
    out.append(")\" fill-rule=\"evenodd\"");
    if label.len > 0 {
        out.append(" role=\"img\" aria-label=\"");
        esc(out, label);
        out.push('"');
    } else {
        out.append(" aria-hidden=\"true\"");
    }
    out.append(">\n");
    out.append(body);
    out.append("</g>\n");
}
