#!/usr/bin/env bash
#
# build-llvm.sh — configure, build, and install clang + lld from the
# llvm-minixrs fork (AArch64 only) into $MINIXRS_SDK.
#
# Prerequisite (roadmap P2): the llvm-minixrs checkout on branch
# minixrs/release/22.x, inside $MINIXRS_FORKS_DIR. Override its location with
# LLVM_MINIXRS_SRC, the build dir with LLVM_BUILD_DIR.
#
# Usage: build-llvm.sh [--baseline]
#
#   --baseline  build and install an UNPATCHED tree and skip the driver smoke
#               test. Used once at P2 bring-up to prove the volume, CMake, the
#               host toolchain, and the install prefix all work before any
#               patch is in flight — so the first patch failure is
#               unambiguously a patch failure. Without it the smoke test is
#               strict.
#
# Knobs: JOBS (default hw.ncpu), LINK_JOBS (default 4).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/env.sh"

BASELINE=0
case "${1:-}" in
    --baseline) BASELINE=1 ;;
    "") ;;
    *) echo "usage: build-llvm.sh [--baseline]" >&2; exit 2 ;;
esac

LLVM_SRC="${LLVM_MINIXRS_SRC:-$MINIXRS_FORKS_DIR/llvm-minixrs}"

if [ ! -f "$LLVM_SRC/llvm/CMakeLists.txt" ]; then
    cat >&2 <<EOF
build-llvm: llvm-minixrs source not found at $LLVM_SRC

Clone the fork first (docs/roadmap.md P2):
    git clone --branch minixrs/release/22.x <llvm-minixrs-url> "$LLVM_SRC"
or point LLVM_MINIXRS_SRC at an existing checkout.
If the forks volume is simply unmounted: scripts/forks-volume.sh mount
EOF
    exit 1
fi

# Case-sensitivity gate. The check above proved llvm/CMakeLists.txt exists; if
# the UPPERCASE spelling resolves too, the filesystem folded the case and this
# tree sits on a case-insensitive volume. LLVM does not survive that. Catch it
# here rather than an hour into compiling — zero writes, no diskutil parsing,
# just a question only the filesystem can answer.
if [ -f "$LLVM_SRC/LLVM/CMakeLists.txt" ]; then
    cat >&2 <<EOF
build-llvm: $LLVM_SRC is on a CASE-INSENSITIVE filesystem
            ("$LLVM_SRC/LLVM/CMakeLists.txt" resolves, so llvm/ == LLVM/)

LLVM cannot be built from a case-insensitive checkout. Put the fork on the
case-sensitive volume and re-clone there:
    scripts/forks-volume.sh create     # first time
    scripts/forks-volume.sh status     # confirms case sensitivity
EOF
    exit 1
fi

BUILD_DIR="${LLVM_BUILD_DIR:-$LLVM_SRC/build-minixrs}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"

CMAKE_EXTRA=()
# ccache pays for itself across the patch/rebuild loop, but is not a
# prerequisite — a machine without it just builds cold.
if command -v ccache >/dev/null 2>&1; then
    CMAKE_EXTRA+=(
        -DCMAKE_C_COMPILER_LAUNCHER=ccache
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    )
    echo "build-llvm: using ccache"
fi

# Assertions stay ON while the fork is young — the minixrs driver/target code
# is new and assertion failures beat silent miscompiles. Flip to OFF once M2
# has been stable for a while and build time starts to matter.
#
# Tests stay ON: check-clang-driver and the TargetParser unit tests are the M2
# gate. Benchmarks and examples are not, so they go.
#
# LLVM_PARALLEL_LINK_JOBS caps concurrent links: Release+assertions link steps
# are memory-hungry, and $JOBS of them at once is how you swap a 36 GiB
# machine to death.
cmake -G Ninja -S "$LLVM_SRC/llvm" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$MINIXRS_SDK" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_PARALLEL_LINK_JOBS="${LINK_JOBS:-4}" \
    -DCLANG_DEFAULT_LINKER=lld \
    ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"}

ninja -C "$BUILD_DIR" -j "$JOBS"
ninja -C "$BUILD_DIR" install

echo "build-llvm: installed into $MINIXRS_SDK"

if [ "$BASELINE" -eq 1 ]; then
    cat <<EOF
build-llvm: --baseline: skipping the driver smoke test.

This is an UNPATCHED tree — the driver does not know the triple yet, so
    clang --target=aarch64-unknown-minixrs
does not define __minixrs__ and has no MinixRS toolchain. That is expected.
The patch series is docs/plans/llvm-m2.md; re-run this script without
--baseline once it has landed.
EOF
    exit 0
fi

echo "build-llvm: driver smoke test:"
"$MINIXRS_SDK/bin/clang" --target=aarch64-unknown-minixrs -dM -E -x c /dev/null \
    | grep -E '__minixrs__|__unix__' \
    || { echo "build-llvm: WARNING: __minixrs__ not defined — fork patches missing?" >&2; exit 1; }
