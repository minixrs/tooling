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

This repo does not run a PR workflow yet — changes land directly on `main`,
so its own entries use `✓ shipped (commit <sha>, YYYY-MM-DD)`. Switch to the
`PR #N` form once formal review is in place. Items owned by another repo keep
that repo's form (M1 shipped as minixrs PR #44).

Flip the previous item forward and slide `◀ next` ahead as part of each
change, in **both** the roadmap phase graph and the matching `docs/plans/`
file. Reconcile stale `◀ ready` markers against `git log` when opening new
work — "pending merge" labels on already-merged work accumulate otherwise.

**Markers describe intent; scripts describe reality.** Prefer running the
gate over trusting a marker:

```sh
verify/selftest.sh          # brand verifier, needs no SDK — 3 fixtures
verify/check-driver.sh      # the M2 gate: does clang know the triple?
ls patches/llvm/*.patch     # non-empty only after the M2 series ships
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
