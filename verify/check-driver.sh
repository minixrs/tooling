#!/usr/bin/env bash
#
# check-driver.sh — the M2 gate as a script: does the fork clang actually
# know aarch64-unknown-minixrs?
#
#   1. preprocessor: __minixrs__, __unix__, __ELF__ are defined
#   2. driver: -### picks ld.lld, links -static, passes the minixrs -z flags,
#      and resolves crt objects out of $MINIXRS_SDK/sysroot/usr/lib
#   3. link: assemble + link verify/testdata/branded.s and confirm the result
#      carries the identity note (check-brand.sh exit 0)
#   4. the triple-named driver: aarch64-unknown-minixrs-clang, next to clang,
#      targets minixrs with no --target — it is the linker rustc's target
#      spec names
#   5. self-contained: clang loads no library from outside the OS, and
#      llvm-config's system libraries link with no extra search path — rustc
#      links this LLVM through llvm-config (P4 design R10)
#
# Step 3 is the "links a branded static ELF" half of the M2 gate. It works
# before musl exists because the fixture carries the note in hand-written asm
# and links -nostdlib; the C-side brand only arrives with musl's crt1.o in P3.
# For the same reason step 2's crt/sysroot assertions are SKIPPED with a
# notice until the sysroot is installed.
#
# Against an unpatched (--baseline) clang this correctly fails at step 1.
#
# Usage: check-driver.sh          uses $MINIXRS_SDK/bin/clang
#        CLANG=/path/to/clang check-driver.sh
#
# Exit codes: 0 all checks passed / 1 a check failed / 3 environment problem
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../scripts/env.sh"

CLANG="${CLANG:-$MINIXRS_SDK/bin/clang}"
TRIPLE=aarch64-unknown-minixrs
SYSROOT="$MINIXRS_SDK/sysroot"
CHECK_BRAND="$SCRIPT_DIR/check-brand.sh"

if [ ! -x "$CLANG" ]; then
    echo "check-driver: $CLANG not found — run scripts/build-llvm.sh first" >&2
    exit 3
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
pass() { echo "check-driver: PASS $*"; }
bad()  { echo "check-driver: FAIL $*" >&2; fail=1; }
skip() { echo "check-driver: SKIP $*"; }

# ---------------------------------------------------------------- step 1
# Everything downstream is meaningless if the target is unknown, so this one
# is a hard gate rather than an accumulated failure.
echo "check-driver: [1/5] preprocessor defines"
defines="$("$CLANG" --target="$TRIPLE" -dM -E -x c /dev/null 2>/dev/null || true)"
missing=()
for m in __minixrs__ __unix__ __ELF__; do
    grep -qE "^#define $m\b" <<<"$defines" || missing+=("$m")
done
if [ "${#missing[@]}" -ne 0 ]; then
    echo "check-driver: FAIL ${missing[*]} not defined for $TRIPLE" >&2
    echo "check-driver: the driver does not know this triple — is this an" >&2
    echo "check-driver: unpatched (--baseline) clang? See docs/plans/llvm-m2.md." >&2
    exit 1
fi
pass "__minixrs__, __unix__, __ELF__ defined"

# ---------------------------------------------------------------- step 2
echo "check-driver: [2/5] driver link line"
: > "$tmp/empty.c"
# -### writes the would-be commands to stderr and runs nothing.
link_line="$("$CLANG" -### --target="$TRIPLE" -o "$tmp/empty.out" "$tmp/empty.c" 2>&1 || true)"

grep -q 'ld\.lld' <<<"$link_line" \
    && pass "linker is ld.lld" \
    || bad "ld.lld not on the link line"

grep -q -- '-static' <<<"$link_line" \
    && pass "links -static" \
    || bad "-static not on the link line"

# docs/sysroot-layout.md / minixrs D13: page-aligned vaddr *and* file offset
# per PT_LOAD, which is what the kernel loader requires.
grep -q 'max-page-size=4096' <<<"$link_line" \
    && pass "-z max-page-size=4096" \
    || bad "-z max-page-size=4096 not on the link line"

grep -q 'separate-loadable-segments' <<<"$link_line" \
    && pass "-z separate-loadable-segments" \
    || bad "-z separate-loadable-segments not on the link line"

if [ -d "$SYSROOT/usr/lib" ]; then
    for obj in crt1.o crti.o crtn.o; do
        grep -q "$SYSROOT/usr/lib/$obj" <<<"$link_line" \
            && pass "$obj from $SYSROOT/usr/lib" \
            || bad "$obj not resolved out of $SYSROOT/usr/lib"
    done
else
    skip "crt/sysroot assertions — no sysroot at $SYSROOT (built in P3)"
fi

# ---------------------------------------------------------------- step 3
echo "check-driver: [3/5] link a branded static ELF"
if "$CLANG" --target="$TRIPLE" -nostdlib -e _start \
        -o "$tmp/branded.elf" "$SCRIPT_DIR/testdata/branded.s" 2>"$tmp/link.err"; then
    if "$CHECK_BRAND" "$tmp/branded.elf"; then
        pass "linked ELF carries the minixrs identity note"
    else
        bad "linked ELF is missing the brand"
    fi
else
    sed 's/^/check-driver:   /' "$tmp/link.err" >&2
    bad "could not link $SCRIPT_DIR/testdata/branded.s for $TRIPLE"
fi

# ---------------------------------------------------------------- step 4
# rustc's target spec names this driver rather than `clang`, which PATH would
# resolve to Apple's. clang takes its target from a triple-prefixed name.
echo "check-driver: [4/5] triple-named driver"
TRIPLE_CLANG="$(dirname "$CLANG")/$TRIPLE-clang"
if [ ! -x "$TRIPLE_CLANG" ]; then
    bad "$TRIPLE_CLANG not found — scripts/build-llvm.sh installs it"
elif "$TRIPLE_CLANG" -dM -E -x c /dev/null 2>/dev/null | grep -qE '^#define __minixrs__\b'; then
    pass "$TRIPLE-clang targets minixrs without --target"
else
    bad "$TRIPLE_CLANG does not target $TRIPLE by its name"
fi

# ---------------------------------------------------------------- step 5
# CMake enables optional dependencies it happens to find — Homebrew's zstd,
# for one — and then clang, and every rustc linked through llvm-config,
# depends on a package nothing here installs.
echo "check-driver: [5/5] self-contained"
foreign="$(otool -L "$CLANG" | tail -n +2 | awk '{print $1}' |
    grep -vE '^(/usr/lib/|/System/Library/|@rpath/|@executable_path/)' || true)"
if [ -z "$foreign" ]; then
    pass "clang loads only OS libraries"
else
    bad "clang loads libraries from outside the OS: $(echo $foreign)"
fi
LLVM_CONFIG="$(dirname "$CLANG")/llvm-config"
syslibs="$("$LLVM_CONFIG" --system-libs 2>/dev/null)" || syslibs="?"
# shellcheck disable=SC2086 # the list is meant to split into -l flags
if [ "$syslibs" != "?" ] &&
    printf 'int main(void) { return 0; }\n' |
        /usr/bin/cc -x c - -o "$tmp/syslibs" $syslibs 2>"$tmp/syslibs.err"; then
    pass "llvm-config's system libraries ($syslibs) link from the OS"
else
    sed 's/^/check-driver:   /' "$tmp/syslibs.err" >&2 2>/dev/null || true
    bad "llvm-config's system libraries ($syslibs) do not link without an extra -L"
fi

if [ "$fail" -eq 0 ]; then
    echo "check-driver: all checks passed"
fi
exit "$fail"
