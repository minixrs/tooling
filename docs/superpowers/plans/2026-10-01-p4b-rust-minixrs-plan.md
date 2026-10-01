# P4b — rust-minixrs: the Target and the std Port: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `rust-minixrs` fork whose stage-1 compiler knows `aarch64-unknown-minixrs` and builds `std` for it — `./x build --stage 1 library` succeeds for the host and the target — against the SDK's own LLVM and a libc-minixrs release wide enough for std.

**Architecture:** Three repos. **tooling** makes the SDK able to host rustc (an LLVM that depends on nothing outside macOS, and the triple-named driver the target spec links with) and widens the libc ABI manifest. **libc-minixrs** gains the ~180 items std uses, under that manifest, released as `minixrs-0.2.185-2`. **rust-minixrs** registers the target, pins that release by tag, and ports std, mostly by putting minixrs on the arm linux-musl already takes.

**Tech Stack:** the SDK (llvm-minixrs 22.1.8, musl-minixrs), rust at `6f72b5dd5f82226a2773d40efea7bab941892a73` (nightly-2026-07-23) and its `./x` bootstrap, libc 0.2.185, bash 3.2.

**Spec:** [`docs/superpowers/specs/2026-09-30-p4-rust-std-design.md`](../specs/2026-09-30-p4-rust-std-design.md) — sections "P4b — rust-minixrs" and decisions R2–R6, R8, R10, R12. The spec was corrected in the same commit as this plan, from what the prototype below found; read the current text.

**Attachments** — the large, mechanical changes travel as files beside this plan, in [`2026-10-01-p4b-rust-minixrs/`](2026-10-01-p4b-rust-minixrs/), so they are applied rather than retyped:

| File | Applied in | What it is |
|---|---|---|
| `libc-minixrs-std-surface.rs` | Task 3 | The block appended to libc-minixrs' `src/unix/minixrs/mod.rs` |
| `rust-0001-target.diff` | Task 5 | The target: `rustc_target`, bootstrap's stage-0 list, rustdoc's OS name, docs, tests |
| `rust-0003-std.diff` | Task 7 | The std port, the null unwinder, the abort-only panic runtime |

**Everything in this plan was run on 2026-10-01**, in a prototype: a scratch libc-minixrs clone, a scratch rust checkout at the pin on the forks volume, and the installed SDK.
- With the attachments applied, `./x build --stage 1 library` completed for both targets.
- `rustc_target`'s spec tests passed 334/334.
- `./x test tidy` failed only on the expected `extdeps` line.
- The check-cfg and assembly tests passed.
- A stage-1 `hello` and a backtrace-capturing program linked, branded and loadable.

Two things were not run as written, because each rewrites the installed SDK:
- **Task 1's LLVM rebuild.** The fix was proven instead by building `llvm-config` alone, with zstd off, in a scratch build directory: its baked system libraries become `-lm -lz -lxml2`. The prototype's rustc linked only by adding `ldflags = "-L/opt/homebrew/lib"`.
- **The new `check-driver.sh` steps' green run against the real SDK.** Each was shown red against the current SDK and green against a stand-in.

Also not run: Task 4's red. Its panic text is quoted from the source.

If a step's output differs from what is written, stop and find out why. Do not adjust the expectation.

## Global Constraints

- **Three repos, three sessions.** Tasks 1, 2 and 9 run in `~/src/tooling`. Task 3 runs **in a session inside `$MINIXRS_FORKS_DIR/libc-minixrs`**. Tasks 4–8 run **in a session inside `$MINIXRS_FORKS_DIR/rust-minixrs`**. Never edit fork source from a tooling session (the cross-repo rule in `CLAUDE.md`). A fork session appends to this repo's ledger by hand (`.superpowers/sdd/2026-10-01-p4b-rust-minixrs-plan/progress.md`) and skips USER-GATED steps, recording them as awaiting the user.
- **Order:** 1 → 2 → 3 (and its push) → 4 → 5 → 6 → 7 → 8 → 9. Task 6 fetches libc by tag from GitHub, so Task 3's push must have happened.
- The forks volume must be mounted for Tasks 2–9: `scripts/forks-volume.sh mount`.
- Pins: rust **`6f72b5dd5f82226a2773d40efea7bab941892a73`**, branch **`minixrs/nightly-2026-07-23`**; libc-minixrs branch **`minixrs/0.2.185`**, new release tag **`minixrs-0.2.185-2`** (a release tag is never moved); toolchain **`nightly-2026-07-23`**.
- rust-minixrs pins libc-minixrs **by git tag** (R12), never by branch, SHA or path.
- `bootstrap.toml` lives **outside the checkout**, at `$MINIXRS_FORKS_DIR/build/rust-minixrs/bootstrap.toml`; the build dir is `$MINIXRS_FORKS_DIR/build/rust-minixrs/build`. Every `./x` command passes `--config "$BT"` (where `BT` is that file) and runs under `env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH` — this machine sets `C_INCLUDE_PATH`, and clang searches it first.
- std must build under bootstrap's default `-D warnings`. Never relax `build.warnings` or `rust.deny-warnings`.
- libc-minixrs definitions are **copied** from the Linux-musl-aarch64 ones (the attachment is that copy), never derived by hand. Its module carries **no `#[cfg]`**.
- Scripts pass `bash -n` and `shellcheck -S warning` and run under macOS bash 3.2. **The Bash tool's shell is zsh:** wrap probes using `PIPESTATUS` in `bash -c`.
- Every commit is GPG-signed with `Signed-off-by` (`git commit -s`); never `--no-gpg-sign`, never `--no-verify`.
- **Nothing leaves the machine without the user's say-so:** no `git push`, no `gh repo fork`, no PR. Steps that do are **USER-GATED** — stop and ask.
- A tooling PR checks its own roadmap box in the same PR (Task 9).

## Review Focus

Conditions the spec implies that no step can exercise until something boots, or that a first implementation is likely to get wrong. Each is pinned where it can be.

1. **std at startup on a kernel without `poll` or signals** — `sanitize_standard_fds` and `reset_sigpipe` must not abort on `ENOSYS`. Nothing runs a minixrs binary until M4, so no test pins this; review the two hunks in `library/std/src/sys/pal/unix/mod.rs` by reading them against musl's `poll` and `signal` returning `-1`/`ENOSYS`.
2. **A std site that compiles but takes the wrong branch at run time** — glibc's `*64` aliases, `readdir_r` instead of `readdir`, the fork/exec spawn path. Pinned by the site table in Task 7, which records a decision for every `"hurd"` site and every `target_env = "musl"` arm; review it, not just the diff.
3. **A program that captures a backtrace** must link and report `Unsupported`, not fail to link and not crash — `_Unwind_FindEnclosingFunction` is reached only through `std::backtrace`, so `hello` alone does not prove it. Task 8, Step 3 links one; Step 4 proves the null unwinder is what makes it link.
4. **The caller's environment leaking into the build** — `C_INCLUDE_PATH`, `RUSTFLAGS`, an in-checkout `bootstrap.toml`. Pinned by the Global Constraints' command form; Task 4, Step 6 asserts no `bootstrap.toml`/`config.toml` exists in the checkout.
5. **A libc item added to the module but not the manifest, or with a wrong value** — must fail the parity gate. Task 3, Steps 4–5.

Known and accepted, not pinned: std's runtime behavior on minixrs (R1 — found at M4); `./x test tidy`'s `extdeps` failure on the git-sourced libc (R12 — a fork-only arrangement, Task 8, Step 5 expects exactly that line).

## File Structure

**tooling:**

