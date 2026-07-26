# llvm-minixrs M2 — teach clang/lld `aarch64-unknown-minixrs`

Companion implementation plan produced by the tooling repo (P2). **Execute in
a session inside `$MINIXRS_FORKS_DIR/llvm-minixrs`** (default
`~/src/minixrs-forks/llvm-minixrs`). Normative references:
`tooling/docs/sysroot-layout.md` (what the driver must emit),
`tooling/docs/abi-note.md` (the brand), `tooling/docs/roadmap.md` (where M2
sits).

## Goal

`clang --target=aarch64-unknown-minixrs` is a real target: the preprocessor
defines `__minixrs__`, the driver selects a MinixRS toolchain that links
statically with `ld.lld` against `$MINIXRS_SDK/sysroot`, and the result
carries the identity note.

**Gate**: `ninja check-clang-driver` and the TargetParser unit tests green;
`tooling/verify/check-driver.sh` green.

**Status: all six steps ready on `minixrs/release/22.x`; the branch is
unpushed.** The triple, its unit tests, the preprocessor target, the driver
toolchain and its lit test are committed (`2963205c993d`, `9018ff2ecf44`,
`8f6f13694e9e`, `0a0281f3c447`, `3cc1fda07298`), **`check-driver.sh` is green
end to end** — it still SKIPs its crt/sysroot assertions, which need the P3
sysroot — `check-clang-driver` is clean at 1403 tests, and the five-patch
series is exported to `tooling/patches/llvm/`. What is left is review and
`git push origin minixrs/release/22.x`. Markers
follow `tooling/docs/roadmap.md`:
`◀ next` (unstarted), `◀ ready (branch …, pending merge)`, `✓ shipped (PR #N,
merged YYYY-MM-DD)`. Flip each step's marker as it lands, and flip **P2b** in
the roadmap's phase graph when the whole series ships — it stays `◀ next`
while the series is only partly implemented, since the three-marker
convention has no in-progress state and these per-step markers carry that
granularity.

## Preconditions

- Branch `minixrs/release/22.x`, based on tag **`llvmorg-22.1.8`**
  (`ca7933e47d3a3451d81e72ac174dcb5aa28b59d1`) — the exact LLVM the pinned
  `nightly-2026-07-23` reports, so the same series later serves rustc (P4).
- The checkout is on the case-sensitive volume
  (`tooling/scripts/forks-volume.sh status`).
- A baseline `build-llvm.sh --baseline` has already succeeded, so any build
  failure from here is unambiguously a patch failure.

One commit per area below, so `export-patches.sh llvm` yields a clean 4–5
patch series.

---

## Step 1 — the triple ◀ ready (branch minixrs/release/22.x, pending merge)

`llvm/include/llvm/TargetParser/Triple.h`, in `enum OSType`:

**Append `MinixRS` after `CheriotRTOS` and move `LastOSType` onto it.** Do not
insert it alphabetically — the enum values are ordinals, and renumbering the
existing OSes is a gratuitous ABI change for a fork that has to rebase.

```cpp
    CheriotRTOS,
    MinixRS,    // minixrs — see tooling/docs/roadmap.md
    LastOSType = MinixRS
```

**On the anchor.** An earlier draft named `Firmware` as the enum tail.
**There is no `Firmware` OSType at this pin**; the tail is `… Vulkan,
CheriotRTOS, LastOSType = CheriotRTOS`. The intent is unchanged — append at
the end — but confirm the anchor before editing, the same way the ordering
hazard below is confirmed:

```sh
grep -n "LastOSType" llvm/include/llvm/TargetParser/Triple.h
```

Add the predicate next to the other `isOS*` helpers:

```cpp
  bool isOSMinixRS() const { return getOS() == Triple::MinixRS; }
```

`llvm/lib/TargetParser/Triple.cpp` — `getOSTypeName`:

```cpp
  case MinixRS: return "minixrs";
```

and `parseOS`, whose `StringSwitch` matches with `StartsWith`:

```cpp
      .StartsWith("minixrs", Triple::MinixRS)
```

