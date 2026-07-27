#!/usr/bin/env bash
#
# build-musl.sh — build the musl-minixrs fork with the SDK clang and install
# the static libc, crt objects, and headers into $MINIXRS_SDK/sysroot/usr.
#
# This is the SDK flavor: the real aarch64-unknown-minixrs triple through the
# patched driver (roadmap P3). minixrs keeps its own tools/build-musl.sh on the
# linux-musl stand-in triple (phase-5 D10) until M3 is stable — that copy is
# the blocking qemu-smoke job's real dependency, not a fallback, and is deleted
# only once minixrs consumes $MINIXRS_SDK.
#
# Three inherited slice-5.6 hazards are genuinely different in this flavor:
#
#   - RANLIB is llvm-ranlib. minixrs uses `llvm-ar s` because the pinned Rust
#     nightly ships llvm-ar but no llvm-ranlib; the SDK ships both, so the
#     workaround does not apply here.
#   - The quad-float builtins musl's vfprintf needs (__multf3, __floatsitf, …
#     for aarch64's IEEE-quad long double) come from compiler-rt via
#     build-compiler-rt.sh, not from a -Zbuild-std compiler_builtins rlib.
#   - No linker script. lld's default layout already satisfies the kernel
#     loader; only the image base needs pinning, and the driver does that.
#
# Run scripts/build-llvm.sh and scripts/build-compiler-rt.sh first.
#
# Usage: build-musl.sh [--force]     (--force rebuilds even if .stamp matches)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/env.sh"

MUSL_SRC="${MUSL_MINIXRS_SRC:-$MINIXRS_FORKS_DIR/musl-minixrs}"
CLANG="$MINIXRS_SDK/bin/clang"
TRIPLE=aarch64-unknown-minixrs
SYSROOT="$MINIXRS_SDK/sysroot"
STAMP="$SYSROOT/.stamp"

# Both build directories sit OUTSIDE the fork work tree, deliberately: minixrs
# pins musl-minixrs as a submodule and its c-headers CI job asserts a clean
# `git status`, so a build dir inside the checkout would fail it. (build-llvm.sh
# builds inside its fork because llvm-minixrs is nobody's submodule.)
BUILD_DIR="${MUSL_BUILD_DIR:-$MINIXRS_FORKS_DIR/build/musl-minixrs}"
HDRS="$MINIXRS_GEN_C_HEADERS_DIR" # env.sh — build-sysroot.sh reads it too

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ ! -x "$MUSL_SRC/configure" ]; then
    cat >&2 <<EOF
build-musl: musl-minixrs source not found at $MUSL_SRC

Clone the fork first (docs/roadmap.md P3):
    git clone <musl-minixrs-url> "$MUSL_SRC"
or point MUSL_MINIXRS_SRC at an existing checkout.
If the forks volume is simply unmounted: scripts/forks-volume.sh mount
EOF
    exit 1
fi
if [ ! -x "$CLANG" ]; then
    echo "build-musl: $CLANG not found — run scripts/build-llvm.sh first" >&2
    exit 1
fi
if [ ! -x "$MINIXRS_SDK/bin/llvm-ranlib" ]; then
    echo "build-musl: $MINIXRS_SDK/bin/llvm-ranlib not found — reinstall the SDK" >&2
    echo "build-musl: (build-llvm.sh installs it via LLVM_INSTALL_UTILS=ON)" >&2
    exit 1
fi

# The generated ABI headers are the reason MINIXRS_SRC is a hard dependency:
# src/minixrs/ipc.c includes <minixrs/ipc.h>, musl compiles its own sources with
# -nostdinc, and the constants must come from the live kernel-shared definitions.
# This repo never vendors a copy — the minixrs repo is the ABI oracle.
if [ ! -d "$MINIXRS_SRC/tools/gen-c-headers" ]; then
    cat >&2 <<EOF
build-musl: minixrs source not found at $MINIXRS_SRC

The generated ABI headers (<minixrs/ipc.h> and friends) come from that repo's
gen-c-headers tool, which is the ABI oracle for this build — tooling never
vendors a copy. Point MINIXRS_SRC at your minixrs checkout, or clone it as a
sibling of this repo.
EOF
    exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "build-musl: cargo not found — needed to run minixrs' gen-c-headers" >&2
    exit 1