| File | Responsibility |
|---|---|
| `scripts/build-llvm.sh` (modify) | Configure with `LLVM_ENABLE_ZSTD=OFF`; install the `aarch64-unknown-minixrs-clang` symlink |
| `verify/check-driver.sh` (modify) | Steps 4 (triple-named driver) and 5 (self-contained SDK) |
| `verify/libc-abi/items.list`, `allow.list` (modify) | The manifest for the widened module |
| `docs/sysroot-layout.md`, `docs/roadmap.md`, `README.md`, `CLAUDE.md` (modify) | Layout, P4b box, gates |
| `patches/rust/*.patch` (generated) | The exported rust-minixrs series |

**libc-minixrs:** `src/unix/minixrs/mod.rs` (append) — constants, types, socket structs, functions and `W*` macros std uses.

**rust-minixrs:**

| File | Responsibility |
|---|---|
| `compiler/rustc_target/src/spec/{base/minixrs.rs, targets/aarch64_unknown_minixrs.rs}` (new); `spec/mod.rs`, `spec/base/mod.rs` | The target and its `Os` variant |
| `src/bootstrap/src/core/sanity.rs` | The stage-0 compiler does not know the triple |
| `src/librustdoc/clean/cfg.rs` | Display name in rustdoc's exhaustive `Os` match |
| `src/doc/rustc/src/{platform-support.md, SUMMARY.md, platform-support/minixrs.md}` | Tier-3 docs |
| `tests/assembly-llvm/targets/targets-elf.rs`, `tests/ui/check-cfg/{well-known-values,cfg-crate-features}.stderr` | Target coverage tidy requires; the new `target_os` value |
| `library/Cargo.toml`, `library/Cargo.lock` | libc-minixrs by tag |
| `library/unwind/src/{lib.rs, minixrs.rs}`, `library/panic_unwind/src/lib.rs`, `library/std/src/sys/personality/mod.rs` | No unwinder: a null one for backtrace-rs, the dummy panic runtime |
| `library/std/...` (24 files) | The port: `os::minixrs`, PAL arms, startup carve-outs |

---

### Task 1: An SDK that can host rustc (tooling)

**Files:**
- Modify: `scripts/build-llvm.sh`, `verify/check-driver.sh`, `docs/sysroot-layout.md`

**Interfaces:**
- Produces: `$MINIXRS_SDK/bin/aarch64-unknown-minixrs-clang` (symlink to `clang`), used as `cc`/`linker` in Task 4's `bootstrap.toml` and named by the target spec in Task 5; an `llvm-config` whose `--system-libs` is `-lm -lz -lxml2`, which Task 5's rustc links against.

**Why:** the prototype's rustc failed to link — `ld: library 'zstd' not found` — because CMake found Homebrew's zstd when the SDK LLVM was configured, so `llvm-config --system-libs` says `-lzstd`, and `otool -L bin/clang` shows `/opt/homebrew/opt/zstd/lib/libzstd.1.dylib`. The SDK has depended on Homebrew without anyone choosing that. Turning zstd off (it only compresses debug sections) removes both. Separately, the target spec cannot say `linker: clang` (R2): `PATH` resolves that to Apple's clang.

- [ ] **Step 1: Write the failing checks**

In `verify/check-driver.sh`, extend the header list after the step-3 lines:

```bash
#   4. the triple-named driver: aarch64-unknown-minixrs-clang, next to clang,
#      targets minixrs with no --target — it is the linker rustc's target
#      spec names
#   5. self-contained: clang loads no library from outside the OS, and
#      llvm-config's system libraries link with no extra search path — rustc
#      links this LLVM through llvm-config (P4 design R10)
```

Renumber the three progress lines from `[n/3]` to `[n/5]` (`[1/5] preprocessor defines`, `[2/5] driver link line`, `[3/5] link a branded static ELF`). Then insert immediately above the final `if [ "$fail" -eq 0 ]; then`:

```bash
# ---------------------------------------------------------------- step 4
# rustc's target spec names this driver rather than `clang`, which PATH would
# resolve to Apple's. clang takes its target from a triple-prefixed name.
echo "check-driver: [4/5] triple-named driver"
TRIPLE_CLANG="$(dirname "$CLANG")/$TRIPLE-clang"
if [ ! -x "$TRIPLE_CLANG" ]; then
    bad "$TRIPLE_CLANG not found — scripts/build-llvm.sh installs it"
elif "$TRIPLE_CLANG" -dM -E -x c /dev/null 2>/dev/null | grep -qE '^#define __minixrs__\b'; then
    pass "$TRIPLE-clang targets minixrs without --target"
else
    bad "$TRIPLE_CLANG does not target $TRIPLE by its name"
fi

# ---------------------------------------------------------------- step 5
# CMake enables optional dependencies it happens to find — Homebrew's zstd,
# for one — and then clang, and every rustc linked through llvm-config,
# depends on a package nothing here installs.
echo "check-driver: [5/5] self-contained"
foreign="$(otool -L "$CLANG" | tail -n +2 | awk '{print $1}' |
    grep -vE '^(/usr/lib/|/System/Library/|@rpath/|@executable_path/)' || true)"
if [ -z "$foreign" ]; then
    pass "clang loads only OS libraries"
else
    bad "clang loads libraries from outside the OS: $(echo $foreign)"
fi
LLVM_CONFIG="$(dirname "$CLANG")/llvm-config"
syslibs="$("$LLVM_CONFIG" --system-libs 2>/dev/null)" || syslibs="?"
# shellcheck disable=SC2086 # the list is meant to split into -l flags
if [ "$syslibs" != "?" ] &&
    printf 'int main(void) { return 0; }\n' |
        /usr/bin/cc -x c - -o "$tmp/syslibs" $syslibs 2>"$tmp/syslibs.err"; then
    pass "llvm-config's system libraries ($syslibs) link from the OS"
else
    sed 's/^/check-driver:   /' "$tmp/syslibs.err" >&2 2>/dev/null || true
    bad "llvm-config's system libraries ($syslibs) do not link without an extra -L"
fi
```

- [ ] **Step 2: Run them against the current SDK**

Run: `bash -n verify/check-driver.sh && shellcheck -S warning verify/check-driver.sh && verify/check-driver.sh; echo "exit=$?"`
Expected: steps 1–3 PASS as before, then:

```
check-driver: FAIL /Users/<you>/toolchains/minixrs/bin/aarch64-unknown-minixrs-clang not found — scripts/build-llvm.sh installs it
check-driver: FAIL clang loads libraries from outside the OS: /opt/homebrew/opt/zstd/lib/libzstd.1.dylib
check-driver:   ld: library 'zstd' not found
check-driver: FAIL llvm-config's system libraries (-lm -lz -lzstd -lxml2) do not link without an extra -L
exit=1
```

- [ ] **Step 3: Fix the build script**

In `scripts/build-llvm.sh`, add to the `cmake` invocation, after `-DCLANG_DEFAULT_LINKER=lld \`:

```bash
    -DLLVM_ENABLE_ZSTD=OFF \
