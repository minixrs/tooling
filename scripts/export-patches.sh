#!/usr/bin/env bash
#
# export-patches.sh — export each fork's commit series into patches/<fork>/
# via git format-patch. Forks are rebase-maintained; re-export after every
# rebase so this repo always holds the current series.
#
# Usage: export-patches.sh [all|llvm|musl|rust|libc ...]     (default: all)
#
# Base refs (the upstream point each fork branched from) can be overridden:
#   MINIXRS_LLVM_BASE   default llvmorg-22.1.8   (the LLVM the pinned nightly
#                       reports; the fork branches from the tag, not the
#                       moving release/22.x head, so the exported series is
#                       reproducible)
#   MINIXRS_MUSL_BASE   default v1.2.5
#   MINIXRS_RUST_BASE   default 6f72b5dd5   (the minixrs rustc pin commit)
#   MINIXRS_LIBC_BASE   default upstream/main
#
# "all" skips forks that aren't cloned yet; naming a fork explicitly errors
# if it is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/env.sh"

export_fork() { # <name> <dir-basename> <base-ref> <required: 0|1>
    local name="$1" src="$MINIXRS_FORKS_DIR/$2" base="$3" required="$4"
    if [ ! -d "$src/.git" ]; then
        if [ "$required" -eq 1 ]; then
            echo "export-patches: no checkout at $src" >&2
            echo "export-patches: if the forks volume is unmounted: scripts/forks-volume.sh mount" >&2
            exit 1
        fi
        echo "export-patches: skipping $name — no checkout at $src"
        return 0
    fi
    local out="$REPO_ROOT/patches/$name"
    mkdir -p "$out"
    rm -f "$out"/*.patch
    git -C "$src" format-patch --output-directory "$out" "$base..HEAD" >/dev/null
    local count
    count="$(find "$out" -name '*.patch' | wc -l | tr -d ' ')"
    echo "export-patches: $name → $count patch(es) from $base..HEAD"
}

run_one() { # <name> <required>
    case "$1" in
        llvm) export_fork llvm llvm-minixrs "${MINIXRS_LLVM_BASE:-llvmorg-22.1.8}" "$2" ;;
        musl) export_fork musl musl-minixrs "${MINIXRS_MUSL_BASE:-v1.2.5}" "$2" ;;
        rust) export_fork rust rust-minixrs "${MINIXRS_RUST_BASE:-6f72b5dd5}" "$2" ;;
        libc) export_fork libc libc-minixrs "${MINIXRS_LIBC_BASE:-upstream/main}" "$2" ;;
        *)
            echo "export-patches: unknown fork '$1' (llvm|musl|rust|libc|all)" >&2
            exit 3
            ;;
    esac
}

if [ $# -eq 0 ] || [ "${1:-}" = "all" ]; then
    for f in llvm musl rust libc; do
        run_one "$f" 0
    done
else
    for f in "$@"; do
        run_one "$f" 1
    done
fi
