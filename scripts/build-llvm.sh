#!/usr/bin/env bash
#
# build-llvm.sh — configure, build, and install clang + lld from the
# llvm-minixrs fork (AArch64 only) into $MINIXRS_SDK.
#
# Prerequisite (roadmap P2): the llvm-minixrs sibling checkout on branch
# minixrs/release/22.x. Override its location with LLVM_MINIXRS_SRC, the
# build dir with LLVM_BUILD_DIR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SIBLINGS_DIR="${MINIXRS_FORKS_DIR:-$(dirname "$REPO_ROOT")}"
. "$SCRIPT_DIR/env.sh"

LLVM_SRC="${LLVM_MINIXRS_SRC:-$SIBLINGS_DIR/llvm-minixrs}"

if [ ! -f "$LLVM_SRC/llvm/CMakeLists.txt" ]; then
    cat >&2 <<EOF
build-llvm: llvm-minixrs source not found at $LLVM_SRC

Clone the fork first (docs/roadmap.md P2):
    git clone --branch minixrs/release/22.x <llvm-minixrs-url> "$LLVM_SRC"
or point LLVM_MINIXRS_SRC at an existing checkout.
EOF
    exit 1
fi

BUILD_DIR="${LLVM_BUILD_DIR:-$LLVM_SRC/build-minixrs}"

# Assertions stay ON while the fork is young — the minixrs driver/target code
# is new and assertion failures beat silent miscompiles. Flip to OFF once M2
# has been stable for a while and build time starts to matter.
cmake -G Ninja -S "$LLVM_SRC/llvm" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$MINIXRS_SDK" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DCLANG_DEFAULT_LINKER=lld

ninja -C "$BUILD_DIR"
ninja -C "$BUILD_DIR" install

echo "build-llvm: installed into $MINIXRS_SDK"
echo "build-llvm: driver smoke test:"
"$MINIXRS_SDK/bin/clang" --target=aarch64-unknown-minixrs -dM -E -x c /dev/null \
    | grep -E '__minixrs__|__unix__' \
    || { echo "build-llvm: WARNING: __minixrs__ not defined — fork patches missing?" >&2; exit 1; }
