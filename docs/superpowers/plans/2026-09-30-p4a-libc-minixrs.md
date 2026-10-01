# P4a — libc-minixrs and the ABI Parity Gate: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `libc-minixrs` fork with a `src/unix/minixrs/` module that makes the libc crate compile for `target_os = "minixrs"`, and a host-side gate in this repo proving every definition in it matches the SDK sysroot's C headers.

**Architecture:** One manifest (`verify/libc-abi/items.list`) drives an awk generator that emits a C file and a Rust file, each writing the same ordered table of sizes, alignments, offsets and constants into a `.minixrs_abi` section. `verify/check-libc-abi.sh` compiles both, extracts the sections, and hands them to `verify/libc-abi/compare.sh`. The comparer is a separate script so `verify/selftest.sh` can exercise it with fabricated tables and no SDK.

**Tech Stack:** bash 3.2 (macOS), awk, the SDK's patched clang and `llvm-objcopy`, `cargo +nightly-2026-07-23 -Zbuild-std=core`, the `libc` crate at tag `0.2.185`.

**Spec:** [`docs/superpowers/specs/2026-09-30-p4-rust-std-design.md`](../specs/2026-09-30-p4-rust-std-design.md) — sections "P4a — libc-minixrs" and decisions R5, R7, R12.

**Every code block in this plan was run on 2026-09-30** against the installed SDK and a scratch copy of libc 0.2.185: the module compiles with zero warnings, the gate reports `209 entries identical`, and each mutation in Task 4 produced the output quoted there. If a step's output differs from what is written, stop and find out why — do not adjust the expectation.

**After execution:** the final whole-branch review added each field's size to the table, so the gate now reports `309 entries identical`, not 209, and a mutation's entry numbers shift accordingly. It also widened coverage to unions, enums, statics and `src/new/minixrs/`. The counts below are the ones observed while the plan ran; they are history.

## Global Constraints

- **Two repos, two sessions.** Tasks 1, 2 and 5 run in `~/src/tooling`. Tasks 3 and 4 edit `$MINIXRS_FORKS_DIR/libc-minixrs` and run **in a session inside that checkout** — never edit fork source from a tooling session (the cross-repo rule in `CLAUDE.md`).
- The forks volume must be mounted for Tasks 3–5: `scripts/forks-volume.sh mount`.
- libc fork base: tag **`0.2.185`** of `rust-lang/libc`. Branch **`minixrs/0.2.185`**. Release tag **`minixrs-0.2.185-1`**; a release tag is never moved.
- Definitions are **copied** from libc's Linux-musl-aarch64 sources, never derived from a header by hand.
- The module carries **no `#[cfg]`** and **no Linux-only API** (epoll, inotify, netlink).
- Scripts must pass `bash -n` and `shellcheck -S warning`, and run under macOS bash 3.2: an empty array expands as `${ARR[@]+"${ARR[@]}"}`.
- **The Bash tool's shell is zsh.** Wrap any multi-step probe that uses `PIPESTATUS` or `read -ra` in `bash -c`.
- Every commit is GPG-signed and carries `Signed-off-by` (`git commit -s`); never `--no-gpg-sign`, never `--no-verify`.
- **Nothing leaves the machine without the user's say-so:** no `git push`, no `gh repo fork`, no PR. Steps that do are marked **USER-GATED** — stop and ask.
- A tooling PR checks its own roadmap box in the same PR (Task 5).

## Review Focus

Conditions the spec implies that a first implementation would likely get wrong. Each is pinned by a step in the task named.

1. **A definition added to the module but not to the manifest** — must fail the gate, not pass unchecked. Task 4, Step 6.
2. **A `#[cfg]` in the module hiding a second definition under a checked name** — must fail the gate. Task 4, Step 7.
3. **The forks volume unmounted, or the fork not cloned** — must exit 2 with a message naming `scripts/forks-volume.sh mount`, not a cargo error. Task 2, Step 6.
4. **`RUSTFLAGS` set in the caller's environment** — must not change or break the comparison. Task 4, Step 8.
5. **Tables of different lengths, or empty** — must be exit 2 ("malformed"), never exit 0 and never a plain mismatch. Task 1, fixtures `abi-truncated` and `abi-empty`.

Known and accepted, not pinned by a test: function signatures are not compared (the PASS line counts them), and two *private* fields swapped inside a struct are invisible unless they move a public field.

## File Structure

**tooling** (`~/src/tooling`):

| File | Responsibility |
|---|---|
| `verify/libc-abi/compare.sh` (new) | Compare two raw u64 tables; name the label of each differing entry |
| `verify/libc-abi/gen.awk` (new) | Manifest → C emitter, Rust emitter, label file |
| `verify/libc-abi/items.list` (new) | The manifest: what is checked |
| `verify/libc-abi/allow.list` (new) | Module items deliberately not checked, each with a reason |
| `verify/testdata/aarch64-unknown-minixrs-unix.json` (new) | Test-only target: `os: minixrs`, `target-family: ["unix"]` |
| `verify/check-libc-abi.sh` (new) | The P4a gate: guards, coverage, build both sides, compare |
| `verify/selftest.sh` (modify) | Four comparer fixtures |
| `scripts/export-patches.sh` (modify) | libc base default → `0.2.185` |
| `patches/libc/*.patch` (generated) | The exported series |
| `docs/roadmap.md`, `README.md`, `CLAUDE.md` (modify) | P4a box, script lists, fixture count |

**libc-minixrs** (`$MINIXRS_FORKS_DIR/libc-minixrs`):

| File | Responsibility |
|---|---|
| `build.rs` (modify) | Allow `target_os = "minixrs"` in check-cfg |
| `src/unix/mod.rs` (modify) | Select the `minixrs` module |
| `src/new/mod.rs` (modify) | Select `new::minixrs`, which supplies the `unistd` module the Unix family re-exports |
| `src/new/minixrs/{mod,unistd}.rs` (new) | `STD{IN,OUT,ERR}_FILENO` |
| `src/unix/minixrs/mod.rs` (new) | The definitions |

---

### Task 1: The table comparer and its selftest fixtures (tooling)

**Files:**
- Create: `verify/libc-abi/compare.sh`
- Modify: `verify/selftest.sh`

**Interfaces:**
- Produces: `verify/libc-abi/compare.sh <c.bin> <rust.bin> <labels>` — exit 0 identical, 1 mismatch (one `MISMATCH <label>: C=0x<hex> Rust=0x<hex>` line per differing entry), 2 malformed input. Task 2's script calls it with exactly these three arguments.

