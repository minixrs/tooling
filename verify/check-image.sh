#!/usr/bin/env bash
#
# check-image.sh — verify an ELF against the minixrs kernel loader's rules, on
# the host, before it ever reaches QEMU.
#
# Mirrors `load_into` / `load_segment` in the minixrs repo's
# kernel/src/boot_image/elf.rs, plus the user VA map. Every rule below is one
# the loader enforces at boot or at exec, so a violation here is an image the
# kernel would refuse — except the stack-overlap rule, which is worse: the
# kernel maps the image happily and then hands the process a stack on top of
# its own text.
#
# Rules checked:
#   - ET_EXEC (a PIE/-shared default is ET_DYN → the loader's BadType) and
#     EM_AARCH64, with e_phentsize == 56 (BadPhentsize)
#   - the minixrs identity note — delegated to check-brand.sh rather than
#     parsed a second time
#   - per PT_LOAD: p_vaddr and p_offset 4 KiB-aligned, p_filesz <= p_memsz
#     (Misaligned), the file range present in the file (Truncated), and never
#     PF_W|PF_X (WriteExec)
#   - some PT_LOAD covers the program header table, which is what gives musl's
#     __init_tls a usable AT_PHDR (`segment_covers_phdrs`)
#   - no PT_LOAD overlaps the stack page, reaches the device window, or runs
#     past USER_VA_TOP
#
# Parsing is od/dd straight on the file, like check-brand.sh, so this needs no
# toolchain at all; `llvm-readelf --program-headers` shows the same table in
# human-readable form.
#
# Usage: check-image.sh <elf> [<elf>...]
#
# Exit codes:
#   0  every file satisfies every loader rule
#   1  at least one file violates a rule (the kernel would refuse it)
#   3  usage error, unreadable file, or not a little-endian ELF64 — the same
#      "cannot even parse this" boundary check-brand.sh draws
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_BRAND="$SCRIPT_DIR/check-brand.sh"

EHDR_SIZE=64
PHDR_SIZE=56
ET_EXEC=2
EM_AARCH64=183 # 0xB7
PT_LOAD=1
PF_X=1
PF_W=2

# ---------------------------------------------------------------------------
# minixrs VA map. Duplicated here by necessity: this script runs on the host
# with no minixrs checkout, so it cannot read the constants it is asserting.
# Each is annotated with its defining file in the minixrs repo — re-check them
# whenever that VA map moves.
# ---------------------------------------------------------------------------
# (No `_` digit separators: bash arithmetic parses those as variable names,
# unlike the Rust sources these mirror.)
PAGE_SIZE=4096                      # kernel-shared/src/message.rs USER_PAGE_SIZE
STACK_VA=$((0x200000))              # kernel/src/arch/aarch64/userland.rs SERVER_STACK_VA
STACK_PAGES=1                       # userland.rs maps exactly one page there
DEVICE_WINDOW_BASE=$((0x40000000))  # kernel-shared/src/uspace.rs USER_DEVICE_WINDOW_BASE
USER_VA_TOP=$((1 << 48))            # kernel-shared/src/message.rs USER_VA_TOP

die() { echo "check-image: error: $*" >&2; exit 3; }

[ $# -ge 1 ] || die "usage: check-image.sh <elf> [<elf>...]"
[ -x "$CHECK_BRAND" ] || die "check-brand.sh not found next to this script"

read_u16() { od -A n -N 2 -j "$2" -t u2 "$1" | tr -d ' \t\n'; }
read_u32() { od -A n -N 4 -j "$2" -t u4 "$1" | tr -d ' \t\n'; }
read_u64() { od -A n -N 8 -j "$2" -t u8 "$1" | tr -d ' \t\n'; }
read_u8()  { od -A n -N 1 -j "$2" -t u1 "$1" | tr -d ' \t\n'; }

hx() { printf '0x%x' "$1"; }

# bash arithmetic is 64-bit *signed*, so a u64 field with the high bit set
# wraps negative and would make the range comparisons below silently pass.
# Nothing the SDK linker emits comes near 2^63; treat it as a violation rather
# than trust it.
fits_i64() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 0 )); }

CUR=""      # file currently under check, for bad()
NBAD=0      # violations found in it

bad() { echo "check-image: $CUR: $*" >&2; NBAD=$(( NBAD + 1 )); }

