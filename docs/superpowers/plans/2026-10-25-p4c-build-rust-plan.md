# P4c — `build-rust.sh` and the M5 Gate: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `scripts/build-rust.sh` builds rust-minixrs's stage-1 toolchain, installs it at `$MINIXRS_SDK/rust` and links it as `+minixrs`. `verify/check-rust.sh` then proves M5: a bare `cargo +minixrs build --target aarch64-unknown-minixrs` links a branded, loadable hello, which it installs at `$MINIXRS_SDK/share/minixrs/hello-rs`.

**Architecture:** Tooling only — every task runs in `~/src/tooling`, on branch `feature/p4c-build-rust`. `build-rust.sh` reads the fork but never edits it: it generates `bootstrap.toml` outside the checkout, runs `./x`, and copies the stage-1 sysroot into the SDK. `check-rust.sh` needs only the SDK and rustup, so it must pass with the forks volume unmounted (R9).

**Tech Stack:** bash 3.2, rustup, rust-minixrs at `minixrs/nightly-2026-10-01` (7 commits on `21b707e3f`), the SDK (llvm-minixrs 22.1.8, musl-minixrs), `nightly-2026-10-01`'s cargo.

**Spec:** [`docs/superpowers/specs/2026-09-30-p4-rust-std-design.md`](../specs/2026-09-30-p4-rust-std-design.md) — section "P4c — tooling", decisions R2, R8, R9, R10, and the Risks table. The spec was corrected alongside this plan, from what the prototype below found. The changes: build-rust step 3's cargo, check-rust steps 1 and 3, and the cargo risk row.

**Prototyped on 2026-10-25**, against P4b's stage-1 build (`build/host/stage1`, rustc `24d956a3d`):
- The stage-1 sysroot was copied without its two `rustlib/src` symlinks and linked with rustup as a scratch toolchain.
- `cargo new` plus a bare `cargo +<it> build --target aarch64-unknown-minixrs` linked in 0.4 s. It ran under a fresh `CARGO_HOME`, with `RUSTFLAGS`, `LIBRARY_PATH` and the include paths unset. The result was `Type: EXEC`, had no undefined globals, was BRANDED and LOADABLE, and its only `_Unwind_` definitions were `_Unwind_Backtrace _Unwind_GetCFA _Unwind_GetIP`.
- The toolchain has no cargo of its own. rustup fell back to `nightly`'s cargo, which on this machine is **cargo 1.97** (2026-05-15) — hence the spec change.
- `nightly-2026-10-01`'s cargo reports commit `f3865b2a4d1acc5276f6b3c67d0e057f4dab3928`. That is exactly the fork's `src/tools/cargo` gitlink at `21b707e3f`. Copied into the toolchain's `bin/`, it built the same hello.
- rustc's target features (`+v8a,+fp-armv8,+neon`) equal clang's `-target-feature` list. A clang wrapper adding `-march=armv8.2-a` produced `+v8.2a +crc +fp-armv8 +lse +neon +ras +rdm`.
- Three mutant projects:
  - Defining `_Unwind_Resume`, kept alive by `black_box`, adds it to the definitions.
  - `-Wl,--unresolved-symbols=ignore-all` plus a call to an undefined function links with one undefined global.
  - `-nostartfiles` links an `EXEC` that is MISSING the brand.
- `rustup toolchain link` over an existing name succeeds; relinking is idempotent.

Not run: `build-rust.sh` itself, which does not exist yet, and the install into the real `$MINIXRS_SDK`. P4b's stage 1 predates the fork's last three commits, so the first real run rebuilds rustc.

If a step's output differs from what is written, stop and find out why. Do not adjust the expectation.

## Global Constraints

- Every task runs in `~/src/tooling` on `feature/p4c-build-rust`. **Never edit rust-minixrs, libc-minixrs or any fork** (the cross-repo rule). `build-rust.sh` writes only to `$MINIXRS_FORKS_DIR/build/rust-minixrs/`, `$MINIXRS_SDK/rust/` and rustup's toolchain list.
- Pins: rust **`21b707e3f97e0b522ebd2f277a862339625ad83f`** (`nightly-2026-10-01`); toolchain name **`minixrs`**; host **`aarch64-apple-darwin`**; the SDK's LLVM **22.1.x**.
- Layout: the toolchain at **`$MINIXRS_SDK/rust/`** with its stamp at **`$MINIXRS_SDK/rust/.stamp`**; the hello at **`$MINIXRS_SDK/share/minixrs/hello-rs`**; `bootstrap.toml` at **`$MINIXRS_FORKS_DIR/build/rust-minixrs/bootstrap.toml`**, build dir `…/build/rust-minixrs/build`.
- The forks volume must be mounted for Task 3 and most of Task 4: `scripts/forks-volume.sh mount`.
- Scripts pass `bash -n` and `shellcheck -S warning`, and run under macOS bash 3.2 (empty arrays as `${A[@]+"${A[@]}"}`). **The Bash tool's shell is zsh:** wrap probes that use `PIPESTATUS` in `bash -c`. Do not put `rm` inside a `bash -c` string — the harness refuses it. Run removals as plain commands.
- Every commit is GPG-signed with `Signed-off-by` (`git commit -s`); never `--no-gpg-sign` or `--no-verify`.
- **Nothing leaves the machine without the user's say-so.** No `git push` and no PR; Task 6 is USER-GATED.
- The ledger is `.superpowers/sdd/2026-10-25-p4c-build-rust-plan/progress.md` (gitignored). Record each task's red, green and mutation outputs there.