- [ ] **Step 1: Write the failing fixtures**

In `verify/selftest.sh`, add one line directly below `CHECK_IMAGE="$SCRIPT_DIR/check-image.sh"`:

```bash
COMPARE="$SCRIPT_DIR/libc-abi/compare.sh"
```

Insert these helpers immediately above the line `expect branded 0` (they use the existing `le_bytes`, `detail`, `fail` and `$tmp`):

```bash
# compare.sh, the comparer behind check-libc-abi.sh. The tables are fabricated
# here, so these fixtures need neither an SDK nor a libc-minixrs checkout —
# which is the point of compare.sh being its own script.
u64s() { # <file> [value...] — write raw little-endian u64s
    local f="$1" v
    shift
    : > "$f"
    for v in "$@"; do
        # shellcheck disable=SC2059 # the format *is* the byte string
        printf "$(le_bytes "$v" 8)" >> "$f"
    done
}

expect_compare() { # <label> <expected rc> <expected message> <c.bin> <rust.bin>
    local label="$1" want_rc="$2" want_msg="$3" out rc=0
    out="$("$COMPARE" "$4" "$5" "$tmp/abi.labels" 2>&1)" || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        echo "selftest: FAIL $label (exit $rc, expected $want_rc)" >&2
        detail <<<"$out"
        fail=1
        return
    fi
    if ! grep -qF -- "$want_msg" <<<"$out"; then
        echo "selftest: FAIL $label (exit $rc as expected, but not for the reason under test)" >&2
        echo "selftest:   wanted: $want_msg" >&2
        detail <<<"$out"
        fail=1
        return
    fi
    echo "selftest: PASS $label (exit $rc, \"$want_msg\")"
}
```

Insert these calls immediately above the final `if [ "$fail" -eq 0 ]; then`:

```bash
printf '%s\n' "7: sizeof stat" "7: offsetof stat.st_size" "9: value NCCS" > "$tmp/abi.labels"
u64s "$tmp/abi-c.bin"     128 48 32
u64s "$tmp/abi-same.bin"  128 48 32
u64s "$tmp/abi-off.bin"   128 56 32
u64s "$tmp/abi-short.bin" 128 48
expect_compare abi-identical 0 "3 entries identical" \
    "$tmp/abi-c.bin" "$tmp/abi-same.bin"
expect_compare abi-mismatch  1 "MISMATCH 7: offsetof stat.st_size: C=0x30 Rust=0x38" \
    "$tmp/abi-c.bin" "$tmp/abi-off.bin"
expect_compare abi-truncated 2 "is 16 bytes, expected 24 (3 entries)" \
    "$tmp/abi-c.bin" "$tmp/abi-short.bin"
: > "$tmp/abi.labels"
u64s "$tmp/abi-empty.bin"
expect_compare abi-empty     2 "empty table" \
    "$tmp/abi-empty.bin" "$tmp/abi-empty.bin"
```

Also extend the header comment of `verify/selftest.sh`: after the paragraph ending "every other rule still applies under the flag)", add:

```bash
#
# compare.sh, the libc ABI table comparer behind check-libc-abi.sh — four
# fabricated tables, no SDK and no fork checkout needed:
#
#   identical tables        → exit 0
#   one differing entry     → exit 1, naming that entry's label
#   a short table           → exit 2 (malformed, not a mismatch)
#   an empty table          → exit 2 (nothing compared is not a pass)
```

- [ ] **Step 2: Run the selftest and watch the four fail**

Run: `verify/selftest.sh`
Expected: the 14 existing fixtures PASS; then four `selftest: FAIL abi-…` lines, each with exit 127 (`compare.sh` does not exist); overall exit 1.

- [ ] **Step 3: Write the comparer**

Create `verify/libc-abi/compare.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
#
# compare.sh — compare two ABI tables entry by entry.
#
# Usage: compare.sh <c.bin> <rust.bin> <labels>
#
# Each .bin is a raw little-endian u64 array (the .minixrs_abi section of an
# emitter object); <labels> has one line per entry. Exit 0 if identical, 1 on
# any differing entry — each reported with its label — and 2 if the inputs are
# malformed (a length that disagrees with the label count is malformed, not a
# mismatch: it means the two emitters were not generated from one manifest).
#
# Needs nothing but od/awk, so verify/selftest.sh can exercise it without an
# SDK or a fork checkout.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: compare.sh <c.bin> <rust.bin> <labels>" >&2
    exit 2
fi
for f in "$@"; do
    [ -f "$f" ] || { echo "compare: no such file: $f" >&2; exit 2; }
done

# One hex u64 per line. BSD od prints them unpadded and GNU od zero-padded, so
# leading zeros are stripped to make the two spellings compare equal.
words() {
    od -An -v -tx8 "$1" | tr -s ' \t' '\n\n' | sed -e '/^$/d' -e 's/^0*\([0-9a-f]\)/\1/'
}

n_labels=$(wc -l < "$3" | tr -d ' ')
for bin in "$1" "$2"; do
    bytes=$(wc -c < "$bin" | tr -d ' ')
    if [ "$bytes" -ne $((n_labels * 8)) ]; then
        echo "compare: $bin is $bytes bytes, expected $((n_labels * 8)) ($n_labels entries)" >&2
        exit 2
    fi
done
if [ "$n_labels" -eq 0 ]; then
    echo "compare: empty table — nothing was compared" >&2
    exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
words "$1" > "$tmp/c"
words "$2" > "$tmp/rs"

paste "$tmp/c" "$tmp/rs" "$3" | awk -F'\t' '
    $1 != $2 { printf "MISMATCH %s: C=0x%s Rust=0x%s\n", $3, $1, $2; bad++ }
    END {
        if (bad) { printf "compare: %d of %d entries differ\n", bad, NR; exit 1 }
        printf "compare: %d entries identical\n", NR
    }'
```

- [ ] **Step 4: Run the selftest and watch it pass**

Run: `verify/selftest.sh 2>&1 | tail -5; verify/selftest.sh 2>/dev/null | grep -c PASS`
Expected:

```
selftest: PASS abi-identical (exit 0, "3 entries identical")
selftest: PASS abi-mismatch (exit 1, "MISMATCH 7: offsetof stat.st_size: C=0x30 Rust=0x38")
selftest: PASS abi-truncated (exit 2, "is 16 bytes, expected 24 (3 entries)")
selftest: PASS abi-empty (exit 2, "empty table")
selftest: all fixtures passed
18
```

- [ ] **Step 5: Prove the mismatch fixture is load-bearing**

