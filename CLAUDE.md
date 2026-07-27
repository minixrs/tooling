# tooling — the minixrs toolchain/SDK program

Build scripts, normative specs, and glue for targeting **minixrs** from a real
toolchain: patched clang/lld (`llvm-minixrs`), a musl sysroot
(`musl-minixrs`), and eventually Rust `std` (`rust-minixrs` + `libc-minixrs`),
all under **`aarch64-unknown-minixrs`**.

This repo holds scripts, docs, and exported patch series. It does **not** hold
compiler or OS source.

## Planning docs and status markers

Status lives in `docs/roadmap.md` (phase graph + per-phase sections) and
`docs/plans/*.md` (per-milestone detail). Same three markers as the minixrs
repo, so both trackers read alike:

- `◀ next` — unstarted, and the thing to pick up next (only one at a time)
- `◀ ready (branch …, pending merge)` — implemented but unmerged
- `✓ shipped (PR #N, merged YYYY-MM-DD)` — merged

This repo runs a PR workflow as of PR #1, so its own entries use
`✓ shipped (PR #N, merged YYYY-MM-DD)`. Entries predating it keep the
`✓ shipped (commit <sha>, YYYY-MM-DD)` form they landed with. Items owned by
another repo keep that repo's form (M1 shipped as minixrs PR #44).

Flip the previous item forward and slide `◀ next` ahead as part of each
change, in **both** the roadmap phase graph and the matching `docs/plans/`
file. Reconcile stale `◀ ready` markers against `git log` when opening new
work — "pending merge" labels on already-merged work accumulate otherwise.

**Markers describe intent; scripts describe reality.** Prefer running the
gate over trusting a marker:

```sh
verify/selftest.sh          # brand + image fixtures, needs no SDK — 7 fixtures
verify/check-driver.sh      # the M2 gate: does clang know the triple?
scripts/build-sysroot.sh --skip-musl   # the P3 gate (fails on the image base
                            # until LLVM patch 0006 lands — that is correct)
ls patches/llvm/*.patch     # 5 files since the P2b series was exported
```

## Cross-repo rule

minixrs and fork changes are **planned here, implemented in sessions inside
those repos**. Never edit LLVM/musl/rust source from this repo. `docs/plans/`
is how work crosses the boundary.

Statuses for work owned elsewhere (e.g. M1) are convenience mirrors —
`~/src/minixrs/docs/plan.md` is authoritative for minixrs.

## Layout

`scripts/env.sh` owns the contract; source it rather than hard-coding paths:

- `MINIXRS_SDK` — install prefix, default `~/toolchains/minixrs`. Stays on the
  normal filesystem: it needs no case sensitivity and should work when the
  forks volume is unmounted.
- `MINIXRS_FORKS_DIR` — fork checkouts, default `~/src/minixrs-forks`. A
  **case-sensitive APFS sparsebundle**, because macOS' Data volume folds case
  and that breaks the LLVM and Rust trees. Managed by
  `scripts/forks-volume.sh {create|mount|unmount|status}`; mount it before any
  fork build.
- `MINIXRS_SRC` — the minixrs OS repo, a sibling of this one. Not a fork, does
  not live on the volume.

Layout contract: `docs/sysroot-layout.md`. Nothing may hard-code the SDK path.

## Building

Mount the forks volume first — every fork-consuming script fails fast without it.

- `scripts/build-llvm.sh --baseline` — unpatched tree, smoke test skipped; proves the
  environment before any patch is in flight. Without the flag the smoke test is armed
  and fails unless the driver defines `__minixrs__`.
- Knobs: `JOBS` (default `hw.ncpu`), `LINK_JOBS` (default 4 — Release+assertions links
  are memory-hungry).
- clang+lld, AArch64 only ≈ 4400 ninja edges: **~9 min** cold on 14 cores, ~4 GiB build
  tree, ~3 GiB installed.
- `ccache` is picked up automatically when on PATH. **Ignore Homebrew's advice to prepend
  `…/ccache/libexec`** — the scripts use `CMAKE_{C,CXX}_COMPILER_LAUNCHER`, and the
  symlink dir would double-wrap. Default `max_size` (5 GiB) is smaller than one LLVM
  build; raise it or the cache self-evicts to a ~0% hit rate.
- `build-llvm.sh` reuses the same `build-minixrs` dir as a manual `ninja clang` but
  reconfigures — expect a broader rebuild than the incremental you were just running.
- **musl builds *outside* its fork checkout**, unlike LLVM: minixrs pins
  `musl-minixrs` as a submodule and its CI asserts a clean `git status`. Build dirs
  live in `$MINIXRS_FORKS_DIR/build/`.
- **The ABI headers come from minixrs, never vendored here**: `cargo gen-c-headers
  [OUTDIR]` (package `minixrs-gen-c-headers`) emits `include/minixrs/*.h` plus the
  `abi-selftest.c` that `build-sysroot.sh` compiles under `-nostdinc`.

### Cross-building runtimes (compiler-rt today; musl and rust next)

CMake defaults to the host and says nothing. All four traps below were hit on
`build-compiler-rt.sh`'s first real run:

- **`CMAKE_SYSTEM_NAME` declares a cross build**, not `CMAKE_*_COMPILER_TARGET`.
  Without it macOS sets `APPLE`, compiler-rt builds `clang_rt.osx`, then says
  "no work to do". Use `Generic`.
- **Set `*_COMPILER_TARGET` for every enabled language.** A missed one builds that
  language for the host, the Mach-O object still lands in the ELF archive, and
  `ld.lld` only *warns* (`neither ET_REL nor LLVM bitcode`) before dropping it — so
  the loss surfaces as missing symbols at some later link. Assert the archive is
  uniformly `elf64-littleaarch64`.
- **`find_package` finds the SDK's own LLVM**: `env.sh` puts `$MINIXRS_SDK/bin` on
  `PATH`, and CMake derives package prefixes from `PATH`. Its `LLVMExports.cmake`
  declares SHARED targets, which any correct system name for this target rejects.
  `-DCMAKE_DISABLE_FIND_PACKAGE_LLVM=ON`.
- **Reconfiguring in place does not retarget.** CMake pins `CMAKE_SYSTEM_NAME` and
  the source dir, and compiler-rt caches its *derived* install path — so flipping a
  layout flag rebuilds and installs to the old location anyway. Guard on the derived
  value, `rm -rf` on mismatch.

compiler-rt specifics: enter at `compiler-rt/lib/builtins` (standalone project,
skips `load_llvm_config()`); `LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON` plus
`LLVM_DEFAULT_TARGET_TRIPLE` give the `lib/<triple>/` layout the driver searches.

## Changing scripts

No test suite — the gates are `bash -n <script>`, `shellcheck -S warning scripts/*.sh
verify/*.sh`, `verify/selftest.sh`, and exercising the guard paths by hand, including
with the volume unmounted (`scripts/forks-volume.sh unmount`). Guard-path regressions
are the failure mode here: the scripts are mostly preconditions.

## Gotchas

- **macOS ships bash 3.2.** Under `set -u`, expanding an empty array as
  `"${ARR[@]}"` is a fatal unbound-variable error. Use
  `${ARR[@]+"${ARR[@]}"}` (see `build-llvm.sh`, `verify/selftest.sh`).
- **`env.sh` is sourced from both bash and zsh.** It falls back from
  `BASH_SOURCE` to `$0` for self-location; zsh leaves `BASH_SOURCE` unset, and
  getting this wrong silently resolves every path one directory too high.
- **`build-llvm.sh` refuses a case-insensitive checkout** by testing whether
  `LLVM/CMakeLists.txt` also resolves. Cheaper than discovering it an hour in.
- Fork branches are **rebase-maintained and force-pushed**. Review happens
  over the exported series in `patches/`, not via PRs against fork branches;
  re-run `scripts/export-patches.sh <fork>` after every rebase.
- **Seed fork clones from an existing checkout.** `git clone --reference <checkout>
  --dissociate --branch <tag> --single-branch` cut llvm-project to ~90 s. A GitHub org
  fork shares object storage with upstream, so `gh repo fork` costs no upload and the
  first branch push takes seconds.
- **Plan docs can carry stale upstream facts.** `docs/plans/llvm-m2.md` originally warned
  of a `Triple::Minix` parse collision that no longer exists at the pinned LLVM. Verify
  such claims against the actual checkout before implementing.
- **FileCheck `-NOT` only scans the gaps *between* positive matches.** Text a positive
  pattern consumed is never examined — and a wildcard like `{{[^"]*}}` will happily
  swallow the exact spelling you are excluding. Put whole-output negatives in their own
  FileCheck run with no positive directive, or use `--implicit-check-not`.
- **A new test that passes on its first run has not been verified.** Break the *source*
  to prove a check is load-bearing; breaking only the test proves it is merely
  evaluated. Choose the control token carefully — one that a positive check already
  consumed reports a false green.
- **A sibling check can mask the one you disabled.** Break the whole rule, not one
  clause: disabling only `check-image.sh`'s `p_vaddr` alignment test still printed
  "not 4096-byte aligned" from the `p_offset` test — a false green for the sabotage.
- **The Bash tool's shell is zsh.** `${PIPESTATUS[0]}` and `read -ra` fail or expand
  to nothing *silently*; a probe loop using them reported four identical results that
  were all the no-flags case. Wrap multi-step shell probes in `bash -c`.
- **Bash arithmetic has no `_` digit separators.** Mirroring a minixrs constant like
  `0x0020_0000` into shell must drop them, or `$(( ))` parses `_0000` as a variable
  name (see `verify/check-image.sh`).
- **`-z separate-loadable-segments` is what makes lld emit 4 KiB-aligned `PT_LOAD`s**,
  not `-z max-page-size=4096`, which only sets the granularity — dropping max-page-size
  alone still yields 64 KiB- (hence 4 KiB-) aligned segments. Without
  separate-loadable-segments lld packs segments so only `p_offset ≡ p_vaddr (mod page)`
  holds and *neither* is aligned.