## Review Focus

1. **The caller's environment leaking into a build.** The keys are `RUSTFLAGS`, `CARGO_TARGET_AARCH64_UNKNOWN_MINIXRS_LINKER`, `LIBRARY_PATH`, `C_INCLUDE_PATH` and `~/.cargo/config.toml`; this machine sets the last three. Expected: the gate's hello is built from nothing but the SDK and rustup, and bootstrap ignores `RUSTFLAGS` and the library and include paths. Pinned by Task 4, Step 4.
2. **The SDK used with the forks volume unmounted** (R9). Expected: `check-rust.sh` passes, while `build-rust.sh` fails fast and points at `forks-volume.sh mount`. Pinned by Task 4, Step 7.
3. **A stale artifact presented as current.** Two cases: a stage-1 compiler from an older checkout installed as this one, and an old `hello-rs` left in place after the gate fails. Expected: the first is refused before install, and the second is removed. Pinned by Task 3, Step 5's commit-hash check and Task 4, Step 6.
4. **A fork rebased off the pin.** If the branch sits on a newer upstream, the pin is still an ancestor. Expected: refused before any build. Pinned by Task 3, Step 2.
5. **A machine whose `nightly` is not the pin.** rustup would run a version-skewed cargo. Expected: `cargo +minixrs` is the SDK's own. Pinned by Task 4, Step 5.

Known and accepted, not pinned: step 1's cfg values and rustc's half of step 2 cannot be mutated without rebuilding rustc from an edited target spec. That is a fork edit, out of bounds here, and P4b Task 5, Step 5 already recorded the exact cfg. Task 4 proves step 1 against a foreign compiler, and step 2's comparison from the clang side.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/env.sh` (modify) | Owns the two Rust pins: `MINIXRS_NIGHTLY`, `MINIXRS_RUST_BASE` |
| `verify/check-libc-abi.sh`, `scripts/export-patches.sh` (modify) | Read those pins instead of their own literal defaults |
| `scripts/build-rust.sh` (create) | Guards, `bootstrap.toml`, `./x build`, install, rustup link, stamp |
| `verify/check-rust.sh` (create) | The M5 gate; installs `hello-rs` |
| `docs/superpowers/specs/…-p4-rust-std-design.md` | Already corrected in this plan's commit |
| `docs/sysroot-layout.md`, `README.md`, `CLAUDE.md`, `docs/roadmap.md` (modify) | Layout, scripts, gates, the P4c box |

---

### Task 1: `env.sh` owns the Rust pins

**Files:**
- Modify: `scripts/env.sh`, `verify/check-libc-abi.sh:22-23,36`, `scripts/export-patches.sh:17,53`

**Interfaces:**
- Produces: `MINIXRS_NIGHTLY` (default `nightly-2026-10-01`) and `MINIXRS_RUST_BASE` (default `21b707e3f97e0b522ebd2f277a862339625ad83f`), exported by `env.sh`. Tasks 2 and 3 read both.

**Why:** `build-rust.sh` needs both pins, and each already has a literal default in another script. A default duplicated in two scripts drifts (the reason `MINIXRS_GEN_C_HEADERS_DIR` lives in `env.sh`).

- [ ] **Step 1: Record the current outputs**

```bash
verify/check-libc-abi.sh | tail -1
scripts/export-patches.sh rust libc && git status --short patches
```

Expected: `check-libc-abi: PASS (229 module items covered; 27 function declarations not checked)`; `rust → 7 patch(es) from 21b707e3f..HEAD`, `libc → 3 patch(es) from 0.2.189..HEAD`; empty status. Any status line means the forks moved since P4b's export: stop and report it.

- [ ] **Step 2: Move the defaults**

In `scripts/env.sh`, after the `MINIXRS_GEN_C_HEADERS_DIR` export, add a comment and two exports. The comment says these are the program's one Rust pin, that minixrs owns it (`rust-toolchain.toml`), and that a bump changes both together. Set:
- `MINIXRS_NIGHTLY` to `${MINIXRS_NIGHTLY:-nightly-2026-10-01}`.
- `MINIXRS_RUST_BASE` to `${MINIXRS_RUST_BASE:-21b707e3f97e0b522ebd2f277a862339625ad83f}`.