Break the source, not the test: in `compare.sh` change `$1 != $2 {` to `$1 != $1 {`, run `verify/selftest.sh`, and confirm `abi-mismatch` FAILS with "exit 0, expected 1". Revert the edit and confirm 18 PASS again.

- [ ] **Step 6: Lint and commit**

```bash
bash -n verify/selftest.sh verify/libc-abi/compare.sh
shellcheck -S warning scripts/*.sh verify/*.sh verify/libc-abi/*.sh
git add verify/libc-abi/compare.sh verify/selftest.sh
git commit -s -m "verify: compare.sh, the libc ABI table comparer"
```

Expected: both lint commands print nothing and exit 0.

---

### Task 2: The manifest, the generator, and the gate script (tooling)

**Files:**
- Create: `verify/libc-abi/gen.awk`, `verify/libc-abi/items.list`, `verify/libc-abi/allow.list`
- Create: `verify/testdata/aarch64-unknown-minixrs-unix.json`
- Create: `verify/check-libc-abi.sh`

**Interfaces:**
- Consumes: `verify/libc-abi/compare.sh <c.bin> <rust.bin> <labels>` from Task 1.
- Produces: `verify/check-libc-abi.sh` — exit 0 parity, 1 mismatch / uncovered item / `#[cfg]` in the module, 2 build or usage error. Knobs `MINIXRS_LIBC_DIR` (default `$MINIXRS_FORKS_DIR/libc-minixrs`) and `MINIXRS_NIGHTLY` (default `nightly-2026-07-23`). Tasks 3 and 4 run it from the fork session as `~/src/tooling/verify/check-libc-abi.sh`.
- Produces: the manifest format documented at the top of `items.list`; P4b grows the manifest in the same format.

This task ends with the gate **red for the right reason** (no fork yet). That red run is the free proof that the gate is load-bearing; Task 4 turns it green.

- [ ] **Step 1: Write the test-only target JSON**

Create `verify/testdata/aarch64-unknown-minixrs-unix.json`. It is minixrs' own `tools/targets/aarch64-unknown-minixrs.json` with two changes — `target-family` added, and `features` set to what `clang --target=aarch64-unknown-minixrs -###` reports:

```json
{
  "arch": "aarch64",
  "crt-objects-fallback": "false",
  "data-layout": "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32",
  "default-uwtable": true,
  "disable-redzone": true,
  "features": "+v8a,+fp-armv8,+neon",
  "linker": "rust-lld",
  "linker-flavor": "gnu-lld",
  "llvm-target": "aarch64-unknown-none",
  "max-atomic-width": 128,
  "os": "minixrs",
  "panic-strategy": "abort",
  "pre-link-args": {
    "gnu": [
      "--fix-cortex-a53-843419"
    ],
    "gnu-lld": [
      "--fix-cortex-a53-843419"
    ]
  },
  "relocation-model": "static",
  "stack-probes": {
    "kind": "inline"
  },
  "supported-sanitizers": [
    "kcfi",
    "kernel-address",
    "kernel-hwaddress"
  ],
  "supports-xray": true,
  "target-pointer-width": 64,
  "target-family": [
    "unix"
  ]
}
```

- [ ] **Step 2: Write the generator**

Create `verify/libc-abi/gen.awk`:

```awk
# gen.awk — turn the ABI manifest into a C emitter, a Rust emitter, and a
# label file, all describing the same ordered table of u64 entries.
#
#   awk -v c=OUT.c -v rs=OUT.rs -v labels=OUT.labels -f gen.awk items.list
#
# Entry i of both tables is described by line i of the label file, which is
# what lets compare.sh name the manifest line behind a mismatch.

function entry(label, cexpr, rsexpr) {
    cbody = cbody "    (unsigned long long)(" cexpr "),\n"
    rsbody = rsbody "    (" rsexpr ") as u64,\n"
    print label > labels
    n++
}

function aggregate(ctype,    i, parts, rf, cf) {
    entry(FNR ": sizeof " $2, "sizeof(" ctype ")", "size_of::<libc::" $2 ">()")
    entry(FNR ": alignof " $2, "_Alignof(" ctype ")", "align_of::<libc::" $2 ">()")
    for (i = 3; i <= NF; i++) {
        rf = $i; cf = $i
        if (split($i, parts, "=") == 2) { rf = parts[1]; cf = parts[2] }
        entry(FNR ": offsetof " $2 "." rf, \
              "offsetof(" ctype ", " cf ")", \
              "offset_of!(libc::" $2 ", " rf ")")
    }
}

/^[ \t]*(#|$)/ { next }

$1 == "include" { includes = includes "#include " $2 "\n"; next }

$1 == "int" || $1 == "type" {
    entry(FNR ": sizeof " $2, "sizeof(" $2 ")", "size_of::<libc::" $2 ">()")
    entry(FNR ": alignof " $2, "_Alignof(" $2 ")", "align_of::<libc::" $2 ">()")
    if ($1 == "int")
        entry(FNR ": signedness " $2, "(" $2 ")-1 < 0", "(!(0 as libc::" $2 ")) < (0 as libc::" $2 ")")
    next
}

$1 == "const"   { entry(FNR ": value " $2, $2, "libc::" $2); next }
$1 == "struct"  { aggregate("struct " $2); next }
$1 == "typedef" { aggregate($2); next }

{ printf "gen.awk: %s:%d: unknown kind '%s'\n", FILENAME, FNR, $1 > "/dev/stderr"; bad = 1 }

END {
    if (bad) exit 2
    printf "%s\n__attribute__((section(\".minixrs_abi\"), used))\nconst unsigned long long minixrs_abi_table[%d] = {\n%s};\n", includes, n, cbody > c
    printf "#![no_std]\n#![allow(unused_comparisons, clippy::all)]\nuse core::mem::{align_of, offset_of, size_of};\n\n#[used]\n#[no_mangle]\n#[link_section = \".minixrs_abi\"]\npub static minixrs_abi_table: [u64; %d] = [\n%s];\n", n, rsbody > rs
}
```

- [ ] **Step 3: Write the manifest and the allowlist**

Create `verify/libc-abi/items.list`:

