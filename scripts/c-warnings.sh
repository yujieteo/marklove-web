set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
goose=${GOOSE:-goose}
out=$(mktemp -d "${TMPDIR:-/tmp}/marklove-cwarn-XXXXXX")
trap 'rm -rf "$out"' EXIT
known="$here/scripts/c-analyzer-known.txt"

"$goose" -q -o "$out/marklove.c" "$here/core/marklove.goose" --standalone \
    --include io.h --header "$out/marklove.h"

cc -c -o /dev/null -Wall -Wextra -Wpedantic -Werror \
    -Wno-unused-variable -Wno-unused-function -Wno-unused-parameter \
    -Wno-unused-but-set-variable -Wno-unterminated-string-initialization \
    '-DGS_STACK_RESERVE=(8ull<<20)' -DGS_STACK_GAP=65536 \
    -I "$here/core" -I "$out" "$out/marklove.c"

clang --analyze -Xanalyzer -analyzer-disable-checker=deadcode.DeadStores \
    -Xanalyzer -analyzer-output=text \
    '-DGS_STACK_RESERVE=(8ull<<20)' -DGS_STACK_GAP=65536 \
    -I "$here/core" -I "$out" "$out/marklove.c" -o /dev/null 2>"$out/analyze.log"

sed -n 's/^.*:[0-9][0-9]*:[0-9][0-9]*: warning: //p' "$out/analyze.log" | LC_ALL=C sort > "$out/found.txt"

if [ "${1:-}" = "--print" ]; then
    cat "$out/found.txt"
    exit 0
fi

LC_ALL=C sort "$known" > "$out/known.txt"
new=$(LC_ALL=C comm -13 "$out/known.txt" "$out/found.txt")
gone=$(LC_ALL=C comm -23 "$out/known.txt" "$out/found.txt")
status=0
if [ -n "$new" ]; then
    echo "analyser findings not in scripts/c-analyzer-known.txt:"
    printf '%s\n' "$new"
    status=1
fi
if [ -n "$gone" ]; then
    echo "listed analyser findings that no longer occur; delete them from scripts/c-analyzer-known.txt:"
    printf '%s\n' "$gone"
    status=1
fi
if [ "$status" -eq 0 ]; then
    echo "C warnings and analyser: generated C clean against the known list"
fi
exit "$status"