`verify/check-libc-abi.sh`: `NIGHTLY="$MINIXRS_NIGHTLY"`, and its header comment's default becomes `(default: env.sh's — minixrs' pin; needs rust-src)`.

`scripts/export-patches.sh`: the `rust` arm uses `"$MINIXRS_RUST_BASE"`, and its header line becomes `MINIXRS_RUST_BASE   default from env.sh (the minixrs rustc pin commit)`.

- [ ] **Step 3: Nothing changed behavior**

```bash
bash -n scripts/env.sh verify/check-libc-abi.sh scripts/export-patches.sh
shellcheck -S warning scripts/*.sh verify/*.sh
env -i HOME="$HOME" bash -c '. scripts/env.sh; echo "$MINIXRS_NIGHTLY $MINIXRS_RUST_BASE"'
env -i HOME="$HOME" zsh -fc '. scripts/env.sh; echo "$MINIXRS_NIGHTLY"'
grep -rn 'nightly-2026-10-01\|21b707e3f' scripts verify
```

Then rerun Step 1's commands. Expected:
- shellcheck is clean.
- `nightly-2026-10-01 21b707e3f97e0b522ebd2f277a862339625ad83f`, then `nightly-2026-10-01`.
- The grep's only hits are the two lines in `env.sh`.
- Step 1's outputs repeat exactly, with an empty `git status --short patches`.

- [ ] **Step 4: Commit**

```bash
git add scripts/env.sh verify/check-libc-abi.sh scripts/export-patches.sh
git commit -s -m "env.sh: own the Rust pins

The nightly and the rust base commit each had a literal default in one
script, and build-rust.sh (P4c) needs both. env.sh exports them, as it
does MINIXRS_GEN_C_HEADERS_DIR, so a pin bump is one edit."
```

---

### Task 2: `verify/check-rust.sh`, written red

**Files:**
- Create: `verify/check-rust.sh` (mode 755)

**Interfaces:**
- Consumes: `env.sh`; `verify/check-brand.sh`, `verify/check-image.sh`.
- Produces: `verify/check-rust.sh`. It exits 0 when every check passes, 1 when a check fails, and 3 on an environment problem. Knobs: `MINIXRS_RUST_TOOLCHAIN` (default `minixrs`) and `CLANG` (default `$MINIXRS_SDK/bin/clang`), both in check-driver.sh's style. On success it installs `$MINIXRS_SDK/share/minixrs/hello-rs`.