```
# libc-minixrs ABI manifest — every pub type, struct and const in
# libc-minixrs' src/unix/minixrs/, checked against the SDK sysroot's headers
# by verify/check-libc-abi.sh.
#
#   include <header.h>           a C header the items below need
#   int     NAME                 integer typedef: size, alignment, signedness
#   type    NAME                 any other typedef: size, alignment
#   struct  NAME [FIELD ...]     C `struct NAME`: size, alignment, field offsets
#   typedef NAME [FIELD ...]     C typedef'd aggregate `NAME`: the same
#   const   NAME                 an integer constant's value
#
# A FIELD is the Rust field name. Where C spells it differently, write
# RUST=C — the C side may be a nested designator (st_atime_nsec=st_atim.tv_nsec).
# Only `pub` fields can be listed; private padding is covered by the size and
# by the offsets of the public fields around it.

include <dirent.h>
include <dlfcn.h>
include <locale.h>
include <netdb.h>
include <poll.h>
include <pthread.h>
include <pwd.h>
include <semaphore.h>
include <signal.h>
include <stddef.h>
include <sys/resource.h>
include <sys/select.h>
include <sys/socket.h>
include <sys/stat.h>
include <sys/statvfs.h>
include <sys/types.h>
include <termios.h>
include <time.h>
include <wchar.h>

int blkcnt_t
int blksize_t
int cc_t
int clock_t
int dev_t
int fsblkcnt_t
int fsfilcnt_t
int ino_t
int mode_t
int nfds_t
int nlink_t
int off_t
int pthread_key_t
type pthread_t
int rlim_t
int sa_family_t
int socklen_t
int speed_t
int suseconds_t
int tcflag_t
int time_t
int wchar_t

const FD_SETSIZE
const NCCS

struct sockaddr sa_family sa_data
struct addrinfo ai_flags ai_family ai_socktype ai_protocol ai_addrlen ai_addr ai_canonname ai_next
typedef fd_set
struct tm tm_sec tm_min tm_hour tm_mday tm_mon tm_year tm_wday tm_yday tm_isdst tm_gmtoff tm_zone
typedef Dl_info dli_fname dli_fbase dli_sname dli_saddr
struct lconv decimal_point thousands_sep grouping int_curr_symbol currency_symbol mon_decimal_point mon_thousands_sep mon_grouping positive_sign negative_sign int_frac_digits frac_digits p_cs_precedes p_sep_by_space n_cs_precedes n_sep_by_space p_sign_posn n_sign_posn int_p_cs_precedes int_p_sep_by_space int_n_cs_precedes int_n_sep_by_space int_p_sign_posn int_n_sign_posn
struct passwd pw_name pw_passwd pw_uid pw_gid pw_gecos pw_dir pw_shell
struct dirent d_ino d_off d_reclen d_type d_name
struct stat st_dev st_ino st_mode st_nlink st_uid st_gid st_rdev st_size st_blksize st_blocks st_atime=st_atim.tv_sec st_atime_nsec=st_atim.tv_nsec st_mtime=st_mtim.tv_sec st_mtime_nsec=st_mtim.tv_nsec st_ctime=st_ctim.tv_sec st_ctime_nsec=st_ctim.tv_nsec
struct statvfs f_bsize f_frsize f_blocks f_bfree f_bavail f_files f_ffree f_favail f_fsid f_flag f_namemax
struct termios c_iflag c_oflag c_cflag c_lflag c_line c_cc __c_ispeed __c_ospeed
typedef sigset_t
struct sigaction sa_sigaction sa_mask sa_flags sa_restorer
typedef sem_t
typedef pthread_attr_t
typedef pthread_mutex_t
typedef pthread_cond_t
typedef pthread_rwlock_t
typedef pthread_mutexattr_t
typedef pthread_condattr_t
typedef pthread_rwlockattr_t
```

Create `verify/libc-abi/allow.list`:

```
# Items in libc-minixrs' src/unix/minixrs/ that verify/check-libc-abi.sh does
# NOT compare against the C headers. One per line: NAME, then the reason.
# An item in neither this file nor items.list fails the gate.
```

- [ ] **Step 4: Check the generator alone**

```bash
d="$(mktemp -d)"
awk -v c="$d/t.c" -v rs="$d/t.rs" -v labels="$d/labels" \
    -f verify/libc-abi/gen.awk verify/libc-abi/items.list
wc -l < "$d/labels"; grep -c 'unsigned long long)(' "$d/t.c"; grep -c ' as u64,' "$d/t.rs"
bash -c '. scripts/env.sh; clang --target=aarch64-unknown-minixrs -std=gnu11 -D_GNU_SOURCE -Wall -Werror -c "$0/t.c" -o "$0/t.o" && echo C-OK' "$d"
```

Expected: `209` three times, then `C-OK`. The three counts being equal is the property the comparer relies on.

Then confirm a bad kind is refused: `printf 'strcut stat\n' | awk -v c=/dev/null -v rs=/dev/null -v labels=/dev/null -f verify/libc-abi/gen.awk; echo "exit=$?"` prints `gen.awk: :1: unknown kind 'strcut'` and `exit=2`.

- [ ] **Step 5: Write the gate script**

Create `verify/check-libc-abi.sh` and `chmod +x` it:

```bash
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
# It also enforces coverage: every `pub type`, `pub struct` and `pub const` in
# libc-minixrs' src/unix/minixrs/ must be in items.list or in allow.list, and
# the module may carry no #[cfg]. Function declarations are not checked — a
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

# --- coverage: nothing in the module escapes the manifest --------------------
listed() {
    awk '$1 ~ /^(int|type|const|struct|typedef)$/ { print $2 }' "$ABI_DIR/items.list"
    awk '!/^[ \t]*(#|$)/ { print $1 }' "$ABI_DIR/allow.list"
}
find "$MODULE_DIR" -name '*.rs' -exec cat {} + |
    sed -nE 's/^[[:space:]]*pub (type|struct|const) ([A-Za-z_][A-Za-z0-9_]*).*/\2/p' |
    sort -u > "$work/defined"
listed | sort -u > "$work/listed"
[ -s "$work/defined" ] || die "found no pub type/struct/const under $MODULE_DIR"
# Coverage is by name, so one name must mean one definition. A #[cfg] in the
# module could hide a second, unchecked definition behind a checked one; the
# module is aarch64-only and has no reason to carry one.
if grep -rnE '#\[cfg(_attr)?\(' "$MODULE_DIR" >&2; then
    echo "check-libc-abi: $MODULE_DIR carries #[cfg] — coverage by name cannot see past it" >&2
    exit 1
fi
comm -23 "$work/defined" "$work/listed" > "$work/uncovered"
if [ -s "$work/uncovered" ]; then
    echo "check-libc-abi: defined in $MODULE_DIR but in neither items.list nor allow.list:" >&2
    sed 's/^/  /' "$work/uncovered" >&2
    exit 1
fi

# --- generate both emitters from the one manifest ----------------------------
mkdir -p "$work/rs/src"
awk -v c="$work/table.c" -v rs="$work/rs/src/lib.rs" -v labels="$work/labels" \
    -f "$ABI_DIR/gen.awk" "$ABI_DIR/items.list" || die "items.list did not parse"

# --- C side -------------------------------------------------------------------
# _GNU_SOURCE because the libc crate mirrors musl's full view of each header
# (tm_gmtoff, Dl_info), not the strict-ISO one.
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
    unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_TARGET
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
fns="$(find "$MODULE_DIR" -name '*.rs' -exec cat {} + | grep -cE '^[[:space:]]*pub (unsafe )?fn ' || true)"
echo "check-libc-abi: PASS ($(wc -l < "$work/defined" | tr -d ' ') module items covered; $fns function declarations not checked)"
```