```

and add a comment above the `cmake` line, after the `LLVM_PARALLEL_LINK_JOBS` paragraph:

```bash
# LLVM_ENABLE_ZSTD=OFF: CMake otherwise enables zstd whenever it finds one —
# Homebrew's, here — and clang, plus every rustc linked through llvm-config
# (P4), then depends on a package nothing in this repo installs. zstd only
# compresses debug sections. verify/check-driver.sh step 5 holds the line.
```

After `ninja -C "$BUILD_DIR" install`, add:

```bash
# The name rustc's aarch64-unknown-minixrs target spec gives its linker (P4
# design R2): invoked under it, clang targets minixrs with no --target, and a
# missing SDK is "linker not found" rather than Apple's clang silently.
ln -sf clang "$MINIXRS_SDK/bin/aarch64-unknown-minixrs-clang"
```

In `docs/sysroot-layout.md`, below the `bin/` line, add an indented entry in the tree's own style:

```
│   └── aarch64-unknown-minixrs-clang        → clang; the linker rustc's target spec names (P4)
```

- [ ] **Step 4: Rebuild and install the SDK LLVM**

```bash
scripts/forks-volume.sh mount
scripts/build-llvm.sh 2>&1 | tail -3
```

Expected: `build-llvm: installed into …` and the driver smoke test's `__minixrs__` line. The reconfigure rebuilds broadly (`CLAUDE.md`, Building); ccache absorbs most of it. The musl stamp is **not** invalidated — the clang version string carries the fork SHA, which did not change — and compiler-rt survives the install.

- [ ] **Step 5: Run the checks again**

Run: `verify/check-driver.sh | tail -6; verify/selftest.sh | tail -1; scripts/build-sysroot.sh --skip-musl 2>&1 | tail -1`
Expected: `PASS aarch64-unknown-minixrs-clang targets minixrs without --target`, `PASS clang loads only OS libraries`, `PASS llvm-config's system libraries (-lm -lz -lxml2) link from the OS`, `check-driver: all checks passed`; selftest 18/18; the sysroot gate green (the branded C hello still links with the rebuilt clang).

- [ ] **Step 6: Commit**

```bash
git add scripts/build-llvm.sh verify/check-driver.sh docs/sysroot-layout.md
git commit -s -m "SDK: no Homebrew zstd, and the triple-named clang

rustc links the SDK's LLVM through llvm-config (P4 design R10), and that
LLVM was configured with Homebrew's zstd because CMake found it, so
llvm-config said -lzstd and rustc_driver failed to link. Configure it
off; nothing here compresses debug sections.

Install bin/aarch64-unknown-minixrs-clang, the linker the minixrs
target spec names: clang infers the target from it, and PATH cannot
resolve it to Apple's clang. check-driver.sh gains a step for each."
```

---

### Task 2: The manifest for what std needs (tooling)

**Files:**
- Modify: `verify/libc-abi/items.list`, `verify/libc-abi/allow.list`

**Interfaces:**
- Produces: a manifest naming every item Task 3 adds. Task 3's gate run consumes it.

- [ ] **Step 1: Add the includes**

In `verify/libc-abi/items.list`, add these `include` lines, keeping the block sorted:

```
include <errno.h>
include <fcntl.h>
include <limits.h>
include <netinet/in.h>
include <netinet/tcp.h>
include <stdlib.h>
include <sys/file.h>
include <sys/ioctl.h>
include <sys/un.h>
include <sys/wait.h>
```

- [ ] **Step 2: Append the items**

Append to `verify/libc-abi/items.list`:

```
# P4b: what std needs beyond P4a (aarch64-musl values, copied)
int clockid_t
const AF_INET
const AF_INET6
const AF_UNIX
const AT_FDCWD
const AT_REMOVEDIR
const AT_SYMLINK_NOFOLLOW
const CLOCK_MONOTONIC
const CLOCK_REALTIME
const E2BIG
const EACCES
const EADDRINUSE
const EADDRNOTAVAIL
const EAGAIN
const EAI_SYSTEM
const EBADF
const EBUSY
const ECONNABORTED
const ECONNREFUSED
const ECONNRESET
const EDEADLK
const EDQUOT
const EEXIST
const EFBIG
const EHOSTUNREACH
const EINPROGRESS
const EINTR
const EINVAL
const EIO
const EISCONN
const EISDIR
const ELOOP
const EMFILE
const EMLINK
const ENAMETOOLONG
const ENETDOWN
const ENETUNREACH
const ENFILE
const ENOENT
const ENOMEM
const ENOSPC
const ENOSYS
const ENOTCONN
const ENOTDIR
const ENOTEMPTY
const EOPNOTSUPP
const EPERM
const EPIPE
const ERANGE
const EROFS
const ESPIPE
const ESTALE
const ETIMEDOUT
const ETXTBSY
const EWOULDBLOCK
const EXDEV
const EXIT_FAILURE
const EXIT_SUCCESS
const F_DUPFD_CLOEXEC
const F_GETFD
const F_GETFL
const F_SETFL
const FIOCLEX
const FIONBIO
const IP_ADD_MEMBERSHIP
const IP_DROP_MEMBERSHIP
const IP_MULTICAST_LOOP
const IP_MULTICAST_TTL
const IP_TTL
const IPV6_ADD_MEMBERSHIP
const IPV6_DROP_MEMBERSHIP
const IPV6_MULTICAST_LOOP
const IPV6_V6ONLY
const LOCK_EX
const LOCK_NB
const LOCK_SH
const LOCK_UN
const MSG_NOSIGNAL
const MSG_PEEK
const O_ACCMODE
const O_APPEND
const O_CLOEXEC
const O_CREAT
const O_DIRECTORY
const O_EXCL
const O_NOFOLLOW
const O_NONBLOCK
const O_RDONLY
const O_RDWR
const O_TRUNC
const O_WRONLY
const POLLERR
const POLLHUP
const POLLIN
const POLLNVAL
const POLLOUT
const PTHREAD_MUTEX_NORMAL
const PTHREAD_STACK_MIN
const S_IFBLK
const S_IFCHR
const S_IFDIR
const S_IFIFO
const S_IFLNK
const S_IFMT
const S_IFREG
const S_IFSOCK
const S_IRGRP
const S_IROTH
const S_IRUSR
const S_IWGRP
const S_IWOTH
const S_IWUSR
const S_IXGRP
const S_IXOTH
const S_IXUSR
const SEEK_CUR
const SEEK_END
const SEEK_SET
const SHUT_RD
const SHUT_RDWR
const SHUT_WR
const SIGABRT
const SIGALRM
const SIGBUS
const SIGCHLD
const SIGCONT
const SIGFPE
const SIGHUP
const SIGILL
const SIGINT
const SIGIO
const SIGKILL
const SIGPIPE
const SIGPROF
const SIGQUIT
const SIGSEGV
const SIGSTOP
const SIGSYS
const SIGTERM
const SIGTRAP
const SIGTSTP
const SIGTTIN
const SIGTTOU
const SIGURG
const SIGUSR1
const SIGUSR2
const SIGVTALRM
const SIGWINCH
const SIGXCPU
const SIGXFSZ
const SO_BROADCAST
const SO_ERROR
const SO_KEEPALIVE
const SO_LINGER
const SO_RCVTIMEO
const SO_REUSEADDR
const SO_SNDTIMEO
const SOCK_CLOEXEC
const SOCK_DGRAM
const SOCK_STREAM
const SOL_SOCKET
const SOMAXCONN
const TCP_NODELAY
const TIMER_ABSTIME
const UTIME_OMIT
const _SC_GETPW_R_SIZE_MAX
const _SC_HOST_NAME_MAX
const _SC_NPROCESSORS_ONLN
const _SC_PAGESIZE
struct in_addr s_addr
struct ip_mreq imr_multiaddr imr_interface
struct sockaddr_in sin_family sin_port sin_addr sin_zero
struct sockaddr_in6 sin6_family sin6_port sin6_flowinfo sin6_addr sin6_scope_id
struct sockaddr_storage ss_family
struct sockaddr_un sun_family sun_path
```

Append to `verify/libc-abi/allow.list`:

