/* The input side of the boundary between JavaScript and the Goose core.
 * JavaScript asks for a buffer with ml_in_alloc, writes UTF-8 or bytes into
 * it, and then calls an exported Goose function. Goose copies a buffer into
 * a builder with ml_arg. Results come back as a const u8[:] (a pointer and
 * a length), so no output buffer is needed here. */
#include <stdlib.h>

#define ML_ARGS 8
static uint8_t *ml_in_buf[ML_ARGS];
static int64_t ml_in_len[ML_ARGS];

uint8_t *ml_in_alloc(int32_t i, int32_t n) {
    if (i < 0 || i >= ML_ARGS) return 0;
    free(ml_in_buf[i]);
    ml_in_buf[i] = malloc(n > 0 ? (size_t)n : 1);
    ml_in_len[i] = n > 0 ? n : 0;
    return ml_in_buf[i];
}

static void ml_arg(int32_t i, gs_rref out) {
    if (i < 0 || i >= ML_ARGS || !ml_in_buf[i]) return;
    gs_bld_append(out, ml_in_buf[i], ml_in_len[i]);
}

/* Data stacks in WebAssembly. The Goose runtime reserves one region for
 * each data stack with mmap, and Emscripten's mmap clears all of it.
 * New linear memory is already zero, and the runtime keeps its regions
 * until the end, so the regions come from the heap without a clear. The
 * build links these in place of mmap and munmap (--wrap). A region holds at
 * most GS_STACK_RESERVE bytes and has no guard pages here, so JavaScript
 * limits the size of a document (see web/core.js). */
#ifdef __EMSCRIPTEN__
#include <sys/mman.h>
void *__wrap_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    (void)addr; (void)prot; (void)flags; (void)fd; (void)off;
    void *p = aligned_alloc(65536, (len + 65535) & ~(size_t)65535);
    return p ? p : MAP_FAILED;
}
int __wrap_munmap(void *addr, size_t len) { (void)addr; (void)len; return 0; }
#endif

/* A project ZIP can be large: Goose reads it in its input buffer, with no
 * copy into a data stack. */
const uint8_t *ml_pack_import(sl_u8 zip, int64_t *len);
const uint8_t *ml_pack_import_arg(int64_t *len) {
    sl_u8 zip = { ml_in_buf[0], ml_in_len[0] };
    return ml_pack_import(zip, len);
}

/* Text, math and media metrics for the page layout (core/layout.goose), as
 * the app's TextMeasurer. The browser measures, with the fonts that the
 * page renderer uses: ml_measure gives the advance of a text at 100 px in a
 * CSS font, and ml_math_metric gives an equation's width, ascent or descent
 * (which = 0, 1, 2) for a font size of 1 px, or -1 when it cannot render.
 * which = 3 gives the distance from the top of the box that holds the
 * equation (see math_div in core/pagesvg.goose) to its baseline.
 * JavaScript sets Module.mlMeasure and Module.mlMath (web/pages.js). Without
 * them, as in the tests, an estimate from character counts is used, as the
 * app's ApproximateMeasurer. */
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
EM_JS(double, ml_js_measure, (const uint8_t *t, int tn, const uint8_t *f, int fn), {
    const d = new TextDecoder();
    const text = d.decode(HEAPU8.subarray(t, t + tn));
    const font = d.decode(HEAPU8.subarray(f, f + fn));
    if (Module.mlMeasure) return Module.mlMeasure(text, font);
    return [...text].length * (font.includes("Courier") ? 60 : 50);
});
EM_JS(double, ml_js_math, (const uint8_t *t, int tn, int display, int which), {
    const latex = new TextDecoder().decode(HEAPU8.subarray(t, t + tn));
    if (Module.mlMath) return Module.mlMath(latex, display, which);
    return which == 0 ? [...latex].length * 0.45 : which == 2 ? 0.3 : 0.8;
});
#else
static double ml_js_measure(const uint8_t *t, int tn, const uint8_t *f, int fn) { (void)t; (void)f; (void)fn; return tn * 50.0; }
static double ml_js_math(const uint8_t *t, int tn, int display, int which) { (void)t; (void)display; return which == 0 ? tn * 0.45 : which == 2 ? 0.3 : 0.8; }
#endif
double ml_measure(sl_u8 t, sl_u8 font) { return ml_js_measure(t.data, (int)t.len, font.data, (int)font.len); }
double ml_math_metric(sl_u8 latex, int32_t display, int32_t which) { return ml_js_math(latex.data, (int)latex.len, display, which); }

/* The SVG export traces RGBA pixels of a region in place (core/trace.goose):
 * a region can be larger than a data stack. So are its two arrays with one
 * byte for each pixel and each grid point: they come from the heap. */
const uint8_t *ml_trace(sl_u8 px, sl_u8 rank, sl_u8 taken, int32_t w, int32_t h, int32_t colors, double min_area, double tol,
                        double x, double y, double scale, int64_t *len);
const uint8_t *ml_trace_arg(int32_t w, int32_t h, int32_t colors, double min_area, double tol,
                            double x, double y, double scale, int64_t *len) {
    sl_u8 px = { ml_in_buf[0], ml_in_len[0] };
    int64_t n = w > 0 && h > 0 ? (int64_t)w * h : 0, g = w > 0 && h > 0 ? (int64_t)(w + 1) * (h + 1) : 0;
    sl_u8 rank = { calloc(n + 1, 1), n }, taken = { calloc(g + 1, 1), g };
    static const uint8_t none[1];
    const uint8_t *r = none;
    *len = 0;
    if (rank.data && taken.data) r = ml_trace(px, rank, taken, w, h, colors, min_area, tol, x, y, scale, len);
    free(rank.data);
    free(taken.data);
    return r;
}