**On the ordering hazard.** An earlier draft of this plan warned that
`Triple::Minix` already exists and that, because `parseOS` uses
`StartsWith`, `"minixrs"` would be swallowed by the `"minix"` arm unless
ordered before it. **That is no longer true at this pin.** Minix was deleted
upstream in `24eaf7858b46` ("Cleanup remaining bits for Minix, Contiki and
Myriad", Aug 2023), which is an ancestor of `llvmorg-22.1.8`; there is no
`Minix` enum value and no `"minix"` parse arm to collide with. Verify before
relying on it:

```sh
grep -in minix llvm/include/llvm/TargetParser/Triple.h llvm/lib/TargetParser/Triple.cpp
```

Expect no hits. The hazard is still worth recording in the *forward*
direction: `StartsWith` means that if a future rebase reintroduces a `minix`
arm, it must be ordered **after** `minixrs`, or the longer name gets
shadowed. Nothing currently in the switch is a prefix of `minixrs`.

This was expected to point at a few exhaustive `switch (OS)` statements
needing a `MinixRS` case. **It pointed at none** — a full `ninja clang
TargetParserTests` came back with zero warnings and zero errors, matching an
up-front `grep -rn "Triple::CheriotRTOS" llvm clang lld`, which finds no site
outside `Triple.{h,cpp}`. `Triple.h` is still a hub header, so budget for the
broad rebuild it triggers (~1830 edges here) even though no follow-on edit
was needed.

## Step 2 — triple tests ◀ ready (branch minixrs/release/22.x, pending merge)

`llvm/unittests/TargetParser/TripleTest.cpp`:

```cpp
  T = Triple("aarch64-unknown-minixrs");
  EXPECT_EQ(Triple::aarch64, T.getArch());
  EXPECT_EQ(Triple::UnknownVendor, T.getVendor());
  EXPECT_EQ(Triple::MinixRS, T.getOS());
  EXPECT_EQ(Triple::UnknownEnvironment, T.getEnvironment());
```

Plus a round-trip assert that `Triple::getOSTypeName(Triple::MinixRS)` is
`"minixrs"` and that the normalized triple string survives. The original plan
also called for a regression assert that plain `minix` still parses as
`Triple::Minix` — **drop it**, that enumerator does not exist at this pin and
the test would not compile.

```sh
ninja TargetParserTests && ./unittests/TargetParser/TargetParserTests \
    --gtest_filter='TripleTest.*'
```

## Step 3 — preprocessor target ◀ ready (branch minixrs/release/22.x, pending merge)

`clang/lib/Basic/Targets/OSTargets.h`, modeled on `FuchsiaTargetInfo` (same
file), which is the closest shape: a small static-first ELF OS with no
GNU-libc baggage.

```cpp
// minixrs target
template <typename Target>
class LLVM_LIBRARY_VISIBILITY MinixRSTargetInfo : public OSTargetInfo<Target> {
protected:
  void getOSDefines(const LangOptions &Opts, const llvm::Triple &Triple,
                    MacroBuilder &Builder) const override {
    Builder.defineMacro("__minixrs__");
    Builder.defineMacro("__minixrs");
    Builder.defineMacro("__unix__");
    Builder.defineMacro("__unix");
    Builder.defineMacro("__ELF__");
  }

public:
  MinixRSTargetInfo(const llvm::Triple &Triple, const TargetOptions &Opts)
      : OSTargetInfo<Target>(Triple, Opts) {
    this->WIntType = TargetInfo::UnsignedInt;
  }
};
```

`clang/lib/Basic/Targets.cpp`, in the `case llvm::Triple::aarch64:` inner
`switch (os)` (alongside `Fuchsia`, `Haiku`, `Managarm`, …):

```cpp
    case llvm::Triple::MinixRS:
      return std::make_unique<MinixRSTargetInfo<AArch64leTargetInfo>>(Triple,
                                                                      Opts);
```

The AArch64**be** switch (same file) is deliberately left alone — minixrs is
little-endian only.

Checkpoint — this alone satisfies `check-driver.sh` step 1:

```sh
ninja clang && ./bin/clang --target=aarch64-unknown-minixrs -dM -E -x c /dev/null \
    | grep -E '__minixrs__|__unix__|__ELF__'
```

**Reached.** All five defines emit, and the gate — run against the build-dir
clang, which `check-driver.sh` honors via `CLANG=` so no SDK reinstall is
needed — reports `PASS __minixrs__, __unix__, __ELF__ defined` at step 1/3
while steps 2/3 still fail (`-###` drives `/usr/bin/gcc`, no `-static`, no
`-z` flags). Overall exit 1 is the correct state at this checkpoint; Step 4
closes the rest.

```sh
CLANG=$MINIXRS_FORKS_DIR/llvm-minixrs/build-minixrs/bin/clang \
    verify/check-driver.sh
```

## Step 4 — driver toolchain ◀ ready (branch minixrs/release/22.x, pending merge)

New `clang/lib/Driver/ToolChains/MinixRS.{h,cpp}`, Fuchsia-shaped: derived
from `ToolChain` directly rather than from `Generic_ELF`, so none of the
GCC-detection machinery applies to a platform that will never have a GCC.
Register it in:

- `clang/lib/Driver/CMakeLists.txt` — add `ToolChains/MinixRS.cpp` to the
  source list (kept roughly alphabetical; it lands near `MinGW.cpp` /
  `MSP430.cpp`).
- `clang/lib/Driver/Driver.cpp`, `getToolChain()`'s `switch (Target.getOS())`,
  next to the `Fuchsia` case:

```cpp
    case llvm::Triple::MinixRS:
      TC = std::make_unique<toolchains::MinixRS>(*this, Target, Args);
      break;
```

Behavior is fixed by `docs/sysroot-layout.md`, not invented here:

| Requirement | Implementation |
|---|---|
| `ld.lld` is the linker | `getDefaultLinker()` returns `"ld.lld"` |
| static only — no `.so`, no dynamic linker | always push `-static`; no `-shared`/`-pie` paths |
| crt objects from `<sysroot>/usr/lib` | `crt1.o crti.o` … `crtn.o` via `GetFilePath` |
| `-L<sysroot>/usr/lib` | `AddFilePathLibArgs` / explicit `-L` |
| `<sysroot>/usr/include` on the include path | `AddClangSystemIncludeArgs` |
| compiler-rt builtins, per-target | `GetRuntimeLibType` → `RLT_CompilerRT`, per-target runtime dir |
| minixrs D13 page constraints | `-z max-page-size=4096 -z separate-loadable-segments` |
| no sanitizers | `getSupportedSanitizers()` returns `{}` |

Both `-z` values are real lld options (`lld/ELF/Driver.cpp` parses
`separate-loadable-segments`); push them as separate `"-z"` / value argument
pairs the way `Fuchsia.cpp` does.

**Sysroot resolution.** `--sysroot` wins if given; otherwise compute it
relative to the driver binary. `ToolChain::computeSysRoot()` is already a
virtual with exactly these semantics ("return the sysroot, possibly searching
for a default using target-specific logic"), so this is an `override`, not a
new helper:

```cpp
  SmallString<128> P(getDriver().Dir);   // $MINIXRS_SDK/bin
  llvm::sys::path::append(P, "..", "sysroot");
  llvm::sys::path::remove_dots(P, /*remove_dot_dot=*/true);
```

Since clang installs to `$MINIXRS_SDK/bin` and the sysroot is
`$MINIXRS_SDK/sysroot`, this satisfies the layout contract's "nothing may
hard-code this path" rule without a configure-time `DEFAULT_SYSROOT` — the
SDK stays relocatable. The `remove_dots` call matters for the *gate*, not
just for tidiness: `check-driver.sh` greps the link line for
`$MINIXRS_SDK/sysroot/usr/lib/crt1.o` literally, which a
`…/bin/../sysroot/…` spelling would not match once P3 installs the sysroot
and those assertions stop being SKIPped.

**On `-static` versus `-Bstatic`.** `Fuchsia.cpp` pushes `-Bstatic`; this
driver pushes `-static`, which lld defines as an alias for it
(`lld/ELF/Options.td`). The distinction is not cosmetic — `check-driver.sh`
step 2 greps for `-static`, and `-Bstatic` does not contain that substring.

**On flags the platform cannot honour.** A static-only target gets asked for
dynamic things by build systems that do not know better, and the driver has
to answer each one deliberately — silently dropping them is how a user ends
up holding an artifact that is not what they asked for. The line is *output
kind* versus *executable property*:

| Flag | Answer | Why |
|---|---|---|
| `-shared` | hard error, `err_drv_unsupported_opt_for_target` | a different output kind; ignoring it yields a static executable named `libfoo.so` |
| `-pie`, `-no-pie` | claimed, ignored | properties minixrs pins; the artifact is right either way |
| `-rdynamic` | claimed, ignored | no dynamic symbol table to export |

Leaving `-shared` merely *unclaimed* is not enough: that is only a
`-Wunused-command-line-argument` warning, which plenty of builds silence, and
the wrong `.so` still gets written.

**Known gap.** `GetCXXStdlibType` pins libc++, but there is no
`AddClangCXXStdlibIncludeArgs` override — nothing would be on the other end
of it until a C++ standard library exists in the sysroot. Crib Fuchsia's when
one does.

**Verified link line** (build-dir clang, no sysroot installed, so the crt
names stay unresolved):

```
ld.lld -static -z max-page-size=4096 -z separate-loadable-segments
       --eh-frame-hdr -o … crt1.o crti.o -L<sysroot>/usr/lib …
       libclang_rt.builtins.a -lc crtn.o
```

**Reached.** `check-driver.sh` passes all three steps against the build-dir
clang, including linking `verify/testdata/branded.s` and brand-checking the
result. Its crt/sysroot assertions still SKIP — the sysroot arrives in P3.

## Step 5 — driver test ◀ ready (branch minixrs/release/22.x, pending merge)

`clang/test/Driver/minixrs.c`, FileCheck'ing the `-###` line for the linker
name, `-static`, both `-z` pairs, and the crt/`-L` paths, plus
preprocessor-define coverage. Crib the structure from
`clang/test/Driver/fuchsia.c`.

Tests that assert sysroot-relative paths need a fixture sysroot under
`clang/test/Driver/Inputs/` and an explicit `--sysroot=` — do not let the
test depend on a real `$MINIXRS_SDK`.

**Fixture.** `Inputs/minixrs_tree/` holds both halves — `sysroot/usr/{lib,
include}` with zero-byte `crt1.o`/`crti.o`/`crtn.o`/`libc.a`, and a
`resource_dir/` carrying `lib/aarch64-unknown-minixrs/libclang_rt.builtins.a`.
A new self-contained tree, rather than new entries in the shared
`Inputs/resource_dir_with_per_target_subdir`, keeps the series all-new-files
and cheap to rebase.

Beyond the plan's list, the test also pins the driver-relative default
sysroot and the answers to flags the platform cannot honour (`-shared` errors;
`-pie`/`-no-pie`/`-rdynamic` are dropped silently; sanitizers are rejected) —
the behaviour Step 4 introduced deserves a regression test, not just a
paragraph.

**Deliberately not covered.** The `-nostdlib` / `-nostartfiles` /
`-nodefaultlibs` / `-nolibc` suppression paths in `ConstructJob` have no
assertions. They are ordinary upstream-shaped guards rather than minixrs
policy, and nothing in M2's gate depends on them; fold them in when something
actually consumes them (P4's libc build is the likely first caller).

**A `-NOT` never sees what a positive match ate.** FileCheck tests a `-NOT`
only in the gaps *between* the positive matches that surround it. That one
rule shapes three decisions in this test, and it is the easiest way to write
an assertion that cannot fail:

- The no-dots check gets **its own FileCheck run with no positive directive**,
  which makes its scan region the whole output. It cannot live in the
  default-sysroot run, because that run's `-L{{[^"]*}}/sysroot/usr/lib`
  pattern spells the middle of the path as a wildcard — so it *also matches*,
  and therefore consumes, the unfolded `-L…/bin/../sysroot/usr/lib` the `-NOT`
  is there to reject.
- The happy-path negatives (`-dynamic-linker`, `-shared`, `-pie`) are
  `--implicit-check-not` on the RUN line rather than inline `CHECK-NOT`s,
  which would have scanned only the few tokens between the second `-z` pair
  and `crt1.o`.
- The claimed-flag run is anchored on `ld.lld` and `-static` **before** its
  negatives. A run of bare `-NOT`s also passes on empty output, or on a driver
  that died before emitting a link line.

**Verify the test, not just the code — and pick the control carefully.**
Test-side mutation (breaking a directive and confirming the test fails) proves
a directive is *evaluated*; only source-side mutation proves it is *load
bearing*. Both were run: deleting `remove_dots` from `MinixRS.cpp` and
dropping `ClaimAllArgs(OPT_pie)` each fail the test, and every directive was
also broken in turn. Two traps, both hit for real here:

- A control that lands in a *different* scan region proves nothing. The first
  no-dots control did this, which is how the arrangement above survived a
  round of review.
- A control token that a positive check consumes proves nothing either.
  Probing the `--implicit-check-not`s with `-static` reported three false
  greens, because `CHECK-SAME: "-static"` had already eaten it; re-probing
  with `--eh-frame-hdr`, which no positive check claims, failed all three as
  required.

Under the previous arrangement the `remove_dots` mutation *was* caught, but
only incidentally: `AddClangSystemIncludeArgs` emits an unfolded
`-internal-externc-isystem` path on the cc1 line, ahead of the `-L` anchor.
Adding `-nostdlibinc` removed that witness and the check went green with the
bug present. An assertion resting on a witness it does not name is not an
assertion.

```sh
ninja check-clang-driver     # 1403 tests, 1320 passed, 82 unsupported, 1 XFAIL
```

## Step 6 — wrap-up ◀ ready (branch minixrs/release/22.x, pending merge)

From the build dir:

```sh
ninja check-clang-driver
ninja TargetParserTests && ./unittests/TargetParser/TargetParserTests
```

Then, from the tooling repo:

```sh
scripts/build-llvm.sh            # no --baseline: smoke test armed
scripts/build-compiler-rt.sh     # needs the patched clang; fails before it
verify/check-driver.sh           # the M2 gate
scripts/export-patches.sh llvm   # populates patches/llvm/
```

`check-driver.sh` will SKIP its crt/sysroot assertions until P3 installs the
sysroot — that is expected at M2, and its step 3 (link a branded static ELF
with `-nostdlib`) is the half of the gate that is satisfiable now.

Results: `check-clang-driver` 1403 tests / 0 failures; `TargetParserTests` 645
tests, 642 passed and 3 skipped (AIX host probes); `check-driver.sh` exit 0;
five patches in `patches/llvm/`.

**`build-compiler-rt.sh` had never actually been run.** It could not be —
until Step 4 there was no driver for it to use — so Step 6 was its first
execution, and it failed four times for four different reasons. None of them
is compiler-rt being hard to cross-build; all four are CMake defaulting to the
host and saying nothing:

| Symptom | Cause | Fix |
|---|---|---|
| builds `clang_rt.osx`, then "no work to do" | `CMAKE_SYSTEM_NAME` defaulted to `Darwin`, so `APPLE` was true. `CMAKE_C_COMPILER_TARGET` does **not** declare a cross build | `-DCMAKE_SYSTEM_NAME=Generic` |
| `ADD_LIBRARY called with SHARED option but the target platform does not support dynamic linking` | `load_llvm_config()` found the SDK's own LLVM — `env.sh` puts `$MINIXRS_SDK/bin` on `PATH`, and CMake derives package search prefixes from `PATH` | `-DCMAKE_DISABLE_FIND_PACKAGE_LLVM=ON`, plus entering at `compiler-rt/lib/builtins` (a standalone project) rather than `compiler-rt` |
| installs `lib/generic/libclang_rt.builtins-aarch64.a` | legacy layout; the driver only searches `lib/<triple>/` | `-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON -DLLVM_DEFAULT_TARGET_TRIPLE=<triple>` |
| a Mach-O arm64 `emupac.cpp.obj` inside the ELF archive | `CMAKE_CXX_COMPILER` was auto-detected but `CMAKE_CXX_COMPILER_TARGET` was never set, so C++ sources built for the host | set both |

The last one is the one to remember: it is **not** an error. `ld.lld` warns
`archive member 'emupac.cpp.obj' is neither ET_REL nor LLVM bitcode`, drops
the member, and links successfully — so the symbols it defined go missing at
some later link instead, far from the cause. The script now asserts every
archive member is `elf64-littleaarch64`.

**Reconfiguring in place does not work here.** CMake cannot retarget an
existing cache, and compiler-rt caches its *derived* install path as a
`CACHE PATH` — so flipping `LLVM_ENABLE_PER_TARGET_RUNTIME_DIR` on a stale
cache rebuilds and then installs to the old layout regardless. The script
checks the derived `COMPILER_RT_INSTALL_LIBRARY_DIR` (`lib` = per-target,
`lib/generic` = legacy), not just the inputs, and wipes on mismatch.

Finally `git push origin minixrs/release/22.x`.

## Maintenance contract

- The branch is **rebase-maintained and force-pushed**. It is not a
  merge-based fork; rebasing onto the next `llvmorg-22.1.x` tag is the
  routine update.
- **Review happens over the exported series in `tooling/patches/llvm/`**, not
  via PRs against the fork branch. The tooling repo is the authoritative
  record of what the fork changes.
- Re-run `scripts/export-patches.sh llvm` after **every** rebase, and commit
  the result in the tooling repo. `MINIXRS_LLVM_BASE` (default
  `llvmorg-22.1.8`) moves with the rebase target.
- Patch surface is deliberately mostly *new files* — that is what keeps
  rebases cheap across 22.x point releases (roadmap risk register).
