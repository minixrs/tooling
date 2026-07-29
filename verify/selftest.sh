#!/usr/bin/env bash
#
# selftest.sh — build tiny aarch64 ELF fixtures with the host toolchain and
# check that the verifiers return the right verdict on each.
#
# check-brand.sh, the identity note (docs/abi-note.md):
#
#   branded.s    → exit 0 (branded, abi_version=1)
#   unbranded.s  → exit 1 (missing brand)
#   badabi.s     → exit 2 (unsupported abi_version)
#
# check-image.sh, the kernel loader's rules. All four link branded.s and vary
# only the link, so each fixture violates exactly one rule:
#
#   --image-base=0x100000   → exit 0  (the base LLVM patch 0006 pinned)
#   lld's default base      → exit 1  (0x200000 — lands on the stack page)
#   -pie                    → exit 1  (ET_DYN, the loader's BadType)
#   testdata/misaligned.ld  → exit 1  (a PT_LOAD off 4 KiB alignment)
#
# Those four link with the same -z flags the MinixRS driver passes
# (docs/sysroot-layout.md), because without them lld packs loadable segments
# so that only p_offset ≡ p_vaddr (mod page) holds — neither is page-aligned,
# and every fixture would "fail" for *that* rather than the rule under test.
# `separate-loadable-segments` is the load-bearing one: it gives each segment
# its own page. `max-page-size` only sets the granularity, so dropping it
# alone still yields 64 KiB-aligned (hence 4 KiB-aligned) segments.
#
# Each image expectation therefore asserts the reported reason, not just the
# exit code — image-base-1m is the sentinel that catches these flags drifting
# out of sync with the driver.
#
# Needs a clang able to emit aarch64 ELF objects (any Apple or LLVM clang)
# and a GNU-flavor lld: ld.lld from $MINIXRS_SDK/bin, PATH, or Homebrew LLVM,
# else rust-lld from a rustup toolchain with the llvm-tools component.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_BRAND="$SCRIPT_DIR/check-brand.sh"
CHECK_IMAGE="$SCRIPT_DIR/check-image.sh"
SDK="${MINIXRS_SDK:-$HOME/toolchains/minixrs}"

# What the MinixRS toolchain adds to every link (minixrs D13). Modelling it
# here is what keeps the image fixtures honest — see the header.
ZFLAGS=(-z max-page-size=4096 -z separate-loadable-segments)

CLANG="${CLANG:-$(command -v clang || true)}"
if [ -z "$CLANG" ]; then
    echo "selftest: clang not found" >&2
    exit 3
fi

LLD=""
LLD_ARGS=()
for cand in "$SDK/bin/ld.lld" \
            "$(command -v ld.lld || true)" \
            /opt/homebrew/opt/llvm/bin/ld.lld \
            /usr/local/opt/llvm/bin/ld.lld; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
        LLD="$cand"
        break
    fi
done
if [ -z "$LLD" ] && command -v rustc >/dev/null 2>&1; then
    sysroot="$(rustc --print sysroot 2>/dev/null || true)"
    if [ -n "$sysroot" ]; then
        cand="$(find "$sysroot/lib/rustlib" -name rust-lld -type f 2>/dev/null | head -1)"
        if [ -n "$cand" ]; then
            LLD="$cand"
            LLD_ARGS=(-flavor gnu)
        fi
    fi
fi
if [ -z "$LLD" ]; then
    echo "selftest: no GNU-flavor lld found (install LLVM, or a rustup toolchain with llvm-tools)" >&2
    exit 3
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

compile() { # <fixture basename> — assemble once, reused across links
    [ -f "$tmp/$1.o" ] || "$CLANG" --target=aarch64-unknown-none-elf -c \
        "$SCRIPT_DIR/testdata/$1.s" -o "$tmp/$1.o"
}

link() { # <output basename> <fixture basename> [extra ld args...]
    local out="$1" src="$2"
    shift 2
    compile "$src"
    "$LLD" ${LLD_ARGS[@]+"${LLD_ARGS[@]}"} -e _start "$@" \
        -o "$tmp/$out.elf" "$tmp/$src.o"
}

fail=0

detail() { sed 's/^/selftest:   /' >&2; }

expect() { # <fixture> <expected exit code> — check-brand.sh
    link "$1" "$1"
    local rc=0
    "$CHECK_BRAND" "$tmp/$1.elf" || rc=$?
    if [ "$rc" -eq "$2" ]; then
        echo "selftest: PASS $1 (exit $rc)"
    else
        echo "selftest: FAIL $1 (exit $rc, expected $2)" >&2
        fail=1
    fi
}

expect_image() { # <label> <expected rc> <expected reason> <fixture> [ld args...]
    local label="$1" want_rc="$2" want_msg="$3" src="$4"
    shift 4
    # ${ARR[@]+…} guard: macOS bash 3.2 treats "${ARR[@]}" on an empty array as
    # an unbound variable under `set -u` (CLAUDE.md).
    link "$label" "$src" ${ZFLAGS[@]+"${ZFLAGS[@]}"} "$@"

    local out rc=0
    out="$("$CHECK_IMAGE" "$tmp/$label.elf" 2>&1)" || rc=$?

    if [ "$rc" -ne "$want_rc" ]; then
        echo "selftest: FAIL $label (exit $rc, expected $want_rc)" >&2
        detail <<<"$out"
        fail=1
        return
    fi
    # Exit code alone is not proof: a fixture that violated some *other* rule
    # would score the same. Assert the rule under test actually fired.
    if ! grep -qF -- "$want_msg" <<<"$out"; then
        echo "selftest: FAIL $label (exit $rc as expected, but not for the reason under test)" >&2
        echo "selftest:   wanted: $want_msg" >&2
        detail <<<"$out"
        fail=1
        return
    fi
    echo "selftest: PASS $label (exit $rc, \"$want_msg\")"
}

expect branded 0
expect unbranded 1
expect badabi 2

expect_image image-base-1m    0 "LOADABLE"                  branded --image-base=0x100000
expect_image image-default    1 "overlaps the stack page"   branded
expect_image image-pie        1 "not ET_EXEC"               branded -pie
expect_image image-misaligned 1 "is not 4096-byte aligned"  branded \
    -T "$SCRIPT_DIR/testdata/misaligned.ld"

if [ "$fail" -eq 0 ]; then
    echo "selftest: all fixtures passed"
fi
exit "$fail"
