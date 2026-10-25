#!/usr/bin/env bash
#
# build-rust.sh — build the rust-minixrs fork's stage-1 toolchain (rustc plus
# std for aarch64-apple-darwin and aarch64-unknown-minixrs) against the SDK's
# LLVM, install it at $MINIXRS_SDK/rust, and link it with rustup as +minixrs.
#
# Prerequisites (roadmap P4b): the rust-minixrs checkout on branch
# minixrs/$MINIXRS_NIGHTLY, inside $MINIXRS_FORKS_DIR; the SDK's clang and LLVM
# from scripts/build-llvm.sh; and the pinned nightly installed with rustup,
# whose cargo is installed beside the stage-1 compiler (bootstrap's stage 1
# builds none, and rustup's fallback for a linked toolchain is whatever
# `nightly` the machine has).
#
# Usage: build-rust.sh [--force]     (--force rebuilds even if .stamp matches)
#
# Knobs: RUST_MINIXRS_SRC        the checkout (default $MINIXRS_FORKS_DIR/rust-minixrs)
#        RUST_MINIXRS_BUILD_DIR  bootstrap.toml and bootstrap's build/
#                                (default $MINIXRS_FORKS_DIR/build/rust-minixrs)
#        MINIXRS_RUST_TOOLCHAIN  the rustup name to link (default minixrs)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/env.sh"

FORCE=0
case "${1:-}" in
    --force) FORCE=1 ;;
    "") ;;
    *) echo "usage: build-rust.sh [--force]" >&2; exit 2 ;;
esac

RUST_SRC="${RUST_MINIXRS_SRC:-$MINIXRS_FORKS_DIR/rust-minixrs}"
# Outside the checkout, like build-musl.sh's: bootstrap.toml is generated, and
# the build tree has no business in the fork's `git status`.
BUILD_ROOT="${RUST_MINIXRS_BUILD_DIR:-$MINIXRS_FORKS_DIR/build/rust-minixrs}"
BT="$BUILD_ROOT/bootstrap.toml"
TOOLCHAIN="${MINIXRS_RUST_TOOLCHAIN:-minixrs}"
RUST_DIR="$MINIXRS_SDK/rust"
STAMP="$RUST_DIR/.stamp"
HOST=aarch64-apple-darwin
LLVM_CONFIG="$MINIXRS_SDK/bin/llvm-config"

# ---------------------------------------------------------------------------
# Guards. Each is a precondition that would otherwise surface minutes into the
# build, or not at all; all of them run before anything is written.
# ---------------------------------------------------------------------------

# G1: the checkout.
if [ ! -f "$RUST_SRC/x.py" ]; then
    cat >&2 <<EOF
build-rust: rust-minixrs source not found at $RUST_SRC

Clone the fork first (docs/roadmap.md P4b), or point RUST_MINIXRS_SRC at an
existing checkout.
If the forks volume is simply unmounted: scripts/forks-volume.sh mount
EOF
    exit 1
fi

# G2: case sensitivity, asked the way build-llvm.sh asks it. x.py exists; if
# the UPPERCASE spelling resolves too, the filesystem folded the case.
if [ -f "$RUST_SRC/X.py" ]; then
    cat >&2 <<EOF
build-rust: $RUST_SRC is on a CASE-INSENSITIVE filesystem
            ("$RUST_SRC/X.py" resolves, so x.py == X.py)

The Rust tree cannot be built from a case-insensitive checkout. Put the fork
on the case-sensitive volume and re-clone there:
    scripts/forks-volume.sh create     # first time
    scripts/forks-volume.sh status     # confirms case sensitivity
EOF
    exit 1
fi

# G3: the SDK's LLVM (design R10) and the target tools bootstrap.toml names.
LLVM_VER="$("$LLVM_CONFIG" --version 2>/dev/null || true)"
case "$LLVM_VER" in
    22.1.*) ;;
    *)
        cat >&2 <<EOF
build-rust: $LLVM_CONFIG reports version '${LLVM_VER:-<none>}', not 22.1.x

rustc links the SDK's LLVM (design R10). Build it with scripts/build-llvm.sh.
EOF
        exit 1
        ;;
esac
for tool in aarch64-unknown-minixrs-clang llvm-ar llvm-ranlib; do
    if [ ! -x "$MINIXRS_SDK/bin/$tool" ]; then
        echo "build-rust: $MINIXRS_SDK/bin/$tool not found — run scripts/build-llvm.sh" >&2
        exit 1
    fi
