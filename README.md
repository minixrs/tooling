# tooling — the minixrs toolchain/SDK program

Build scripts, normative specs, and glue for targeting **minixrs**
(`~/src/minixrs`) from a real toolchain: a patched clang/lld
(`llvm-minixrs`), a musl-based sysroot (`musl-minixrs`), and eventually Rust
`std` (`rust-minixrs` + `libc-minixrs`) — all under the target triple
**`aarch64-unknown-minixrs`**.

minixrs binaries are branded with a NetBSD-style ELF `PT_NOTE` so the OS can
verify what it loads. `EI_OSABI` stays 0 permanently — the note *is* the
identity, so stock binutils/gdb/lldb keep working forever. The normative spec
is [docs/abi-note.md](docs/abi-note.md).

## Repo map

```
docs/roadmap.md              phases P0–P4, milestone gates, risk register
docs/superpowers/specs/      per-phase designs (P4 onward)
docs/superpowers/plans/      per-slice implementation plans (P4 onward)
docs/archive/                work that is deliberately unscheduled (upstreaming)
docs/abi-note.md             normative PT_NOTE brand spec (byte-exact)
docs/sysroot-layout.md       $MINIXRS_SDK layout contract
docs/plans/minixrs-m1.md     M1 implementation plan — execute in ~/src/minixrs
docs/plans/llvm-m2.md        M2 patch plan — execute in the llvm-minixrs fork
docs/plans/musl-m3.md        M3 sysroot plan + the two cross-repo hand-offs
scripts/env.sh               exports MINIXRS_SDK/MINIXRS_FORKS_DIR/MINIXRS_SRC
scripts/forks-volume.sh      case-sensitive APFS volume for the fork checkouts
scripts/build-llvm.sh        clang+lld from the llvm-minixrs fork → $MINIXRS_SDK
scripts/build-compiler-rt.sh builtins for aarch64-unknown-minixrs
scripts/build-musl.sh        SDK-flavor musl build → $MINIXRS_SDK/sysroot
scripts/build-sysroot.sh     sysroot assembly + ABI selftest + brand check
scripts/export-patches.sh    git format-patch from the forks → patches/
cmake/minixrs.cmake          CMake toolchain file for C consumers
patches/{llvm,musl,rust,libc}/  exported patch series (rebase-maintained forks)
verify/check-brand.sh        PT_NOTE brand verifier — works today on any ELF
verify/check-image.sh        the kernel loader's rules, checked on the host
verify/selftest.sh           builds fixtures and exercises both verifiers
verify/check-driver.sh       the M2 gate: does clang know the triple?
verify/check-libc-abi.sh     the P4a gate: libc-minixrs vs the sysroot's C headers
```

## Fork checkouts

macOS' Data volume is case-insensitive, which breaks both the LLVM and the
Rust source trees. So the forks do **not** live next to this repo — they live
on a case-sensitive APFS sparsebundle, `$MINIXRS_FORKS_DIR`, default
`~/src/minixrs-forks`:

```sh
scripts/forks-volume.sh create    # one-time: 150 GiB sparse, case-sensitive
scripts/forks-volume.sh mount     # idempotent; after a reboot
scripts/forks-volume.sh status    # mounted? case-sensitive? how full?
```

150 GiB is the ceiling, not the footprint — the image is sparse and grows on
demand. Moving it to another disk needs no script change, only
`MINIXRS_FORKS_BUNDLE`.

minixrs/fork changes are planned here but implemented in sessions inside
those repos.

| Repo | What | Created in |
|---|---|---|
| `~/src/minixrs` | the OS (phase 5 complete) — **not** a fork, stays a sibling of this repo (`$MINIXRS_SRC`) | exists |
| `$MINIXRS_FORKS_DIR/llvm-minixrs` | llvm-project fork at `llvmorg-22.1.8`, branch `minixrs/release/22.x` | P2 |
| `$MINIXRS_FORKS_DIR/musl-minixrs` | musl fork at `v1.2.6`, branch `minixrs` (crt1 carries the brand) | exists |
| `$MINIXRS_FORKS_DIR/rust-minixrs` | rust fork at pin commit `6f72b5dd5` | P4 |
| `$MINIXRS_FORKS_DIR/libc-minixrs` | libc crate fork (`src/unix/minixrs/`) | P4 |

`$MINIXRS_SDK` deliberately stays on the normal filesystem
(`~/toolchains/minixrs`): the installed SDK needs no case sensitivity and
should keep working when the volume is unmounted.

## $MINIXRS_SDK

Everything installs into one prefix, default `~/toolchains/minixrs`:

```sh
. scripts/env.sh          # exports MINIXRS_SDK, puts $MINIXRS_SDK/bin on PATH
```

Layout contract: [docs/sysroot-layout.md](docs/sysroot-layout.md).

## What works today

Both verifiers need no SDK — only `od`/`dd`:

```sh
verify/check-brand.sh path/to/some.elf   # 0 branded / 1 missing / 2 bad ABI
verify/check-image.sh path/to/some.elf   # 0 loadable / 1 breaks a loader rule
verify/selftest.sh                       # builds fixtures, checks all verdicts
```

`check-image.sh` mirrors the minixrs kernel's ELF loader — `ET_EXEC`,
page-aligned `PT_LOAD`s, `AT_PHDR` reachable, W^X, and clear of the stack
guard page (`USER_REGION_LIMIT`) — so a bad image fails in a second on the
host instead of hanging in QEMU. `AT_PHDR` is musl's need, not the loader's:
pass `--boot-module` for minixrs's servers, drivers, mfs and init, which are
never exec'd and deliberately leave their headers unmapped.

The build scripts fail fast with a "clone X first" message until the
corresponding fork exists (see the roadmap for sequencing), and point at
`scripts/forks-volume.sh mount` in case the volume is merely unmounted.

Once `scripts/build-llvm.sh` has installed a clang, the M2 gate is:

```sh
verify/check-driver.sh                    # 0 = clang knows the triple
```

Against an unpatched (`--baseline`) clang it correctly fails at step 1 with
`__minixrs__ not defined`.

## Roadmap

See [docs/roadmap.md](docs/roadmap.md). Status there is a GFM checkbox and
nothing else — the first unchecked box under **Open work** is what to pick up
next. This file deliberately keeps no copy of it.

Per-milestone detail: [minixrs-m1.md](docs/plans/minixrs-m1.md),
[llvm-m2.md](docs/plans/llvm-m2.md), [musl-m3.md](docs/plans/musl-m3.md), and
from P4 on the designs under [docs/superpowers/specs/](docs/superpowers/specs/)
— P4 is [Rust `std`, build and link](docs/superpowers/specs/2026-09-30-p4-rust-std-design.md).

`patches/*/` is `git format-patch` output, re-exported by
`scripts/export-patches.sh` after every fork rebase. `llvm/` holds 5 patches
(0001–0005 from P2b; 0006, the P3b image base, was dropped by P3d) and
`musl/` the port series; the rest stay empty until their fork exists.