- [ ] **Step 6: Exercise the guard paths (Review Focus 3)**

```bash
verify/check-libc-abi.sh; echo "exit=$?"
MINIXRS_FORKS_DIR=/nonexistent verify/check-libc-abi.sh; echo "exit=$?"
MINIXRS_SDK=/nonexistent verify/check-libc-abi.sh; echo "exit=$?"
MINIXRS_NIGHTLY=nightly-1999-01-01 MINIXRS_LIBC_DIR=verify verify/check-libc-abi.sh; echo "exit=$?"
```

Expected, in order — all `exit=2`:
- `no …/libc-minixrs/src/unix/minixrs/mod.rs — is the forks volume mounted (scripts/forks-volume.sh mount) and libc-minixrs cloned?` (the fork does not exist yet — this is the intended red state)
- the same message under `/nonexistent`
- `no clang at /nonexistent/bin/clang — run scripts/build-llvm.sh`
- the fourth stops at the module check (`verify/src/unix/minixrs/mod.rs` is absent), also exit 2 — the toolchain guard is exercised for real in Task 3, Step 5.

- [ ] **Step 7: Lint and commit**

```bash
bash -n verify/check-libc-abi.sh
shellcheck -S warning scripts/*.sh verify/*.sh verify/libc-abi/*.sh
verify/selftest.sh 2>/dev/null | grep -c PASS     # still 18
git add verify/check-libc-abi.sh verify/libc-abi verify/testdata/aarch64-unknown-minixrs-unix.json
git commit -s -m "verify: check-libc-abi.sh, the P4a parity gate

Red until libc-minixrs exists: it stops at the missing-checkout guard."
```

---

### Task 3: Fork bring-up and target registration (libc-minixrs session)

**Run this task in a session whose working directory is `$MINIXRS_FORKS_DIR/libc-minixrs`.**

**Files:**
- Modify: `build.rs`, `src/unix/mod.rs`, `src/new/mod.rs`
- Create: `src/new/minixrs/mod.rs`, `src/new/minixrs/unistd.rs`, `src/unix/minixrs/mod.rs` (header only)

**Interfaces:**
- Consumes: `~/src/tooling/verify/check-libc-abi.sh` and `~/src/tooling/verify/testdata/aarch64-unknown-minixrs-unix.json` from Task 2.
- Produces: branch `minixrs/0.2.185` on which `target_os = "minixrs"` selects `crate::unix::minixrs`. Task 4 fills that module.

- [ ] **Step 1: Clone at the tag and branch**

```bash
~/src/tooling/scripts/forks-volume.sh mount
. ~/src/tooling/scripts/env.sh
git clone --branch 0.2.185 --single-branch https://github.com/rust-lang/libc \
    "$MINIXRS_FORKS_DIR/libc-minixrs"
cd "$MINIXRS_FORKS_DIR/libc-minixrs"
git remote rename origin upstream
git switch -c minixrs/0.2.185
git rev-parse HEAD
```

Expected: `71d5bfcc1bda05da1783666fc2cd7d9669c9c4c8`, the commit tag `0.2.185` points to. (This plan first quoted `096ede8…`, the annotated tag *object*; the Task 3 session caught it — compare against `0.2.185^{commit}`.)

- [ ] **Step 2: USER-GATED — create the GitHub fork**

Stop and ask the user before running this; it creates a public repository:

```bash
gh repo fork rust-lang/libc --org minixrs --fork-name libc-minixrs --remote=false
git remote add origin git@github.com:minixrs/libc-minixrs.git
```

If the user declines for now, continue without `origin`; Tasks 3–5 need no remote until Task 4, Step 10.

- [ ] **Step 3: Record the red state before any edit**

```bash
cargo +nightly-2026-07-23 check -Zbuild-std=core --no-default-features \
    --target ~/src/tooling/verify/testdata/aarch64-unknown-minixrs-unix.json 2>&1 | tail -3
```

Expected: a failure. At the unmodified tag the crate has no arm for this OS, so it fails with `unresolved import` / missing-type errors. This is the baseline the registration fixes.

- [ ] **Step 4: Register the target**

Apply exactly these three edits (shown as a diff against tag `0.2.185`; match on the context lines, not the line numbers):

```diff
--- a/build.rs
+++ b/build.rs
@@ -43,6 +43,7 @@
         "target_os",
         &[
             "switch", "aix", "ohos", "hurd", "rtems", "visionos", "nuttx", "cygwin", "qurt",
+            "minixrs",
         ],
     ),
     (
--- a/src/unix/mod.rs
+++ b/src/unix/mod.rs
@@ -2494,6 +2494,9 @@
     } else if #[cfg(target_os = "nuttx")] {
         mod nuttx;
         pub use self::nuttx::*;
+    } else if #[cfg(target_os = "minixrs")] {
+        mod minixrs;
+        pub use self::minixrs::*;
     } else {
         // Unknown target_os
     }
--- a/src/new/mod.rs
+++ b/src/new/mod.rs
@@ -90,6 +90,9 @@
     } else if #[cfg(target_os = "linux")] {
         mod linux_uapi;
         pub(crate) use linux_uapi::*;
+    } else if #[cfg(target_os = "minixrs")] {
+        mod minixrs;
+        pub(crate) use minixrs::*;
     } else if #[cfg(target_os = "netbsd")] {
         mod netbsd;
         pub(crate) use netbsd::*;
```

Create `src/new/minixrs/mod.rs`:

```rust
//! minixrs: musl-minixrs (musl 1.2.6) over the minixrs IPC layer.
//!
//! * Headers: <https://github.com/minixrs/musl-minixrs>

pub(crate) mod unistd;
```

Create `src/new/minixrs/unistd.rs`:

```rust
//! Header: `unistd.h`

pub use crate::new::common::posix::unistd::{
    STDERR_FILENO,
    STDIN_FILENO,
    STDOUT_FILENO,
};
```

