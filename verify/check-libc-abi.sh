#!/usr/bin/env bash
#
# check-libc-abi.sh — the P4a gate: does libc-minixrs agree with the C headers?
#
# From verify/libc-abi/items.list this generates two emitters — C, compiled by
# the SDK clang against the SDK sysroot, and Rust, compiled against
# libc-minixrs — that each write the same ordered table of sizes, alignments,
# field offsets and constants into a .minixrs_abi section. The two sections
# are compared byte for byte.
#
# It also enforces coverage: every public type, struct, union, enum, static,
# const and re-exported (`pub use`) name in libc-minixrs' minixrs modules (src/unix/minixrs/ and, when present,
# src/new/minixrs/) must be in items.list or in allow.list, and neither module
# may carry #[cfg] or #![cfg]. Function declarations are not checked — a
# signature has no layout to compare — and the PASS line says how many.
#
# Exit: 0 parity; 1 a mismatch or an uncovered item; 2 a build or usage error.
#
# Knobs:
#   MINIXRS_LIBC_DIR   the libc-minixrs checkout
#                      (default $MINIXRS_FORKS_DIR/libc-minixrs)
#   MINIXRS_NIGHTLY    rustup toolchain for the Rust side
#                      (default nightly-2026-07-23 — minixrs' pin; needs rust-src)
#
# The Rust side uses -Zbuild-std=core and verify/testdata's test-only target
# JSON, so this gate does not need rust-minixrs to exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/env.sh
. "$SCRIPT_DIR/../scripts/env.sh"

ABI_DIR="$SCRIPT_DIR/libc-abi"
TARGET_JSON="$SCRIPT_DIR/testdata/aarch64-unknown-minixrs-unix.json"
LIBC_DIR="${MINIXRS_LIBC_DIR:-$MINIXRS_FORKS_DIR/libc-minixrs}"
NIGHTLY="${MINIXRS_NIGHTLY:-nightly-2026-07-23}"
MODULE_DIR="$LIBC_DIR/src/unix/minixrs"
# Every directory whose definitions reach the crate root as minixrs's own.
# src/new/minixrs/ is upstream libc's preferred home for new definitions, so
# anything added there is held to the same coverage rule.
MODULE_DIRS=("$MODULE_DIR")
[ -d "$LIBC_DIR/src/new/minixrs" ] && MODULE_DIRS+=("$LIBC_DIR/src/new/minixrs")

die() { echo "check-libc-abi: $*" >&2; exit 2; }

[ -x "$MINIXRS_SDK/bin/clang" ] ||
    die "no clang at $MINIXRS_SDK/bin/clang — run scripts/build-llvm.sh"
[ -x "$MINIXRS_SDK/bin/llvm-objcopy" ] ||
    die "no llvm-objcopy at $MINIXRS_SDK/bin — run scripts/build-llvm.sh"
[ -f "$MINIXRS_SDK/sysroot/usr/include/stdlib.h" ] ||
    die "no sysroot headers under $MINIXRS_SDK/sysroot — run scripts/build-sysroot.sh"
[ -f "$MODULE_DIR/mod.rs" ] ||
    die "no $MODULE_DIR/mod.rs — is the forks volume mounted (scripts/forks-volume.sh mount) and libc-minixrs cloned?"
cargo "+$NIGHTLY" --version >/dev/null 2>&1 ||
    die "rustup toolchain $NIGHTLY is not installed"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- coverage: nothing in the modules escapes the manifest -------------------
listed() {
    awk '$1 ~ /^(int|type|const|struct|union|typedef)$/ { print $2 }' "$ABI_DIR/items.list"
    awk '!/^[ \t]*(#|$)/ { print $1 }' "$ABI_DIR/allow.list"
}
module_source() { find "${MODULE_DIRS[@]}" -name '*.rs' -exec cat {} +; }
# Attributes may share the item's line (`#[doc(hidden)] pub type …`). A
# `pub const fn` is a function, not a constant: it extracts as the name "fn"
# and is dropped here, then counted with the other functions below.
module_source |
    sed -nE 's/^[[:space:]]*(#\[[^]]*\][[:space:]]*)*pub[[:space:]]+(unsafe[[:space:]]+)?(type|struct|union|enum|static|const)[[:space:]]+(mut[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*).*/\5/p' |
    grep -vx 'fn' > "$work/defined" || true
# A `pub use` publishes a name as surely as a `pub const` does — src/new/
# minixrs/unistd.rs consists of nothing else — so each re-exported name is a
# module item too (its alias, for `X as Y`). A glob from outside the modules
# cannot be enumerated, so it is refused; `self::…::*` is fine, because the
# submodule it names is scanned directly.
module_source | sed 's://.*$::' | tr '\n' ' ' |
    { grep -oE 'pub[[:space:]]+use[[:space:]]+[^;]*;' || true; } |
    awk '
        function emit(item, whole,    seg, n) {
            gsub(/^ +| +$/, "", item)
            if (item == "") return
            if (item ~ / as /) { sub(/.* as /, "", item); print item; return }
            if (item ~ /\*$/) { if (whole !~ /^self::/) print "!glob " whole; return }
            n = split(item, seg, "::"); print seg[n]
        }
        {
            s = $0
            sub(/^pub[ \t]+use[ \t]+/, "", s); sub(/;$/, "", s); gsub(/[ \t]+/, " ", s)
            if (index(s, "{")) {
                inner = s; sub(/^[^{]*\{/, "", inner); sub(/\}[^}]*$/, "", inner)
                if (index(inner, "{")) { print "!nested " s; next }
                n = split(inner, part, ",")
                for (i = 1; i <= n; i++) emit(part[i], s)
            } else emit(s, s)
        }' > "$work/reexported"