done

# G4: the LLVM components rustc_llvm links, read from the checkout so a rebase
# that adds one is caught here rather than at rustc's link (spec, Risks). The
# array spans lines, hence the sed range.
REQUIRED="$(sed -n '/^const REQUIRED_COMPONENTS/,/;/p' "$RUST_SRC/compiler/rustc_llvm/build.rs" |
    grep -o '"[a-z0-9]*"' | tr -d '"' || true)"
if [ -z "$REQUIRED" ]; then
    cat >&2 <<EOF
build-rust: found no REQUIRED_COMPONENTS in $RUST_SRC/compiler/rustc_llvm/build.rs

The list's format has changed; update this script's parse.
EOF
    exit 1
fi
HAVE=" $("$LLVM_CONFIG" --components) "
MISSING=""
for c in $REQUIRED aarch64; do
    case "$HAVE" in
        *" $c "*) ;;
        *) MISSING="$MISSING $c" ;;
    esac
done
if [ -n "$MISSING" ]; then
    cat >&2 <<EOF
build-rust: the SDK's LLVM lacks components rustc links:$MISSING

The fix is a scripts/build-llvm.sh flag that builds them (P4 design, Risks).
EOF
    exit 1
fi

# G5: the branch is the minixrs series on the pin. Ancestry alone is not
# enough: upstream history is all merge commits, so a branch rebased onto a
# newer upstream still has the pin as an ancestor, but brings merges with it.
if ! git -C "$RUST_SRC" merge-base --is-ancestor "$MINIXRS_RUST_BASE" HEAD 2>/dev/null \
    || [ "$(git -C "$RUST_SRC" rev-list --merges --count "$MINIXRS_RUST_BASE"..HEAD)" != 0 ]; then
    cat >&2 <<EOF
build-rust: $RUST_SRC HEAD is not the minixrs series on the pin
            (MINIXRS_RUST_BASE=$MINIXRS_RUST_BASE, $MINIXRS_NIGHTLY)

HEAD must descend from the pin through the fork's own commits only, with no
merge commit between them. A merge in that range means the branch sits on
newer upstream history; check out minixrs/$MINIXRS_NIGHTLY, or bump the pin
in scripts/env.sh.
EOF
    exit 1
fi

# G6: libc-minixrs pinned by tag (design R12). The tag and the commit Cargo
# resolved it to both go into the stamp.
LIBC_PIN="$(sed -n 's|^source = "git+https://github.com/minixrs/libc-minixrs?tag=\([^#"]*#[0-9a-f]*\)"$|\1|p' \
    "$RUST_SRC/library/Cargo.lock" 2>/dev/null | head -1)"
if [ -z "$LIBC_PIN" ]; then
    cat >&2 <<EOF
build-rust: $RUST_SRC/library/Cargo.lock does not take libc-minixrs by tag

std must take libc from a libc-minixrs tag (design R12), so that the stamp and
the build name one release.
EOF
    exit 1
fi

# G7: the pinned nightly's cargo, built from the fork's own src/tools/cargo.
if ! CARGO_BIN="$(rustup which --toolchain "$MINIXRS_NIGHTLY" cargo 2>/dev/null)"; then
    cat >&2 <<EOF
build-rust: no cargo for $MINIXRS_NIGHTLY

Install the pinned nightly; its cargo is installed beside the stage-1 compiler:
    rustup toolchain install $MINIXRS_NIGHTLY
EOF
    exit 1
fi
CARGO_HASH="$("$CARGO_BIN" -vV | sed -n 's/^commit-hash: //p')"
FORK_CARGO="$(git -C "$RUST_SRC" rev-parse HEAD:src/tools/cargo)"
if [ "$CARGO_HASH" != "$FORK_CARGO" ]; then
    cat >&2 <<EOF
build-rust: $MINIXRS_NIGHTLY's cargo is not the fork's
    $CARGO_BIN: commit-hash ${CARGO_HASH:-<none>}
    $RUST_SRC src/tools/cargo: $FORK_CARGO
EOF
    exit 1
fi

RUST_HEAD="$(git -C "$RUST_SRC" rev-parse HEAD)"
CLANG_ID="$("$MINIXRS_SDK/bin/clang" --version | head -1)"
WANT="rust=$RUST_HEAD libc=$LIBC_PIN clang=$CLANG_ID"