**Shape.** Model it on `verify/check-driver.sh`: a header listing the steps, `pass`/`bad` helpers with the prefix `check-rust:`, and `mktemp -d` cleaned by `trap`. It differs in one way. `bad` accumulates *within* a step, and the step ends with `end_step`: if anything failed, the script removes `$MINIXRS_SDK/share/minixrs/hello-rs` (saying so, as `build-sysroot.sh`'s `reject` does) and exits 1. So every assertion of the failing step is reported, and no later step runs. The progress lines are `check-rust: [n/6] <title>`.

**Environment checks** (exit 3, before step 1):
- `rustup` is on `PATH`.
- `rustc +$MINIXRS_RUST_TOOLCHAIN -V` succeeds; else `toolchain minixrs is not linked — run scripts/build-rust.sh`. (Not a match on `rustup toolchain list`: a prefix match takes `minixrs-old` for `minixrs`, and an exact one misses `nightly-2026-10-01`, which rustup lists with its host suffix.)
- `$CLANG` is executable.

**Steps** (the spec's six, in order). `T=aarch64-unknown-minixrs` and `TC=$MINIXRS_RUST_TOOLCHAIN`.

1. **The toolchain.** `rustc +$TC --print sysroot`, resolved with `cd … && pwd -P`, equals `$MINIXRS_SDK/rust` resolved the same way. Then each of these five lines appears verbatim (`grep -Fx`) in `rustc +$TC --print cfg --target $T`: `target_os="minixrs"`, `target_env=""`, `target_family="unix"`, `panic="abort"`, `target_feature="crt-static"`.
2. **Target features.** The rustc set is the `"features"` value of `rustc +$TC -Z unstable-options --print target-spec-json --target $T`, split on commas and sorted. The clang set is every `-target-feature` argument of `"$CLANG" --target=$T -### -c -x c /dev/null -o /dev/null` (run under `env -u CPATH -u C_INCLUDE_PATH`), sorted. The two must be equal; on a mismatch, print both space-joined.
3. **A bare cargo build.**
   - `rustup which --toolchain $TC cargo` equals `$MINIXRS_SDK/rust/bin/cargo`; otherwise FAIL `cargo +minixrs is not the SDK's (rustup would fall back to another toolchain's)`.
   - Then, in `$tmp`, run `cargo +$TC new --vcs none hello-rs`, then `cargo +$TC build --target $T` inside it.
   - Both commands run under exactly this environment, so nothing from the caller reaches them:

     ```bash
     clean_env=(env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" CARGO_HOME="$tmp/cargo-home"
         PATH="$MINIXRS_SDK/bin:$(dirname "$(command -v rustup)"):/usr/bin:/bin")
     [ -n "${RUSTUP_HOME:-}" ] && clean_env+=(RUSTUP_HOME="$RUSTUP_HOME")
     ```

     `$MINIXRS_SDK/bin` comes first because rustc finds its linker, `aarch64-unknown-minixrs-clang` (R2), through `PATH`. A fresh `CARGO_HOME` keeps `~/.cargo/config.toml` out of scope.
   - On a build failure, show the output indented and FAIL. The output under test is `$tmp/hello-rs/target/$T/debug/hello-rs`.
4. **Link closure.**
   - `llvm-readelf -h` reports `Type: EXEC`.
   - `llvm-readelf -sW` lists no symbol with `$7 == "UND" && $5 == "GLOBAL"`; on failure, name them. musl's `_DYNAMIC` is a LOCAL undefined, and std's `__cxa_thread_atexit_impl` is WEAK; neither counts.
   - Every `_Unwind_*` that `llvm-nm --defined-only` reports is one of `_Unwind_Backtrace _Unwind_FindEnclosingFunction _Unwind_GetCFA _Unwind_GetIP`; on failure, name the others.
5. **Brand and layout.** `check-brand.sh` and `check-image.sh` pass, without `--boot-module`.
6. **Install.** `mkdir -p "$MINIXRS_SDK/share/minixrs"` and copy the binary to `hello-rs`. Print `check-rust: hello-rs installed at …`, then `check-rust: all checks passed`.

Put a short comment above step 3's environment saying why each part is there. Comment the step-4 exemptions as above.

- [ ] **Step 1: Write the script**

As above.

- [ ] **Step 2: Lint**

Run: `bash -n verify/check-rust.sh && shellcheck -S warning verify/check-rust.sh && echo ok`
Expected: `ok`.

- [ ] **Step 3: Red — nothing is installed yet**

Run: `bash -c 'verify/check-rust.sh; echo exit=$?'`
Expected: `check-rust: toolchain minixrs is not linked — run scripts/build-rust.sh`, `exit=3`.

- [ ] **Step 4: Red against the stock pinned nightly**

Run: `bash -c 'MINIXRS_RUST_TOOLCHAIN=nightly-2026-10-01 verify/check-rust.sh; echo exit=$?'`
Expected: under `[1/6]`, a FAIL for the sysroot (it names `~/.rustup/toolchains/nightly-2026-10-01-…`), then a FAIL for each of the five cfg lines — that rustc does not know the target. Then `exit=1` and no `[2/6]` line. This is the cfg assertions' only cheap red (Review Focus, known and accepted).

- [ ] **Step 5: Commit**

```bash
git add verify/check-rust.sh
git commit -s -m "verify: check-rust.sh, the M5 gate

A bare cargo +minixrs build of a fresh cargo new project, with nothing
from the caller's environment, must link an ET_EXEC with no undefined
globals and no unwinder but the null one, that check-brand.sh and
check-image.sh accept. It is installed as share/minixrs/hello-rs; a
failure at any step removes an older one."
```

---

### Task 3: `scripts/build-rust.sh`

**Files:**
- Create: `scripts/build-rust.sh` (mode 755)

**Interfaces:**
- Consumes: `MINIXRS_NIGHTLY` and `MINIXRS_RUST_BASE` (Task 1); the SDK's `llvm-config`, `aarch64-unknown-minixrs-clang`, `llvm-ar` and `llvm-ranlib`.
- Produces: `$MINIXRS_SDK/rust/`, a stage-1 sysroot plus `bin/cargo`, with `.stamp` = `rust=<fork HEAD> libc=<tag>#<sha> clang=<clang --version line 1>`; and rustup toolchain `minixrs` linked to it. Knobs: `RUST_MINIXRS_SRC` (default `$MINIXRS_FORKS_DIR/rust-minixrs`; the script's `RUST_SRC`), `RUST_MINIXRS_BUILD_DIR` (default `$MINIXRS_FORKS_DIR/build/rust-minixrs`; the script's `BUILD_ROOT`, holding `BT=$BUILD_ROOT/bootstrap.toml` and bootstrap's `build/`), `MINIXRS_RUST_TOOLCHAIN` (default `minixrs`). Usage: `build-rust.sh [--force]`; any other argument prints usage and exits 2.

**Shape.** Model it on `build-llvm.sh` (guards, heredoc messages) and `build-musl.sh` (stamp, `--force`). Each guard prints `build-rust: …` and exits 1, in this order:

| # | Guard | Message must say |
|---|---|---|
| G1 | `$RUST_SRC/x.py` exists | not found; clone the fork (roadmap P4b) or set `RUST_MINIXRS_SRC`; if the volume is unmounted, `scripts/forks-volume.sh mount` |
| G2 | `$RUST_SRC/X.py` does **not** resolve | case-insensitive filesystem, as `build-llvm.sh` words it |
| G3 | `llvm-config --version` matches `22.1.*`; `aarch64-unknown-minixrs-clang`, `llvm-ar`, `llvm-ranlib` exist in `$MINIXRS_SDK/bin` | the version found, and `scripts/build-llvm.sh` |
| G4 | every name in `REQUIRED_COMPONENTS` in `$RUST_SRC/compiler/rustc_llvm/build.rs`, plus `aarch64`, appears in `llvm-config --components` | the missing components; that a fix is a `build-llvm.sh` flag (spec, Risks). An empty parse is its own failure: the list's format changed |
| G5 | `git merge-base --is-ancestor "$MINIXRS_RUST_BASE" HEAD`, **and** `git rev-list --merges --count "$MINIXRS_RUST_BASE"..HEAD` is `0` | the branch is not the minixrs series on the pin. upstream history is all merge commits, so a branch rebased onto newer upstream fails the second test though it passes the first |
| G6 | `library/Cargo.lock` has a `source = "git+https://github.com/minixrs/libc-minixrs?tag=…#…"` line; capture `tag#sha` as `LIBC_PIN` | libc-minixrs is not pinned by tag (design R12) |
| G7 | `rustup which --toolchain "$MINIXRS_NIGHTLY" cargo` succeeds, and that cargo's `-vV` `commit-hash:` equals `git -C "$RUST_SRC" rev-parse HEAD:src/tools/cargo` | `rustup toolchain install $MINIXRS_NIGHTLY`; or, on a mismatch, both hashes |

G4's parse, which must survive the array spanning lines:

```bash
sed -n '/^const REQUIRED_COMPONENTS/,/;/p' "$RUST_SRC/compiler/rustc_llvm/build.rs" |
    grep -o '"[a-z0-9]*"' | tr -d '"'
```

Then:
1. **Freshness.** `WANT="rust=$(git rev-parse HEAD) libc=$LIBC_PIN clang=$("$MINIXRS_SDK/bin/clang" --version | head -1)"`. Skip the build when all of these hold: no `--force`, `.stamp` equals `WANT`, and `bin/rustc` and `bin/cargo` exist under `$MINIXRS_SDK/rust`. Then relink (step 5 below), print `build-rust: toolchain up to date ($MINIXRS_SDK/rust)` and the stamp, and exit 0.
2. **`bootstrap.toml`.** Write P4b Task 4's file (P4b plan, lines 786–813), except that the first comment line reads `# Generated by tooling's scripts/build-rust.sh — edits are overwritten.` Every path comes from `$MINIXRS_SDK` and the build dir, never a literal.
3. **Build.** `( cd "$RUST_SRC" && env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u LIBRARY_PATH -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS -u CARGO_BUILD_RUSTFLAGS ./x build --stage 1 library --config "$BT" )`. Comment it: clang searches the include paths before `--sysroot`, and adds `LIBRARY_PATH` as a `-L` to every link (spec, P4c). Unset, not set-empty: bootstrap passes its own flags to cargo through `RUSTFLAGS`, and an empty `CARGO_ENCODED_RUSTFLAGS` would override them (`CLAUDE.md`).
4. **Verify, then install.** `S1="$BUILD_ROOT/build/aarch64-apple-darwin/stage1"`. Its `bin/rustc -vV` must report `commit-hash: <fork HEAD, full>` and `LLVM version: 22.1.`; otherwise exit 1 (`the stage-1 compiler is not this checkout's`) before touching the SDK. Then:
   - remove `${MINIXRS_SDK:?}/rust`;
   - `cp -R "$S1" "$MINIXRS_SDK/rust"`;
   - remove the two symlink dirs `lib/rustlib/src` and `lib/rustlib/rustc-src`. They point into the checkout, so they dangle whenever the volume is unmounted (R9), and nothing in M5 reads them;
   - `cp` G7's cargo to `rust/bin/cargo`.
5. **Link.** `rustup toolchain link "$TOOLCHAIN" "$MINIXRS_SDK/rust"`.
6. **Stamp last** — `printf '%s\n' "$WANT" > "$MINIXRS_SDK/rust/.stamp"` — so an interrupted install rebuilds. Then print `build-rust: installed into $MINIXRS_SDK/rust, linked as +minixrs` and `build-rust: next: verify/check-rust.sh`.

- [ ] **Step 1: Write the guards and usage only, ending in `echo "build-rust: guards passed"; exit 0`**

The guards are the script's failure mode (`CLAUDE.md`, Changing scripts), so prove each before the 10-minute part exists.

- [ ] **Step 2: Red for each guard**

```bash
bash -n scripts/build-rust.sh && shellcheck -S warning scripts/build-rust.sh
bash -c 'scripts/build-rust.sh --bogus; echo exit=$?'
bash -c 'RUST_MINIXRS_SRC=/nonexistent scripts/build-rust.sh; echo exit=$?'
bash -c 'MINIXRS_RUST_BASE=1625626af12 scripts/build-rust.sh; echo exit=$?'
bash -c 'MINIXRS_RUST_BASE=0abfedbc7cd scripts/build-rust.sh; echo exit=$?'
bash -c 'MINIXRS_NIGHTLY=nightly-2026-07-23 scripts/build-rust.sh; echo exit=$?'
bash -c 'MINIXRS_NIGHTLY=nightly-1999-01-01 scripts/build-rust.sh; echo exit=$?'
scripts/build-rust.sh
```

Expected, in order:
- usage, `exit=2`.
- G1, `exit=1`.
- G5 for the pin's parent. `1625626af12` is an ancestor, but `21b707e3f` is a merge in the range. `exit=1`.
- G5 for upstream `main`, which is not an ancestor. `exit=1`.
- G7's mismatch, with two different hashes. `exit=1`.
- G7's "install it". `exit=1`.
- `build-rust: guards passed`.

G2, G3 and G4 have no cheap environmental red. Prove them with a scratch copy, so nothing on the volume is edited:
- G2: point `RUST_MINIXRS_SRC` at a directory on the case-insensitive Data volume that holds only `x.py`.
- G3 and G4: point `MINIXRS_SDK` at a scratch prefix whose `bin/` symlinks the real `clang`, `aarch64-unknown-minixrs-clang`, `llvm-ar` and `llvm-ranlib`, and whose `bin/llvm-config` is a wrapper script around the real one. For G3 the wrapper prints `21.1.0` for `--version`. For G4 it drops `lto` from `--components`. Otherwise it `exec`s the real one.

Record each red in the ledger.

- [ ] **Step 3: Write the rest of the script (steps 1–6 above)**

- [ ] **Step 4: First run**

```bash
scripts/forks-volume.sh mount
bash -c 'time scripts/build-rust.sh 2>&1 | tail -5'
```

Expected: `Build completed successfully`, then the two final `build-rust:` lines. The build is incremental over P4b's build dir, but the fork's last three commits touch `rustc_target` and `library/Cargo.toml`, so rustc and std rebuild. Record the time.

- [ ] **Step 5: The install is what was built**

```bash
ls "$MINIXRS_SDK/rust/bin"; ls "$MINIXRS_SDK/rust/lib/rustlib"
rustc +minixrs -vV | grep -E 'commit-hash|LLVM'
git -C "$MINIXRS_FORKS_DIR/rust-minixrs" rev-parse HEAD
cargo +minixrs -V; cat "$MINIXRS_SDK/rust/.stamp"
```

Expected:
- `cargo rustc`, then `aarch64-apple-darwin aarch64-unknown-minixrs`, with no `src` and no `rustc-src`.
- rustc's commit-hash equals the fork HEAD (`38030f361c5…` unless the fork moved), and it reports `LLVM version: 22.1.8`.
- `cargo 1.101.0-nightly (f3865b2a4 2026-09-29)`.
- A stamp naming the fork HEAD, `minixrs-0.2.189-1#…` and the clang line.

- [ ] **Step 6: Second run is a no-op**

Run: `bash -c 'time scripts/build-rust.sh 2>&1 | tail -2'`
Expected: `build-rust: toolchain up to date (…/rust)` and the stamp, in seconds. Every guard ran first.

- [ ] **Step 7: The gate goes green**

Run: `bash -c 'verify/check-rust.sh; echo exit=$?'`
Expected: all six steps PASS, then `hello-rs installed at …/share/minixrs/hello-rs`, `all checks passed`, `exit=0`. `file "$MINIXRS_SDK/share/minixrs/hello-rs"` says `ELF 64-bit LSB executable, ARM aarch64, … statically linked`.

- [ ] **Step 8: Commit**

```bash
git add scripts/build-rust.sh
git commit -s -m "scripts: build-rust.sh — the stage-1 toolchain, installed as +minixrs

Guards first: the checkout, its case sensitivity, the SDK's LLVM and
the components rustc_llvm requires, the branch on the pin, libc pinned
by tag, and the pinned nightly's cargo built from the fork's own cargo
commit. Then bootstrap.toml outside the checkout, ./x build --stage 1
library with the caller's flags and search paths unset, and an install
of the stage-1 sysroot plus that cargo into \$MINIXRS_SDK/rust, linked
with rustup. The stamp keys on the fork, the libc tag and clang."
```

---

### Task 4: Prove the gate bites

No new file. Each step breaks one input and expects one specific failure, then restores. Record every output in the ledger. A fix that a step forces is committed with a message naming the step.

**Interfaces:**
- Consumes: Tasks 2–3's scripts and installed toolchain.

- [ ] **Step 1: The sysroot check (R9)**

```bash
rustup toolchain link minixrs "$MINIXRS_FORKS_DIR/build/rust-minixrs/build/aarch64-apple-darwin/stage1"
bash -c 'verify/check-rust.sh; echo exit=$?'
rustup toolchain link minixrs "$MINIXRS_SDK/rust"
```

Expected: `[1/6]` FAILs only the sysroot assertion, naming the build tree; the cfg lines PASS. `exit=1`.

- [ ] **Step 2: The feature comparison, from the clang side**

```bash
printf '#!/bin/sh\nexec "%s" -march=armv8.2-a "$@"\n' "$MINIXRS_SDK/bin/clang" > "$TMPDIR/clang-mut"
chmod +x "$TMPDIR/clang-mut"
bash -c 'CLANG="$TMPDIR/clang-mut" verify/check-rust.sh; echo exit=$?'
```

Expected: `[2/6]` FAILs and prints rustc `+fp-armv8 +neon +v8a` against clang `+crc +fp-armv8 +lse +neon +ras +rdm +v8.2a`. `exit=1`.

- [ ] **Step 3: Steps 4 and 5, by mutating the program under test**

Edit, one at a time, the source that `check-rust.sh` builds. The script uses `cargo new`'s `main.rs`, so add a line after `cargo new` that overwrites `src/main.rs` (and, where shown, writes `build.rs`). Run the gate after each mutation, and restore with `git checkout verify/check-rust.sh`:

| Mutation | Expected |
|---|---|
| `main.rs`: `#[unsafe(no_mangle)] pub extern "C" fn _Unwind_Resume() {}` and `fn main() { std::hint::black_box(_Unwind_Resume as extern "C" fn()); }` | `[4/6]` FAIL naming `_Unwind_Resume` |
| `main.rs`: `unsafe extern "C" { fn not_defined_anywhere(); }` and `fn main() { unsafe { not_defined_anywhere() } }`; `build.rs`: `cargo:rustc-link-arg=-Wl,--unresolved-symbols=ignore-all` | `[4/6]` FAIL naming `not_defined_anywhere` |
| `build.rs`: `cargo:rustc-link-arg=-nostartfiles` | `[5/6]` FAIL: `MISSING minixrs brand`, then `NOT LOADABLE` |

Each ends with `exit=1` and the message that the stale `hello-rs` was removed.

- [ ] **Step 4: The caller's environment does not leak (Review Focus 1)**

```bash
bash -c 'mkdir -p "$TMPDIR/evil-home"
printf "[build]\nrustflags = [\"-C\", \"link-arg=-Wl,--bogus-flag\"]\n" > "$TMPDIR/evil-home/config.toml"
RUSTFLAGS="-C link-arg=-Wl,--bogus-flag" CARGO_ENCODED_RUSTFLAGS="-Cpanic=unwind" \
CARGO_TARGET_AARCH64_UNKNOWN_MINIXRS_LINKER=/usr/bin/false CARGO_HOME="$TMPDIR/evil-home" \
LIBRARY_PATH=/nonexistent C_INCLUDE_PATH=/nonexistent RUSTUP_TOOLCHAIN=stable \
    verify/check-rust.sh | tail -1; echo exit=${PIPESTATUS[0]}'
```

Expected: `check-rust: all checks passed`, `exit=0`. Prove the poison is real by running the same cargo build with it, outside the script:

```bash
bash -c 'cd "$(mktemp -d)" && cargo +minixrs new -q --vcs none p && cd p &&
CARGO_TARGET_AARCH64_UNKNOWN_MINIXRS_LINKER=/usr/bin/false cargo +minixrs build --target aarch64-unknown-minixrs 2>&1 | grep -c "linking with"'
```

Expected: `1` — a link with that linker fails.

- [ ] **Step 5: `cargo +minixrs` is the SDK's (Review Focus 5)**

```bash
mv "$MINIXRS_SDK/rust/bin/cargo" "$TMPDIR/cargo.keep"
bash -c 'verify/check-rust.sh; echo exit=$?'
mv "$TMPDIR/cargo.keep" "$MINIXRS_SDK/rust/bin/cargo"
```

Expected: `[3/6]` FAIL, `cargo +minixrs is not the SDK's …`, `exit=1`.

- [ ] **Step 6: No stale `hello-rs` (Review Focus 3)**

After Step 5's failure: `ls "$MINIXRS_SDK/share/minixrs"` lists `hello` only. Then run `verify/check-rust.sh | tail -1`. Expected: `all checks passed`, and `hello-rs` is back.

- [ ] **Step 7: The volume unmounted (Review Focus 2)**

```bash
cd ~ && ~/src/tooling/scripts/forks-volume.sh unmount
bash -c '~/src/tooling/verify/check-rust.sh | tail -1; echo exit=${PIPESTATUS[0]}'
bash -c '~/src/tooling/scripts/build-rust.sh 2>&1 | head -3; echo exit=${PIPESTATUS[0]}'
~/src/tooling/scripts/forks-volume.sh mount && cd ~/src/tooling
```

Expected: `all checks passed`, `exit=0`; then G1's message naming `forks-volume.sh mount`, `exit=1`. If the unmount reports the volume busy, find the holder with `lsof +D "$MINIXRS_FORKS_DIR" | head`, close it, and retry. Do not force the unmount.

- [ ] **Step 8: Clean tree**

Run: `git status --short`
Expected: empty, unless a step forced a fix, which is then committed.

---

### Task 5: Docs, the box, and the whole-branch sweep

**Files:**
- Modify: `docs/sysroot-layout.md`, `README.md`, `CLAUDE.md`, `docs/roadmap.md`

- [ ] **Step 1: `docs/sysroot-layout.md`**

- In the tree, add `rust/` between `lib/` and `sysroot/`: `installed by build-rust.sh (P4c); rustup toolchain +minixrs`, with children `bin/rustc, bin/cargo` (cargo: the pinned nightly's) and `.stamp` (`"rust=<sha> libc=<tag>#<sha> clang=<version line>"`).
- Under `share/minixrs/`, add `hello-rs`: the branded std hello installed by `verify/check-rust.sh` (M5 gate), which aborts if booted until M4.
- Add a contract point. The toolchain needs `$MINIXRS_SDK/bin` on `PATH`, because rustc finds its linker by name (R2). It carries no `rust-src`, and it works with the forks volume unmounted (R9).

- [ ] **Step 2: `README.md`**

- Repo map: `scripts/build-rust.sh` (stage-1 rust-minixrs → `$MINIXRS_SDK/rust`, linked as `+minixrs`) and `verify/check-rust.sh` (the M5 gate).
- "What works today": a short paragraph after the M2 gate, giving the two commands and what they prove.

- [ ] **Step 3: `CLAUDE.md`**

- Gates block: add `scripts/build-rust.sh` (installs and links `+minixrs`) and `verify/check-rust.sh` (the M5 gate — installs `hello-rs`; passes with the volume unmounted).
- The gotcha ending "P4c's `build-rust.sh` owes the `env -u`" becomes: `build-rust.sh` unsets them for bootstrap, and `check-rust.sh` builds under `env -i`.
- New gotchas, one line of why each:
  - **rustup's fallback cargo for a linked toolchain is the `nightly` toolchain's, whatever version that is** (1.97 here). `build-rust.sh` installs the pin's cargo, whose commit G7 compares to the fork's `src/tools/cargo` gitlink.
  - **`~/.cargo/config.toml` is in scope for every cargo build**, cwd notwithstanding, and this machine has one. An isolated build needs a fresh `CARGO_HOME`.
- Any learning from Tasks 3–4 that cost real time.

- [ ] **Step 4: `docs/roadmap.md`**

Check the P4c box. Nothing else in the roadmap restates P4c.

- [ ] **Step 5: Re-export, and sweep for what this branch falsified**

```bash
scripts/export-patches.sh rust libc && git status --short patches
grep -rnE 'P4c|build-rust|check-rust|hello-rs|not yet|until P4|owes the|will generate|no cargo|falls back' \
    README.md CLAUDE.md docs scripts verify | grep -vE 'docs/plans/|docs/archive/|docs/superpowers/plans/'
```

Expected: empty status — the series is P4b's, unchanged. Read every grep hit. Fix any that this branch made false, such as a "will", "owes" or "not yet" that is now done. The P4 spec's P4c section describes the design and stays. Also run the rename grep for anything Task 1 moved: `grep -rn 'MINIXRS_NIGHTLY:-\|MINIXRS_RUST_BASE:-' scripts verify`. Its only hits must be in `env.sh`.

- [ ] **Step 6: All gates**

Run: `shellcheck -S warning scripts/*.sh verify/*.sh && verify/selftest.sh | tail -1 && verify/check-driver.sh | tail -1 && verify/check-libc-abi.sh | tail -1 && scripts/build-rust.sh | tail -2 && verify/check-rust.sh | tail -1`
Expected: clean; `18/18`; `all checks passed`; `PASS (229 module items covered; 27 function declarations not checked)`; `toolchain up to date`; `all checks passed`.

- [ ] **Step 7: Commit**

```bash
git add docs/sysroot-layout.md README.md CLAUDE.md docs/roadmap.md
git commit -s -m "P4c: the rust toolchain in the SDK, and the M5 gate; check the box"
```

---

### Task 6: USER-GATED — whole-branch review, then push and PR

- [ ] **Step 1:** A fresh reviewer gets `git diff main...HEAD` as a file plus the spec. It verifies each guard's logic and each check's assertion by reading, not by trusting the ledger.
- [ ] **Step 2:** Run `/claude-md-management:revise-claude-md`.
- [ ] **Step 3:** Stop. Surface the branch, the ledger's rulings, and the review's findings, and ask the user before `git push` and the PR.
