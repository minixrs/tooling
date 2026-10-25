#!/usr/bin/env bash
#
# check-rust.sh — the M5 gate as a script: does a bare
# `cargo +minixrs build --target aarch64-unknown-minixrs` link a branded,
# loadable hello?
#
#   1. the toolchain: rustc +minixrs reports $MINIXRS_SDK/rust as its sysroot,
#      and the target's cfg is the one P4b recorded
#   2. target features: rustc's set for the triple equals the one clang -###
#      passes
#   3. a bare cargo build: cargo +minixrs is the SDK's own, and a fresh
#      `cargo new` hello builds with nothing from the caller's environment
#   4. link closure: ET_EXEC, no undefined globals, and no unwinder but the
#      null one
#   5. brand and layout: check-brand.sh and check-image.sh accept it
#   6. install: the hello is copied to $MINIXRS_SDK/share/minixrs/hello-rs
#
# Every assertion of a step is reported, but a step with a failure ends the
# run: no later step runs, and an older hello-rs is removed, so a stale one is
# never presented as this toolchain's.
#
# Usage: check-rust.sh            uses toolchain minixrs and $MINIXRS_SDK/bin/clang
#        MINIXRS_RUST_TOOLCHAIN=<name> CLANG=/path/to/clang check-rust.sh
#
# Exit codes: 0 all checks passed / 1 a check failed / 3 environment problem
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../scripts/env.sh"

TC="${MINIXRS_RUST_TOOLCHAIN:-minixrs}"
CLANG="${CLANG:-$MINIXRS_SDK/bin/clang}"
T=aarch64-unknown-minixrs
RUST_DIR="$MINIXRS_SDK/rust"
HELLO_INSTALLED="$MINIXRS_SDK/share/minixrs/hello-rs"

# ---------------------------------------------------------- environment
if ! command -v rustup >/dev/null 2>&1; then
    echo "check-rust: rustup not found on PATH" >&2
    exit 3
fi
# Asked of rustc rather than matched in `rustup toolchain list`: a prefix match
# takes minixrs-old for minixrs, and an exact one misses nightly-2026-10-01,
# which rustup lists with its host suffix.
if ! rustc +"$TC" -V >/dev/null 2>&1; then
    echo "check-rust: toolchain $TC is not linked — run scripts/build-rust.sh" >&2
    exit 3
fi
if [ ! -x "$CLANG" ]; then
    echo "check-rust: $CLANG not found — run scripts/build-llvm.sh first" >&2
    exit 3
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
pass() { echo "check-rust: PASS $*"; }
bad()  { echo "check-rust: FAIL $*" >&2; fail=1; }
indent() { sed -e '/^$/d' -e 's/^/check-rust:   /' "$1" >&2; }
joined() { paste -sd " " - <<<"$1"; }

# A step with a failure ends the run, and takes an older hello-rs with it.
end_step() {
    if [ "$fail" -ne 0 ]; then
        if [ -f "$HELLO_INSTALLED" ]; then
            rm -f "$HELLO_INSTALLED"
            echo "check-rust: removed the stale $HELLO_INSTALLED" >&2
        fi
        exit 1
    fi
}