fi

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"

# ---------------------------------------------------------------------------
# Freshness. The stamp keys on the musl commit, the minixrs commit, and the
# compiler identity — a fork rebase, an ABI change, or an SDK rebuild each
# invalidate it. minixrs is in there because it is the ABI oracle: without it a
# kernel-shared constant change would leave the stale generated headers
# installed in the sysroot, and the ABI selftest would compare stale against
# stale and pass. (A commit is the granularity: uncommitted kernel-shared edits
# still need --force, same as minixrs' own submodule-sha stamp.)
#
# minixrs' build.rs uses this file as its rerun-if-changed target.
# ---------------------------------------------------------------------------
MUSL_SHA="$(git -C "$MUSL_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
MINIXRS_SHA="$(git -C "$MINIXRS_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
CLANG_ID="$("$CLANG" --version | head -1)"
WANT="musl=$MUSL_SHA minixrs=$MINIXRS_SHA clang=$CLANG_ID"

# The generated headers are part of the output, not a throwaway intermediate:
# build-sysroot.sh compiles abi-selftest.c straight out of $HDRS. If they are
# gone the sysroot is not actually reusable, so do not take the early exit —
# otherwise the only recovery is --force, which nothing points the user at.
if [ "$FORCE" -eq 0 ] && [ -f "$STAMP" ] && [ -f "$SYSROOT/usr/lib/libc.a" ] \
    && [ -f "$HDRS/abi-selftest.c" ] && [ -f "$HDRS/include/minixrs/ipc.h" ] \
    && [ "$(cat "$STAMP")" = "$WANT" ]; then
    echo "build-musl: sysroot up to date ($SYSROOT)"
    echo "build-musl: $WANT"
    exit 0
fi

echo "build-musl: building $MUSL_SRC ($MUSL_SHA) -> $SYSROOT"

# ---------------------------------------------------------------------------
# ABI headers first — musl's own sources need them on the include path.
# ---------------------------------------------------------------------------
rm -rf "$HDRS"
mkdir -p "$HDRS"
( cd "$MINIXRS_SRC" && cargo gen-c-headers "$HDRS" )

for h in "$HDRS/include/minixrs/ipc.h" "$HDRS/abi-selftest.c"; do
    if [ ! -f "$h" ]; then
        echo "build-musl: gen-c-headers did not produce $h" >&2
        echo "build-musl: has its output layout changed? (minixrs tools/gen-c-headers)" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Configure + build, out of tree. Static-only platform: no shared objects, no
# dynamic linker (docs/sysroot-layout.md). configure's aarch64*) arm matches
# this triple, and the port itself is triple-agnostic, so no fork change is
# needed to move off the stand-in triple.
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR" "$SYSROOT"
mkdir -p "$BUILD_DIR"

( cd "$BUILD_DIR" && "$MUSL_SRC/configure" \
    --target="$TRIPLE" \
    --prefix="$SYSROOT/usr" \
    --disable-shared \
    CC="$CLANG" \
    CFLAGS="--target=$TRIPLE -I$HDRS/include" \
    AR="$MINIXRS_SDK/bin/llvm-ar" \
    RANLIB="$MINIXRS_SDK/bin/llvm-ranlib" )

# configure's linker probes ("checking whether linker accepts ...") all fail
# here: they link a test program, and there is no sysroot to link against yet —
# this run is what creates it. Harmless, and not worth chasing: --disable-shared
# means only libc.a and the crt objects get built, and nothing in that set is
# linked. The probes' results only ever gate shared-library link flags.
make -C "$BUILD_DIR" -j"$JOBS"
make -C "$BUILD_DIR" install

# ---------------------------------------------------------------------------
# Install the generated ABI headers alongside musl's own so C compiles against
# a single -isystem root. They are copied into the SYSROOT, never into the fork
# work tree.
# ---------------------------------------------------------------------------
mkdir -p "$SYSROOT/usr/include/minixrs"
cp "$HDRS"/include/minixrs/*.h "$SYSROOT/usr/include/minixrs/"

printf '%s\n' "$WANT" > "$STAMP"

echo "build-musl: installed into $SYSROOT/usr"
echo "build-musl: stamp $STAMP — $WANT"
