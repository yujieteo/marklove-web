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
