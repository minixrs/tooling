# Archived: upstreaming the triple (formerly roadmap phase P5)

**Not scheduled.** This was phase P5 in [`docs/roadmap.md`](../roadmap.md) until 2026-09-30. It
was removed from the roadmap because it is not the next thing after P4, or the thing after that:
several phases of libc and Rust `std` work, and a much more capable kernel, come first. It is kept
here so the intent is not lost. It carries no status and no checkbox; when it becomes real work it
returns to the roadmap as a new phase with its own spec.

## The original text

> **P5 — upstreaming (optional) — blocked on M2–M5 stability**
>
> Upstream the LLVM triple, then propose rustc tier-3. Needs M2–M5 stability and a public story
> for the OS. No schedule.

## What has to be true first

- **The Rust phases after P4 are done.** P4 only builds and links. Still to come, as separate
  roadmap phases: booting a std program (M4), then widening `libc-minixrs` and the std port call
  by call as minixrs grows the syscalls behind them.
- **Everything in P4's "Owed later" ledger is paid** — see
  [the P4 design](../superpowers/specs/2026-09-30-p4-rust-std-design.md#owed-later). In
  particular **libunwind and `panic = "unwind"`**: an upstream tier-3 target that cannot unwind is
  a hard sell, and P4 deliberately ships abort-only.
- **The kernel is much further along.** Threads, signals, a real `mmap`, pipes, and a userland
  beyond a hello world — roughly minixrs Phases 6 and 7.
- **The fork patch series are stable** across at least one LLVM point release and one nightly
  bump, so what is proposed upstream is not still moving.
- **The OS has a public story** — documentation and a reason for upstream maintainers to carry
  the target.

## Shape of the work, when it comes

1. LLVM: the `Triple` OS entry and the clang driver (`patches/llvm/` 0001–0005).
2. The `libc` crate: `src/unix/minixrs/`.
3. rustc: the target spec and std `target_os` branches, as a tier-3 target with a named
   maintainer.

Revisit the self-contained `rust-lld` link mode then. P4 chose the patched clang as the linker
driver (design decision R2); upstream tier-3 targets more often link without a C toolchain.
