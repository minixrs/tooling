/* Fixture linker script for verify/selftest.sh.
 *
 * The positive twin of guard.ld: places branded.s's single PT_LOAD so its
 * end lands exactly at USER_REGION_LIMIT (0x3FFEF000) — the boundary itself,
 * one page below guard.ld's target. `vend > USER_REGION_LIMIT` is what
 * check-image.sh's ceiling rule tests, so a segment ending exactly *at* the
 * limit must still be LOADABLE; only strictly past it is a violation. This
 * is the fixture that would catch the rule being tightened by one page (e.g.
 * `>` mistakenly written as `>=`) as well as the guard.ld fixture catches it
 * being loosened.
 *
 * Same layout trick as guard.ld, shifted down one page: `. = 0x3FFEE000;`
 * here (vs. guard.ld's 0x3FFEF000). lld backs the combined segment's base
 * off by a further page to fit the headers ahead of "." (observed:
 * 0x3FFED000, one page below the explicit "."), which is what makes the
 * two-page segment's end land exactly on 0x3FFEF000. Verified with
 * `llvm-readelf --program-headers` after linking; verify/selftest.sh's
 * image-at-limit expectation pins the LOADABLE verdict, so drift here fails
 * the selftest loudly.
 */
PHDRS {
    combined PT_LOAD FLAGS(5) FILEHDR PHDRS;
    note PT_NOTE;
}
SECTIONS {
    . = 0x3FFEE000;
    .note.minixrs.ident : { *(.note.minixrs.ident) } :combined :note
    .text : { *(.text) } :combined
}
