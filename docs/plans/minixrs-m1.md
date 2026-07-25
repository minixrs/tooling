# minixrs M1 — `aarch64-unknown-minixrs` + ELF branding

Companion implementation plan produced by the tooling repo (P0). **Execute in
a session inside `~/src/minixrs`.** Normative references:
`tooling/docs/abi-note.md` (the note spec) and `tooling/docs/roadmap.md`
(where M1 sits).

## Goal

The 9 user binaries — `servers/{pm,vfs,ds,sched,rs,vm}`, `drivers/tty`,
`userland/{init,worker}` — build on a custom target
`aarch64-unknown-minixrs` via `-Zbuild-std`, each carries the identity note,
and the kernel refuses to load an ELF without it. The **kernel stays on
`aarch64-unknown-none`** — it is truthfully bare-metal.

**Gate**: QEMU boot green (`tools/check-boot-log.sh`) with all 9 branded;
kernel rejects unbranded; pack-time assertion active; CI green.

## Preconditions

- Land after phase-5 slice 5.3 (in progress at planning time).
- Toolchain pin unchanged: `nightly-2026-07-23` with `rust-src` +
  `llvm-tools` (both required — build-std needs rust-src).
- No forks needed. `llvm-target` stays `aarch64-unknown-none` until the fork
  rustc exists (P4).

## Step 1 — target JSON

New file `tools/targets/aarch64-unknown-minixrs.json`. This is the pinned
nightly's `aarch64-unknown-none` spec (from
`rustc -Zunstable-options --print target-spec-json --target
aarch64-unknown-none`, `metadata` block dropped) plus **one** semantic
addition, `"os": "minixrs"`:

```json
{
  "arch": "aarch64",
  "crt-objects-fallback": "false",
  "data-layout": "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32",
  "default-uwtable": true,
  "disable-redzone": true,
  "features": "+v8a,+strict-align,+neon",
  "linker": "rust-lld",
  "linker-flavor": "gnu-lld",
  "llvm-target": "aarch64-unknown-none",
  "max-atomic-width": 128,
  "os": "minixrs",
  "panic-strategy": "abort",
  "pre-link-args": {
    "gnu": [
      "--fix-cortex-a53-843419"
    ],
    "gnu-lld": [
      "--fix-cortex-a53-843419"
    ]
  },
  "relocation-model": "static",
  "stack-probes": {
    "kind": "inline"
  },
  "supported-sanitizers": [
    "kcfi",
    "kernel-address",
    "kernel-hwaddress"
  ],
  "supports-xray": true,
  "target-pointer-width": 64
}
```

On future nightly bumps: regenerate the base spec the same way and re-apply
the `"os"` line (risk register: spec-format churn).

## Step 2 — the `minixrs-abi-note` crate

New root-level workspace member `minixrs-abi-note/` (flat, next to
`server-rt`): `#![no_std]`, zero deps, one exported macro. Body exactly as in
`tooling/docs/abi-note.md`:

```rust
#![no_std]

/// Emit the minixrs ELF identity note (tooling/docs/abi-note.md) into the
/// current binary. Invoke once at the crate root of every user-space binary
/// crate — a library's asm object can be dropped by archive-member
/// selection, so the note must live in the binary crate itself.
#[macro_export]
macro_rules! brand {
    () => {
        #[cfg(target_os = "minixrs")]
        ::core::arch::global_asm!(
            r#"
            .pushsection .note.minixrs.ident, "a", %note
            .p2align 2
            .long 8
            .long 8
            .long 1
            .asciz "minixrs"
            .long 1
            .long 0
            .popsection
            "#
        );
    };
}
```

## Step 3 — `user.ld` × 9

Same edit in all nine copies (they are line-identical today). Two hunks:

```diff
 PHDRS {
     text   PT_LOAD FLAGS(5); /* R+X */
     rodata PT_LOAD FLAGS(4); /* R   */
     data   PT_LOAD FLAGS(6); /* RW  */
+    note   PT_NOTE FLAGS(4); /* minixrs identity note */
 }
```

```diff
     . = ALIGN(4K);
-    .rodata : ALIGN(4K) {
+    /*
+     * minixrs identity note (tooling/docs/abi-note.md): first thing in the
+     * RO segment, dual-assigned so it lands in the rodata PT_LOAD *and* its
+     * own PT_NOTE phdr. KEEP() is mandatory — nothing references the
+     * section — and this rule must stay ahead of the /DISCARD/ *(.note.*)
+     * rule below (first match wins).
+     */
+    .note.minixrs.ident : {
+        KEEP(*(.note.minixrs.ident))
+    } :rodata :note
+
+    .rodata : {
         *(.rodata .rodata.*)
     } :rodata
```

The rodata PT_LOAD now *starts* with the 28-byte note (still page-aligned
vaddr + file offset — the `. = ALIGN(4K);` line is untouched), and `.rodata`
follows immediately inside the same segment. The `/DISCARD/` rule keeps its
`*(.note .note.*)` line — it now only eats foreign notes. Verify with
`llvm-readelf -lW`: exactly 3 PT_LOAD (all page-aligned) + 1 PT_NOTE.

