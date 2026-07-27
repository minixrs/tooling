# minixrs toolchain program — roadmap

The program takes minixrs from "bare-metal Rust binaries on
`aarch64-unknown-none`" to a real OS target: patched clang/lld, musl sysroot,
and Rust `std`, all under `aarch64-unknown-minixrs`, with every binary carrying
the [identity note](abi-note.md) and the kernel enforcing it.

**Locked decisions**

1. Rust `std` PAL sits on **musl libc** (std → libc crate → musl), the classic
   Unix route. The PAL is downstream of the C toolchain + musl sysroot.
2. Forks are **separate repos** (`llvm-minixrs`, `musl-minixrs`, later
   `rust-minixrs`, `libc-minixrs`) under the `minixrs` GitHub org, checked
   out together in `$MINIXRS_FORKS_DIR` — a case-sensitive APFS volume, not
   a sibling directory of this repo (see the risk register). This repo holds
   build scripts, cmake toolchain files, sysroot assembly, patch exports,
   docs, and the brand verifier.
3. The first milestone is **Rust-first**: custom target JSON + `-Zbuild-std`,
   rebuild the existing minixrs userland on the new triple, PT_NOTE branding,
   kernel enforcement — no forks needed for M1.

**Pinned environment**

- minixrs pins `nightly-2026-07-23` (rustc 1.99.0-nightly, commit `6f72b5dd5`,
  **LLVM 22.1.8**) with `rust-src` + `llvm-tools` — so the LLVM fork targets
  `release/22.x` and the same patch series later serves rustc.
