#!/usr/bin/env bash
#
# build-musl.sh — build the musl-minixrs fork with the fork clang and install
# the static libc, crt objects, and headers into $MINIXRS_SDK/sysroot/usr.
#
# This is the SDK flavor (real aarch64-unknown-minixrs triple, roadmap P3).
# The minixrs repo keeps its own CI-fallback tools/build-musl.sh using the
# linux-musl triple workaround (phase-5 D10) until M3 stabilizes; that copy
# is deleted once minixrs consumes $MINIXRS_SDK.
#
# Run scripts/build-llvm.sh first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/env.sh"

MUSL_SRC="${MUSL_MINIXRS_SRC:-$MINIXRS_FORKS_DIR/musl-minixrs}"
CLANG="$MINIXRS_SDK/bin/clang"
TRIPLE=aarch64-unknown-minixrs

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

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
BUILD_DIR="${MUSL_BUILD_DIR:-$MUSL_SRC/build-minixrs}"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Static-only platform: no shared objects, no dynamic linker (see
# docs/sysroot-layout.md). The fork's configure knows the minixrs triple;
# crt1.o carries the identity note (docs/abi-note.md).
"$MUSL_SRC/configure" \
    CC="$CLANG" \
    CFLAGS="--target=$TRIPLE" \
    AR="$MINIXRS_SDK/bin/llvm-ar" \
    RANLIB="$MINIXRS_SDK/bin/llvm-ranlib" \
    --target="$TRIPLE" \
    --prefix="$MINIXRS_SDK/sysroot/usr" \
    --disable-shared

make -j"$JOBS"
make install

echo "build-musl: installed into $MINIXRS_SDK/sysroot/usr"
