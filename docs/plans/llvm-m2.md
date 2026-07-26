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

**Status: Steps 1–4 ready on `minixrs/release/22.x`; Step 5 is next.** The
triple, its unit tests, the preprocessor target and the driver toolchain are
committed (`2963205c993d`, `9018ff2ecf44`, `8f6f13694e9e`, `0a0281f3c447`),
so **`check-driver.sh` is green end to end** — it still SKIPs its crt/sysroot
assertions, which need the P3 sysroot. What is left is the lit test that
pins the link line (Step 5) and the wrap-up (Step 6);
`tooling/patches/llvm/` stays empty until Step 6 exports the series. Markers
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

## Step 5 — driver test ◀ next

`clang/test/Driver/minixrs.c`, FileCheck'ing the `-###` line for the linker
name, `-static`, both `-z` pairs, and the crt/`-L` paths, plus
preprocessor-define coverage. Crib the structure from
`clang/test/Driver/fuchsia.c`.

Tests that assert sysroot-relative paths need a fixture sysroot under
`clang/test/Driver/Inputs/` and an explicit `--sysroot=` — do not let the
test depend on a real `$MINIXRS_SDK`.

## Step 6 — wrap-up — unstarted

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