link_toolchain() {
    rustup toolchain link "$TOOLCHAIN" "$RUST_DIR"
}

# ---------------------------------------------------------------------------
# Freshness. The stamp keys on the fork commit, the libc-minixrs tag and the
# commit it resolved to, and the compiler identity — the same reasoning as
# build-musl.sh's. The relink is cheap and repairs a toolchain someone
# unlinked.
# ---------------------------------------------------------------------------
if [ "$FORCE" -eq 0 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ] \
    && [ -x "$RUST_DIR/bin/rustc" ] && [ -x "$RUST_DIR/bin/cargo" ]; then
    link_toolchain
    echo "build-rust: toolchain up to date ($RUST_DIR)"
    echo "build-rust: $WANT"
    exit 0
fi

echo "build-rust: building $RUST_SRC ($RUST_HEAD) -> $RUST_DIR"

# ---------------------------------------------------------------------------
# bootstrap.toml, outside the checkout. The SDK's llvm-config (R10), stage 1
# (R8), both targets, and the SDK's tools for the minixrs one.
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_ROOT"
cat > "$BT" <<EOF
# Generated by tooling's scripts/build-rust.sh — edits are overwritten.
change-id = "ignore"

[llvm]
download-ci-llvm = false

[build]
build-dir = "$BUILD_ROOT/build"
target = ["$HOST", "aarch64-unknown-minixrs"]
docs = false
extended = false

[rust]
download-rustc = false
channel = "nightly"
lld = false

# The SDK's LLVM (design R10); rustc links it through llvm-config.
[target.$HOST]
llvm-config = "$LLVM_CONFIG"

[target.aarch64-unknown-minixrs]
cc = "$MINIXRS_SDK/bin/aarch64-unknown-minixrs-clang"
ar = "$MINIXRS_SDK/bin/llvm-ar"
ranlib = "$MINIXRS_SDK/bin/llvm-ranlib"
linker = "$MINIXRS_SDK/bin/aarch64-unknown-minixrs-clang"
EOF

# ---------------------------------------------------------------------------
# Build. The caller's search paths and flags are unset: clang searches
# CPATH/C_INCLUDE_PATH before --sysroot, and adds LIBRARY_PATH as a -L to every
# link, minixrs cross links included (spec, P4c). Unset, not set empty:
# bootstrap passes its own flags to cargo through RUSTFLAGS, and an empty
# CARGO_ENCODED_RUSTFLAGS would override them (CLAUDE.md).
# ---------------------------------------------------------------------------
( cd "$RUST_SRC" && env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
    -u LIBRARY_PATH -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS -u CARGO_BUILD_RUSTFLAGS \
    ./x build --stage 1 library --config "$BT" )

# ---------------------------------------------------------------------------
# Verify, then install. A stage-1 compiler from another checkout — an older
# build left in the build dir — is refused before the SDK is touched.
# ---------------------------------------------------------------------------
S1="$BUILD_ROOT/build/$HOST/stage1"
S1_VV="$("$S1/bin/rustc" -vV 2>/dev/null || true)"
if ! printf '%s\n' "$S1_VV" | grep -qx "commit-hash: $RUST_HEAD" \
    || ! printf '%s\n' "$S1_VV" | grep -q '^LLVM version: 22\.1\.'; then
    cat >&2 <<EOF
build-rust: the stage-1 compiler is not this checkout's
    want: commit-hash: $RUST_HEAD, LLVM version: 22.1.x
    $S1/bin/rustc -vV says:
$(printf '%s\n' "$S1_VV" | sed 's/^/        /')
EOF
    exit 1
fi

rm -rf "${MINIXRS_SDK:?}/rust"
cp -R "$S1" "$RUST_DIR"
# Symlinks into the checkout: they dangle whenever the forks volume is
# unmounted (R9), and nothing in M5 reads them.
rm -rf "$RUST_DIR/lib/rustlib/src" "$RUST_DIR/lib/rustlib/rustc-src"
cp "$CARGO_BIN" "$RUST_DIR/bin/cargo"

link_toolchain

# Last, so an interrupted install rebuilds.
printf '%s\n' "$WANT" > "$STAMP"

echo "build-rust: installed into $RUST_DIR, linked as +$TOOLCHAIN"
echo "build-rust: next: verify/check-rust.sh"
