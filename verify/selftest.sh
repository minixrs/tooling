#!/usr/bin/env bash
#
# selftest.sh — build tiny aarch64 ELF fixtures with the host toolchain and
# check that check-brand.sh returns the right verdict on each:
#
#   branded.s    → exit 0 (branded, abi_version=1)
#   unbranded.s  → exit 1 (missing brand)
#   badabi.s     → exit 2 (unsupported abi_version)
#
# Needs a clang able to emit aarch64 ELF objects (any Apple or LLVM clang)
# and a GNU-flavor lld: ld.lld from $MINIXRS_SDK/bin, PATH, or Homebrew LLVM,
# else rust-lld from a rustup toolchain with the llvm-tools component.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-brand.sh"
SDK="${MINIXRS_SDK:-$HOME/toolchains/minixrs}"

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

build() { # <fixture basename>
    "$CLANG" --target=aarch64-unknown-none-elf -c \
        "$SCRIPT_DIR/testdata/$1.s" -o "$tmp/$1.o"
    "$LLD" ${LLD_ARGS[@]+"${LLD_ARGS[@]}"} -e _start -o "$tmp/$1.elf" "$tmp/$1.o"
}

fail=0
expect() { # <fixture> <expected exit code>
    build "$1"
    local rc=0
    "$CHECK" "$tmp/$1.elf" || rc=$?
    if [ "$rc" -eq "$2" ]; then
        echo "selftest: PASS $1 (exit $rc)"
    else
        echo "selftest: FAIL $1 (exit $rc, expected $2)" >&2
        fail=1
    fi
}

expect branded 0
expect unbranded 1
expect badabi 2

if [ "$fail" -eq 0 ]; then
    echo "selftest: all fixtures passed"
fi
exit "$fail"
