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
docs/roadmap.md              phases P0–P5, milestone gates, risk register
docs/abi-note.md             normative PT_NOTE brand spec (byte-exact)
docs/sysroot-layout.md       $MINIXRS_SDK layout contract
docs/plans/minixrs-m1.md     M1 implementation plan — execute in ~/src/minixrs
docs/plans/llvm-m2.md        M2 patch plan — execute in the llvm-minixrs fork
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
verify/selftest.sh           builds fixtures and exercises the verifier
verify/check-driver.sh       the M2 gate: does clang know the triple?
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
| `~/src/minixrs` | the OS (phase 5 in progress) — **not** a fork, stays a sibling of this repo (`$MINIXRS_SRC`) | exists |
| `$MINIXRS_FORKS_DIR/llvm-minixrs` | llvm-project fork at `llvmorg-22.1.8`, branch `minixrs/release/22.x` | P2 |
| `$MINIXRS_FORKS_DIR/musl-minixrs` | musl v1.2.5 fork (crt1 carries the brand) | P3 |
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

The brand verifier needs no SDK — only `od`/`dd`:

```sh
verify/check-brand.sh path/to/some.elf   # 0 branded / 1 missing / 2 bad ABI
verify/selftest.sh                       # builds fixtures, checks all verdicts
```

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

See [docs/roadmap.md](docs/roadmap.md), which tracks phase status with the
same `◀ next` / `◀ ready` / `✓ shipped` markers the minixrs repo uses.

| Phase | Status |
|---|---|
| P0 tooling bootstrap | ✓ shipped |
| P1 / M1 triple + branding (minixrs repo) | ✓ shipped (PR #44) |
| P2a llvm fork bring-up | ✓ shipped |
| **P2b / M2 LLVM patch series** | **◀ next** — [docs/plans/llvm-m2.md](docs/plans/llvm-m2.md) |
| P3 / M3 sysroot | blocked on P2b + minixrs slice 5.6 |

`patches/llvm/` is `git format-patch` output and stays empty until P2b ships.
