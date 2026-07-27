/* Fixture linker script for verify/selftest.sh.
 *
 * Forces one PT_LOAD off 4 KiB alignment so check-image.sh's Misaligned rule
 * (kernel/src/boot_image/elf.rs `load_segment`) has something to catch.
 *
 * Everything else about the resulting image stays valid — ET_EXEC, base
 * 0x100000, program headers covered by the first PT_LOAD, clear of the stack
 * page at 0x200000 — so the fixture fails for the alignment rule alone and
 * not incidentally.
 */
SECTIONS {
    . = 0x100000 + SIZEOF_HEADERS;
    .note.minixrs.ident : { *(.note.minixrs.ident) }

    . = 0x101008; /* 8 bytes past the page boundary, deliberately */
    .text : { *(.text) }
}
