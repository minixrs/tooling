# tooling — the minixrs toolchain/SDK program

Build scripts, normative specs, and glue for targeting **minixrs** from a real
toolchain: patched clang/lld (`llvm-minixrs`), a musl sysroot
(`musl-minixrs`), and eventually Rust `std` (`rust-minixrs` + `libc-minixrs`),
all under **`aarch64-unknown-minixrs`**.

This repo holds scripts, docs, and exported patch series. It does **not** hold
compiler or OS source.

## Planning docs and status markers

Status lives in `docs/roadmap.md` and nowhere else. `docs/plans/*.md` and
`docs/superpowers/` carry *detail*, and README.md links to the roadmap — none
of them repeats a status, because the copies are what go stale.
`docs/archive/` holds work that is deliberately unscheduled (upstreaming); it
carries no status at all.

**Status is a GFM checkbox and nothing else**, matching the minixrs repo's
`docs/conventions/git-and-prs.md`:

- `- [ ]` unstarted, `- [x]` done. **The first unchecked box in roadmap order is
  what to pick up next** — there is no `◀ next` pointer to slide.
- A PR checks its **own** box, in the same PR as the work. Never a follow-up
  commit, never a cleanup inherited by the next change.
- No PR number, no merge date, no "pending merge" state. `git log` and the PR
  list answer those better than a hand-maintained line does.
- Lines in the older form — `✓ shipped (PR #N, merged YYYY-MM-DD)`, or
  `✓ shipped (commit <sha>, …)` from before the PR workflow — are retired-form
  history in the roadmap's phase sections. Leave them; never write a new one.

**Markers describe intent; scripts describe reality.** Prefer running the
gate over trusting a marker:

```sh
verify/selftest.sh          # brand, image + ABI-comparer fixtures, needs no SDK — 18 fixtures
verify/check-driver.sh      # the M2 gate: does clang know the triple?
verify/check-libc-abi.sh    # the P4a gate: libc-minixrs matches the C headers
scripts/build-sysroot.sh --skip-musl   # the P3 gate — installs the branded
                            # hello at $MINIXRS_SDK/share/minixrs/hello
ls patches/llvm/*.patch     # 5 files (0001-0005 M2; 0006 the image base, dropped P3d)
ls patches/libc/*.patch     # 2 files (P4a)
```

## Workflow: superpowers

Work from P4 on is built with the superpowers skills, the same way the minixrs
repo builds its slices (`~/src/minixrs/docs/conventions/docs-and-workflow.md`
is the source of these rules; the mdBook, dprint and Hunk parts of it do not
apply here):

- **`brainstorming`** for the design, **`writing-plans`** for the task
  breakdown, **`subagent-driven-development`** to execute — a fresh subagent per
  task, a review after each, then a whole-branch review.
- Designs land in **`docs/superpowers/specs/`**, plans in
  **`docs/superpowers/plans/`**, named `YYYY-MM-DD-<topic>-{design,plan}.md`.
  One design per roadmap phase; one plan per slice. `docs/plans/*.md` are the
  pre-superpowers history for M1–M3 — leave them, write no new ones.
- **The roadmap links to a spec by relative path and never restates it.** Two
  copies drift, and the roadmap is the one people read.
- **A plan for a fork or for minixrs is written here and executed in a session
  inside that repo** (the cross-repo rule below). The plan is the hand-off.
- **A plan is not authority.** Where a plan and its spec disagree, the spec
  wins and the plan gets corrected.

Review habits that carry over, each of which caught real defects in minixrs:

- **Give a fresh reviewer the diff as a file** and ask it to verify the
  arithmetic by hand, not to confirm that a check exists.
- **The dominant defect in a subagent-driven branch is a comment, doc line or
  assertion that was true when written and falsified by a later task in the
  same branch.** Each task sees one file. As a whole-branch step, grep for
  every "not yet", "until P<n>", "nothing reaches this" and count-style
  tripwire the branch could have invalidated — in scripts, `docs/`, README.md
  and this file.
- **A rename, a moved path or a reworded claim owes a tree-wide grep** for the
  old spelling before committing. A review-fix round owes it too.
- **A subagent's report is a claim about its work, not evidence of it.** Verify
  the artifact. Work dispatched in parallel needs a dedupe pass.

## Cross-repo rule

