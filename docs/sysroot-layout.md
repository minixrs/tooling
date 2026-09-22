# $MINIXRS_SDK layout contract

One prefix holds the whole SDK. Default `~/toolchains/minixrs`; every script
sources `scripts/env.sh`, and consumers (minixrs CI, the cmake toolchain
file, future rustc builds) read the `MINIXRS_SDK` environment variable.

```
$MINIXRS_SDK/
├── bin/                                   installed by build-llvm.sh (M2)
│   ├── clang, clang++                     the fork driver — knows the triple
│   ├── ld.lld, lld
│   ├── llvm-ar, llvm-nm, llvm-objcopy, llvm-objdump,
│   │   llvm-ranlib, llvm-readelf, llvm-readobj, …   (LLVM_INSTALL_UTILS=ON)
│   └── llvm-config                        used by rust-minixrs bootstrap (P4)
├── lib/
│   ├── clang/
│   │   └── 22/                            clang resource dir
│   │       └── lib/
│   │           └── aarch64-unknown-minixrs/
│   │               └── libclang_rt.builtins.a     build-compiler-rt.sh (M2)
│   └── cmake/llvm/                        for compiler-rt & rustc configure
├── sysroot/                               installed by build-musl.sh (M3)
│   ├── .stamp                             "musl=<sha> minixrs=<sha>
│   │                                      clang=<version line>" — freshness
│   │                                      key; minixrs' build.rs uses it as a
│   │                                      rerun-if-changed target. minixrs is
│   │                                      in the key because it is the ABI
│   │                                      oracle (see below)
│   └── usr/
│       ├── include/                       musl headers
│       │   └── minixrs/                   generated ABI headers (ipc.h,
│       │                                  callnr.h, com.h, errno.h) copied in
│       │                                  from minixrs' gen-c-headers, so C
│       │                                  compiles against one -isystem root
│       └── lib/
│           ├── libc.a                     static only — no shared objects
│           ├── crt1.o                     carries the brand note (abi-note.md)
│           ├── crti.o
│           └── crtn.o
└── share/
    └── minixrs/
        └── hello                          branded static hello world ELF,
                                           installed by build-sysroot.sh —
                                           canned exec-test artifact for
                                           minixrs sessions (M3 gate)
```

## Contract points

- **Static-only platform.** No `.so`, no dynamic linker, no `syslibdir`.
  Everything links `-static`; the clang MinixRS driver defaults to it.
- **Page size 4096, separate loadable segments.** The driver passes
  `-z max-page-size=4096 -z separate-loadable-segments` (minixrs D13) so the
  kernel's loader constraints (page-aligned vaddr *and* file offset per
  PT_LOAD) always hold.
- **The driver pins no image base.** SDK-built images link at lld's aarch64
  default, `0x0020_0000`; minixrs repo-built images keep `0x0010_0000` via
  their own `servers/*/user.ld` / `userland/*/user.ld`. Both bases are
  correct at once — each process has its own TTBR0, so nothing collides
  across processes. What the kernel loader actually requires, and what
  `verify/check-image.sh` checks regardless of base: `ET_EXEC`, `PT_LOAD`s
  4 KiB-aligned in both vaddr and file offset, the program headers covered by
  a `PT_LOAD` (`AT_PHDR` reachable), every `PT_LOAD` clear of the stack guard
  page (`USER_REGION_LIMIT`, `kernel-shared/src/uspace.rs`), and the identity
  note present. Historical note: the driver used to pin `--image-base=0x100000`
  (LLVM patch 0006, dropped at P3d) because minixrs used to map the initial
  stack page at lld's default, `0x0020_0000`; the stack has since moved to the
  top of user VA, so the collision the pin guarded against no longer exists.
- **crt objects come from `sysroot/usr/lib`.** The driver searches there —
  crt1.o is the C-side brand emitter, so replacing it with a foreign crt1
  produces binaries the kernel refuses.
- **compiler-rt builtins are per-target** in the clang resource dir
  (`lib/clang/<major>/lib/<triple>/`). The `22` component tracks the fork's
  major version; scripts derive it from `clang --print-resource-dir` rather
  than hard-coding.
- **The generated ABI headers are the oracle, and they come from minixrs.**
  This repo never vendors a copy: `build-musl.sh` runs
  `cargo gen-c-headers` in `$MINIXRS_SRC` and installs the result here, and
  `build-sysroot.sh` compiles the `abi-selftest.c` that comes with it against
  the installed headers under `-nostdinc` — so a POSIX errno that drifted from
  `kernel-shared` is a build failure, not a runtime surprise.
- **The sysroot is validated before it is trusted.** `build-sysroot.sh` links
  a hello world from a bare driver line and runs both `check-brand.sh` and
  `check-image.sh` on it; a failure of either means nothing is installed to
  `share/minixrs/hello`.
- Nothing in minixrs may hard-code this path; only `$MINIXRS_SDK` (with the
  `~/toolchains/minixrs` default) is contractual.
