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
. "$SCRIPT_DIR/env.sh"

LLVM_SRC="${LLVM_MINIXRS_SRC:-$MINIXRS_FORKS_DIR/llvm-minixrs}"
CLANG="$MINIXRS_SDK/bin/clang"
TRIPLE=aarch64-unknown-minixrs

if [ ! -d "$LLVM_SRC/compiler-rt" ]; then
    echo "build-compiler-rt: compiler-rt source not found at $LLVM_SRC/compiler-rt" >&2
    echo "build-compiler-rt: clone llvm-minixrs first (see scripts/build-llvm.sh)" >&2
    echo "build-compiler-rt: if the forks volume is unmounted: scripts/forks-volume.sh mount" >&2
    exit 1
fi
if [ ! -x "$CLANG" ]; then
    echo "build-compiler-rt: $CLANG not found — run scripts/build-llvm.sh first" >&2
    exit 1
fi

RESOURCE_DIR="$("$CLANG" --print-resource-dir)"
BUILD_DIR="${COMPILER_RT_BUILD_DIR:-$LLVM_SRC/build-compiler-rt-minixrs}"

# The source is compiler-rt/lib/builtins, not compiler-rt: that subdirectory
# is a standalone CMake project, and entering there skips the full project's
# load_llvm_config(). Going in at the top instead pulls in the *host* LLVM's
# LLVMExports.cmake, which declares SHARED targets and hard-errors under a
# CMAKE_SYSTEM_NAME that has no dynamic linking — which is every correct
# configuration for this target.
SRC_DIR="$LLVM_SRC/compiler-rt/lib/builtins"

# Reconfiguring in place is not enough here, and the failures are all quiet
# ones. CMake will not retarget an existing cache (CMAKE_SYSTEM_NAME and the
# source directory are fixed once set), and compiler-rt caches its *derived*
# install path as a CACHE PATH, so flipping LLVM_ENABLE_PER_TARGET_RUNTIME_DIR
# on a stale cache re-runs the build and installs to the old layout anyway.
# Check the derived value, not just the inputs, and start clean on any
# mismatch. Observed failure modes: a host-configured cache builds
# clang_rt.osx and says "no work to do"; a pre-per-target cache installs to
# lib/generic/ where the driver will never look.
cache_ok() {
    [ -f "$BUILD_DIR/CMakeCache.txt" ] || return 1
    grep -q '^CMAKE_SYSTEM_NAME:.*=Generic$' "$BUILD_DIR/CMakeCache.txt" &&
    grep -qF "CMAKE_HOME_DIRECTORY:INTERNAL=$SRC_DIR" "$BUILD_DIR/CMakeCache.txt" &&
    grep -qF "CMAKE_INSTALL_PREFIX:PATH=$RESOURCE_DIR" "$BUILD_DIR/CMakeCache.txt" &&
    # Relative to CMAKE_INSTALL_PREFIX, and the discriminator between the two
    # layout branches: "lib" is per-target, "lib/generic" is the legacy one.
    grep -q '^COMPILER_RT_INSTALL_LIBRARY_DIR:PATH=lib$' "$BUILD_DIR/CMakeCache.txt"
}
if [ -d "$BUILD_DIR" ] && ! cache_ok; then
    echo "build-compiler-rt: $BUILD_DIR was configured differently — reconfiguring from scratch"
    rm -rf "$BUILD_DIR"
fi

# Builtins only, for exactly this target, freestanding probes (no sysroot
# exists yet when this first runs — try_compile must not attempt a full
# link). Installs under the resource dir's per-target lib directory, which
# is where the fork driver looks for libclang_rt.builtins.a.
#
# LLVM_ENABLE_PER_TARGET_RUNTIME_DIR selects the layout the clang driver
# actually searches: lib/<triple>/libclang_rt.builtins.a. Without it the
# install lands in the legacy lib/generic/libclang_rt.builtins-<arch>.a, which
# builds fine and then never gets found. LLVM_DEFAULT_TARGET_TRIPLE names the
# <triple> directory, and is not inferred from CMAKE_C_COMPILER_TARGET here.
#
# CMAKE_DISABLE_FIND_PACKAGE_LLVM stops load_llvm_config() finding the SDK's
# own LLVM. env.sh puts $MINIXRS_SDK/bin on PATH, CMake derives package search
# prefixes from PATH, and the resulting LLVMExports.cmake declares SHARED
# targets that a no-dynamic-linking platform rejects. Builtins only wants that
# package for XRay and testing support, neither of which is built here;
# load_llvm_config() warns and carries on without it.
#
# CMAKE_SYSTEM_NAME=Generic is what makes this a cross build.
# CMAKE_C_COMPILER_TARGET alone does not: CMAKE_SYSTEM_NAME then defaults to
# the host, so on macOS compiler-rt sees APPLE and builds Darwin builtins for
# a target that is neither. Generic is the standard pairing for
# COMPILER_RT_BAREMETAL_BUILD, which is the right posture until P3 gives the
# target a sysroot.
cmake -G Ninja -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_INSTALL_PREFIX="$RESOURCE_DIR" \
    -DCMAKE_C_COMPILER="$CLANG" \
    -DCMAKE_C_COMPILER_TARGET="$TRIPLE" \
    -DCMAKE_ASM_COMPILER="$CLANG" \
    -DCMAKE_ASM_COMPILER_TARGET="$TRIPLE" \
    -DCMAKE_CXX_COMPILER="$MINIXRS_SDK/bin/clang++" \
    -DCMAKE_CXX_COMPILER_TARGET="$TRIPLE" \
    -DCMAKE_AR="$MINIXRS_SDK/bin/llvm-ar" \
    -DCMAKE_RANLIB="$MINIXRS_SDK/bin/llvm-ranlib" \
    -DCMAKE_NM="$MINIXRS_SDK/bin/llvm-nm" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_DISABLE_FIND_PACKAGE_LLVM=ON \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$TRIPLE" \
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

# Every member must be an ELF aarch64 object. A missed *_COMPILER_TARGET lets
# one language build for the host instead, and the archive still installs:
# ld.lld only warns ("neither ET_REL nor LLVM bitcode") and silently drops the
# member, so whatever it defined goes missing at link time rather than here.
#
# The check has to fail *closed*. Counting only mismatches is not enough: a
# missing llvm-objdump, a read error, or an empty archive each yield zero
# lines, therefore zero mismatches, therefore a cheerful pass — which is the
# same quiet-success class this check exists to catch. So require a positive
# count of good members as well, and let objdump's own errors through.
OBJDUMP="$MINIXRS_SDK/bin/llvm-objdump"
if [ ! -x "$OBJDUMP" ]; then
    echo "build-compiler-rt: $OBJDUMP is missing or not executable — cannot verify $LIB" >&2
    exit 1
fi
FORMATS="$("$OBJDUMP" -f "$LIB" | grep "file format" || true)"
GOOD="$(printf '%s\n' "$FORMATS" | grep -c "elf64-littleaarch64" || true)"
BAD="$(printf '%s\n' "$FORMATS" | grep -v "elf64-littleaarch64" | grep -c "file format" || true)"
if [ "$GOOD" -lt 1 ] || [ "$BAD" -ne 0 ]; then
    echo "build-compiler-rt: $LIB failed verification — $GOOD elf64-littleaarch64 member(s), $BAD other" >&2
    printf '%s\n' "$FORMATS" | grep -v "elf64-littleaarch64" >&2
    exit 1
fi
echo "build-compiler-rt: installed $LIB ($GOOD members, all elf64-littleaarch64)"