Create `src/unix/minixrs/mod.rs` with only its header — Task 4 adds the definitions:

```rust
//! minixrs, aarch64: definitions for musl-minixrs (musl 1.2.6).
//!
//! musl-minixrs leaves musl's aarch64 type layouts and constants untouched,
//! so everything here is the Linux-musl-aarch64 definition, copied from
//! `src/unix/linux_like/`. Nothing here is derived by hand from a header.
//!
//! Every `pub type`, `pub struct` and `pub const` in this module is checked
//! against the C headers by `verify/check-libc-abi.sh` in the minixrs tooling
//! repo. Adding an item here without adding it to that manifest fails the gate.

use crate::prelude::*;
```

Why `src/new/minixrs/` exists: `src/new/mod.rs` ends with `pub use unistd::*;` for every Unix-family target, and the `unistd` module normally arrives through a `target_env` arm (`musl`, `gnu`). This target's `target_env` is empty (spec R4), so no arm supplies one and the crate fails with `unresolved import unistd`.

- [ ] **Step 5: Confirm the registration took, and what is still missing**

```bash
cargo +nightly-2026-07-23 check -Zbuild-std=core --no-default-features --message-format=short \
    --target ~/src/tooling/verify/testdata/aarch64-unknown-minixrs-unix.json 2>&1 |
    grep -o 'cannot find type `[A-Za-z0-9_]*`' | sort -u | wc -l
~/src/tooling/verify/check-libc-abi.sh; echo "exit=$?"
MINIXRS_NIGHTLY=nightly-1999-01-01 ~/src/tooling/verify/check-libc-abi.sh; echo "exit=$?"
```

Expected:
- `34` — the distinct types `src/unix/mod.rs` needs from an OS module. There is no `unresolved import` error any more; that is the proof the registration worked.
- `check-libc-abi: found no pub type/struct/const under …/src/unix/minixrs`, `exit=2`.
- `check-libc-abi: rustup toolchain nightly-1999-01-01 is not installed`, `exit=2`.

- [ ] **Step 6: Commit**

```bash
git add build.rs src/unix/mod.rs src/new/mod.rs src/new/minixrs src/unix/minixrs
git commit -s -m "minixrs: register target_os = \"minixrs\"

Selects an (empty) src/unix/minixrs module and supplies the unistd module
the Unix family re-exports, which no target_env arm provides because this
target's env is empty."
```

---

### Task 4: The aarch64 definitions (libc-minixrs session)

**Run this task in a session whose working directory is `$MINIXRS_FORKS_DIR/libc-minixrs`.**

**Files:**
- Modify: `src/unix/minixrs/mod.rs`

**Interfaces:**
- Consumes: the registration from Task 3; `~/src/tooling/verify/check-libc-abi.sh` and its manifest from Task 2.
- Produces: tag `minixrs-0.2.185-1`, which P4b's `library/Cargo.toml` pins (spec R12). The module's 45 items are exactly the 45 names in `items.list`.

- [ ] **Step 1: Confirm the gate is red**

Run: `~/src/tooling/verify/check-libc-abi.sh; echo "exit=$?"`
Expected: `found no pub type/struct/const`, `exit=2` — as Task 3 left it.

- [ ] **Step 2: Write the definitions**

Replace `src/unix/minixrs/mod.rs` with the following. Each definition is the Linux-musl-aarch64 one from `src/unix/linux_like/` (`mod.rs`, `linux_l4re_shared.rs`, `linux/mod.rs`, `linux/musl/mod.rs`, `linux/musl/b64/mod.rs`, `linux/musl/b64/aarch64/mod.rs`) with its `#[cfg]` alternatives resolved for little-endian aarch64:

```rust
//! minixrs, aarch64: definitions for musl-minixrs (musl 1.2.6).
//!
//! musl-minixrs leaves musl's aarch64 type layouts and constants untouched,
//! so everything here is the Linux-musl-aarch64 definition, copied from
//! `src/unix/linux_like/`. Nothing here is derived by hand from a header.
//!
//! Every `pub type`, `pub struct` and `pub const` in this module is checked
//! against the C headers by `verify/check-libc-abi.sh` in the minixrs tooling
//! repo. Adding an item here without adding it to that manifest fails the gate.

use crate::prelude::*;

pub type blkcnt_t = i64;
pub type blksize_t = c_int;
pub type cc_t = c_uchar;
pub type clock_t = c_long;
pub type dev_t = u64;
pub type fsblkcnt_t = u64;
pub type fsfilcnt_t = u64;
pub type ino_t = u64;
pub type mode_t = u32;
pub type nfds_t = c_ulong;
pub type nlink_t = u32;
pub type off_t = i64;
pub type pthread_key_t = c_uint;
pub type pthread_t = *mut c_void;
pub type rlim_t = c_ulonglong;
pub type sa_family_t = u16;
pub type socklen_t = u32;
pub type speed_t = c_uint;
pub type suseconds_t = i64;
pub type tcflag_t = c_uint;
pub type time_t = i64;
pub type wchar_t = u32;

pub const FD_SETSIZE: usize = 1024;
pub const NCCS: usize = 32;

s! {
    pub struct sockaddr {
        pub sa_family: sa_family_t,
        pub sa_data: [c_char; 14],
    }

    pub struct addrinfo {
        pub ai_flags: c_int,
        pub ai_family: c_int,
        pub ai_socktype: c_int,
        pub ai_protocol: c_int,
        pub ai_addrlen: socklen_t,
        pub ai_addr: *mut sockaddr,
        pub ai_canonname: *mut c_char,
        pub ai_next: *mut addrinfo,
    }

    pub struct fd_set {
        fds_bits: [c_ulong; FD_SETSIZE / 64],
    }

    pub struct tm {
        pub tm_sec: c_int,
        pub tm_min: c_int,
        pub tm_hour: c_int,
        pub tm_mday: c_int,
        pub tm_mon: c_int,
        pub tm_year: c_int,
        pub tm_wday: c_int,
        pub tm_yday: c_int,
        pub tm_isdst: c_int,
        pub tm_gmtoff: c_long,
        pub tm_zone: *const c_char,
    }

    pub struct Dl_info {
        pub dli_fname: *const c_char,
        pub dli_fbase: *mut c_void,
        pub dli_sname: *const c_char,
        pub dli_saddr: *mut c_void,
    }

    pub struct lconv {
        pub decimal_point: *mut c_char,
        pub thousands_sep: *mut c_char,
        pub grouping: *mut c_char,
        pub int_curr_symbol: *mut c_char,
        pub currency_symbol: *mut c_char,
        pub mon_decimal_point: *mut c_char,
        pub mon_thousands_sep: *mut c_char,
        pub mon_grouping: *mut c_char,
        pub positive_sign: *mut c_char,
        pub negative_sign: *mut c_char,
        pub int_frac_digits: c_char,
        pub frac_digits: c_char,
        pub p_cs_precedes: c_char,
        pub p_sep_by_space: c_char,
        pub n_cs_precedes: c_char,
        pub n_sep_by_space: c_char,
        pub p_sign_posn: c_char,
        pub n_sign_posn: c_char,
        pub int_p_cs_precedes: c_char,
        pub int_p_sep_by_space: c_char,
        pub int_n_cs_precedes: c_char,
        pub int_n_sep_by_space: c_char,
        pub int_p_sign_posn: c_char,
        pub int_n_sign_posn: c_char,
    }

    pub struct passwd {
        pub pw_name: *mut c_char,
        pub pw_passwd: *mut c_char,
        pub pw_uid: crate::uid_t,
        pub pw_gid: crate::gid_t,
        pub pw_gecos: *mut c_char,
        pub pw_dir: *mut c_char,
        pub pw_shell: *mut c_char,
    }

    pub struct dirent {
        pub d_ino: ino_t,
        pub d_off: off_t,
        pub d_reclen: c_ushort,
        pub d_type: c_uchar,
        pub d_name: [c_char; 256],
    }

    pub struct stat {
        pub st_dev: dev_t,
        pub st_ino: ino_t,
        pub st_mode: mode_t,
        pub st_nlink: nlink_t,
        pub st_uid: crate::uid_t,
        pub st_gid: crate::gid_t,
        pub st_rdev: dev_t,
        __pad0: Padding<c_ulong>,
        pub st_size: off_t,
        pub st_blksize: blksize_t,
        __pad1: Padding<c_int>,
        pub st_blocks: blkcnt_t,
        pub st_atime: time_t,
        pub st_atime_nsec: c_long,
        pub st_mtime: time_t,
        pub st_mtime_nsec: c_long,
        pub st_ctime: time_t,
        pub st_ctime_nsec: c_long,
        __unused: Padding<[c_uint; 2]>,
    }

    pub struct statvfs {
        pub f_bsize: c_ulong,
        pub f_frsize: c_ulong,
        pub f_blocks: fsblkcnt_t,
        pub f_bfree: fsblkcnt_t,
        pub f_bavail: fsblkcnt_t,
        pub f_files: fsfilcnt_t,
        pub f_ffree: fsfilcnt_t,
        pub f_favail: fsfilcnt_t,
        pub f_fsid: c_ulong,
        pub f_flag: c_ulong,
        pub f_namemax: c_ulong,
        __f_reserved: Padding<[c_int; 6]>,
    }

    pub struct termios {
        pub c_iflag: tcflag_t,
        pub c_oflag: tcflag_t,
        pub c_cflag: tcflag_t,
        pub c_lflag: tcflag_t,
        pub c_line: cc_t,
        pub c_cc: [cc_t; NCCS],
        pub __c_ispeed: speed_t,
        pub __c_ospeed: speed_t,
    }

    pub struct sigset_t {
        __val: [c_ulong; 16],
    }

    // FIXME(1.0): This should not implement `PartialEq`
    #[allow(unpredictable_function_pointer_comparisons)]
    pub struct sigaction {
        pub sa_sigaction: crate::sighandler_t,
        pub sa_mask: sigset_t,
        pub sa_flags: c_int,
        pub sa_restorer: Option<extern "C" fn()>,
    }

    pub struct sem_t {
        __val: [c_int; 8],
    }

    // musl declares each pthread object as a union of an int array and a
    // pointer-width array; one u64 array has the same size and alignment.
    pub struct pthread_attr_t {
        __size: [u64; 7],
    }

    pub struct pthread_mutex_t {
        __size: [u64; 5],
    }

    pub struct pthread_cond_t {
        __size: [u64; 6],
    }

    pub struct pthread_rwlock_t {
        __size: [u64; 7],
    }

    pub struct pthread_mutexattr_t {
        __attr: c_uint,
    }

    pub struct pthread_condattr_t {
        __attr: c_uint,
    }

    pub struct pthread_rwlockattr_t {
        __attr: [c_uint; 2],
    }
}
```

Three deliberate differences from the Linux source, each checked by the gate:
- `time_t` and `suseconds_t` are written `i64`. Linux-musl spells them `c_long` behind a deprecation attribute for 32-bit targets; this target is 64-bit only.
- The pthread objects are `[u64; N]` rather than `[u8; __SIZEOF_…]` plus an alignment attribute. musl declares each as a union of an `int` array and a pointer-width array, so size and alignment are the same; the gate compares both.
- `fd_set`'s length is `FD_SETSIZE / 64` rather than `FD_SETSIZE as usize / ULONG_SIZE`, the same value without a second constant.

- [ ] **Step 3: The crate compiles, without warnings**

```bash
cargo +nightly-2026-07-23 check -Zbuild-std=core --no-default-features --message-format=short \
    --target ~/src/tooling/verify/testdata/aarch64-unknown-minixrs-unix.json 2>&1 | tail -3
```

Expected: `Finished` with no `warning:` and no `error` line above it.

- [ ] **Step 4: The gate is green**

Run: `~/src/tooling/verify/check-libc-abi.sh`
Expected:

```
compare: 209 entries identical
check-libc-abi: PASS (45 module items covered; 0 function declarations not checked)
```

- [ ] **Step 5: Prove the comparison is load-bearing — break the source**

A green first run proves nothing. Make each edit, run the gate, confirm the quoted output, and **revert before the next**:

| Edit in `src/unix/minixrs/mod.rs` | Expected |
|---|---|
| `pub type nlink_t = u32;` → `u64` | exit 1; first line `MISMATCH 47: sizeof nlink_t: C=0x4 Rust=0x8`, then its alignment, `sizeof stat` and the `stat` offsets from `st_nlink` on; last line `compare: 16 of 209 entries differ` |
| `pub type off_t = i64;` → `u64` | exit 1; exactly `MISMATCH 48: signedness off_t: C=0x1 Rust=0x0`; `compare: 1 of 209 entries differ` |
| `pub const NCCS: usize = 32;` → `33` | exit 1; exactly `MISMATCH 61: value NCCS: C=0x20 Rust=0x21`; `compare: 1 of 209 entries differ` |

