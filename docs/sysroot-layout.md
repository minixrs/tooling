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
- **Images are based at `0x0010_0000`.** The driver passes
  `--image-base=0x100000` (LLVM patch 0006). lld's default aarch64 base is
  `0x200000`, which is exactly where minixrs maps every process's initial stack
  page (`SERVER_STACK_VA`, `kernel/src/arch/aarch64/userland.rs`), so a
  default-linked binary would be loaded onto its own stack and corrupt its text
  at the first push. `0x0010_0000` is the base `servers/*/user.ld` already
  uses; processes can share it because each has its own TTBR0. The flag is
  gated by `verify/check-driver.sh`, its consequence by
  `verify/check-image.sh`.
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