```
Ioctl                       ioctl()'s request type; C has no typedef for it (musl declares `int`)
PTHREAD_MUTEX_INITIALIZER   an aggregate constant; the gate compares integer constants only
PTHREAD_COND_INITIALIZER    an aggregate constant; the gate compares integer constants only
```

- [ ] **Step 3: Run the gate against the current fork — it must fail**

Run: `verify/check-libc-abi.sh 2>&1 | tail -2; echo "exit=$?"` (inside `bash -c` for the exit code)
Expected: exit 2, `the Rust emitter did not compile — a manifest item libc-minixrs does not have?`. The C side compiles (the headers have every item); the Rust side does not, because `minixrs-0.2.185-1` lacks them. That is this task's red.

- [ ] **Step 4: Commit**

```bash
git add verify/libc-abi/items.list verify/libc-abi/allow.list
git commit -s -m "verify: the libc-minixrs manifest for what std needs (P4b)

169 constants, clockid_t and six socket structs, each compared against
the SDK sysroot's headers once libc-minixrs carries them. Ioctl and the
two aggregate initializers are allow-listed with their reasons."
```

---

### Task 3: The std surface (libc-minixrs session)

**Run this task in a session whose working directory is `$MINIXRS_FORKS_DIR/libc-minixrs`.**

**Files:**
- Modify: `src/unix/minixrs/mod.rs`

**Interfaces:**
- Consumes: Task 2's manifest via `~/src/tooling/verify/check-libc-abi.sh`.
- Produces: tag **`minixrs-0.2.185-2`**, pushed — Task 6 pins it.

The block is the Linux-musl-aarch64 definition of each item, taken from libc 0.2.185's own expansion for `aarch64-unknown-linux-musl` (`cargo rustc -- -Zunpretty=expanded`), with two adjustments, both to P4a's own representation: `SO_RCVTIMEO`/`SO_SNDTIMEO` name their `_OLD` values (20, 21) directly, and the two pthread initializers build P4a's `{ __size: [u64; N] }` structs.

- [ ] **Step 1: Confirm the starting point**

```bash
git switch minixrs/0.2.185 && git status --short && git describe --tags
```

Expected: clean, `minixrs-0.2.185-1`.

- [ ] **Step 2: Append the block**

```bash
cat ~/src/tooling/docs/superpowers/plans/2026-10-01-p4b-rust-minixrs/libc-minixrs-std-surface.rs \
    >> src/unix/minixrs/mod.rs
rustfmt +nightly-2026-07-23 --edition 2021 src/unix/minixrs/mod.rs
git diff --stat
```

Expected: `src/unix/minixrs/mod.rs | 340 ++++…`, insertions only (rustfmt changes nothing; the attachment is already formatted).

- [ ] **Step 3: The gate goes green**

Run: `~/src/tooling/verify/check-libc-abi.sh 2>&1 | tail -2`
Expected:

```
compare: 526 entries identical
check-libc-abi: PASS (227 module items covered; 27 function declarations not checked)
```

Also: `cargo +nightly-2026-07-23 build -Zbuild-std=core -Zjson-target-spec --target ~/src/tooling/verify/testdata/aarch64-unknown-minixrs-unix.json 2>&1 | grep -c '^warning'` → `0`.

- [ ] **Step 4: Prove a wrong value fails (Review Focus 5)**

```bash
cp src/unix/minixrs/mod.rs /tmp/minixrs-mod.rs.keep
sed -i '' 's/^pub const SO_RCVTIMEO: c_int = 20;/pub const SO_RCVTIMEO: c_int = 66;/' src/unix/minixrs/mod.rs
bash -c '~/src/tooling/verify/check-libc-abi.sh 2>&1 | tail -2; echo exit=${PIPESTATUS[0]}'
cp /tmp/minixrs-mod.rs.keep src/unix/minixrs/mod.rs
```

