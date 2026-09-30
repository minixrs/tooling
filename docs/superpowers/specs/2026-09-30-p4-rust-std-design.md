# P4 — Rust `std` for `aarch64-unknown-minixrs`: build and link

Design for roadmap phase P4. Status lives in [`docs/roadmap.md`](../../roadmap.md) and nowhere
else; this file holds the reasoning.

## Outcome

After P4, this works on a machine with the SDK installed, with no target JSON, no `-Zbuild-std`
and no `RUSTFLAGS`:

```sh
cargo new hello && cd hello
cargo +minixrs build --target aarch64-unknown-minixrs
```

and the resulting ELF is branded, has a layout the minixrs loader accepts, and is installed at
`$MINIXRS_SDK/share/minixrs/hello-rs`. That is the **M5 gate**, and it is where P4 ends.

**P4 does not boot anything.** The old roadmap put M4 ("std hello world on minixrs") before M5.
This design inverts that: M4 moves to the phase after P4. The reason is a dependency the roadmap
did not show — see [Why the boot is not in P4](#why-the-boot-is-not-in-p4).

P4 is the first of several Rust phases. Later phases widen libc-minixrs and the std port as the
kernel grows; upstreaming is archived in [`docs/archive/upstreaming.md`](../../archive/upstreaming.md)
until those are done.

## Why the boot is not in P4

Verified against the pinned nightly's `library/` (`nightly-2026-07-23`), the musl fork, and the
minixrs trackers on 2026-09-29:

- **`malloc` has no memory.** `musl-minixrs`'s `src/minixrs/_syscall.c` dispatches six calls
  (`writev`, `write`, `exit`, `exit_group`, `set_tid_address`, `ioctl`); its default arm returns
  `-ENOSYS`. `brk` and `mmap` therefore fail, `malloc` returns `NULL`, and `println!` — which
  allocates its line buffer — aborts. The fix is minixrs pre-Phase-6 **chunk 5 ("musl syscall
  surface")** in `~/src/minixrs/docs/plans/phase-6-prep.md`, which is unchecked.
- **std's startup aborts on `ENOSYS`.** `std/src/sys/pal/unix/mod.rs` calls `poll()` on fds 0–2
  and aborts on any errno outside a short list, then asserts that `signal(SIGPIPE, SIG_IGN)`
  succeeded. P4 fixes both in std (R6), but that only gets the program as far as `malloc`.

Blocking P4 on kernel work would stall the toolchain for no benefit: everything P4 builds can be
verified on the host.

## Locked decisions

| # | Decision | Rejected alternative, and why |
|---|---|---|
| **R1** | P4 ends at M5 (build + link + host checks). M4 (boot) opens the next phase. | P4 includes the boot — blocks on minixrs chunk 5. |
| **R2** | The patched **clang is the linker driver** for Rust binaries: `linker-flavor: gnu-cc`, `linker: clang`, pre-link arg `--target=aarch64-unknown-minixrs`. | `rust-lld` with self-contained crt objects — restates the driver's crt order and `-z` flags in the target spec, and the two copies drift. The brand only reaches a binary through musl-minixrs's `crt1.o`, which the driver already selects. |
| **R3** | **`panic = "abort"` only.** No unwinder is built or linked. | Shipping LLVM libunwind — the largest item in the phase, and untestable because nothing boots. Owed later; see the [ledger](#owed-later). |
| **R4** | std reuses `sys/pal/unix` with `target_os = "minixrs"` branches; `families: ["unix"]`, `env: ""`. | A dedicated IPC-speaking PAL — thousands of lines duplicating musl-minixrs, and contrary to roadmap locked decision 1. `env: "musl"` — drags in Linux-musl `cfg` paths across crates.io. |
| **R5** | **No fake success in std.** Where the kernel lacks a call, std calls musl, musl answers `-ENOSYS`, and std returns `Err` or tolerates the errno. When the kernel grows the call, the feature turns on with no std change. | Stubbing calls to succeed — hides kernel gaps and needs a second std change later. |
| **R6** | A carve-out (std behaving differently on minixrs) is allowed **only** where std would otherwise abort at startup, or where a `cfg` chain would not compile. | Excluding whole features by `target_os` — violates R5. |
| **R7** | The libc ABI gate is a **host-side byte comparison** of C-emitted and Rust-emitted tables (`verify/check-libc-abi.sh`). | The roadmap's "Rust-consts emitter in minixrs gen-c-headers" — needs a minixrs change, and covers constants only. Errno parity is already transitive: `abi-selftest.c` proves musl's errnos equal minixrs's, and R7 proves libc-minixrs's equal musl's. |
| **R8** | Build **stage 1**: a stage-1 rustc plus stage-1 std for host and target. | Stage 2 — roughly double the build, and only needed to ship a compiler. |
| **R9** | The toolchain is **installed to `$MINIXRS_SDK/rust/`** and rustup links that. | Linking the build tree on the forks volume — breaks `cargo +minixrs` whenever the volume is unmounted, against the `MINIXRS_SDK` contract. |
| **R10** | rustc links the **installed llvm-minixrs** through `llvm-config`. The SDK's LLVM is 22.1.8, static, AArch64-only; the host is AArch64 too, so one backend serves both. | Patching `src/llvm-project` and building LLVM again — stays the documented fallback if the external LLVM is rejected. |
| **R11** | minixrs **keeps** its target JSON and `check-cfg` shims through P4. | Deleting them at M5 as the roadmap said — minixrs CI would then need the fork toolchain, which has no runner story. Owed later. |
| **R12** | rust-minixrs pins libc-minixrs by **git tag** (`minixrs-0.2.185-N`) in `library/Cargo.toml`'s existing `[patch.crates-io]`. | A branch or bare SHA — fork branches are force-pushed, so a SHA can be orphaned. A path dependency — makes the exported patch series unbuildable elsewhere. |

## Slices

Each slice gets its own plan under `docs/superpowers/plans/`, written in this repo and executed in
a session inside the owning repo (the cross-repo rule). Each has one roadmap checkbox.

| Slice | Repo | Delivers | Gate |
|---|---|---|---|
| **P4a** | `libc-minixrs` + tooling | The fork and `verify/check-libc-abi.sh` | The parity check is green and its negative fixture is red |
| **P4b** | `rust-minixrs` | Target spec, std port, libc pinned | `./x build --stage 1 library` succeeds for host and target |
| **P4c** | tooling | `build-rust.sh`, `check-rust.sh`, patch exports, layout docs | M5 |

P4a's gate needs no rustc fork, so P4a and the first half of P4b can proceed independently; P4b
cannot finish until a libc-minixrs tag exists.

## P4a — libc-minixrs

- **Fork:** `minixrs/libc-minixrs`, from `rust-lang/libc` tag `0.2.185` — the version std pins in
  `library/Cargo.lock`. Branch `minixrs/0.2.185`, rebase-maintained, force-pushed; tags
  `minixrs-0.2.185-N` are never moved.
- **Content:** one self-contained module, `src/unix/minixrs/`, plus the three registration points
  the Hurd port touches: `build.rs`, `src/unix/mod.rs`, `src/new/mod.rs`.
- **Source of the definitions:** musl-minixrs leaves musl's aarch64 type layouts and constants
  untouched (its delta is seven files, none under `arch/aarch64/bits/`), so the definitions are
  libc's existing Linux-musl-aarch64 ones, copied. They are not re-derived from headers by hand.
- **Size rule:** the module contains what std compiles against, grown until P4b's gate passes. No
  Linux-only API (epoll, inotify, netlink, `/proc` helpers). Later phases widen it.

### The parity gate — `verify/check-libc-abi.sh`

1. A tooling-owned manifest, `verify/libc-abi/items.list`, names every struct (with its fields)
   and every constant in `src/unix/minixrs/`.
2. From the manifest the script generates two emitters. The C one is compiled by the SDK clang
   against the SDK sysroot; the Rust one against libc-minixrs. Each defines a single `.rodata`
   symbol holding the same ordered table of `u64`s: `sizeof`, `alignof` and each field offset per
   struct, and each constant's value.
3. Both objects are reduced to the raw bytes of that symbol with `llvm-objcopy` and compared. A
   mismatch reports the manifest line it corresponds to.
4. **Coverage is enforced.** Every `pub struct` and `pub const` in the module must appear in the
   manifest, or in `verify/libc-abi/allow.list` with a reason on the same line. A definition in
   neither fails the check — otherwise a new item bypasses the gate without anyone noticing.

The Rust side builds with the pinned nightly, `-Zbuild-std=core`, and a test-only target JSON
under `verify/testdata/` (`os: minixrs`, `families: ["unix"]`), so the gate does not depend on
rust-minixrs existing.

`verify/selftest.sh` gains a negative fixture: a manifest line with a deliberately wrong offset
must make the comparer fail, and fail naming that line.

## P4b — rust-minixrs

- **Fork:** `minixrs/rust-minixrs` at commit `6f72b5dd5` (the pinned nightly). Branch
  `minixrs/nightly-2026-07-23`, rebase-maintained; series exported to `patches/rust/`.

### Target spec

| Field | Value | Why |
|---|---|---|
| `llvm-target` | `aarch64-unknown-minixrs` | The real triple; rustc now links an LLVM that knows it |
| `os` / `env` / `vendor` | `minixrs` / `""` / `unknown` | R4 |
| `families` | `["unix"]` | R4 |
| linker | `gnu-cc`, `clang`, pre-link `--target=aarch64-unknown-minixrs` | R2 |
| `features` | `+v8a,+fp-armv8,+neon` | Exactly what `clang --target=aarch64-unknown-minixrs -###` reports, so C and Rust objects agree |
| relocation | `static`; no PIE; `crt-static` default on and not switchable; no dynamic linking | The SDK's C hello is `ET_EXEC`; minixrs has no dynamic loader |
| `panic-strategy` | `abort` | R3 |
| `has-thread-local` | `true` | ELF TLS, as clang emits for C |
| metadata | tier 3, `std: true`, `host_tools: false` | |

rustc passes `-nodefaultlibs` with the `gnu-cc` flavor, so the driver contributes the crt objects
and the `-z` flags but not `libc` or the builtins: `libc.a` arrives through the libc crate's
`#[link]` attribute and the builtins through Rust's `compiler_builtins`. P4c's gate checks the
linked result rather than assuming this division holds.

### std changes

Most of the Unix PAL needs no edit. `stack_overflow.rs`, for example, installs handlers only for
an explicit OS list; minixrs is not on it and gets the no-op. The edits:

| Site | Change | Justified by |
|---|---|---|
| `sys/pal/unix/mod.rs`, `sanitize_standard_fds` | `ENOSYS` from `poll` breaks to the `fcntl` fallback, as the existing Unikraft arm does | R6, startup abort |
| `sys/pal/unix/mod.rs`, `reset_sigpipe` | The `rtassert!` on `signal()` tolerates `ENOSYS` on minixrs | R6, startup abort |
| `unwind/src/lib.rs` | minixrs joins the group that links no unwinder library | R3 |
| `sys/random/mod.rs` | Selects `unix_legacy` (`/dev/urandom`) | R6, the default arm selects nothing and does not compile |
| `sys/thread_local/mod.rs` | Joins Hurd's `linux_like` destructor arm | R6, compile |
| `std/build.rs` | Added to the "no special requirements" list | std refuses to build otherwise |
| `os/mod.rs`, new `os/minixrs/{mod,fs,raw}.rs` | `std::os::minixrs`, mirroring `os/hurd` | R6, compile |
| `sys/{args,env_consts,fd,fs,paths,pipe,process,thread,time,net}` | One `target_os` entry wherever Hurd has one | R6, compile |
| `library/Cargo.toml` | `[patch.crates-io] libc = { git = …, tag = "minixrs-0.2.185-N" }`; `Cargo.lock` regenerated | R12 |

The plan enumerates the exact sites from `grep -rn '"hurd"' library/` (30 files, 95 hits at the
pin) and decides each one; "Hurd has a line here" is a prompt to look, not a rule to copy. The
compiler side also needs the target registered with bootstrap's sanity check, since the stage-0
compiler does not know the triple.

## P4c — tooling

### `scripts/build-rust.sh`

Guards before any work, in the style of `build-llvm.sh`: forks volume mounted; checkout on a
case-sensitive filesystem; `$MINIXRS_SDK/bin/llvm-config --version` is 22.1.x; the fork's
merge-base with its branch is the pinned commit. Then:

1. Generate `bootstrap.toml` outside the checkout: external `llvm-config` (R10), build stage 1
   (R8), targets `aarch64-apple-darwin,aarch64-unknown-minixrs`, build dir under
   `$MINIXRS_FORKS_DIR/build/`.
2. `./x build --stage 1 library`.
3. Install the stage-1 toolchain to `$MINIXRS_SDK/rust/` (R9).
4. `rustup toolchain link minixrs "$MINIXRS_SDK/rust"`.

A stamp records the fork SHA, the libc-minixrs tag, and the clang version string, so a rebuild of
any of the three invalidates it — the same reasoning as `build-musl.sh`'s stamp.

### `verify/check-rust.sh` — the M5 gate

In order; any failure stops the script and nothing is installed:

1. `rustc +minixrs --print cfg --target aarch64-unknown-minixrs` shows `target_os="minixrs"`,
   `target_env=""`, `target_family="unix"`, `panic="abort"`, `target_feature="crt-static"`.
2. rustc's target feature set equals the one `clang -###` reports for the triple.
3. A fresh `cargo new` hello builds with a bare
   `cargo +minixrs build --target aarch64-unknown-minixrs`, run with `RUSTFLAGS` and
   `CARGO_ENCODED_RUSTFLAGS` unset and no `.cargo/config.toml` in scope.
4. The output is `ET_EXEC`, has no undefined symbols, and contains no `_Unwind_*` symbol.
5. `verify/check-brand.sh` and `verify/check-image.sh` pass on it.
6. It is installed at `$MINIXRS_SDK/share/minixrs/hello-rs`.

Each assertion is added before the thing it checks is in place, or is mutation-proven by breaking
the source, per `CLAUDE.md`'s "a new test that passes on its first run has not been verified".

### Other tooling edits

- `scripts/export-patches.sh` already has `rust` and `libc` arms; the `libc` base default is
  `upstream/main` and becomes `0.2.185`.
- `docs/sysroot-layout.md` gains `rust/` and `share/minixrs/hello-rs`.
- `README.md` and `CLAUDE.md` gain the new scripts and gates.

## Owed later

Everything P4 knowingly leaves undone. The archived upstreaming plan lists these as
prerequisites, so none can be dropped silently.

| Owed | Unblocked by | Until then |
|---|---|---|
| **libunwind and `panic = "unwind"`** — a `scripts/build-libunwind.sh` cross-building LLVM libunwind into the SDK (expect the four CMake traps `build-compiler-rt.sh` hit), the `unwind` crate arm switched to link it, the target default reconsidered | A later phase; also needs `AT_PHDR`/`dl_iterate_phdr` to work for the image in question (`check-image.sh --boot-module` drops the `AT_PHDR` rule because boot modules lack it) | `catch_unwind` does not catch; no backtraces; crates requiring unwinding do not work |
| **M4 — a std hello boots on minixrs** | minixrs chunk 5 (`brk`/`mmap`) | `malloc` returns `NULL`; `hello-rs` aborts if booted |
| TLS larger than musl's builtin block (16 words) | The same `mmap` | `__init_tls` crashes if std's `PT_TLS` does not fit; measure `hello-rs`'s `PT_TLS` at M4 |
| `HashMap`'s default hasher | `/dev/urandom` in minixrs | Panics on first use |
| SIGPIPE ignore; stack-overflow reporting | Signals (minixrs Phase 7) | Silently absent |
| `thread::spawn`, `fs`, `process`, `net`, `time` | Their syscalls in musl-minixrs | Runtime `Err` carrying `ENOSYS` |
| Delete minixrs's target JSON and `check-cfg` shims (R11) | A CI story for the fork toolchain | minixrs stays on `-Zbuild-std` |
| Widening `src/unix/minixrs/` beyond std's needs | Demand from real crates | Crates using missing items fail to compile |

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| rustc rejects the external LLVM (upstream 22.1.8 lacks rust-lang's LLVM patches) | P4b cannot build | R10's fallback: apply `patches/llvm/` to the fork's `src/llvm-project` and build it in-tree |
| The SDK LLVM lacks a component rustc links | Link failure late in the rustc build | `build-rust.sh` checks `llvm-config --components` against rustc's list before building; a fix is a `build-llvm.sh` flag, not a redesign |
| `hello-rs` passes every host check and is still wrong at runtime | Found only at M4 | Accepted under R1. The host checks prove brand, layout, and link closure, not behavior |
| A linked toolchain has no `cargo` | `cargo +minixrs` fails | rustup falls back to another installed toolchain's cargo for custom toolchains; `check-rust.sh` step 3 proves it rather than assuming |
| The parity manifest and the module drift | Unchecked definitions | The coverage rule in the parity gate |
| The build outgrows the forks volume | `ENOSPC` | 138 GiB free on 2026-09-29; the existing risk-register mitigation (move the bundle) applies |

## Verification summary

```sh
verify/selftest.sh          # includes the parity comparer's negative fixture
verify/check-libc-abi.sh    # P4a gate
scripts/build-rust.sh       # P4b gate is its step 2
verify/check-rust.sh        # P4c / M5 gate — installs hello-rs
```
