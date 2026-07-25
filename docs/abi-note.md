# The minixrs ELF identity note (normative)

Every minixrs user-space executable carries a NetBSD-style ELF note that
identifies it as a minixrs binary and states which minixrs ABI it was built
for. The kernel (and any other consumer — mkfs, pack-time assertions,
`verify/check-brand.sh`) verifies this note before running the binary.

`EI_OSABI` in the ELF header stays `0` (`ELFOSABI_NONE`) **permanently**. The
note is the sole identity mechanism. This is deliberate: stock binutils, gdb,
lldb, and every other ELF consumer keep working with no patches, forever.

## Note format

| Property | Value |
|---|---|
| Section name | `.note.minixrs.ident` |
| Section type | `SHT_NOTE`, flags `SHF_ALLOC` |
| Alignment | 4 bytes |
| Owner (name) | `"minixrs\0"` — `namesz = 8` |
| Type | `NT_MINIXRS_IDENT = 1` |
| Descriptor | 2 × u32 little-endian: `[abi_version, flags]` — `descsz = 8` |
| `abi_version` | currently `1` |
| `flags` | `0`, all bits reserved (must be written as 0) |

Program-header placement: the note gets a **dedicated `PT_NOTE`** program
header (`p_flags = PF_R`), and the section is also placed at the **start of
the read-only `PT_LOAD`** segment. Consumers locate the note by walking
`PT_NOTE` program headers, never by section name — sections may be stripped.

## Exact byte layout (28 bytes)

```
offset  bytes                    field
0x00    08 00 00 00              namesz = 8
0x04    08 00 00 00              descsz = 8
0x08    01 00 00 00              type   = NT_MINIXRS_IDENT (1)
0x0c    6d 69 6e 69 78 72 73 00  name   = "minixrs\0"
0x14    01 00 00 00              desc[0] = abi_version = 1
0x18    00 00 00 00              desc[1] = flags = 0
```

Both name and descriptor are already 4-byte multiples, so no padding is
emitted.

## Consumer rules

1. Walk `PT_NOTE` program headers only. Iterate the note records inside each
   segment (`namesz`/`descsz` are padded up to 4-byte multiples between
   records).
2. **Ignore** notes whose owner is not exactly `"minixrs\0"` or whose type is
   not `NT_MINIXRS_IDENT` (foreign-owner notes are normal and harmless).
3. Accept `descsz >= 8`. Read **only** the words you know
   (`abi_version`, `flags`); never reject a note for being longer than
   expected — that is how the format grows.
4. **Reject** an unknown `abi_version` (`!= 1` today) — the binary was built
   for an ABI this consumer does not speak.
5. A binary with no matching note is **not a minixrs binary**; the kernel
   refuses to execute it (`ElfError::MissingBrand` /
   `ElfError::UnsupportedAbi` in minixrs).

## Producer rules

### Rust (M1): the `minixrs-abi-note` crate

A minixrs workspace crate exports a `brand!();` macro, invoked once at the
crate root of **every binary crate** (not in a library — an unreferenced
archive member's asm object can be dropped by archive-member selection):

```rust
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

### C (P3): musl crt1.o

The same assembly block is compiled into `crt1.o` in the musl-minixrs fork,
so every C binary is branded regardless of which driver linked it. (A
FreeBSD-`crtbrand`-style separate object was rejected: it only brands binaries
linked through a cooperating driver.)

### Linker script requirements

Wherever a custom linker script is in play (the 9 minixrs `user.ld` copies):

- `PHDRS` gains `note PT_NOTE FLAGS(4);`.
- An output section rule places the note at the start of the read-only
  segment, **dual-assigned** to both phdrs:

  ```ld
  .note.minixrs.ident : {
      KEEP(*(.note.minixrs.ident))
  } :rodata :note
  ```

- `KEEP` is **mandatory** — nothing references the note, so without it
  `--gc-sections` (or plain liveness) drops it.
- The rule must appear **before** any `/DISCARD/` rule matching `*(.note.*)`
  — first match wins in ld scripts.

## Verification

`verify/check-brand.sh <elf>` implements the consumer rules byte-exactly with
`od`/`dd` (no toolchain dependency) and is the reference verifier. Exit codes:
`0` branded with supported ABI, `1` missing, `2` unsupported `abi_version`.
`llvm-readelf -n <elf>` shows the same note in human-readable form.

The kernel-side implementation is a ~60-line scan in `kernel-shared`
(usable from the kernel, from `kernel/build.rs` host-side, and later from
mkfs) — see `docs/plans/minixrs-m1.md`.

## Versioning policy

- New descriptor words: append, bump nothing — old consumers ignore them
  (rule 3), new consumers must tolerate their absence when `descsz` is short.
- Incompatible ABI change: bump `abi_version`. Old kernels then correctly
  refuse new binaries and vice versa.
- `flags` bits may only be assigned meanings that are backwards-compatible
  with the bit being 0.