if grep -q '^!' "$work/reexported"; then
    echo "check-libc-abi: a re-export whose names coverage cannot enumerate:" >&2
    sed -n 's/^!/  /p' "$work/reexported" >&2
    exit 1
fi
cat "$work/reexported" >> "$work/defined"
sort -u -o "$work/defined" "$work/defined"
listed | sort -u > "$work/listed"
[ -s "$work/defined" ] || die "found no public definitions under $MODULE_DIR"
# Coverage is by name, so one name must mean one definition. A #[cfg] in a
# module could hide a second, unchecked definition behind a checked one; the
# modules are aarch64-only and have no reason to carry one, inner or outer.
if grep -rnE '#!?\[cfg(_attr)?\(' "${MODULE_DIRS[@]}" >&2; then
    echo "check-libc-abi: a minixrs module carries #[cfg] — coverage by name cannot see past it" >&2
    exit 1
fi
comm -23 "$work/defined" "$work/listed" > "$work/uncovered"
if [ -s "$work/uncovered" ]; then
    echo "check-libc-abi: defined in ${MODULE_DIRS[*]} but in neither items.list nor allow.list:" >&2
    sed 's/^/  /' "$work/uncovered" >&2
    exit 1
fi

# --- generate both emitters from the one manifest ----------------------------
mkdir -p "$work/rs/src"
awk -v c="$work/table.c" -v rs="$work/rs/src/lib.rs" -v labels="$work/labels" \
    -f "$ABI_DIR/gen.awk" "$ABI_DIR/items.list" || die "items.list did not parse"

# --- C side -------------------------------------------------------------------
# _GNU_SOURCE because the libc crate mirrors musl's full view of each header
# (tm_gmtoff, Dl_info), not the strict-ISO one. The include-path variables are
# cleared because clang searches them BEFORE the sysroot: an ambient header
# would otherwise stand in for musl's on the C side of the comparison.
env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH \
    "$MINIXRS_SDK/bin/clang" --target=aarch64-unknown-minixrs -std=gnu11 -D_GNU_SOURCE \
    -Wall -Werror -c "$work/table.c" -o "$work/table.c.o" ||
    die "the C emitter did not compile — a manifest item the headers do not have?"

# --- Rust side ----------------------------------------------------------------
cat > "$work/rs/Cargo.toml" <<TOML
[package]
name = "minixrs-abi-table"
version = "0.0.0"
edition = "2021"

[dependencies]
libc = { path = "$LIBC_DIR", default-features = false }

[workspace]
TOML
(
    cd "$work/rs"
    # The ambient environment must not leak flags into a layout comparison.
    # CARGO_ENCODED_RUSTFLAGS set-but-empty outranks every other rustflags
    # source — RUSTFLAGS, CARGO_BUILD_RUSTFLAGS, and [build]/[target] rustflags
    # in any config.toml — where unsetting it would let those through. An empty
    # CARGO_BUILD_RUSTC_WRAPPER likewise disables a configured wrapper.
    export CARGO_ENCODED_RUSTFLAGS=''
    export CARGO_BUILD_RUSTC_WRAPPER='' CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER=''
    unset RUSTFLAGS CARGO_BUILD_RUSTFLAGS CARGO_BUILD_TARGET CARGO_BUILD_RUSTC \
        RUSTC RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER
    CARGO_TARGET_DIR="$work/target" cargo "+$NIGHTLY" rustc --quiet --release \
        -Zbuild-std=core --target "$TARGET_JSON" -- --emit=obj -C codegen-units=1
) || die "the Rust emitter did not compile — a manifest item libc-minixrs does not have?"

rs_obj="$(find "$work/target" -name 'minixrs_abi_table-*.o' | head -n 1)"
[ -n "$rs_obj" ] || die "cargo produced no minixrs_abi_table object"

# --- compare ------------------------------------------------------------------
"$MINIXRS_SDK/bin/llvm-objcopy" -O binary --only-section=.minixrs_abi "$work/table.c.o" "$work/c.bin"
"$MINIXRS_SDK/bin/llvm-objcopy" -O binary --only-section=.minixrs_abi "$rs_obj" "$work/rs.bin"
"$ABI_DIR/compare.sh" "$work/c.bin" "$work/rs.bin" "$work/labels"
# Say what was NOT checked, so a PASS is not read as covering signatures.
fns="$(module_source | grep -cE '^[[:space:]]*pub[[:space:]]+((const|unsafe|safe|extern([[:space:]]+"[^"]*")?)[[:space:]]+)*fn[[:space:]]' || true)"
echo "check-libc-abi: PASS ($(wc -l < "$work/defined" | tr -d ' ') module items covered; $fns function declarations not checked)"
