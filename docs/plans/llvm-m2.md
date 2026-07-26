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

## Step 1 — the triple

`llvm/include/llvm/TargetParser/Triple.h`, in `enum OSType`:

**Append `MinixRS` after `Firmware` and move `LastOSType` onto it.** Do not
insert it alphabetically — the enum values are ordinals, and renumbering the
existing OSes is a gratuitous ABI change for a fork that has to rebase.

```cpp
    Firmware,
    MinixRS,    // minixrs — see tooling/docs/roadmap.md
    LastOSType = MinixRS
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

Expect the build to point at a few exhaustive `switch (OS)` statements that
now need a `MinixRS` case; add them as the compiler finds them rather than
hunting up front.

## Step 2 — triple tests

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

## Step 3 — preprocessor target

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

Checkpoint — this alone satisfies `check-driver.sh` step 1:

```sh
ninja clang && ./bin/clang --target=aarch64-unknown-minixrs -dM -E -x c /dev/null \
    | grep -E '__minixrs__|__unix__|__ELF__'
```

## Step 4 — driver toolchain

New `clang/lib/Driver/ToolChains/MinixRS.{h,cpp}`, Fuchsia/NetBSD-shaped.
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
| `ld.lld` is the linker | `GetDefaultLinker()` returns `"lld"` |
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
relative to the driver binary:

```cpp
  SmallString<128> P(getDriver().Dir);   // $MINIXRS_SDK/bin
  llvm::sys::path::append(P, "..", "sysroot");
```

Since clang installs to `$MINIXRS_SDK/bin` and the sysroot is
`$MINIXRS_SDK/sysroot`, this satisfies the layout contract's "nothing may
hard-code this path" rule without a configure-time `DEFAULT_SYSROOT` — the
SDK stays relocatable.

## Step 5 — driver test

`clang/test/Driver/minixrs.c`, FileCheck'ing the `-###` line for the linker
name, `-static`, both `-z` pairs, and the crt/`-L` paths, plus
preprocessor-define coverage. Crib the structure from
`clang/test/Driver/fuchsia.c`.

Tests that assert sysroot-relative paths need a fixture sysroot under
`clang/test/Driver/Inputs/` and an explicit `--sysroot=` — do not let the
test depend on a real `$MINIXRS_SDK`.

## Step 6 — wrap-up

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
