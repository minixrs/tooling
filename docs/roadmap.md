# minixrs toolchain program — roadmap

The program takes minixrs from "bare-metal Rust binaries on
`aarch64-unknown-none`" to a real OS target: patched clang/lld, musl sysroot,
and Rust `std`, all under `aarch64-unknown-minixrs`, with every binary carrying
the [identity note](abi-note.md) and the kernel enforcing it.

**Locked decisions**

1. Rust `std` PAL sits on **musl libc** (std → libc crate → musl), the classic
   Unix route. The PAL is downstream of the C toolchain + musl sysroot.
2. Forks are **sibling repos** (`llvm-minixrs`, `musl-minixrs`, later
   `rust-minixrs`, `libc-minixrs`); this repo holds build scripts, cmake
   toolchain files, sysroot assembly, patch exports, docs, and the brand
   verifier.
3. The first milestone is **Rust-first**: custom target JSON + `-Zbuild-std`,
   rebuild the existing minixrs userland on the new triple, PT_NOTE branding,
   kernel enforcement — no forks needed for M1.

**Pinned environment**

- minixrs pins `nightly-2026-07-23` (rustc 1.99.0-nightly, commit `6f72b5dd5`,
  **LLVM 22.1.8**) with `rust-src` + `llvm-tools` — so the LLVM fork targets
  `release/22.x` and the same patch series later serves rustc.
- minixrs phase 5 (musl + FS) is in progress at slice 5.3. The ABI freeze
  point is slice 5.6; exec-from-FS is slice 5.9.
- Cross-repo rule: minixrs/fork changes are planned here but implemented in
  separate sessions inside those repos.

## Phase graph

```
P0 tooling bootstrap (done — this repo)                    — no deps
P1 [minixrs] M1: triple JSON + build-std + notes + kernel  — needs P0 spec; land after slice 5.3
P2 [llvm-minixrs] M2: patched clang/lld/compiler-rt SDK    — independent; can run parallel to P1
P3 [musl-minixrs + tooling] M3: real-triple sysroot, C hello — tooling half needs P2; OS half needs slices 5.4/5.5/5.6 (5.9 for exec-from-FS)
P4 [libc-minixrs + rust-minixrs] M4/M5: std PAL, rustup link — needs P3 + slice 5.6 ABI freeze
P5 upstreaming: LLVM triple + rustc tier-3 (optional)      — needs M2–M5 stability
```

North star (deliberately **not** sequenced): self-hosted compilers on minixrs.
Blockers: threads, mmap, big stacks, FS scale.

## P0 — tooling bootstrap (this repo)

Repo skeleton, normative PT_NOTE spec, roadmap, sysroot layout contract, the
M1 companion plan, guarded build scripts, cmake toolchain file, and the brand
verifier with fixture selftests. **Done** when `verify/selftest.sh` passes and
`verify/check-brand.sh` correctly reports a current (unbranded) minixrs server
ELF as missing the brand.

## P1 — M1: the triple exists (minixrs repo)

Full plan: [plans/minixrs-m1.md](plans/minixrs-m1.md). Summary:

- `tools/targets/aarch64-unknown-minixrs.json` mirrors the pinned nightly's
  `aarch64-unknown-none` spec, changing only `"os": "minixrs"`; `llvm-target`
  stays `aarch64-unknown-none` until the fork rustc exists (P4).
- The **kernel stays** on `aarch64-unknown-none` (truthfully bare-metal); only
  the 9 user binaries move.
- Per-crate 3-line `build.rs` emits `-Tuser.ld` (cfg-gated), letting
  `kernel/build.rs` drop the `CARGO_ENCODED_RUSTFLAGS` cancel-hack and
  collapse 9 isolated nested target dirs into one shared one.
- Nested builds add `-Zbuild-std=core,alloc`
  `-Zbuild-std-features=compiler-builtins-mem`.
- `brand!();` in each of the 9 `main.rs`; `user.ld` × 9 gains the PT_NOTE
  phdr + KEEP rule; kernel-shared gains the note scan; `load_exec_image()`
  enforces it (staged warn → reject); `kernel/build.rs` asserts at pack time.

**M1 gate**: QEMU boot green with all 9 branded; kernel rejects unbranded;
pack assertion active; CI green.

## P2 — M2: the toolchain exists (llvm-minixrs)

Branch `minixrs/release/22.x`, rebase-maintained, series exported to
`patches/llvm/` via `scripts/export-patches.sh`. Patch surface ~350–450 lines,
mostly new files:

- `llvm/include/llvm/TargetParser/Triple.h` + `Triple.cpp`: OS enum + parse
  (~10 lines); `TripleTest.cpp` coverage.
- `clang/lib/Basic/Targets/OSTargets.h`: `MinixRSTargetInfo` defining
  `__minixrs__`, `__unix__`, `__ELF__`; `Targets.cpp` case.
- New `clang/lib/Driver/ToolChains/MinixRS.{h,cpp}` modeled on
  Fuchsia/NetBSD: ld.lld, static-only, crt1/crti/crtn from the sysroot,
  compiler-rt per-target builtins,
  `-z max-page-size=4096 -z separate-loadable-segments` (per minixrs D13);
  `Driver.cpp` case; `clang/test/Driver/minixrs.c`.

