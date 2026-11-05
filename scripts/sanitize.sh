#!/bin/sh
set -eu

here=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
goose=${GOOSE:-goose}
out=$(mktemp -d "${TMPDIR:-/tmp}/marklove-sanitize-XXXXXX")
trap 'rm -rf "${out}"' EXIT

"${goose}" -q -o "${out}/marklove.c" "${here}/core/marklove.goose" --standalone \
    --include io.h --header "${out}/marklove.h" 2>/dev/null

goose_packs_structs_unaligned=-fno-sanitize=alignment

cc -O1 -g -fsanitize=undefined,address -fno-sanitize-recover=all "${goose_packs_structs_unaligned}" \
    -DGS_STACK_RESERVE='(8ull<<20)' -DGS_STACK_GAP=65536 \
    -I "${here}/core" -I "${out}" -o "${out}/run" "${here}/tests/sanitize/main.c" -lm 2>"${out}/cc.log" || { cat "${out}/cc.log"; exit 1; }

"${out}/run"
