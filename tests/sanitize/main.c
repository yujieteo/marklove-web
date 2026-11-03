#include "marklove.c"
#include <stdio.h>
#include <string.h>

static const char *SOURCE =
    "---\ntitle: Waves\nauthor: A. Writer\n---\n\n# Sound\n\nSpeed is $v = f\\lambda$.\n\n. . .\n\n"
    "More text \xc3\xa9.\n\n![A cat](images/cat.png)\n\n::: plot\nx: 0, 6.28\ny: -2, 2\ny = sin(x)\n:::\n\n"
    "::: chart bar\n| A | B |\n| --- | ---: |\n| x | 1 |\n:::\n\n::: notes\nSay hello.\n:::\n";

static void put(int slot, const char *text) {
    size_t n = strlen(text);
    memcpy(ml_in_alloc(slot, (int32_t)n), text, n);
}

static void document(void) {
    put(0, SOURCE);
    for (int slot = 1; slot < 6; slot++) put(slot, "");
}

static int64_t checked(const uint8_t *out, int64_t len) {
    if (out == NULL || len < 0) {
        fprintf(stderr, "bad output\n");
        exit(1);
    }
    volatile uint8_t sink = 0;
    for (int64_t i = 0; i < len; i++) sink ^= out[i];
    return len;
}

int main(void) {
    int64_t len = 0, total = 0;
    goose_init(0, 0);
    for (int kind = 0; kind < 2; kind++) {
        for (int opts = 0; opts < 16; opts++) {
            document();
            total += checked(ml_page(kind, opts, &len), len);
        }
    }
    for (int kind = 0; kind < 6; kind++) {
        document();
        total += checked(ml_text(kind, 0, &len), len);
    }
    document();
    total += checked(ml_outline(0, &len), len);
    put(0, SOURCE);
    for (int slot = 1; slot < 6; slot++) put(slot, "");
    total += checked(ml_lint(&len), len);
    const char *keys[] = {"i", "x", "Escape", "d", "w", "u", "v", "j", "p", ":", "Enter"};
    ml_vim_reset();
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        put(0, SOURCE);
        put(1, keys[i]);
        total += checked(ml_vim_key(0, 5, &len), len);
    }
    put(0, SOURCE);
    put(1, "sound");
    total += checked(ml_find(0, 0, &len), len);
    printf("sanitizer run ok, %lld bytes checked\n", (long long)total);
    return 0;
}
