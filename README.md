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
scripts/env.sh               exports MINIXRS_SDK, prepends its bin/ to PATH
scripts/build-llvm.sh        clang+lld from the llvm-minixrs fork → $MINIXRS_SDK
scripts/build-compiler-rt.sh builtins for aarch64-unknown-minixrs
scripts/build-musl.sh        SDK-flavor musl build → $MINIXRS_SDK/sysroot
scripts/build-sysroot.sh     sysroot assembly + ABI selftest + brand check
scripts/export-patches.sh    git format-patch from the forks → patches/
cmake/minixrs.cmake          CMake toolchain file for C consumers
patches/{llvm,musl,rust,libc}/  exported patch series (rebase-maintained forks)
verify/check-brand.sh        PT_NOTE brand verifier — works today on any ELF
verify/selftest.sh           builds fixtures and exercises the verifier
```

## Sibling repos

Forks live next to this repo (override with `MINIXRS_FORKS_DIR`); minixrs/fork
changes are planned here but implemented in sessions inside those repos.

| Repo | What | Created in |
|---|---|---|
| `~/src/minixrs` | the OS (phase 5 in progress) | exists |
| `~/src/llvm-minixrs` | llvm-project fork, branch `minixrs/release/22.x` | P2 |
| `~/src/musl-minixrs` | musl v1.2.5 fork (crt1 carries the brand) | P3 |
| `~/src/rust-minixrs` | rust fork at pin commit `6f72b5dd5` | P4 |
| `~/src/libc-minixrs` | libc crate fork (`src/unix/minixrs/`) | P4 |

macOS note: `rust-minixrs` (and ideally `llvm-minixrs`) must sit on a
case-sensitive APFS volume — see the existing `~/src/rust.sparsebundle` +
`~/src/mount-rust.sh` arrangement.

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
corresponding fork exists (see the roadmap for sequencing).

## Roadmap

See [docs/roadmap.md](docs/roadmap.md). Current milestone: **M1** — custom
target JSON + `-Zbuild-std`, all 9 minixrs user binaries branded and the
kernel rejecting unbranded ELFs. M1 is executed in the minixrs repo, driven by
[docs/plans/minixrs-m1.md](docs/plans/minixrs-m1.md).