- minixrs phase 5 (musl + FS) is in progress at slice 5.7. Slice 5.6 shipped
  2026-07-26 (minixrs PR #47), so **the ABI freeze is in effect**: `Message`
  layout, call numbers, endpoints and errnos now change only via a deliberate
  ABI-bump PR touching both repos. exec-from-FS is still slice 5.9.
- Cross-repo rule: minixrs/fork changes are planned here but implemented in
  separate sessions inside those repos.

## Status markers

Same convention as the minixrs repo (`docs/plan.md` / `docs/plans/*`), so the
two trackers read alike:

- `◀ next` — unstarted, and the thing to pick up next (only one at a time)
- `◀ ready (branch …, pending merge)` — implemented but unmerged
- `✓ shipped (PR #N, merged YYYY-MM-DD)` — merged

This repo runs a PR workflow as of PR #1, so entries use
`✓ shipped (PR #N, merged YYYY-MM-DD)`. Entries predating it keep the
`✓ shipped (commit <sha>, YYYY-MM-DD)` form they landed with — P0 and P2a went
straight to `main`. Items owned by another repo keep that repo's form (M1
shipped as minixrs PR #44).

Flip the previous item forward and slide `◀ next` ahead as part of each
change, in **both** the phase graph below and the matching `plans/` detail
file. Reconcile stale `◀ ready` markers against `git log` when opening new
work — "pending merge" labels on already-merged work accumulate otherwise.

## Phase graph

```
P0  tooling bootstrap (this repo)                            ✓ shipped (commit afbdc66, 2026-07-25)
P1  [minixrs] M1: triple JSON + build-std + notes + kernel   ✓ shipped (PR #44, merged 2026-07-25)
P2a [tooling] llvm fork bring-up: volume, fork, baseline     ✓ shipped (commit bd49a45, 2026-07-25)
P2b [llvm-minixrs] M2: the patch series — triple + driver    ✓ shipped (PR #1, merged 2026-07-26)
P3  [musl-minixrs + tooling] M3: real-triple sysroot, C hello   ◀ next — tooling half ready (branch feature/p3-m3-sysroot); LLVM 0006 + minixrs consumption remain
P4  [libc-minixrs + rust-minixrs] M4/M5: std PAL, rustup link   — needs P3 (the slice 5.6 ABI freeze is now in effect)
P5  upstreaming: LLVM triple + rustc tier-3 (optional)          — needs M2–M5 stability
```

**P2 is split into P2a/P2b deliberately.** The bring-up half (volume, fork,
tooling, baseline build) and the patch half land in different repos in
different sessions, and only the patch half closes the M2 gate. Marking "P2"
as one unit made an empty `patches/llvm/` look like a bug rather than the
expected state.

North star (deliberately **not** sequenced): self-hosted compilers on minixrs.
Blockers: threads, mmap, big stacks, FS scale.

## P0 — tooling bootstrap (this repo) ✓ shipped (commit afbdc66, 2026-07-25)

Repo skeleton, normative PT_NOTE spec, roadmap, sysroot layout contract, the
M1 companion plan, guarded build scripts, cmake toolchain file, and the brand
verifier with fixture selftests. **Done** when `verify/selftest.sh` passes and
`verify/check-brand.sh` correctly reports a current (unbranded) minixrs server
ELF as missing the brand.

## P1 — M1: the triple exists (minixrs repo) ✓ shipped (PR #44, merged 2026-07-25)

Executed in `~/src/minixrs`; that repo's `docs/plan.md` is authoritative for
its status. Full plan: [plans/minixrs-m1.md](plans/minixrs-m1.md). Summary:

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

Two halves, tracked separately because they land in different repos:

### P2a — fork bring-up (this repo) ✓ shipped (commit bd49a45, 2026-07-25)

`scripts/forks-volume.sh` + the case-sensitive volume, the
`$MINIXRS_FORKS_DIR` layout contract in `env.sh`, `build-llvm.sh` hardening,
`verify/check-driver.sh`, and one unpatched `build-llvm.sh --baseline` that
proved the volume, CMake 4.3, Xcode 26.6, and the `$MINIXRS_SDK` install
layout before any patch was in flight.

### P2b — the LLVM patch series (llvm-minixrs) ✓ shipped (PR #1, merged 2026-07-26)

Full patch plan: [plans/llvm-m2.md](plans/llvm-m2.md). Execute in
`$MINIXRS_FORKS_DIR/llvm-minixrs`; no LLVM source is edited from this repo
(cross-repo rule). `patches/llvm/` now holds the five-patch series — it is
`git format-patch` output over `llvmorg-22.1.8..HEAD`, regenerated by
`scripts/export-patches.sh llvm` after every rebase, and it is the reviewable
artifact for this work rather than a PR against the fork branch.

Repo **`minixrs/llvm-minixrs`** (a GitHub fork of `llvm/llvm-project` under
the org — shares object storage upstream, so creating it costs no upload).
Checked out at `$MINIXRS_FORKS_DIR/llvm-minixrs` on the case-sensitive volume
(`scripts/forks-volume.sh`).

**Pinned base: tag `llvmorg-22.1.8`** (`ca7933e47d3a`) — the exact LLVM the
pinned nightly reports, so the same series later serves rustc (P4). The fork
branches from the tag rather than the moving `release/22.x` head, which is
what makes the exported series reproducible; `MINIXRS_LLVM_BASE` defaults to
it.

Branch `minixrs/release/22.x`, rebase-maintained and force-pushed, series
exported to `patches/llvm/` via `scripts/export-patches.sh`. Review happens
over that exported series, not via PRs against the fork branch. Patch surface
~350–450 lines, mostly new files:

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
defines `__minixrs__` and links a branded static ELF — scripted as
`verify/check-driver.sh`. Two commands tell you where M2 actually stands,
without trusting any marker:

```sh
verify/check-driver.sh      # exits 0 (crt/sysroot assertions SKIP until P3)
ls patches/llvm/*.patch     # 5 files
```

## P3 — M3: the sysroot exists (musl-minixrs + tooling) — ◀ next

Full plan: [plans/musl-m3.md](plans/musl-m3.md).

**The OS half is done and the fork exists.** minixrs slice 5.6 (PR #47,
2026-07-26) shipped the port and ran a branded C hello world on minixrs, so
milestone A is reached — but **through the stand-in triple**
(`aarch64-unknown-linux-musl` + stock clang), not the patched clang. Closing M3
means reproducing that through the SDK on the real `aarch64-unknown-minixrs`
triple. The port itself is not the remaining work; the toolchain flavor is.

Three parts, in three repos:

| Part | Status |
|---|---|
| **P3a** [tooling] the SDK sysroot: `build-musl.sh`, `build-sysroot.sh`, `verify/check-image.sh` | ◀ ready (branch `feature/p3-m3-sysroot`, pending merge) |
| **P3b** [llvm-minixrs] patch 0006: pin the image base at `0x0010_0000` | ◀ next |
| **P3c** [minixrs] `kernel/build.rs` consumes `$MINIXRS_SDK` | — needs P3b |

P3a builds a sysroot that installs, passes the ABI selftest, and links a
branded hello from a bare `clang --target=aarch64-unknown-minixrs hello.c -o
hello`. The one thing still wrong is the image base, which is P3b's job — see
below.

The fork: `minixrs/musl-minixrs`, branch **`minixrs`** (the default; `main` is a
pristine upstream mirror, never committed to), based on tag **v1.2.6**. Its
whole delta is 7 files — `arch/aarch64/syscall_arch.h`,
`src/thread/aarch64/syscall_cp.s`, `src/minixrs/{ipc.c,_syscall.c,
minixrs_internal.h}`, `crt/crt1.c`'s brand block, and `MINIXRS.md`. Keeping it
that small is the design goal: musl's ~297 `__syscall` call sites are untouched,
which is what lets the other ~1900 files rebase for free. Read `MINIXRS.md`
before touching it. (The old `KevinBarnard/musl-minix` at v1.2.5 is archived and
nothing was carried over.)

Ownership split:

- minixrs keeps its `tools/build-musl.sh` (linux-musl-triple workaround per
  phase-5 D10) until M3 stabilizes, then deletes it. It is **not** a fallback —
  as of 5.6 it is the blocking `qemu-smoke` job's real dependency.
- tooling owns the SDK flavor: `scripts/build-musl.sh` builds musl-minixrs
  with the patched clang into `$MINIXRS_SDK/sysroot/usr/{include,lib}`;
  minixrs consumes via the `$MINIXRS_SDK` env var.
- The crt1 brand rides in via the musl fork (see abi-note.md).
- `scripts/build-sysroot.sh` compiles minixrs' generated `abi-selftest.c`
  against the real sysroot (`-nostdinc`, POSIX errno block armed), then links
  a hello world and runs both `verify/check-brand.sh` and
  `verify/check-image.sh` on it before installing it at
  `$MINIXRS_SDK/share/minixrs/hello` as a canned test artifact for minixrs
  sessions. A hello that fails either check is not installed.

**Inherited from slice 5.6** — each cost real debugging time there. Three of
the four turned out **not** to recur in the SDK flavor; all four were checked
against the installed SDK rather than assumed:

- **`RANLIB` must be `llvm-ar s`** — the pinned nightly ships `llvm-ar` but no
  `llvm-ranlib`. **Moot here:** the SDK ships `llvm-ranlib` (`LLVM_INSTALL_UTILS
  =ON`). `build-musl.sh` uses it and guards on it.
- **Quad-float builtins.** musl's `vfprintf` needs `__multf3`/`__floatsitf`/…
  (aarch64 `long double` is IEEE quad) and configure finds no library for them.
  minixrs sources them from `compiler_builtins` **as built by `-Zbuild-std`**.
  **Already solved here:** `build-compiler-rt.sh` installs a builtins archive
  that exports them, and the driver adds it automatically.
- **The linker script must be complete** — an orphan section past the last
  `PT_LOAD` is a silent load failure, and `__init_tls` dereferences `AT_PHDR`.
  **No linker script here:** lld's default layout already satisfies the loader.
  Only the image base needs pinning (P3b), because lld defaults to `0x200000`
  and minixrs maps every process's stack page at `SERVER_STACK_VA =
  0x0020_0000`. `verify/check-image.sh` is what turns that class of bug from a
  QEMU hang into a one-second host check.
- **The exec stack is one 4 KiB page.** Measured sufficient (~2 KB worst chain)
  and deliberately not grown — but v1.2.6's `fmt_fp` allocates a **VLA**,
  ~512 B for `%f` and **~7.4 KB for `%Lf`**, so the first C program printing a
  `long double` overflows it. No static frame scan predicts that. **Still
  live** — nothing in the SDK flavor changes it.

**M3 gate**: branded C hello world exec'd on minixrs, built by the **patched
clang on the real triple**. M3a = boot-embedded; M3b = via slice 5.9
exec-from-FS. (minixrs milestone A already cleared the M3a *shape* on the
stand-in triple — that is the reference to reproduce, not the gate itself.)

Three commands tell you where P3 actually stands, without trusting a marker:

```sh
verify/selftest.sh                     # brand + image fixtures, no SDK needed
verify/check-driver.sh                 # crt/sysroot assertions ACTIVE once P3a lands
scripts/build-sysroot.sh --skip-musl   # green only once P3b lands
```

## P4 — M4/M5: Rust std (libc-minixrs + rust-minixrs) — blocked on P3

The slice 5.6 ABI freeze this waited on is **in effect** as of 2026-07-26, so
the only remaining gate is P3. Order:

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

## P5 — upstreaming (optional) — blocked on M2–M5 stability

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
| macOS case-insensitive FS | rust and llvm checkouts break | **automated (P2)**: `scripts/forks-volume.sh` owns a case-sensitive APFS sparsebundle at `$MINIXRS_FORKS_DIR`, and `build-llvm.sh` refuses to configure if `LLVM/CMakeLists.txt` resolves (i.e. the tree is on a folding FS). External `llvm-config` still avoids a second LLVM build at P4 |
| Forks volume unmounted at build time | scripts report a confusing "clone the fork first" | every fork-consuming script points at `scripts/forks-volume.sh mount` in its not-found message |
| Sparsebundle outgrows the internal SSD (rust-minixrs at P4; local Time Machine snapshots pin deleted build bands) | builds fail on ENOSPC | move the bundle to the external SSD — only `MINIXRS_FORKS_BUNDLE` changes, no script edits |
| exec-from-FS (slice 5.9) bypasses the pack assertion | unbranded binaries reachable | the runtime `load_exec_image()` check is the authoritative gate; mkfs gets the same shared kernel-shared scan |
| An image larger than 1 MiB collides with the stack page at `0x0020_0000` — the image base is `0x0010_0000` and the gap is exactly 1 MiB | the process overwrites its own text at first push; no loader error | `verify/check-image.sh` catches it on the host, in a second, before QEMU. The OS-side fix (relocate the initial stack out of the low image region) is a later minixrs slice, not P3 |
| The `check-image.sh` VA constants are copies of minixrs' | a VA-map change in minixrs silently invalidates the checker | each constant is annotated with its defining file in minixrs; re-check on any uspace change (`SERVER_STACK_VA`, `USER_DEVICE_WINDOW_BASE`, `USER_VA_TOP`) |
| `env: ""` vs `"musl"` in the P4 target spec | crates.io cfg probes misfire | keep `env` empty; audit `cfg(target_env)` usage in early ports |
