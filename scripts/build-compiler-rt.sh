#!/usr/bin/env bash
#
# build-compiler-rt.sh — build compiler-rt builtins for
# aarch64-unknown-minixrs with the installed fork clang and install them into
# clang's per-target resource directory
# ($MINIXRS_SDK/lib/clang/<major>/lib/aarch64-unknown-minixrs/).
#
# Run scripts/build-llvm.sh first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SIBLINGS_DIR="${MINIXRS_FORKS_DIR:-$(dirname "$REPO_ROOT")}"
. "$SCRIPT_DIR/env.sh"

LLVM_SRC="${LLVM_MINIXRS_SRC:-$SIBLINGS_DIR/llvm-minixrs}"
CLANG="$MINIXRS_SDK/bin/clang"
TRIPLE=aarch64-unknown-minixrs

if [ ! -d "$LLVM_SRC/compiler-rt" ]; then
    echo "build-compiler-rt: compiler-rt source not found at $LLVM_SRC/compiler-rt" >&2
    echo "build-compiler-rt: clone llvm-minixrs first (see scripts/build-llvm.sh)" >&2
    exit 1
fi
if [ ! -x "$CLANG" ]; then
    echo "build-compiler-rt: $CLANG not found — run scripts/build-llvm.sh first" >&2
    exit 1
fi

RESOURCE_DIR="$("$CLANG" --print-resource-dir)"
BUILD_DIR="${COMPILER_RT_BUILD_DIR:-$LLVM_SRC/build-compiler-rt-minixrs}"

# Builtins only, for exactly this target, freestanding probes (no sysroot
# exists yet when this first runs — try_compile must not attempt a full
# link). Installs under the resource dir's per-target lib directory, which
# is where the fork driver looks for libclang_rt.builtins.a.
cmake -G Ninja -S "$LLVM_SRC/compiler-rt" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$RESOURCE_DIR" \
    -DCMAKE_C_COMPILER="$CLANG" \
    -DCMAKE_C_COMPILER_TARGET="$TRIPLE" \
    -DCMAKE_ASM_COMPILER="$CLANG" \
    -DCMAKE_ASM_COMPILER_TARGET="$TRIPLE" \
    -DCMAKE_AR="$MINIXRS_SDK/bin/llvm-ar" \
    -DCMAKE_RANLIB="$MINIXRS_SDK/bin/llvm-ranlib" \
    -DCMAKE_NM="$MINIXRS_SDK/bin/llvm-nm" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DLLVM_CMAKE_DIR="$MINIXRS_SDK/lib/cmake/llvm" \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BAREMETAL_BUILD=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF

ninja -C "$BUILD_DIR"
ninja -C "$BUILD_DIR" install

LIB="$RESOURCE_DIR/lib/$TRIPLE/libclang_rt.builtins.a"
if [ ! -f "$LIB" ]; then
    echo "build-compiler-rt: expected $LIB after install — layout drift?" >&2
    exit 1
fi
echo "build-compiler-rt: installed $LIB"