Built by `scripts/build-llvm.sh` (clang;lld, AArch64 only,
`LLVM_INSTALL_UTILS=ON`, prefix `$MINIXRS_SDK`) and
`scripts/build-compiler-rt.sh` (builtins-only,
`COMPILER_RT_DEFAULT_TARGET_ONLY`, baremetal).

**M2 gate**: driver test passes; `clang --target=aarch64-unknown-minixrs`
defines `__minixrs__` and links a branded static ELF.

## P3 — M3: the sysroot exists (musl-minixrs + tooling)

Ownership split:

- minixrs keeps its CI-fallback `tools/build-musl.sh` (linux-musl-triple
  workaround per phase-5 D10) until M3 stabilizes, then deletes it.
- tooling owns the SDK flavor: `scripts/build-musl.sh` builds musl-minixrs
  with the patched clang into `$MINIXRS_SDK/sysroot/usr/{include,lib}`;
  minixrs consumes via the `$MINIXRS_SDK` env var.
- The crt1 brand rides in via the musl fork (see abi-note.md).
- `scripts/build-sysroot.sh` runs the minixrs gen-c-headers ABI selftest
  against the real sysroot and brand-checks a linked hello world, which it
  installs at `$MINIXRS_SDK/share/minixrs/hello` as a canned test artifact
  for minixrs sessions.

**M3 gate**: branded C hello world exec'd on minixrs. M3a = boot-embedded
(≈ minixrs milestone A); M3b = via slice 5.9 exec-from-FS. The tooling half
can be fully ready before the OS half.

## P4 — M4/M5: Rust std (libc-minixrs + rust-minixrs)

Start only after the slice 5.6 ABI freeze. Order:

1. **libc-minixrs**: `src/unix/minixrs/` mirroring the musl-aarch64
   definitions, D7/D8 errno parity; extend minixrs gen-c-headers with a
   Rust-consts emitter as a CI diff gate.
2. **rust-minixrs** at pin commit `6f72b5dd5`: `rustc_target` base + target
   spec (`os: "minixrs"`, **`env: ""`** — not `"musl"`, which would drag in
   Linux-musl ecosystem cfg paths; `families: ["unix"]`, static-crt,
   rust-lld; `llvm-target` now `aarch64-unknown-minixrs`). std reuses
   `sys/pal/unix` with `target_os` branches (crib the recent Hurd/Cygwin
   tier-3 PRs). musl provides all symbols, so kernel gaps surface as runtime
   `ENOSYS` errors (e.g. `thread::spawn` → `Err`), not compile errors.
3. Build rustc against the installed llvm-minixrs via `bootstrap.toml`
   `llvm-config` — no second LLVM build. (Patching the `src/llvm-project`
   submodule is the documented fallback.)
4. `./x build library`; `rustup toolchain link minixrs …/stage2`.

**M4 gate**: std hello world on minixrs.
**M5 gate**: bare `cargo +minixrs build --target aarch64-unknown-minixrs`
with no JSON and no build-std — then delete the JSON + check-cfg shims from
minixrs.

## P5 — upstreaming (optional)

Upstream the LLVM triple, then propose rustc tier-3. Needs M2–M5 stability
and a public story for the OS. No schedule.

## Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| build-std quirks: `compiler-builtins-mem` needed for memcpy/memset | link failures in nested builds | pass `-Zbuild-std-features=compiler-builtins-mem` explicitly; verify on the pinned nightly (M1 step) |
| Target-spec JSON format churn on nightly bumps | nested builds break on toolchain update | regenerate from `rustc --print target-spec-json --target aarch64-unknown-none` and re-apply the one-line `os` change |
| `unexpected_cfgs` on host clippy (`-D warnings`) | CI red | workspace `check-cfg` for `cfg(target_os, values("minixrs"))` |
| Nested-build blowup: 9 isolated target dirs × build-std | core compiled 9× per kernel build | shared nested `CARGO_TARGET_DIR` (M1) |
| LLVM fork drift across 22.x point releases | rebase cost | patch surface is mostly new files — rebases are cheap; patches exported to `patches/llvm/` after every rebase |
| minixrs nightly bumps once rust-minixrs exists | fork and pin diverge | bump both in lockstep; the pin commit is recorded in the rust-minixrs branch name/tag |
| macOS case-insensitive FS | rust (and possibly llvm) checkouts break | case-sensitive APFS volume before first clone (`~/src/rust.sparsebundle` pattern); LLVM build ~2–4 GB; external `llvm-config` avoids a second LLVM build |
| exec-from-FS (slice 5.9) bypasses the pack assertion | unbranded binaries reachable | the runtime `load_exec_image()` check is the authoritative gate; mkfs gets the same shared kernel-shared scan |
| `env: ""` vs `"musl"` in the P4 target spec | crates.io cfg probes misfire | keep `env` empty; audit `cfg(target_env)` usage in early ports |
