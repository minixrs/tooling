#!/usr/bin/env bash
#
# compare.sh — compare two ABI tables entry by entry.
#
# Usage: compare.sh <c.bin> <rust.bin> <labels>
#
# Each .bin is a raw little-endian u64 array (the .minixrs_abi section of an
# emitter object); <labels> has one line per entry. Exit 0 if identical, 1 on
# any differing entry — each reported with its label — and 2 if the inputs are
# malformed (a length that disagrees with the label count is malformed, not a
# mismatch: it means the two emitters were not generated from one manifest).
#
# Needs nothing but od/awk, so verify/selftest.sh can exercise it without an
# SDK or a fork checkout.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: compare.sh <c.bin> <rust.bin> <labels>" >&2
    exit 2
fi
for f in "$@"; do
    [ -f "$f" ] || { echo "compare: no such file: $f" >&2; exit 2; }
done

# One hex u64 per line. BSD od prints them unpadded and GNU od zero-padded, so
# leading zeros are stripped to make the two spellings compare equal.
words() {
    od -An -v -tx8 "$1" | tr -s ' \t' '\n\n' | sed -e '/^$/d' -e 's/^0*\([0-9a-f]\)/\1/'
}

n_labels=$(wc -l < "$3" | tr -d ' ')
for bin in "$1" "$2"; do
    bytes=$(wc -c < "$bin" | tr -d ' ')
    if [ "$bytes" -ne $((n_labels * 8)) ]; then
        echo "compare: $bin is $bytes bytes, expected $((n_labels * 8)) ($n_labels entries)" >&2
        exit 2
    fi
done
if [ "$n_labels" -eq 0 ]; then
    echo "compare: empty table — nothing was compared" >&2
    exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
words "$1" > "$tmp/c"
words "$2" > "$tmp/rs"

paste "$tmp/c" "$tmp/rs" "$3" | awk -F'\t' '
    $1 != $2 { printf "MISMATCH %s: C=0x%s Rust=0x%s\n", $3, $1, $2; bad++ }
    END {
        if (bad) { printf "compare: %d of %d entries differ\n", bad, NR; exit 1 }
        printf "compare: %d entries identical\n", NR
    }'