# Physical paths, so a symlinked prefix or rustup's toolchain link compares
# equal to what it points at. A path that does not resolve is returned as is.
resolve_dir()  { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
resolve_file() { printf '%s/%s\n' "$(resolve_dir "$(dirname "$1")")" "$(basename "$1")"; }

# ---------------------------------------------------------------- step 1
echo "check-rust: [1/6] the toolchain"
sysroot="$(rustc +"$TC" --print sysroot 2>/dev/null)" || sysroot="?"
have="$(resolve_dir "$sysroot")"
want="$(resolve_dir "$RUST_DIR")"
if [ "$have" = "$want" ]; then
    pass "rustc +$TC's sysroot is $RUST_DIR"
else
    bad "rustc +$TC's sysroot is $have, not $want"
fi

if ! rustc +"$TC" --print cfg --target "$T" >"$tmp/cfg" 2>"$tmp/cfg.err"; then
    indent "$tmp/cfg.err"
fi
for line in 'target_os="minixrs"' 'target_env=""' 'target_family="unix"' \
        'panic="abort"' 'target_feature="crt-static"'; do
    grep -Fxq "$line" "$tmp/cfg" \
        && pass "cfg $line" \
        || bad "cfg $line not reported for $T"
done
end_step

# ---------------------------------------------------------------- step 2
echo "check-rust: [2/6] target features"
spec="$(rustc +"$TC" -Z unstable-options --print target-spec-json --target "$T" 2>/dev/null)" || spec=""
rust_features="$(sed -n 's/^ *"features": *"\([^"]*\)",\{0,1\}$/\1/p' <<<"$spec" |
    tr ',' '\n' | sed '/^$/d' | sort)"
# -### writes the would-be commands to stderr and runs nothing. An ambient
# include path would not change the features, but keep clang's view the SDK's.
clang_line="$(env -u CPATH -u C_INCLUDE_PATH "$CLANG" --target="$T" -### -c -x c /dev/null -o /dev/null 2>&1)" ||
    clang_line=""
clang_features="$(grep -o '"-target-feature" "[^"]*"' <<<"$clang_line" |
    sed 's/^"-target-feature" "\(.*\)"$/\1/' | sort)" || clang_features=""
if [ -z "$rust_features" ]; then
    bad "rustc +$TC reports no target features for $T"
elif [ -z "$clang_features" ]; then
    bad "$CLANG passes no -target-feature for $T"
elif [ "$rust_features" = "$clang_features" ]; then
    pass "rustc and clang agree: $(joined "$rust_features")"
else
    bad "rustc ($(joined "$rust_features")) and clang ($(joined "$clang_features")) disagree on $T's features"
fi
end_step

# ---------------------------------------------------------------- step 3
echo "check-rust: [3/6] a bare cargo build"
# rustup falls back to another toolchain's cargo when a linked one has none.
cargo_path="$(rustup which --toolchain "$TC" cargo 2>/dev/null)" || cargo_path="?"
if [ "$(resolve_file "$cargo_path")" = "$(resolve_file "$RUST_DIR/bin/cargo")" ]; then
    pass "cargo +$TC is $RUST_DIR/bin/cargo"
else
    bad "cargo +minixrs is not the SDK's (rustup would fall back to another toolchain's): $cargo_path"
fi
end_step

# Nothing from the caller reaches the build:
#   env -i       drops RUSTFLAGS, CARGO_ENCODED_RUSTFLAGS, CARGO_TARGET_*_LINKER,
#                LIBRARY_PATH, C_INCLUDE_PATH and CPATH along with everything else
#   PATH         $MINIXRS_SDK/bin first, because rustc finds its linker,
#                aarch64-unknown-minixrs-clang (R2), through PATH; then rustup's
#                proxies, then the OS
#   CARGO_HOME   a fresh one, so ~/.cargo/config.toml is out of scope
#   RUSTUP_HOME  only if the caller set one, so rustup finds the same toolchains
clean_env=(env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" CARGO_HOME="$tmp/cargo-home"
    PATH="$MINIXRS_SDK/bin:$(dirname "$(command -v rustup)"):/usr/bin:/bin")
[ -n "${RUSTUP_HOME:-}" ] && clean_env+=(RUSTUP_HOME="$RUSTUP_HOME")

out="$tmp/hello-rs/target/$T/debug/hello-rs"
if ! (cd "$tmp" && "${clean_env[@]}" cargo +"$TC" new --vcs none hello-rs) >"$tmp/new.log" 2>&1; then
    indent "$tmp/new.log"
    bad "cargo +$TC new failed"
elif ! (cd "$tmp/hello-rs" && "${clean_env[@]}" cargo +"$TC" build --target "$T") >"$tmp/build.log" 2>&1; then
    indent "$tmp/build.log"
    bad "cargo +$TC build --target $T failed"
elif [ ! -f "$out" ]; then
    bad "cargo +$TC build --target $T left no $out"
else
    pass "cargo +$TC build --target $T linked a hello"
fi
end_step

# ---------------------------------------------------------------- step 4
echo "check-rust: [4/6] link closure"
header="$(llvm-readelf -h "$out" 2>&1)" || header=""
grep -Eq '^ *Type: +EXEC' <<<"$header" \
    && pass "ET_EXEC" \
    || bad "not ET_EXEC: $(grep -E '^ *Type:' <<<"$header" || echo 'no ELF header')"

# Columns: $5 binding, $7 section index, $8 name. musl's _DYNAMIC is a LOCAL
# hidden undefined, as in the C hello, and std's __cxa_thread_atexit_impl is
# WEAK; neither is GLOBAL, so neither counts.
syms="$(llvm-readelf -sW "$out" 2>/dev/null)" || syms=""
if [ -z "$syms" ]; then
    bad "llvm-readelf -sW read no symbol table from $out"
else
    und="$(awk '$7 == "UND" && $5 == "GLOBAL" { print $8 }' <<<"$syms" | sort -u)"
    if [ -z "$und" ]; then
        pass "no undefined global symbols"
    else
        bad "undefined global symbols: $(joined "$und")"
    fi
fi

# The null unwinder defines exactly these four; any other _Unwind_* means a
# real unwinder was linked.
defined="$(llvm-nm --defined-only "$out" 2>/dev/null)" || defined=""
unwind="$(awk '{ print $NF }' <<<"$defined" | grep '^_Unwind_' | sort -u)" || unwind=""
others="$(grep -vxE '_Unwind_(Backtrace|FindEnclosingFunction|GetCFA|GetIP)' <<<"$unwind")" || others=""
if [ -z "$defined" ]; then
    bad "llvm-nm --defined-only read no symbols from $out"
elif [ -z "$others" ]; then
    pass "no _Unwind_* but the null unwinder's ($(joined "$unwind"))"
else
    bad "_Unwind_* beyond the null unwinder's: $(joined "$others")"
fi
end_step

# ---------------------------------------------------------------- step 5
echo "check-rust: [5/6] brand and layout"
"$SCRIPT_DIR/check-brand.sh" "$out" \
    && pass "check-brand.sh accepts it" \
    || bad "the hello is not correctly branded (see above; the brand comes from musl's crt1.o)"
"$SCRIPT_DIR/check-image.sh" "$out" \
    && pass "check-image.sh accepts it" \
    || bad "the hello violates the kernel loader's rules (see above)"
end_step

# ---------------------------------------------------------------- step 6
echo "check-rust: [6/6] install"
mkdir -p "$MINIXRS_SDK/share/minixrs"
cp "$out" "$HELLO_INSTALLED"
echo "check-rust: hello-rs installed at $HELLO_INSTALLED"
echo "check-rust: all checks passed"