## Step 4 — per-crate `build.rs` × 9

Each of the 9 binary crates gets:

```rust
fn main() {
    println!("cargo:rerun-if-changed=user.ld");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("minixrs") {
        let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
        println!("cargo:rustc-link-arg=-T{dir}/user.ld");
    }
}
```

The cfg gate keeps host builds (clippy, check) linker-flag-free.

## Step 5 — `kernel/build.rs` nested builds

Today (`kernel/build.rs` ~lines 174–220): each server builds with
`CARGO_ENCODED_RUSTFLAGS=-Clink-arg=-T<user.ld>` (the cancel-hack — it
replaces config rustflags entirely) and an isolated per-crate
`CARGO_TARGET_DIR` (`{crate_name}-target`). Change to:

- **Drop** `CARGO_ENCODED_RUSTFLAGS` entirely — step 4's build.rs now owns
  the link arg.
- `--target` points at the JSON:
  `<workspace>/tools/targets/aarch64-unknown-minixrs.json` (absolute path).
- Add `-Zbuild-std=core,alloc -Zbuild-std-features=compiler-builtins-mem`.
  The `mem` feature provides memcpy/memset — **verify it is still required
  on the pinned nightly** (recent nightlies flirt with enabling it by
  default; passing it explicitly is harmless either way).
- **One shared** nested target dir instead of 9:
  e.g. `CARGO_TARGET_DIR=<workspace>/target/minixrs-user`. Without this,
  build-std compiles core+alloc 9× per kernel build. The nested invocations
  run sequentially from build.rs, and cargo's own locking covers any overlap.

## Step 6 — cfg migration + check-cfg

- Flip `target_os` cfgs in the 9 `main.rs` from `"none"` to `"minixrs"` —
  currently the pattern is
  `#[cfg_attr(target_os = "none", unsafe(link_section = ".text._start"))]`
  (e.g. `servers/pm/src/main.rs:107`).
- `grep -rn 'target_os' server-rt/ minix-ipc/ drivers/driver-rt/` and flip
  any user-side occurrences the same way (kernel-side `"none"` cfgs stay).
- Workspace `check-cfg` so host clippy (`-D warnings`) doesn't trip
  `unexpected_cfgs` — builtin host targets don't know `"minixrs"`:

  ```toml
  [workspace.lints.rust]
  unexpected_cfgs = { level = "warn", check-cfg = ['cfg(target_os, values("minixrs"))'] }
  ```

  plus `[lints] workspace = true` in members that don't already inherit.
  (Delete this shim at M5 when the real rustc target exists.)

## Step 7 — brand the 9 binaries

One line near the top of each `main.rs` (after the crate attrs):

```rust
minixrs_abi_note::brand!();
```

plus the `minixrs-abi-note` path dependency in each of the 9 `Cargo.toml`s.

## Step 8 — kernel-shared scan + kernel enforcement

New `kernel-shared/src/brand.rs` (pure, no_std, no deps — callable from the
kernel, from `kernel/build.rs` host-side, and later from mkfs):

