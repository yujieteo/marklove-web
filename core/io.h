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

#ifdef __EMSCRIPTEN__
#include <sys/mman.h>
void *__wrap_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    (void)addr; (void)prot; (void)flags; (void)fd; (void)off;
    void *p = aligned_alloc(65536, (len + 65535) & ~(size_t)65535);
    return p ? p : MAP_FAILED;
}
int __wrap_munmap(void *addr, size_t len) { (void)addr; (void)len; return 0; }
#endif

const uint8_t *ml_pack_import(sl_u8 zip, int64_t *len);
const uint8_t *ml_pack_import_arg(int64_t *len) {
    sl_u8 zip = { ml_in_buf[0], ml_in_len[0] };
    return ml_pack_import(zip, len);
}

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