# check_file <elf>: prints one verdict line; returns 0 loadable, 1 not.
# Environment problems exit 3 via die.
check_file() {
    local f="$1"
    CUR="$f"
    NBAD=0

    [ -r "$f" ] || die "cannot read $f"
    local size
    size="$(wc -c < "$f" | tr -d ' \t\n')"
    (( size >= EHDR_SIZE )) || die "$f: too short to be an ELF64 header"

    local magic
    magic="$(od -A n -N 4 -t x1 "$f" | tr -d ' \n')"
    [ "$magic" = "7f454c46" ] || die "$f: not an ELF file"
    [ "$(read_u8 "$f" 4)" = "2" ] || die "$f: not ELF64"
    [ "$(read_u8 "$f" 5)" = "1" ] || die "$f: not little-endian"

    local etype emachine phoff phentsize phnum
    etype="$(read_u16 "$f" 16)"
    emachine="$(read_u16 "$f" 18)"
    phoff="$(read_u64 "$f" 32)"
    phentsize="$(read_u16 "$f" 54)"
    phnum="$(read_u16 "$f" 56)"

    (( etype == ET_EXEC )) || \
        bad "e_type is $etype, not ET_EXEC ($ET_EXEC) — the loader returns BadType"
    (( emachine == EM_AARCH64 )) || \
        bad "e_machine is $emachine, not EM_AARCH64 ($EM_AARCH64)"
    # Everything below indexes the program header table, so bail out rather
    # than read garbage past EOF if it is unusable.
    if (( phentsize != PHDR_SIZE )); then
        bad "e_phentsize is $phentsize, not $PHDR_SIZE — the loader returns BadPhentsize"
        report "$f"
        return 1
    fi
    if ! fits_i64 "$phoff" || (( phoff + phnum * phentsize > size )); then
        bad "program header table (e_phoff=$(hx "$phoff"), $phnum entries) does not fit in the file"
        report "$f"
        return 1
    fi

    local ph_bytes=$(( phnum * phentsize ))
    local loads=0 phdrs_covered=0
    local ph i ptype pflags poff pvaddr pfilesz pmemsz npages vend
    for (( i = 0; i < phnum; i++ )); do
        ph=$(( phoff + i * phentsize ))
        ptype="$(read_u32 "$f" "$ph")"
        (( ptype == PT_LOAD )) || continue
        loads=$(( loads + 1 ))

        pflags="$(read_u32 "$f" $(( ph + 4 )))"
        poff="$(read_u64 "$f" $(( ph + 8 )))"
        pvaddr="$(read_u64 "$f" $(( ph + 16 )))"
        pfilesz="$(read_u64 "$f" $(( ph + 32 )))"
        pmemsz="$(read_u64 "$f" $(( ph + 40 )))"

        if ! fits_i64 "$poff" || ! fits_i64 "$pvaddr" \
            || ! fits_i64 "$pfilesz" || ! fits_i64 "$pmemsz"; then
            bad "PT_LOAD #$i has a field above 2^63 — refusing to reason about it"
            continue
        fi

        # --- load_segment()'s Misaligned / Truncated / WriteExec ------------
        if (( pvaddr % PAGE_SIZE != 0 )); then
            bad "PT_LOAD #$i p_vaddr $(hx "$pvaddr") is not ${PAGE_SIZE}-byte aligned"
        fi
        if (( poff % PAGE_SIZE != 0 )); then
            bad "PT_LOAD #$i p_offset $(hx "$poff") is not ${PAGE_SIZE}-byte aligned"
        fi
        if (( pfilesz > pmemsz )); then
            bad "PT_LOAD #$i p_filesz $pfilesz exceeds p_memsz $pmemsz"
        fi
        if (( poff + pfilesz > size )); then
            bad "PT_LOAD #$i file range $(hx "$poff")+$pfilesz runs past the end of the file ($size)"
        fi
        if (( (pflags & PF_W) != 0 && (pflags & PF_X) != 0 )); then
            bad "PT_LOAD #$i is both writable and executable (p_flags=$(hx "$pflags"))"
        fi

        # --- segment_covers_phdrs(): the AT_PHDR condition ------------------
        if (( phoff >= poff && phoff + ph_bytes <= poff + pfilesz )); then
            phdrs_covered=1
        fi

        # --- the VA map ----------------------------------------------------
        # The loader maps ceil(p_memsz / PAGE_SIZE) pages from p_vaddr, so a
        # zero-memsz segment occupies nothing.
        npages=$(( (pmemsz + PAGE_SIZE - 1) / PAGE_SIZE ))
        (( npages > 0 )) || continue
        vend=$(( pvaddr + npages * PAGE_SIZE ))

        if (( pvaddr < STACK_VA + STACK_PAGES * PAGE_SIZE && vend > STACK_VA )); then
            bad "PT_LOAD #$i [$(hx "$pvaddr"),$(hx "$vend")) overlaps the stack page at $(hx "$STACK_VA") (SERVER_STACK_VA)"
        fi
        if (( vend > DEVICE_WINDOW_BASE )); then
            bad "PT_LOAD #$i [$(hx "$pvaddr"),$(hx "$vend")) reaches the device window at $(hx "$DEVICE_WINDOW_BASE")"
        fi
        if (( vend > USER_VA_TOP )); then
            bad "PT_LOAD #$i [$(hx "$pvaddr"),$(hx "$vend")) runs past USER_VA_TOP $(hx "$USER_VA_TOP")"
        fi
    done

    if (( loads == 0 )); then
        bad "no PT_LOAD segments — the loader would map nothing"
    elif (( phdrs_covered == 0 )); then
        bad "no PT_LOAD covers the program headers — AT_PHDR would be unset and musl's __init_tls dereferences it"
    fi

    # The brand is a loader rule too (load_into calls scan_brand), but
    # check-brand.sh already implements it byte-exactly. Its verdict line is
    # swallowed on success so this script speaks with one voice; run
    # check-brand.sh directly for the note details.
    local brc=0 bout
    bout="$("$CHECK_BRAND" "$f" 2>&1)" || brc=$?
    case "$brc" in
        0) ;;
        3) die "$f: check-brand.sh could not parse this file: $bout" ;;
        *) bad "identity note rejected by check-brand.sh (exit $brc): $bout" ;;
    esac

    report "$f"
    if (( NBAD == 0 )); then
        return 0
    fi
    return 1
}

# report <elf>: the one verdict line per file, in check-brand.sh's voice.
# Always succeeds — the caller decides the exit status from NBAD.
report() {
    if (( NBAD == 0 )); then
        echo "$1: LOADABLE (satisfies the minixrs loader rules)"
    else
        echo "$1: NOT LOADABLE ($NBAD rule violation(s))"
    fi
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
