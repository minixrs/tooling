#!/usr/bin/env bash
#
# forks-volume.sh — manage the case-sensitive APFS volume that holds the
# minixrs fork checkouts.
#
# macOS' default Data volume is case-INsensitive, which breaks both the LLVM
# and the Rust source trees (llvm/ vs LLVM/, and rust's many case-colliding
# test fixtures). A sparsebundle disk image gives us a case-sensitive volume
# without repartitioning: the image is sparse, so the 150 GiB size below is a
# ceiling, not a footprint — it grows on demand and holds llvm-minixrs now
# plus rust-minixrs at P4.
#
# Usage: forks-volume.sh {create|mount|unmount|status}
#
#   create    make the sparsebundle (refuses if it exists), then mount
#   mount     attach it at $MINIXRS_FORKS_DIR — idempotent
#   unmount   detach, and remove the mountpoint if it is empty
#   status    exit 0 mounted / 1 not; prints case sensitivity and usage
#
# Overrides:
#   MINIXRS_FORKS_BUNDLE   image path      default ~/src/minixrs-forks.sparsebundle
#   MINIXRS_FORKS_DIR      mountpoint      default ~/src/minixrs-forks
#
# Moving the bundle to another disk (e.g. an external SSD if the internal
# gets tight) needs no change here — only MINIXRS_FORKS_BUNDLE moves.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/env.sh"

BUNDLE="${MINIXRS_FORKS_BUNDLE:-$HOME/src/minixrs-forks.sparsebundle}"
VOLNAME=minixrs-forks
SIZE=150g

is_mounted() {
    mount | grep -q " on $MINIXRS_FORKS_DIR "
}

# Empirical case-sensitivity probe: create a lowercase file and ask for the
# uppercase name back. Beats parsing `diskutil info`, and it tests the path
# actually in use rather than the volume someone thinks is there.
probe_case_sensitive() { # <dir> -> 0 sensitive, 1 insensitive
    local dir="$1" probe base upper rc
    probe="$(mktemp "$dir/.minixrs-case-probe.XXXXXX")"
    base="$(basename "$probe" | tr '[:lower:]' '[:upper:]')"
    upper="${probe%/*}/$base"
    rc=0
    [ -e "$upper" ] && rc=1
    rm -f "$probe"
    return "$rc"
}

cmd_create() {
    if [ -e "$BUNDLE" ]; then
        echo "forks-volume: $BUNDLE already exists — refusing to overwrite" >&2
        echo "forks-volume: use 'mount' to attach it, or remove it by hand first" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$BUNDLE")"
    echo "forks-volume: creating $SIZE case-sensitive APFS sparsebundle at $BUNDLE"
    hdiutil create -type SPARSEBUNDLE -size "$SIZE" \
        -fs "Case-sensitive APFS" -volname "$VOLNAME" "$BUNDLE"
    cmd_mount
    # Keep Spotlight out of multi-gigabyte build trees: indexing an LLVM
    # build directory is pure waste and slows the build down.
    touch "$MINIXRS_FORKS_DIR/.metadata_never_index"
    echo "forks-volume: created and mounted at $MINIXRS_FORKS_DIR"
}

cmd_mount() {
    if is_mounted; then
        echo "forks-volume: already mounted at $MINIXRS_FORKS_DIR"
        return 0
    fi
    if [ ! -e "$BUNDLE" ]; then
        echo "forks-volume: no sparsebundle at $BUNDLE — run 'forks-volume.sh create'" >&2
        exit 1
    fi
    mkdir -p "$MINIXRS_FORKS_DIR"
    hdiutil attach "$BUNDLE" -mountpoint "$MINIXRS_FORKS_DIR" -nobrowse
    echo "forks-volume: mounted at $MINIXRS_FORKS_DIR"
}

cmd_unmount() {
    if ! is_mounted; then
        echo "forks-volume: not mounted at $MINIXRS_FORKS_DIR"
    else
        hdiutil detach "$MINIXRS_FORKS_DIR"
    fi
    # An empty mountpoint left behind looks exactly like an empty fork
    # checkout dir, which is how you end up debugging a "missing" clone that
    # is really just an unmounted volume.
    rmdir "$MINIXRS_FORKS_DIR" 2>/dev/null || true
}

cmd_status() {
    if ! is_mounted; then
        echo "forks-volume: NOT MOUNTED ($MINIXRS_FORKS_DIR)"
        echo "forks-volume: bundle: $BUNDLE $([ -e "$BUNDLE" ] && echo "(exists)" || echo "(missing)")"
        return 1
    fi
    echo "forks-volume: mounted at $MINIXRS_FORKS_DIR"
    if probe_case_sensitive "$MINIXRS_FORKS_DIR"; then
        echo "forks-volume: case sensitivity: CASE-SENSITIVE (good)"
    else
        echo "forks-volume: case sensitivity: CASE-INSENSITIVE — fork checkouts will break" >&2
    fi
    df -h "$MINIXRS_FORKS_DIR"
    return 0
}

case "${1:-}" in
    create)  cmd_create ;;
    mount)   cmd_mount ;;
    unmount) cmd_unmount ;;
    status)  cmd_status ;;
    *)
        echo "usage: forks-volume.sh {create|mount|unmount|status}" >&2
        exit 2
        ;;
esac