```rust
//! Shared minixrs ELF brand scan. Spec: tooling/docs/abi-note.md.

pub const NT_MINIXRS_IDENT: u32 = 1;
pub const BRAND_OWNER: &[u8] = b"minixrs\0";
pub const BRAND_ABI_VERSION: u32 = 1;

const PT_NOTE: u32 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrandInfo {
    pub abi_version: u32,
    pub flags: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrandError {
    /// No PT_NOTE segment carries an owner="minixrs\0", type=1 note.
    MissingBrand,
    /// Brand present but built for an ABI this kernel does not speak.
    UnsupportedAbi(u32),
    /// Not a little-endian ELF64, or truncated/overflowing offsets.
    Malformed,
}

fn u16le(b: &[u8], off: usize) -> Option<u16> {
    Some(u16::from_le_bytes(b.get(off..off + 2)?.try_into().ok()?))
}
fn u32le(b: &[u8], off: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(off..off + 4)?.try_into().ok()?))
}
fn u64le(b: &[u8], off: usize) -> Option<u64> {
    Some(u64::from_le_bytes(b.get(off..off + 8)?.try_into().ok()?))
}

pub fn scan_brand(elf: &[u8]) -> Result<BrandInfo, BrandError> {
    use BrandError::Malformed;
    if elf.get(..4) != Some(b"\x7fELF".as_slice())
        || elf.get(4) != Some(&2)  // ELFCLASS64
        || elf.get(5) != Some(&1)  // ELFDATA2LSB
    {
        return Err(Malformed);
    }
    let phoff = u64le(elf, 0x20).ok_or(Malformed)? as usize;
    let phentsize = u16le(elf, 0x36).ok_or(Malformed)? as usize;
    let phnum = u16le(elf, 0x38).ok_or(Malformed)? as usize;

    for i in 0..phnum {
        let ph = i
            .checked_mul(phentsize)
            .and_then(|o| o.checked_add(phoff))
            .ok_or(Malformed)?;
        if u32le(elf, ph).ok_or(Malformed)? != PT_NOTE {
            continue;
        }
        let off = u64le(elf, ph + 8).ok_or(Malformed)? as usize;
        let filesz = u64le(elf, ph + 32).ok_or(Malformed)? as usize;
        let end = off.checked_add(filesz).ok_or(Malformed)?;
        let seg = elf.get(off..end).ok_or(Malformed)?;

        let mut pos = 0usize;
        while pos + 12 <= seg.len() {
            let namesz = u32le(seg, pos).ok_or(Malformed)? as usize;
            let descsz = u32le(seg, pos + 4).ok_or(Malformed)? as usize;
            let ntype = u32le(seg, pos + 8).ok_or(Malformed)?;
            let name_off = pos + 12;
            let desc_off = name_off
                .checked_add(namesz.next_multiple_of(4))
                .ok_or(Malformed)?;
            let next = desc_off
                .checked_add(descsz.next_multiple_of(4))
                .ok_or(Malformed)?;
            if next > seg.len() {
                break; // truncated tail; other PT_NOTE segments may still match
            }
            if &seg[name_off..name_off + namesz] == BRAND_OWNER
                && ntype == NT_MINIXRS_IDENT
                && descsz >= 8
            {
                let abi = u32le(seg, desc_off).ok_or(Malformed)?;
                let flags = u32le(seg, desc_off + 4).ok_or(Malformed)?;
                if abi != BRAND_ABI_VERSION {
                    return Err(BrandError::UnsupportedAbi(abi));
                }
                return Ok(BrandInfo { abi_version: abi, flags });
            }
            pos = next;
        }
    }
    Err(BrandError::MissingBrand)
}
```

Host unit tests in the same module (`#[cfg(test)]`): the canonical 28 bytes
wrapped in a minimal synthetic ELF; a foreign-owner note; descsz=12 (longer,
must pass); abi_version=2 (must be `UnsupportedAbi`); no PT_NOTE (missing).

Kernel wiring:

- `ElfError` gains `MissingBrand` and `UnsupportedAbi` variants
  (`kernel/src/boot_image/elf.rs`).
- Call from `load_exec_image()` (`kernel/src/arch/aarch64/userland.rs`) —
  the single load choke point, so this covers boot, exec, and future
  exec-from-FS.
- **Staged, two commits in the same PR**: commit 1 logs a warning on scan
  failure and continues (boot everything, read the log); commit 2 turns the
  warning into a hard reject. Never land commit 1 alone.

## Step 9 — pack-time assertion

`kernel/Cargo.toml` gains kernel-shared as a **build**-dependency, and after
each nested server build in `kernel/build.rs`:

```rust
let bytes = std::fs::read(&elf_path).unwrap();
if let Err(e) = kernel_shared::brand::scan_brand(&bytes) {
    panic!("{}: missing/bad minixrs brand: {e:?}", elf_path.display());
}
```

(Use the actual kernel-shared package/crate name.) This fails the build on
any unbranded server ELF. Note: exec-from-FS (slice 5.9) bypasses this — the
runtime check in step 8 is the authoritative gate, and mkfs should reuse the
same scan when it exists.

## Step 10 — CI

- Cache the shared nested target dir (`target/minixrs-user`).
- Clippy must stay green with `-D warnings` — that's what step 6's
  check-cfg is for.
- QEMU boot verified via `tools/check-boot-log.sh` (M1 gate).
- Reject-path coverage: the step-8 unit tests cover the scan; for the kernel
  path, a QEMU test that packs one intentionally unbranded binary (build one
  server with the brand line commented via a test-only feature, or keep a
  prebuilt unbranded fixture) and asserts the kernel's reject log line.
- From the tooling repo: `tooling/verify/check-brand.sh` on all 9 packed
  ELFs must exit 0.

## Step 11 — doc fix

`docs/plans/phase-5-musl-fs.md` calls the musl sibling repo `musl-minix`
(lines 47 and 241 at planning time). Rename both references to
`musl-minixrs` for naming consistency across all forks.

## Verification checklist (the M1 gate, expanded)

1. `cargo build` (workspace) green; 9 nested builds go through the JSON
   target with build-std, one shared nested target dir.
2. `llvm-readelf -lW` on each packed ELF: 3 page-aligned PT_LOAD + 1
   PT_NOTE.
3. `tooling/verify/check-brand.sh <all 9 ELFs>` → exit 0, abi_version=1.
4. QEMU boot: `tools/check-boot-log.sh` clean.
5. Unbranded binary → kernel reject line (and pack assertion panics if it
   sneaks into the boot image).
6. Host `cargo clippy` / `cargo test` green (check-cfg in place).
