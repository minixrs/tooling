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
│   └── usr/
│       ├── include/                       musl headers (+ minixrs ABI headers)
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
- **crt objects come from `sysroot/usr/lib`.** The driver searches there —
  crt1.o is the C-side brand emitter, so replacing it with a foreign crt1
  produces binaries the kernel refuses.
- **compiler-rt builtins are per-target** in the clang resource dir
  (`lib/clang/<major>/lib/<triple>/`). The `22` component tracks the fork's
  major version; scripts derive it from `clang --print-resource-dir` rather
  than hard-coding.
- **The sysroot is the ABI oracle.** `build-sysroot.sh` diffs the minixrs
  gen-c-headers output against the installed headers (ABI selftest) and
  brand-checks a freshly linked hello world before declaring the sysroot
  good.
- Nothing in minixrs may hard-code this path; only `$MINIXRS_SDK` (with the
  `~/toolchains/minixrs` default) is contractual.
