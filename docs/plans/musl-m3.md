# M3 — the sysroot exists, on the real triple

Roadmap phase **P3**. Companion to [llvm-m2.md](llvm-m2.md).

minixrs slice 5.6 (PR #47, 2026-07-26) already ran a branded C hello world —
but through the **stand-in triple**: `aarch64-unknown-linux-musl`, stock clang,
a hand-written `hello.ld`, and a `compiler_builtins` rlib scraped out of a
nested build dir. M3 is reproducing that through the SDK:

```sh
clang --target=aarch64-unknown-minixrs hello.c -o hello
```

and nothing else. **The port is not the remaining work. The toolchain flavor
is.**

## What the SDK flavor changes

Three hazards were inherited from slice 5.6. Each resolves differently here,
and all three are verified on disk rather than assumed:

| Slice 5.6 hazard | In the SDK flavor |
|---|---|
| `RANLIB` must be `llvm-ar s` — the pinned nightly ships no `llvm-ranlib` | **Moot.** The SDK ships `llvm-ranlib` (a symlink to `llvm-ar`, via `LLVM_INSTALL_UTILS=ON`). `build-musl.sh` uses it and guards on it. |
| Quad-float builtins (`__multf3`, `__floatsitf`, … for aarch64's IEEE-quad `long double`) come from `-Zbuild-std`'s `compiler_builtins` | **Already solved.** `build-compiler-rt.sh` installs `lib/clang/22/lib/aarch64-unknown-minixrs/libclang_rt.builtins.a`, which exports them, and the driver adds it automatically. |
| The linker script must be complete — orphan sections past the last `PT_LOAD` are a silent load failure | **No linker script.** lld's default layout already satisfies the loader (ET_EXEC, 4 KiB-aligned segments, ELF header + phdrs inside `PT_LOAD` #0 so `AT_PHDR` resolves, `PT_NOTE` carrying the brand). Only the image base needs pinning — see below. |

No musl fork change is expected: `configure`'s `aarch64*)` arm matches
`aarch64-unknown-minixrs`, and the port is triple-agnostic. This was confirmed
by building it — `patches/musl/0001-*.patch` is unchanged by M3.

## The one real design finding: the image base

lld defaults to an image base of `0x200000`. minixrs maps **every** process's
stack page at `SERVER_STACK_VA = 0x0020_0000`
(`kernel/src/arch/aarch64/userland.rs:144`). A default-linked SDK binary lands
exactly on its own stack.

**Decision: pin the base in the driver**, not in a per-project linker script or
a `-Wl,--image-base` in the build scripts, so that an ordinary `clang`
invocation stays sufficient — which is the whole milestone. Images go at
`0x0010_0000`, the same base `servers/*/user.ld` uses. Sharing it is safe:
every process gets its own TTBR0, which is also why the servers can share it
with each other.

This is **LLVM patch 0006**, the first hand-off below.

## Work in this repo

P3a, ✓ shipped (PR #3, merged 2026-07-27):

- **`verify/check-image.sh`** (new) — the kernel loader's rules, on the host, in
  a second, instead of a hang in QEMU. Asserts against
  `kernel/src/boot_image/elf.rs` (`load_into` / `load_segment`) plus the user VA
  map; delegates the identity note to `check-brand.sh` rather than parsing it
  twice. Same `od`/`dd`, no-toolchain style, same `0 / 1 / 3` exit-code idiom.
  The minixrs constants are duplicated in it by necessity — each is annotated
  with its defining file.
- **`verify/selftest.sh`** — four image fixtures over the existing `branded.s`,
  driven by link flags: `--image-base=0x100000` → 0, default base → 1 (stack
  overlap), `-pie` → 1 (`ET_DYN`), `testdata/misaligned.ld` → 1 (off page
  alignment). Each asserts the *reason*, not just the exit code.
- **`scripts/build-musl.sh`** — actually works now. Generates the ABI headers
  first, configures out of tree, installs `usr/{include,lib}` and a `.stamp`.
- **`scripts/build-sysroot.sh`** — the fictional selftest is gone (it called a
  package name and a flag that never existed); the real gate compiles the
  generated `abi-selftest.c` with `-DMINIXRS_ABI_CHECK_POSIX_ERRNO`.

### Why the fixtures pass the driver's `-z` flags

`verify/selftest.sh` links its image fixtures with
`-z max-page-size=4096 -z separate-loadable-segments`, mirroring the driver.
Without them lld packs loadable segments so that only `p_offset ≡ p_vaddr`
(mod page) holds — **neither is page-aligned** — and every fixture would fail
the alignment rule instead of the rule under test.

`separate-loadable-segments` is the load-bearing one; it gives each segment its
own page. `max-page-size` only sets the granularity, so dropping *it* alone
still yields 64 KiB-aligned (hence 4 KiB-aligned) segments. `image-base-1m` is
the sentinel fixture that catches these flags drifting away from the driver.

### Build-directory placement

`build-musl.sh` builds **outside** the fork work tree
(`$MINIXRS_FORKS_DIR/build/musl-minixrs`, overridable with `MUSL_BUILD_DIR`),
unlike `build-llvm.sh`, which builds inside its fork. The reason is specific:
minixrs pins `musl-minixrs` as a submodule and its c-headers CI job asserts a
clean `git status`, and musl's `.gitignore` would not cover a build directory.
`llvm-minixrs` is nobody's submodule.

The generated ABI headers land in `$MINIXRS_GEN_C_HEADERS_DIR` (`env.sh`,
default `$MINIXRS_FORKS_DIR/build/gen-c-headers`) because both `build-musl.sh`
and `build-sysroot.sh` must agree on the path. Consequence: `build-sysroot.sh
--skip-musl` needs the forks volume mounted, and its not-found message names
both recoveries (`forks-volume.sh mount`, `build-musl.sh`).

They are treated as **output, not an intermediate**: `build-musl.sh`'s stamp
early-exit checks for them, so deleting them forces a rebuild rather than
leaving `--force` as the only undocumented way out.

## Current state

`scripts/build-musl.sh && scripts/build-sysroot.sh` today:

```
build-sysroot: PASS layout (musl=6010533f minixrs=1132e62f clang=clang version 22.1.8 (… 85b2f7a57345))
build-sysroot: PASS ABI selftest
hello: BRANDED minixrs abi_version=1 flags=0
hello: LOADABLE (satisfies the minixrs loader rules)
build-sysroot: branded hello installed at …/share/minixrs/hello
```

The stamp carries **three** fields, not two — `musl=` (the fork commit the
sysroot was built from), `minixrs=` (the commit whose `gen-c-headers` output was
installed), and `clang=`.

That is P3a plus P3b: the sysroot installs, the ABI selftest passes against the
fork's own `bits/errno.h`, and hello links from a bare driver line, carries the
brand from musl's `crt1.o`, and now clears the loader rules — the `0x200000`
stack-page overlap that stood here until patch 0006 is gone, because the driver
pins the base at `0x0010_0000`. `llvm-readelf --program-headers` confirms it
directly: four `PT_LOAD`s from `0x100000`, each 4 KiB aligned, the last ending
at `0x108738` — a clear megabyte below the stack page. `build-sysroot.sh`
refuses to install a hello that fails `check-image.sh` rather than papering
over it, which is why the install line is itself the gate.

`verify/check-driver.sh` now runs its crt/sysroot assertions for real — they
were `SKIP` until the sysroot existed — and passes all three.

**M3a is closed.** With P3c (minixrs PR #50, 2026-07-30) the consumption side
landed too: minixrs's `kernel/build.rs` builds its boot-embedded `hello` with
`$MINIXRS_SDK/bin/clang --target=aarch64-unknown-minixrs` and boots it — entry
`0x101000`, four page-aligned `PT_LOAD`s, brand note at `0x100200`, last mapped
byte `0x108ce0`, all five C boot markers, 72/72 on minixrs's marker check. Its
copy of the hello measures 46,664 B against the stand-in triple's 200,152 B.

Two things this gate does **not** cover, both carried forward:

- **The SDK flavor has zero CI coverage anywhere.** No minixrs job installs an
  SDK, so `qemu-smoke` exercises the in-tree musl sysroot and `clippy-kernel`
  the `worker` fallback. The SDK path is proven only by local runs. An
  SDK-cached CI job is future work.
- **Nothing enforces that the SDK's musl and minixrs's `external/musl` agree.**
  They do today — the stamp's `musl=6010533f` is the merge commit of the
  submodule's `f1db256f` and `git diff` between them is empty — but an equality
  check is impossible, since the SHAs legitimately differ. Rebase the fork
  without re-running `build-sysroot.sh` and the two flavors silently test
  different libc code. Likewise `minixrs=` is a **snapshot** of the installed
  `minixrs/*.h`: any `kernel-shared` ABI change needs a `build-sysroot.sh`
  re-run, which is tolerable only under the slice-5.6 ABI freeze.

## Cross-repo hand-offs

Planned here, implemented in sessions inside those repos (cross-repo rule).

### 1. `llvm-minixrs` — patch 0006, the image base ✓ shipped (PR #4, merged 2026-07-30)

Full spec: **[llvm-m2.md](llvm-m2.md) Step 7** — the file a llvm-minixrs
session already opens, which carries the branch preconditions, the maintenance
contract, and Step 5's FileCheck lessons. Deliberately not restated here: one
spec, one place.

In outline — push `--image-base=0x100000` in `minixrs::Linker::ConstructJob`
beside the existing `-z` flags, **unconditionally**. A user `--image-base`
already outranks it without any detection code, because lld takes the last
spelling (`getLastArg`) and both `-Wl,` and `-T` arguments render after the
driver's own flags. Cover it with a positive check in the main run plus a
second run asserting that ordering.

Then back here: rebuild (`scripts/build-llvm.sh`), re-export
(`scripts/export-patches.sh llvm`) → **6** patches, update every "5 files"
reference (CLAUDE.md, roadmap, README), and add the image base to
`docs/sysroot-layout.md`'s contract points. That file is the normative
statement of what the driver must emit, and its link-flag bullet (line 52)
lists only the `-z` pair — leaving 0006 out would understate the contract
`check-driver.sh` gates.

**Done when** `scripts/build-sysroot.sh` installs the hello, i.e.
`check-image.sh` is green on a bare driver link.

### 2. `minixrs` — consume the SDK ✓ shipped (minixrs PR #50, merged 2026-07-30)

`kernel/build.rs`'s `build_hello` drops the
`--target=aarch64-unknown-linux-musl` compile, the `hello.ld` script, the
`find_compiler_builtins` glob, and the hand-built `rust-lld` line, becoming one
`$MINIXRS_SDK/bin/clang --target=aarch64-unknown-minixrs` call, keyed on
`$MINIXRS_SDK/sysroot/.stamp` with the existing `worker`-as-`hello` fallback
intact.

`tools/build-musl.sh` **stays** until M3 is stable — as of slice 5.6 it is the
blocking `qemu-smoke` job's real dependency, not a fallback.

**As landed**, two refinements on the sketch above. The SDK call did not
*replace* the stand-in path but was added beside it: selection is three-way
(`Sdk` → `Musl` → `Worker`), because "`build-musl.sh` stays" and "`build_hello`
becomes one clang call" cannot both hold in one function. And a *usable* SDK
that fails to build panics rather than falling through to `Musl` — the boot
markers are byte-identical across the two flavors, so demoting would report a
regressed toolchain as a healthy build. minixrs mutation-tested that: forcing
`--image-base=0x200000` in the SDK call cost the `name=hello entry=` trace and
all five C markers, which is also why no build-time loader gate was added there
— an image-base regression is already loud at exec time. `check-image.sh`
remains the by-hand loader check.

The `docs/plan.md` reconcile ask was satisfied differently than written: slice
5.6 had already been flipped by the time P3c ran, and the stale `◀ ready` marker
was **5.7**'s (PR #48, merged 2026-07-27). minixrs PR #50 flipped that one; its
own P3c entry correctly stays `◀ ready` until a later minixrs commit flips it,
per the marker convention.

## M3 gate ✓ M3a passed 2026-07-30

After both hand-offs: `check-image.sh` green on the SDK hello, then QEMU on
minixrs prints the slice-5.6 hello markers from a binary built by the patched
clang on the real triple. M3a = boot-embedded; M3b = via slice 5.9
exec-from-FS, out of scope here.

**Both conditions met.** `check-image.sh` reports `LOADABLE` on the SDK hello,
and minixrs boots one built by `$MINIXRS_SDK/bin/clang` on the real triple with
all five C markers and a full 72/72 marker check. M3b remains open and arrives
with minixrs slice 5.9.

## Out of scope

Relocating minixrs' initial stack (see the roadmap risk register); anything
under P4 (libc-minixrs, rust-minixrs); M3b.