minixrs and fork changes are **planned here, implemented in sessions inside
those repos**. Never edit LLVM/musl/rust/libc source from this repo. A plan —
`docs/superpowers/plans/` from P4 on, `docs/plans/` before it — is how work
crosses the boundary.

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
- **`build-musl.sh`'s stamp embeds the clang version string**, which carries the
  fork SHA — so any LLVM rebuild invalidates it and `build-sysroot.sh` rebuilds
  musl. That is correct, not a surprise to route around with `--skip-musl`.
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

**An LLVM rebuild does not clobber compiler-rt.** `build-llvm.sh` runs `ninja
install` into the prefix without wiping it, so
`lib/clang/22/lib/<triple>/libclang_rt.builtins.a` survives — no need to re-run
`build-compiler-rt.sh` after a driver-only patch. Confirm the file is there
rather than assume it.

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
- **Dropping a patch is a fork operation.** `patches/` is `export-patches.sh` output, so deleting a
  `.patch` file only lasts until the next export — the commit must leave the fork branch (a force-push).
  A hand deletion also leaves the survivors numbered `[PATCH n/<old count>]`; the real export fixes
  that. Dropping the *tip* commit is a `git reset --hard HEAD~1`, not a rebase, so no SHA or
  signature below it changes. Re-exports also churn the `-- \n<git version>` trailer; that is noise.
- **Seed fork clones from an existing checkout.** `git clone --reference <checkout>
  --dissociate --branch <tag> --single-branch` cut llvm-project to ~90 s. A GitHub org
  fork shares object storage with upstream, so `gh repo fork` costs no upload and the
  first branch push takes seconds.
- **Plan docs can carry stale upstream facts.** `docs/plans/llvm-m2.md` originally warned
  of a `Triple::Minix` parse collision that no longer exists at the pinned LLVM. Verify
  such claims against the actual checkout before implementing.
- **A hand-off plan from minixrs can lag its own spec.** Read the spec's current text on the
  minixrs branch before implementing; the spec wins where they differ.
- **`shellcheck -S warning` fails on unused variables (SC2034).** A constant copied from minixrs
  that no check reads belongs in a comment, not an assignment.
- **FileCheck `-NOT` only scans the gaps *between* positive matches.** Text a positive
  pattern consumed is never examined — and a wildcard like `{{[^"]*}}` will happily
  swallow the exact spelling you are excluding. Put whole-output negatives in their own
  FileCheck run with no positive directive, or use `--implicit-check-not`.
- **A new test that passes on its first run has not been verified.** Break the *source*
  to prove a check is load-bearing; breaking only the test proves it is merely
  evaluated. Choose the control token carefully — one that a positive check already
  consumed reports a false green. The same holds for a new assertion in a gate
  script: add it *before* the fix is installed, so the failing run is free proof
  that it is load bearing.
- **A grep hit is not the consumer.** `imageBase` appears in `lld/ELF/Writer.cpp`
  as a *diagnostic* threshold and in `LinkerScript.cpp` as the actual layout base;
  citing the first as the second put three wrong claims into a plan doc. Trace
  which site drives behavior, and cite the line you actually read — line numbers
  drift by one if you count a `sed` window by hand instead of using `grep -n`.
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
- **`od -tx8` pads differently on BSD and GNU.** macOS prints `30`, GNU prints
  `0000000000000030`. `verify/libc-abi/compare.sh` strips leading zeros for
  that reason; an expected string written against one will not match the other.
- **A libc-minixrs definition needs a manifest line.** `verify/check-libc-abi.sh`
  fails on any public type, struct, union, enum, static or const in
  `src/unix/minixrs/` or `src/new/minixrs/` that `verify/libc-abi/items.list`
  (or `allow.list`) does not name, and on any `#[cfg]` or `#![cfg]` there. It
  compares each field's offset and width, but not a field's signedness.
  musl hides some members behind `_GNU_SOURCE` and spells others as macros
  (`st_atime` is `st_atim.tv_sec`; `sa_sigaction` is already a macro, so it
  takes no `RUST=C` mapping).
- **`git rev-parse <tag>` on an annotated tag names the tag object, not the
  commit.** The P4a plan expected `096ede8` for libc's `0.2.185`; the checkout
  is `71d5bfc`, the commit the tag points to. Compare against `<tag>^{commit}`.
