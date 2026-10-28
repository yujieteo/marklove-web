#!/bin/sh
# Builds the Marklove core (Goose -> C -> WebAssembly) into web/.
#
#   GOOSE=/path/to/goose EMCC=/path/to/emcc ./build.sh
#
# Output: web/marklove.mjs and web/marklove.wasm. The web/ folder is then a
# static site: copy it to any path on a web server.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
goose=${GOOSE:-goose}
emcc=${EMCC:-emcc}
out=${OUT:-"$here/build"}
mkdir -p "$out"

# Goose writes one C file with a header for the exported functions.
"$goose" -q -o "$out/marklove.c" "$here/core/marklove.goose" --standalone \
    --include io.h --header "$out/marklove.h"

# Goose lays out its values for 64-bit pointers, but wasm32 has 32-bit
# pointers. Each pointer field of a C type (a slice, a builder header or a
# reference) becomes 8 bytes wide, so that the C sizes are the Goose sizes.
perl -pi -e 'if (/^typedef struct \{.*\*.*\} \w+;$/) { s/([A-Za-z_][\w ]*?\s*\*+)\s*(\w+);/union { $1$2; uint64_t gs_w_$2; };/g }' \
    "$out/marklove.c" "$out/marklove.h"

exports=$(sed -n 's/^.*[[:space:]]\(ml_[a-z0-9_]*\)(.*$/_\1/p' "$out/marklove.h" | sort -u | tr '\n' ',')

"$emcc" "$out/marklove.c" -I "$here/core" -O2 \
    -DGS_STACK_RESERVE='(8ull<<20)' -DGS_STACK_GAP=65536 \
    -Wl,--wrap=mmap -Wl,--wrap=munmap -sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=4MB \
    -sMODULARIZE -sEXPORT_ES6 -sENVIRONMENT=web,node -sALLOW_MEMORY_GROWTH \
    -sEXPORTED_FUNCTIONS="_malloc,_free,_goose_init,_ml_in_alloc,_ml_pack_import_arg,${exports%,}" \
    -sEXPORTED_RUNTIME_METHODS=HEAPU8 \
    -o "$here/web/marklove.mjs"

echo "Built web/marklove.mjs and web/marklove.wasm"
