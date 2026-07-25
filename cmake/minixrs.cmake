# CMake toolchain file for aarch64-unknown-minixrs (static ELF userland).
#
# Usage:
#   cmake -DCMAKE_TOOLCHAIN_FILE=<tooling>/cmake/minixrs.cmake ...
#
# Expects the SDK at $MINIXRS_SDK (default ~/toolchains/minixrs): the fork
# clang/lld from scripts/build-llvm.sh and the musl sysroot from
# scripts/build-sysroot.sh. Layout contract: docs/sysroot-layout.md.

if(DEFINED ENV{MINIXRS_SDK})
    set(MINIXRS_SDK "$ENV{MINIXRS_SDK}")
else()
    set(MINIXRS_SDK "$ENV{HOME}/toolchains/minixrs")
endif()

# "Generic" keeps CMake from assuming a hosted platform it knows; minixrs is
# not (yet) in CMake's platform list.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(MINIXRS_TRIPLE aarch64-unknown-minixrs)

set(CMAKE_C_COMPILER   "${MINIXRS_SDK}/bin/clang")
set(CMAKE_CXX_COMPILER "${MINIXRS_SDK}/bin/clang++")
set(CMAKE_ASM_COMPILER "${MINIXRS_SDK}/bin/clang")
set(CMAKE_C_COMPILER_TARGET   ${MINIXRS_TRIPLE})
set(CMAKE_CXX_COMPILER_TARGET ${MINIXRS_TRIPLE})
set(CMAKE_ASM_COMPILER_TARGET ${MINIXRS_TRIPLE})

set(CMAKE_SYSROOT "${MINIXRS_SDK}/sysroot")

# Static-only platform: no shared objects exist (docs/sysroot-layout.md).
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "minixrs is static-only" FORCE)

# Probe with a static library so try_compile never needs to run (or fully
# link) a target executable on the build host.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