The second and third rows matter most. In the second, size and alignment are unchanged, so only the signedness entry can catch it. In the third, `termios` does not move at all — the extra `c_cc` byte lands in padding before `__c_ispeed` — so only the constant's own entry can catch it.

- [ ] **Step 6: Prove coverage is enforced (Review Focus 1)**

```bash
cp src/unix/minixrs/mod.rs /tmp/minixrs-mod.rs.keep
printf 'pub type sneaky_t = u8;\n' >> src/unix/minixrs/mod.rs
~/src/tooling/verify/check-libc-abi.sh; echo "exit=$?"
cp /tmp/minixrs-mod.rs.keep src/unix/minixrs/mod.rs && rm /tmp/minixrs-mod.rs.keep
```

Expected: `defined in … but in neither items.list nor allow.list:` followed by `  sneaky_t`, and `exit=1`. The copy-aside is deliberate: the file is not committed yet, so `git restore` would discard Step 2.

- [ ] **Step 7: Prove a `#[cfg]` is refused (Review Focus 2)**

```bash
cp src/unix/minixrs/mod.rs /tmp/minixrs-mod.rs.keep
printf '#[cfg(target_endian = "big")]\npub type time_t = i32;\n' >> src/unix/minixrs/mod.rs
~/src/tooling/verify/check-libc-abi.sh; echo "exit=$?"
cp /tmp/minixrs-mod.rs.keep src/unix/minixrs/mod.rs && rm /tmp/minixrs-mod.rs.keep
```

Expected: the offending line echoed with its file and line number, then `carries #[cfg] — coverage by name cannot see past it`, `exit=1`. Without this guard the duplicate `time_t` would pass, because coverage is by name.

- [ ] **Step 8: Prove the caller's flags do not leak (Review Focus 4)**

Run: `RUSTFLAGS='--this-flag-does-not-exist' ~/src/tooling/verify/check-libc-abi.sh | tail -1`
Expected: the same `PASS` line as Step 4. If the script honoured `RUSTFLAGS`, rustc would reject the flag.

- [ ] **Step 9: Commit and tag**

```bash
~/src/tooling/verify/check-libc-abi.sh          # green, on the restored file
git status --short                              # only src/unix/minixrs/mod.rs
git add src/unix/minixrs/mod.rs
git commit -s -m "minixrs: aarch64 definitions for musl-minixrs

The 45 types, structs and constants src/unix/mod.rs needs from an OS
module, copied from the Linux-musl-aarch64 definitions. Each is checked
against the SDK sysroot's headers by the tooling repo's
verify/check-libc-abi.sh."
git tag -s minixrs-0.2.185-1 -m "libc-minixrs 0.2.185, release 1: the P4a seed"
git log --oneline 0.2.185..HEAD
```

Expected: exactly two commits above the tag.

- [ ] **Step 10: USER-GATED — push**

Stop and ask the user. On approval:

```bash
git push -u origin minixrs/0.2.185
git push origin minixrs-0.2.185-1
```

---

### Task 5: Export the series, update the docs, check the box (tooling)

**Files:**
- Modify: `scripts/export-patches.sh`
- Create: `patches/libc/0001-*.patch`, `patches/libc/0002-*.patch` (generated)
- Modify: `docs/roadmap.md`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: the two commits and the tag from Tasks 3–4.

- [ ] **Step 1: Fix the libc base default**

In `scripts/export-patches.sh`, change the header comment line

```
#   MINIXRS_LIBC_BASE   default upstream/main
```

to

```
#   MINIXRS_LIBC_BASE   default 0.2.185   (the libc version std pins at the
#                       minixrs rustc pin; bump with any fork rebase)
```

and in `run_one` change `"${MINIXRS_LIBC_BASE:-upstream/main}"` to `"${MINIXRS_LIBC_BASE:-0.2.185}"`.

- [ ] **Step 2: Export**

Run: `scripts/export-patches.sh libc && ls patches/libc/`
Expected: `export-patches: libc → 2 patch(es) from 0.2.185..HEAD`, and two files, `0001-minixrs-register-target_os-minixrs.patch` and `0002-minixrs-aarch64-definitions-for-musl-minixrs.patch`.

- [ ] **Step 3: Update the docs**

`docs/roadmap.md` — under "Open work", change `- [ ] P4a:` to `- [x] P4a:`. Change nothing else there.

`README.md` — in the script list, below the `verify/check-driver.sh` line, add:

```
verify/check-libc-abi.sh     the P4a gate: libc-minixrs vs the sysroot's C headers
```

`CLAUDE.md` — in the "Markers describe intent; scripts describe reality" block, change `14 fixtures` to `18 fixtures` and add below the `verify/check-driver.sh` line:

```sh
verify/check-libc-abi.sh    # the P4a gate: libc-minixrs matches the C headers
ls patches/libc/*.patch     # 2 files
```

and add to the "Gotchas" list:

```markdown
- **`od -tx8` pads differently on BSD and GNU.** macOS prints `30`, GNU prints
  `0000000000000030`. `verify/libc-abi/compare.sh` strips leading zeros for
  that reason; an expected string written against one will not match the other.
- **A libc-minixrs definition needs a manifest line.** `verify/check-libc-abi.sh`
  fails on any `pub type`/`struct`/`const` in `src/unix/minixrs/` that
  `verify/libc-abi/items.list` does not name, and on any `#[cfg]` in the module.
  musl hides some members behind `_GNU_SOURCE` and spells others as macros
  (`st_atime` is `st_atim.tv_sec`; `sa_sigaction` is already a macro, so it
  takes no `RUST=C` mapping).
```

- [ ] **Step 4: Sweep for claims this branch falsified**

```bash
grep -rn '14 fixtures\|upstream/main\|needs no SDK' --include='*.md' --include='*.sh' .
```

Expected: no `14 fixtures`, no `upstream/main`. Read each `needs no SDK` hit: it must still be true (the four new fixtures need none).

- [ ] **Step 5: Run every gate, then commit**

```bash
bash -n scripts/export-patches.sh
shellcheck -S warning scripts/*.sh verify/*.sh verify/libc-abi/*.sh
verify/selftest.sh 2>/dev/null | grep -c PASS        # 18
verify/check-libc-abi.sh                             # PASS, 209 entries
git add scripts/export-patches.sh patches/libc docs/roadmap.md README.md CLAUDE.md
git commit -s -m "P4a: export the libc-minixrs series; check the box"
```

- [ ] **Step 6: USER-GATED — push and open the PR**

Stop. Per the user's pre-PR checklist: run `/claude-md-management:revise-claude-md`, then ask the user to confirm before `git push` or opening a PR.