Expected: `MISMATCH 261: value SO_RCVTIMEO: C=0x14 Rust=0x42`, `compare: 1 of 526 entries differ`, `exit=1`. (The number is the manifest line; it shifts if Task 2's lines landed elsewhere.)

Then widen a struct field the same way — `pub sin6_flowinfo: u32,` → `u64,` inside `sockaddr_in6` — and expect three `MISMATCH … sockaddr_in6…` lines (`sizeof sockaddr_in6.sin6_flowinfo: C=0x4 Rust=0x8`, and the offsets of `sin6_addr` and `sin6_scope_id`), `6 of 526 entries differ`, `exit=1`. Restore from `/tmp/minixrs-mod.rs.keep`.

- [ ] **Step 5: Prove an unlisted item fails**

```bash
printf 'pub const NOT_IN_THE_MANIFEST: c_int = 1;\n' >> src/unix/minixrs/mod.rs
bash -c '~/src/tooling/verify/check-libc-abi.sh 2>&1 | tail -2; echo exit=${PIPESTATUS[0]}'
cp /tmp/minixrs-mod.rs.keep src/unix/minixrs/mod.rs && rm /tmp/minixrs-mod.rs.keep
```

Expected: `… in neither items.list nor allow.list:` / `  NOT_IN_THE_MANIFEST`, `exit=1`.

- [ ] **Step 6: Commit and tag**

```bash
~/src/tooling/verify/check-libc-abi.sh | tail -1     # green on the restored file
git add src/unix/minixrs/mod.rs
git commit -s -m "minixrs: what std needs

The constants, functions, socket structs and wait-status macros the
standard library uses on a Unix target, copied from the
Linux-musl-aarch64 definitions. Each type, struct and integer constant
is checked against the SDK sysroot's headers by the tooling repo's
verify/check-libc-abi.sh."
git tag -s minixrs-0.2.185-2 -m "libc-minixrs 0.2.185, release 2: what std needs (P4b)"
git log --oneline 0.2.185..HEAD
```

Expected: three commits above `0.2.185`.

- [ ] **Step 7: USER-GATED — push**

Stop and ask the user. On approval:

```bash
git push origin minixrs/0.2.185
git push origin minixrs-0.2.185-2
```

---

### Task 4: Fork bring-up (rust-minixrs session)

**Run this task in a session whose working directory is `$MINIXRS_FORKS_DIR/rust-minixrs`** (create it in Step 2, then start the session there).

**Files:**
- Create: `$MINIXRS_FORKS_DIR/build/rust-minixrs/bootstrap.toml` (outside the checkout)

**Interfaces:**
- Consumes: Task 1's `aarch64-unknown-minixrs-clang` and `llvm-config`.
- Produces: branch `minixrs/nightly-2026-07-23` at the pin, and `BT=$MINIXRS_FORKS_DIR/build/rust-minixrs/bootstrap.toml`, which every later `./x` command passes as `--config "$BT"`.

- [ ] **Step 1: USER-GATED — create the GitHub fork**

Stop and ask; it creates a public repository:

```bash
gh repo fork rust-lang/rust --org minixrs --fork-name rust-minixrs --remote=false
```

If declined for now, continue; nothing needs `origin` until Task 8, Step 7.

- [ ] **Step 2: Clone at the pin**

```bash
~/src/tooling/scripts/forks-volume.sh mount
. ~/src/tooling/scripts/env.sh
git clone --filter=blob:none --no-checkout https://github.com/rust-lang/rust "$MINIXRS_FORKS_DIR/rust-minixrs"
cd "$MINIXRS_FORKS_DIR/rust-minixrs"
git remote rename origin upstream
git remote add origin git@github.com:minixrs/rust-minixrs.git
git switch -c minixrs/nightly-2026-07-23 6f72b5dd5f82226a2773d40efea7bab941892a73
git log -1 --format='%H %s'
```

Expected: `6f72b5dd5f82226a2773d40efea7bab941892a73 Auto merge of #143208 - Mark-Simulacrum:skip-noop-cleanup, r=oli-obk`. Blobless: history is complete (later rebases need it), file contents are fetched on demand. The forks volume is case-sensitive, which the rust tree requires.

- [ ] **Step 3: Write `bootstrap.toml` outside the checkout**

```bash
mkdir -p "$MINIXRS_FORKS_DIR/build/rust-minixrs"
cat > "$MINIXRS_FORKS_DIR/build/rust-minixrs/bootstrap.toml" <<EOF
# rust-minixrs, P4b. P4c's scripts/build-rust.sh will generate this file.
change-id = "ignore"

[llvm]
download-ci-llvm = false

[build]
build-dir = "$MINIXRS_FORKS_DIR/build/rust-minixrs/build"
target = ["aarch64-apple-darwin", "aarch64-unknown-minixrs"]
docs = false
extended = false

[rust]
download-rustc = false
channel = "nightly"
lld = false

# The SDK's LLVM (design R10); rustc links it through llvm-config.
[target.aarch64-apple-darwin]
llvm-config = "$MINIXRS_SDK/bin/llvm-config"

[target.aarch64-unknown-minixrs]
cc = "$MINIXRS_SDK/bin/aarch64-unknown-minixrs-clang"
ar = "$MINIXRS_SDK/bin/llvm-ar"
ranlib = "$MINIXRS_SDK/bin/llvm-ranlib"
linker = "$MINIXRS_SDK/bin/aarch64-unknown-minixrs-clang"
EOF
BT="$MINIXRS_FORKS_DIR/build/rust-minixrs/bootstrap.toml"
grep -c "$HOME" "$BT"
```

Expected: `6` — every path expanded, none left as a literal `$MINIXRS_…`.

- [ ] **Step 4: Record the red state**

```bash
env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
    ./x build --stage 1 library --config "$BT" 2>&1 | tail -8
```

Expected: after bootstrap downloads its stage 0 and compiles itself, a panic from `src/bootstrap/src/core/sanity.rs` beginning `aarch64-unknown-minixrs: No such target exists in the target list,` (the message continues over two more lines, ending in the `BOOTSTRAP_SKIP_TARGET_SANITY` hint) — neither the stage-0 compiler nor this tree knows the triple yet. Taken from the source, not from a run: the prototype had the stage-0 list entry from the start.

- [ ] **Step 5: Ledger**

Append to `~/src/tooling/.superpowers/sdd/2026-10-01-p4b-rust-minixrs-plan/progress.md` the clone's HEAD and whether Step 1 ran or awaits the user.

- [ ] **Step 6: Guard check (Review Focus 4)**

Run: `ls bootstrap.toml config.toml 2>&1 | grep -c 'No such file'`
Expected: `2`. A `bootstrap.toml` in the checkout would be read in preference to nothing and silently diverge from `$BT`.

---

### Task 5: The target (rust-minixrs session)

**Files:** as `rust-0001-target.diff` — new `compiler/rustc_target/src/spec/base/minixrs.rs`, `compiler/rustc_target/src/spec/targets/aarch64_unknown_minixrs.rs`, `src/doc/rustc/src/platform-support/minixrs.md`; modified `compiler/rustc_target/src/spec/{mod.rs, base/mod.rs}`, `src/bootstrap/src/core/sanity.rs`, `src/librustdoc/clean/cfg.rs`, `src/doc/rustc/src/{SUMMARY.md, platform-support.md}`, `tests/assembly-llvm/targets/targets-elf.rs`, `tests/ui/check-cfg/{well-known-values,cfg-crate-features}.stderr`.

**Interfaces:**
- Consumes: `$BT` (Task 4).
- Produces: `Os::Minixrs` and the built-in target `aarch64-unknown-minixrs`; a stage-1 rustc at `$MINIXRS_FORKS_DIR/build/rust-minixrs/build/host/stage1/bin/rustc`.

The two new spec files, for review (they are in the attachment verbatim):

```rust
// compiler/rustc_target/src/spec/base/minixrs.rs
use crate::spec::{Os, PanicStrategy, RelocModel, TargetOptions, cvs};

pub(crate) fn opts() -> TargetOptions {
    TargetOptions {
        os: Os::Minixrs,
        families: cvs!["unix"],
        // minixrs has no dynamic loader: every program is a static `ET_EXEC`,
        // as the SDK's C programs are.
        dynamic_linking: false,
        relocation_model: RelocModel::Static,
        position_independent_executables: false,
        crt_static_default: true,
        crt_static_respected: true,
        crt_static_allows_dylibs: false,
        has_thread_local: true,
        // No unwinder is linked yet.
        panic_strategy: PanicStrategy::Abort,
        ..Default::default()
    }
}
```

```rust
// compiler/rustc_target/src/spec/targets/aarch64_unknown_minixrs.rs
use crate::spec::{Arch, FramePointer, StackProbeType, Target, TargetMetadata, base};

pub(crate) fn target() -> Target {
    let mut base = base::minixrs::opts();
    base.max_atomic_width = Some(128);
    base.stack_probes = StackProbeType::Inline;
    // What `clang --target=aarch64-unknown-minixrs` enables, so C and Rust
    // objects in one image agree.
    base.features = "+v8a,+fp-armv8,+neon".into();
    base.frame_pointer = FramePointer::NonLeaf;
    // The minixrs SDK's clang, by its triple-prefixed name: invoked so, it
    // targets minixrs, selects musl-minixrs's crt objects (which carry the
    // image brand) and passes the minixrs layout flags to lld.
    base.linker = Some("aarch64-unknown-minixrs-clang".into());

    Target {
        llvm_target: "aarch64-unknown-minixrs".into(),
        metadata: TargetMetadata {
            description: Some("ARM64 minixrs".into()),
            tier: Some(3),
            host_tools: Some(false),
            std: Some(true),
        },
        pointer_width: 64,
        data_layout: "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32".into(),
        arch: Arch::AArch64,
        options: base,
    }
}
```

`crt_static_respected` is `true` because rustc rejects a target whose static CRT is on by default but not respected (the spec's "not switchable" was corrected). `-C target-feature=-crt-static` then simply fails to link — there is no shared libc. The `linker_flavor` is the default, `gnu-cc`.

- [ ] **Step 1: Apply the attachment**

```bash
A=~/src/tooling/docs/superpowers/plans/2026-10-01-p4b-rust-minixrs
git apply --check "$A/rust-0001-target.diff" && git apply "$A/rust-0001-target.diff"
git status --short
```

Expected: 9 modified (`M`) and 3 untracked (`??`) paths, all under `compiler/`, `src/` and `tests/`.

- [ ] **Step 2: rustc_target's spec tests include and pass the new target**

```bash
cd compiler/rustc_target
CFG_RELEASE=1.99.0-nightly CFG_RELEASE_CHANNEL=nightly CFG_VERSION=1.99.0-nightly \
RUSTC_BOOTSTRAP=1 CARGO_ENCODED_RUSTFLAGS='' \
CARGO_TARGET_DIR="$MINIXRS_FORKS_DIR/build/rust-minixrs/rustc-target-test" \
    cargo +nightly-2026-07-23 test -q -p rustc_target --lib spec:: 2>&1 | grep 'test result'
cd ../..
```

Expected: `test result: ok. 334 passed; 0 failed; 0 ignored; 0 measured; 2 filtered out` (333 at the unmodified pin — one consistency test per built-in target). The `CFG_*` variables stand in for what `./x` sets; the `unexpected cfg condition name: bootstrap` warnings are the same outside `./x`.

- [ ] **Step 3: Prove the target's test bites**

Set `crt_static_respected: false` in `base/minixrs.rs`, rerun Step 2's command with the filter `spec::tests::aarch64_unknown_minixrs`, and restore.
Expected: `panicked at compiler/rustc_target/src/spec/mod.rs:…: static CRT can be enabled but \`crt_static_respected\` is not set`, `0 passed; 1 failed`.

- [ ] **Step 4: Build the stage-1 compiler**

```bash
env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
    ./x build --stage 1 compiler --config "$BT" 2>&1 | tail -3
```

Expected: `Build completed successfully` after roughly 15–20 minutes on 14 cores. The prototype's one failure here was `ld: library 'zstd' not found`, which Task 1 removed; if it reappears, the SDK was not rebuilt.

- [ ] **Step 5: The compiler knows the target**

```bash
S1="$MINIXRS_FORKS_DIR/build/rust-minixrs/build/host/stage1/bin/rustc"
"$S1" --print cfg --target aarch64-unknown-minixrs |
    grep -E 'target_(os|env|family|vendor)|panic|crt-static|"neon"|has_atomic="128"'
```

Expected exactly:

```
panic="abort"
target_env=""
target_family="unix"
target_feature="crt-static"
target_feature="neon"
target_has_atomic="128"
target_os="minixrs"
target_vendor="unknown"
```

- [ ] **Step 6: The test-suite edits**

```bash
env -u CPATH -u C_INCLUDE_PATH ./x test --stage 1 --config "$BT" --bless \
    tests/ui/check-cfg/well-known-values.rs tests/ui/check-cfg/cfg-crate-features.rs 2>&1 | grep 'test result'
git diff --stat tests/ui
env -u CPATH -u C_INCLUDE_PATH ./x test --stage 1 --config "$BT" \
    tests/assembly-llvm/targets/targets-elf.rs 2>&1 | grep 'test result'
```

Expected: the check-cfg run passes, and `git diff --stat tests/ui` is empty — the attachment's `.stderr` edits are already the blessed output (`cfg-crate-features.stderr` truncates the list, so adding an OS moves its cut-off, `\`rtems\` and 16 more`, rather than inserting one name). The assembly suite: `37 passed; 0 failed; 232 ignored` for each of the two targets — 37 is every AArch64 revision, `aarch64_unknown_minixrs` among them (`build/aarch64-apple-darwin/test/assembly-llvm/targets/targets-elf.aarch64_unknown_minixrs` exists); the rest need LLVM backends the SDK does not build.

- [ ] **Step 7: Commit**

```bash
git add compiler src tests
git commit -s -m "Add the aarch64-unknown-minixrs target

minixrs is a microkernel OS written in Rust whose userland libc is a
musl fork. The target is static ET_EXEC only, panic=abort (no unwinder
yet), and links through the minixrs SDK's clang by its triple-prefixed
name, which supplies the crt objects that brand the image.

Also: the triple in bootstrap's stage-0 missing list, its name in
rustdoc's cfg rendering, tier-3 docs, and the assembly and check-cfg
test updates tidy requires."
```

---

### Task 6: Pin libc-minixrs (rust-minixrs session)

**Files:**
- Modify: `library/Cargo.toml`, `library/Cargo.lock`

**Interfaces:**
- Consumes: tag `minixrs-0.2.185-2` on `github.com/minixrs/libc-minixrs` (Task 3, Step 7).
- Produces: a library workspace whose `libc` is that tag.

- [ ] **Step 1: Pin by tag**

Append to the existing `[patch.crates-io]` table at the end of `library/Cargo.toml`:

```toml

# minixrs: the libc fork that knows target_os = "minixrs". Pinned by tag —
# fork branches are force-pushed, so a branch or bare SHA can be orphaned.
libc = { git = "https://github.com/minixrs/libc-minixrs", tag = "minixrs-0.2.185-2" }
```

- [ ] **Step 2: Regenerate the lock entry**

```bash
(cd library && "$MINIXRS_FORKS_DIR/build/rust-minixrs/build/aarch64-apple-darwin/stage0/bin/cargo" update -p libc)
git diff library/Cargo.lock
```

Expected: one entry changes — the `source` line becomes `"git+https://github.com/minixrs/libc-minixrs?tag=minixrs-0.2.185-2#<sha>"` and its `checksum` line goes. `<sha>` is `git -C "$MINIXRS_FORKS_DIR/libc-minixrs" rev-parse 'minixrs-0.2.185-2^{commit}'` — compare them.

- [ ] **Step 3: The red Task 7 fixes**

```bash
env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
    ./x build --stage 1 library --config "$BT" > /tmp/p4b-red.log 2>&1
grep -cE '^error\[' /tmp/p4b-red.log; grep -E '^error\[' /tmp/p4b-red.log | sort | uniq -c | sort -rn | head -3
```

Expected: the host's std builds, then std for `aarch64-unknown-minixrs` fails — 27 errors at the prototype, led by `unresolved import \`super::platform::raw\`` (×3) and `cannot find module or crate \`imp\`` (×2). libc itself compiles: the pin works.

- [ ] **Step 4: Commit**

```bash
git add library/Cargo.toml library/Cargo.lock
git commit -s -m "library: take libc from libc-minixrs

The libc fork that knows target_os = \"minixrs\", pinned by its release
tag. Every item it adds is checked against the minixrs SDK's C headers
by the minixrs tooling repo."
```

---

### Task 7: The std port (rust-minixrs session)

**Files:** as `rust-0003-std.diff`, plus the generated `library/std/src/os/minixrs/fs.rs`.

**Interfaces:**
- Consumes: Task 5's target, Task 6's libc.
- Produces: the P4b gate — `./x build --stage 1 library` green for both targets.

**The decisions.** The rule: **minixrs takes the arm linux-musl takes** where that arm is a POSIX or musl path with different behavior. It does not take glibc's `*64` aliases or Hurd-only items. Where the kernel lacks a call, std calls musl, musl answers `ENOSYS`, and std returns `Err` (R5). Every `"hurd"` site at the pin, and every `target_env = "musl"` arm:

| Site | minixrs | Why |
|---|---|---|
| `std/build.rs` | joins | std refuses an unlisted OS |
| `env.rs` (doc list), `os/mod.rs`, `os/unix/mod.rs`, `sys/env_consts.rs` | joins | `std::os::minixrs`, `env::consts::OS` |
| `os/minixrs/{mod,fs,raw}.rs` (new) | — | `os/hurd`'s, with aarch64-musl widths and musl's `st_atime`/`st_atime_nsec` fields |
| `sys/args/unix.rs` | joins | argc/argv from the static store |
| `sys/fd/unix.rs`: `read_vectored_at`, `write_vectored_at` | joins | `preadv`/`pwritev`, as linux-musl |
| `sys/fd/unix.rs`: `off64_t`, `pread64`, `pwrite64` | no | glibc aliases; musl's plain names are 64-bit |
| `sys/fs/unix.rs`: the `readdir` `DirEntry` model (8 sites), `readdir as readdir64` (a musl arm, not Hurd's), `DirEntry::ino` | joins | linux-musl's `readdir`, not deprecated `readdir_r` |
| `sys/fs/unix.rs`: `os_datasync` | joins | `fdatasync` |
| `sys/fs/unix.rs`: `lock`, `lock_shared`, `try_lock`, `try_lock_shared`, `unlock`; `fs/tests.rs` (5) | joins | `flock`; the tests' expectations follow it |
| `sys/fs/unix.rs`: `dirfd`, `fstatat64`, `readdir64`, `*64` imports, `DirEntry::metadata` via `fstatat`; `fs/unix/dir.rs` | no | glibc-only (`not(target_env = "musl")`) |
| `sys/fs/unix.rs`: `modified`/`accessed` | no | Hurd's arm reads `st_mtim`; minixrs's `stat` has musl's `st_mtime`/`_nsec`, which the default arm reads |
| `sys/fs/unix.rs`: `Dir::drop`'s `dirfd` exclusion | no | minixrs is not excluded, so it already asserts the fd |
| `sys/io/error/unix.rs`: `errno_location` | joins | musl's `__errno_location` (link) |
| `sys/io/error/unix.rs`: `__xpg_strerror_r` | no | musl's `strerror_r` is already the XSI one |
| `sys/io/kernel_copy/linux.rs` | no | not compiled for minixrs |
| `sys/net/connection/socket/{mod,unix}.rs` (4), `os/unix/net/stream.rs` | joins | `SOCK_CLOEXEC`, `accept4`, `MSG_NOSIGNAL` |
| `sys/pal/unix/mod.rs`: `sanitize_standard_fds` | carve-out | `ENOSYS` from `poll` falls to the `fcntl` path, as Unikraft's does (R6) |
| `sys/pal/unix/mod.rs`: `reset_sigpipe` | carve-out | the `rtassert!` tolerates `ENOSYS` (R6) |
| `sys/pal/unix/mod.rs`: `SIGLOST`; `sys/process/unix/unix.rs` (3) | no | Hurd-only signal |
| `sys/pal/unix/stack_overflow.rs` (6) | no | no handler until signals exist (spec) |
| `sys/paths/unix.rs`: `current_exe` | joins | `/proc/self/exe`; `Err` until it exists (R5) |
| `sys/pipe/unix.rs` | joins | `pipe2` |
| `sys/process/unix/unix.rs`: `posix_spawn` (4, musl arms) | no | fork/exec; the `posix_spawn` surface is a later libc widening, and both fail with `ENOSYS` today |
| `sys/random/mod.rs` | joins | `unix_legacy` (`/dev/urandom`) |
| `sys/thread/mod.rs`: `set_name` | joins Hurd | the `unsupported` stub; `sys/thread/unix.rs`'s `CStr` import follows |
| `sys/thread/{mod,unix}.rs`: `sleep_until` (4) | joins | `clock_nanosleep(TIMER_ABSTIME)` |
| `sys/thread/unix.rs`: `available_parallelism` | joins | `sysconf(_SC_NPROCESSORS_ONLN)` |
| `sys/thread_local/mod.rs` | joins | the `linux_like` destructor arm (`__cxa_thread_atexit_impl` is weak) |
| `sys/time/unix.rs` | no | Hurd's `expect(unused)` |
| `unwind/src/lib.rs`: `gcc_s` | no | Hurd links libgcc_s |
| `unwind/src/lib.rs` + new `unwind/src/minixrs.rs` | null unwinder | see below |
| `panic_unwind/src/lib.rs`, `sys/personality/mod.rs` | `dummy`, no gcc personality | as espidf and nuttx; bootstrap builds the `panic-unwind` feature for every target |

**The null unwinder** (`library/unwind/src/minixrs.rs`, in the attachment):

```rust
//! A null unwinder for minixrs, which links no unwinder yet (`panic = "abort"`).
//!
//! backtrace-rs, which std compiles in for every Unix target, calls
//! `_Unwind_Backtrace` to walk the stack. Answering `_URC_END_OF_STACK` before
//! the first frame leaves every trace empty, which std reports as
//! `BacktraceStatus::Unsupported`. No context is ever handed out, so the
//! accessors below are never reached; they exist only so that the link
//! resolves. Delete this module when LLVM libunwind is linked for minixrs.

use core::ffi::c_void;

const URC_END_OF_STACK: i32 = 5;

#[unsafe(no_mangle)]
pub extern "C" fn _Unwind_Backtrace(_trace: *mut c_void, _arg: *mut c_void) -> i32 {
    URC_END_OF_STACK
}

#[unsafe(no_mangle)]
pub extern "C" fn _Unwind_GetIP(_ctx: *mut c_void) -> usize {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn _Unwind_GetCFA(_ctx: *mut c_void) -> usize {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn _Unwind_FindEnclosingFunction(_pc: *mut c_void) -> *mut c_void {
    core::ptr::null_mut()
}
```

The alternatives the prototype rejected:
- **Gate backtrace-rs's libunwind arm.** It's a git submodule, so this means a third fork.
- **Gate std's two `trace_unsynchronized` callers.** That leaves 13 unused-variable and unused-`mut` warnings, which `-D warnings` rejects.

**The startup carve-outs** (`library/std/src/sys/pal/unix/mod.rs`, in the attachment):

```rust
                    #[cfg(any(target_vendor = "unikraft", target_os = "minixrs"))]
                    libc::ENOSYS => {
                        // Not all configurations of Unikraft enable `LIBPOSIX_EVENT`,
                        // and the minixrs kernel has no `poll` yet.
                        break 'poll;
                    }
```

```rust
                // The minixrs kernel has no signals yet: musl answers ENOSYS, and a
                // process that cannot be sent SIGPIPE needs no disposition for it.
                #[cfg(target_os = "minixrs")]
                rtassert!(
                    signal(libc::SIGPIPE, handler) != libc::SIG_ERR
                        || crate::sys::io::errno() == libc::ENOSYS
                );
                #[cfg(not(target_os = "minixrs"))]
                rtassert!(signal(libc::SIGPIPE, handler) != libc::SIG_ERR);
```

- [ ] **Step 1: Apply the attachment and generate `os/minixrs/fs.rs`**

```bash
A=~/src/tooling/docs/superpowers/plans/2026-10-01-p4b-rust-minixrs
git apply --check "$A/rust-0003-std.diff" && git apply "$A/rust-0003-std.diff"
sed -e 's/Hurd-specific/minixrs-specific/; s/os::hurd::/os::minixrs::/g' \
    -e 's/st_\([amc]\)tim\.tv_sec/st_\1time/; s/st_\([amc]\)tim\.tv_nsec/st_\1time_nsec/' \
    library/std/src/os/hurd/fs.rs > library/std/src/os/minixrs/fs.rs
diff library/std/src/os/hurd/fs.rs library/std/src/os/minixrs/fs.rs | grep -c '^>'
```

Expected: `23` changed lines — the module doc line, 16 `use std::os::minixrs::fs::MetadataExt;` doc examples, and six `st_[amc]time{,_nsec}` field reads.

- [ ] **Step 2: The gate**

```bash
env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
    ./x build --stage 1 library --config "$BT" 2>&1 | tail -4
```

Expected:

```
Building stage1 library artifacts{alloc, compiler_builtins, core, panic_abort, panic_unwind, proc_macro, rustc-std-workspace-core, std, std_detect, sysroot, test, unwind} (stage1:aarch64-apple-darwin -> stage1:aarch64-unknown-minixrs)
warning: dropping unsupported crate type `dylib` for target `aarch64-unknown-minixrs`
warning: `std` (lib) generated 1 warning
Build completed successfully in …
```

The `dylib` notice is not a lint, so `-D warnings` does not reject it. This target has no dynamic linking, so std is built only as an rlib.

- [ ] **Step 3: Commit — two commits**

```bash
git add library/unwind library/panic_unwind library/std/src/sys/personality
git commit -s -m "unwind, panic_unwind: minixrs links no unwinder

minixrs is panic=abort until LLVM libunwind is built for it. The
panic_unwind crate takes its dummy runtime and std no gcc personality,
as for espidf and nuttx. backtrace-rs still links the stack-walker entry
points on every Unix target, so the unwind crate gives minixrs a null
unwinder: _Unwind_Backtrace reports the end of the stack before the
first frame, and std calls the resulting empty trace unsupported."
git add library/std
git commit -s -m "std: port to minixrs

minixrs's libc is a musl fork, so std takes the arm linux-musl takes
wherever that is a POSIX or musl path, and not glibc's *64 aliases.
std::os::minixrs mirrors std::os::hurd with aarch64 musl widths.

Two startup carve-outs: poll() answering ENOSYS falls back to the fcntl
probe, and SIGPIPE's disposition may fail with ENOSYS. The kernel has
neither poll nor signals yet; neither should abort every program."
git status --short
```

Expected: clean.

---

### Task 8: Verify the toolchain and push (rust-minixrs session)

**Interfaces:**
- Consumes: the stage-1 sysroot (`$S1` from Task 5, Step 5).
- Produces: the pushed branch.

- [ ] **Step 1: A std hello links, branded and loadable**

```bash
. ~/src/tooling/scripts/env.sh      # puts $MINIXRS_SDK/bin, and so the linker, on PATH
mkdir -p /tmp/p4b && cd /tmp/p4b
printf 'fn main() {\n    println!("hello from minixrs");\n}\n' > hello.rs
"$S1" --edition 2024 -O --target aarch64-unknown-minixrs hello.rs -o hello
~/src/tooling/verify/check-brand.sh hello && ~/src/tooling/verify/check-image.sh hello
llvm-readelf -h hello | grep Type
llvm-readelf -sW hello | awk '$7 == "UND" && $5 == "GLOBAL"' | wc -l
```

Expected: `BRANDED minixrs abi_version=1 flags=0`, `LOADABLE (satisfies the minixrs loader rules)`, `Type: EXEC`, `0` undefined globals. (`_DYNAMIC` is a *local* hidden undefined, exactly as in the SDK's C hello; `__cxa_thread_atexit_impl` is weak.)

- [ ] **Step 2: Only the null unwinder's symbols**

Run: `llvm-nm hello | grep -o '_Unwind_[A-Za-z]*' | sort -u | tr '\n' ' '`
Expected: `_Unwind_Backtrace _Unwind_GetCFA _Unwind_GetIP` — the null unwinder's own definitions (`T`), nothing else.

- [ ] **Step 3: A backtrace-capturing program links (Review Focus 3)**

```bash
printf 'use std::backtrace::Backtrace;\nfn main() {\n    let bt = Backtrace::force_capture();\n    println!("{:?} {}", bt.status(), bt);\n}\n' > bt.rs
"$S1" --edition 2024 -O --target aarch64-unknown-minixrs bt.rs -o bt
llvm-nm bt | grep -o '_Unwind_[A-Za-z]*' | sort -u | tr '\n' ' '
~/src/tooling/verify/check-brand.sh bt && ~/src/tooling/verify/check-image.sh bt
```

Expected: `_Unwind_Backtrace _Unwind_FindEnclosingFunction _Unwind_GetCFA _Unwind_GetIP`, then BRANDED and LOADABLE. `std::backtrace` is what reaches the fourth symbol.

- [ ] **Step 4: Prove the null unwinder is load-bearing**

In `library/unwind/src/lib.rs`, comment out `        mod minixrs;` (the line in the `target_os = "minixrs"` arm). Rebuild the library (Task 7, Step 2's command), and relink `bt.rs`:

```bash
"$S1" --edition 2024 -O --target aarch64-unknown-minixrs bt.rs -o bt-mut 2>&1 |
    grep -oE 'undefined symbol: _Unwind_[A-Za-z]+' | sort -u
```

Expected: exactly the four — `_Unwind_Backtrace`, `_Unwind_FindEnclosingFunction`, `_Unwind_GetCFA`, `_Unwind_GetIP`. Restore with `git checkout library/unwind/src/lib.rs`, rebuild, and confirm `git status --short` is clean.

- [ ] **Step 5: tidy**

```bash
cd "$MINIXRS_FORKS_DIR/rust-minixrs"
env -u CPATH -u C_INCLUDE_PATH ./x test tidy --config "$BT" 2>&1 | grep -E 'fmt:|tidy \[|failed'
```

Expected: `fmt: checked … files` with no diff, then exactly:

```
tidy [extdeps]: invalid source: "git+https://github.com/minixrs/libc-minixrs?tag=minixrs-0.2.185-2#<sha>"
tidy [extdeps]: FAIL
tidy: The following check failed: extdeps
```

That failure is R12's fork-only pin. tidy allows only crates.io and one rust-lang git source in a lock file. Any *other* tidy failure (`alphabetical`, `target_policy`, `pal`, `style`) is a real defect: fix it.

- [ ] **Step 6: Ledger**

Append to the tooling ledger: the branch head, the four commit SHAs (`git log --oneline 6f72b5dd5..HEAD`), and the outputs of Steps 1–5.

- [ ] **Step 7: USER-GATED — push**

Stop and ask. On approval:

```bash
git push -u origin minixrs/nightly-2026-07-23
```

---

### Task 9: Export the series and check the box (tooling)

**Files:**
- Create: `patches/rust/0001-*.patch` … `0004-*.patch` (generated)
- Modify: `docs/roadmap.md`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: Export**

```bash
scripts/export-patches.sh rust libc
ls patches/rust/*.patch | wc -l; ls patches/libc/*.patch | wc -l
```

Expected: `export-patches: rust → 4 patch(es) from 6f72b5dd5..HEAD`, `libc → 3 patch(es) from 0.2.185..HEAD`; `4`, `3`.

- [ ] **Step 2: Docs that count or describe what changed**

- `docs/roadmap.md`: check the P4b box. Do not touch P4c's.
- `CLAUDE.md`:
  - The gates block: `ls patches/libc/*.patch # 3 files (P4a, P4b)` and `ls patches/rust/*.patch # 4 files (P4b)`. `check-driver.sh` is now "the M2 gate, plus the triple-named driver and a self-contained SDK".
  - A gotcha: **build-std treats std's path dependencies like registry crates**. Editing a `[patch]`ed path crate doesn't rebuild it, so `rm -rf target` between rounds.
  - A second gotcha: the **zstd lesson**. CMake enables optional dependencies it happens to find.
- `README.md`: the patches line, `rust/` now holds 4 patches.

Then grep the tree for anything this branch falsified (`CLAUDE.md`'s whole-branch rule):

```bash
grep -rnE 'stays empty until|no rust-minixrs|rust/ .*empty|crt-static.*not switchable|linker: clang|pre-link .--target|minixrs-0\.2\.185-1' \
    README.md CLAUDE.md docs scripts verify | grep -v 'docs/superpowers/plans/2026-09-30'
```

Expected: no hits outside history. Fix each one that remains.

- [ ] **Step 3: Gates**

Run: `shellcheck -S warning scripts/*.sh verify/*.sh && verify/selftest.sh | tail -1 && verify/check-driver.sh | tail -1 && verify/check-libc-abi.sh | tail -1`
Expected: clean; `18/18`; `all checks passed`; `PASS (227 module items covered; 27 function declarations not checked)`.

- [ ] **Step 4: Commit**

```bash
git add patches docs/roadmap.md README.md CLAUDE.md
git commit -s -m "P4b: export the rust-minixrs and libc-minixrs series; check the box"
```

- [ ] **Step 5: USER-GATED — push and open the PR**

Run `/claude-md-management:revise-claude-md`, then ask the user before pushing.
