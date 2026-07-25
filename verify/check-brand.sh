#!/usr/bin/env bash
#
# check-brand.sh — verify the minixrs ELF identity note (docs/abi-note.md).
#
# Walks the program headers of each ELF argument, scans every PT_NOTE segment
# for a note with owner "minixrs\0" and type NT_MINIXRS_IDENT (1), and checks
# the ABI version. Foreign-owner notes are ignored, longer descriptors are
# accepted (only the known words are read) — the consumer rules from the
# spec, byte-exact.
#
# Parsing is done with od/dd directly on the file, so the script needs no
# toolchain at all; `llvm-readelf -n <elf>` shows the same note in
# human-readable form. od decodes in *host* byte order, matching the ELF's
# own little-endian encoding (checked via EI_DATA) on every host we support.
#
# Usage: check-brand.sh <elf> [<elf>...]
#
# Exit codes:
#   0  every file carries the brand with a supported abi_version
#   1  at least one file is missing the brand (or its note is malformed)
#   2  at least one file has an unsupported abi_version
#   3  usage error, unreadable file, or not a little-endian ELF64
set -euo pipefail

NOTE_OWNER="minixrs"
NT_MINIXRS_IDENT=1
SUPPORTED_ABI=1
PT_NOTE=4

die() { echo "check-brand: error: $*" >&2; exit 3; }

[ $# -ge 1 ] || die "usage: check-brand.sh <elf> [<elf>...]"

read_u16() { od -A n -N 2 -j "$2" -t u2 "$1" | tr -d ' \t\n'; }
read_u32() { od -A n -N 4 -j "$2" -t u4 "$1" | tr -d ' \t\n'; }
read_u64() { od -A n -N 8 -j "$2" -t u8 "$1" | tr -d ' \t\n'; }
read_u8()  { od -A n -N 1 -j "$2" -t u1 "$1" | tr -d ' \t\n'; }
read_str() { dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | LC_ALL=C tr -d '\0'; }

# check_file <elf>: prints one verdict line; returns 0 branded, 1 missing,
# 2 unsupported ABI. Environment problems exit 3 via die.
check_file() {
    local f="$1"
    [ -r "$f" ] || die "cannot read $f"

    local magic
    magic="$(od -A n -N 4 -t x1 "$f" | tr -d ' \n')"
    [ "$magic" = "7f454c46" ] || die "$f: not an ELF file"
    [ "$(read_u8 "$f" 4)" = "2" ] || die "$f: not ELF64"
    [ "$(read_u8 "$f" 5)" = "1" ] || die "$f: not little-endian"

    local phoff phentsize phnum
    phoff="$(read_u64 "$f" 32)"
    phentsize="$(read_u16 "$f" 54)"
    phnum="$(read_u16 "$f" 56)"

    local i ph ptype poff pfilesz pos end
    local namesz descsz ntype name_off desc_off next owner abi flags
    for (( i = 0; i < phnum; i++ )); do
        ph=$(( phoff + i * phentsize ))
        ptype="$(read_u32 "$f" "$ph")"
        [ "$ptype" -eq "$PT_NOTE" ] || continue
        poff="$(read_u64 "$f" $(( ph + 8 )))"
        pfilesz="$(read_u64 "$f" $(( ph + 32 )))"

        # Walk the note records inside this PT_NOTE segment.
        pos=$poff
        end=$(( poff + pfilesz ))
        while (( pos + 12 <= end )); do
            namesz="$(read_u32 "$f" "$pos")"
            descsz="$(read_u32 "$f" $(( pos + 4 )))"
            ntype="$(read_u32 "$f" $(( pos + 8 )))"
            name_off=$(( pos + 12 ))
            desc_off=$(( name_off + ((namesz + 3) & ~3) ))
            next=$(( desc_off + ((descsz + 3) & ~3) ))
            if (( next <= pos || next > end )); then
                break # malformed/truncated record; try other segments
            fi

            owner="$(read_str "$f" "$name_off" "$namesz")"
            if [ "$owner" = "$NOTE_OWNER" ] && [ "$ntype" -eq "$NT_MINIXRS_IDENT" ]; then
                if (( descsz < 8 )); then
                    echo "$f: MALFORMED minixrs note (descsz=$descsz < 8)"
                    return 1
                fi
                abi="$(read_u32 "$f" "$desc_off")"
                flags="$(read_u32 "$f" $(( desc_off + 4 )))"
                if [ "$abi" -eq "$SUPPORTED_ABI" ]; then
                    echo "$f: BRANDED minixrs abi_version=$abi flags=$flags"
                    return 0
                fi
                echo "$f: UNSUPPORTED minixrs abi_version=$abi (supported: $SUPPORTED_ABI)"
                return 2
            fi
            pos=$next
        done
    done

    echo "$f: MISSING minixrs brand (no PT_NOTE with owner \"$NOTE_OWNER\", type $NT_MINIXRS_IDENT)"
    return 1
}

worst=0
for f in "$@"; do
    rc=0
    check_file "$f" || rc=$?
    if (( rc > worst )); then
        worst=$rc
    fi
done
exit "$worst"
