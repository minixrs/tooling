#!/usr/bin/env bash
#
# build-sysroot.sh — assemble and validate the minixrs sysroot (roadmap P3):
#
#   1. build + install musl (scripts/build-musl.sh) unless --skip-musl
#   2. sanity-check the installed layout (docs/sysroot-layout.md)
#   3. run the minixrs gen-c-headers ABI selftest against the real sysroot
#   4. link a static hello world with the SDK clang and verify its brand
#
# The hello ELF is installed at $MINIXRS_SDK/share/minixrs/hello — minixrs
# sessions use it as a canned exec-test artifact (M3 gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SIBLINGS_DIR="${MINIXRS_FORKS_DIR:-$(dirname "$REPO_ROOT")}"
. "$SCRIPT_DIR/env.sh"

CLANG="$MINIXRS_SDK/bin/clang"
TRIPLE=aarch64-unknown-minixrs
SYSROOT="$MINIXRS_SDK/sysroot"

SKIP_MUSL=0
[ "${1:-}" = "--skip-musl" ] && SKIP_MUSL=1

if [ ! -x "$CLANG" ]; then
    echo "build-sysroot: $CLANG not found — run scripts/build-llvm.sh first" >&2
    exit 1
fi

if [ "$SKIP_MUSL" -eq 0 ]; then
    "$SCRIPT_DIR/build-musl.sh"
fi

for f in usr/lib/libc.a usr/lib/crt1.o usr/lib/crti.o usr/lib/crtn.o usr/include/stdio.h; do
    if [ ! -f "$SYSROOT/$f" ]; then
        echo "build-sysroot: missing $SYSROOT/$f — musl install incomplete?" >&2
        exit 1
    fi
done

# ABI selftest: minixrs' gen-c-headers diffs its generated ABI constants
# against the sysroot headers. The exact CLI is finalized in the minixrs repo
# (phase-5 slices 5.4+); override the whole command with MINIXRS_ABI_SELFTEST
# if it has moved.
MINIXRS_SRC="${MINIXRS_SRC:-$SIBLINGS_DIR/minixrs}"
if [ -n "${MINIXRS_ABI_SELFTEST:-}" ]; then
    if eval "$MINIXRS_ABI_SELFTEST"; then
        echo "build-sysroot: ABI selftest passed"
    else
        echo "build-sysroot: ABI selftest FAILED" >&2
        exit 1
    fi
elif [ -d "$MINIXRS_SRC/tools/gen-c-headers" ]; then
    if (cd "$MINIXRS_SRC" && cargo run -q -p gen-c-headers -- --check-sysroot "$SYSROOT"); then
        echo "build-sysroot: ABI selftest passed"
    else
        echo "build-sysroot: ABI selftest FAILED" >&2
        exit 1
    fi
else
    echo "build-sysroot: WARNING: gen-c-headers not found under $MINIXRS_SRC — ABI selftest skipped" >&2
fi

# Branded hello world: proves headers, crt objects, libc, driver defaults,
# and the crt1-carried brand all line up.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/hello.c" <<'EOF'
#include <stdio.h>

int main(void)
{
    printf("hello from the minixrs sysroot\n");
    return 0;
}
EOF

"$CLANG" --target="$TRIPLE" --sysroot="$SYSROOT" -static -o "$tmp/hello" "$tmp/hello.c"
"$REPO_ROOT/verify/check-brand.sh" "$tmp/hello"

mkdir -p "$MINIXRS_SDK/share/minixrs"
cp "$tmp/hello" "$MINIXRS_SDK/share/minixrs/hello"
echo "build-sysroot: branded hello installed at $MINIXRS_SDK/share/minixrs/hello"
