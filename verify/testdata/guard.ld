/* Fixture linker script for verify/selftest.sh.
 *
 * Places branded.s's single PT_LOAD so its end lands exactly at
 * USER_REGION_LIMIT + PAGE_SIZE (0x3FFEF000 + 0x1000 = 0x3FFF0000) — the
 * top of the stack's guard page (kernel-shared/src/uspace.rs
 * USER_STACK_BASE). That segment therefore reaches into the guard page but
 * not one byte into the stack itself (which starts at USER_STACK_BASE).
 *
 * This is the one fixture that tells the current rule (ceiling at
 * USER_REGION_LIMIT, exclusive) apart from the earlier V14 draft's ceiling at
 * USER_STACK_BASE (0x3FFF0000), i.e. `vend > USER_REGION_LIMIT + PAGE_SIZE`:
 * that draft rule does not fire here, since 0x3FFF0000 is not *strictly
 * greater* than USER_REGION_LIMIT + PAGE_SIZE — only the current rule does.
 *
 * `combined` forces the ELF header, program headers, the note, and .text
 * all into ONE PT_LOAD (`FILEHDR PHDRS`) so nothing lands on a page past
 * the target boundary. lld backs the segment's base off by a further page
 * to fit the headers ahead of "." (observed: 0x3FFEE000, one page below
 * the explicit "."), which is what makes the two-page segment's end land
 * exactly on 0x3FFF0000. verify/selftest.sh's image-on-guard expectation
 * pins that exact end address in its match string, so any lld layout drift
 * here fails the selftest loudly rather than silently passing a stale
 * fixture.
 * `note` duplicates the note section into its own PT_NOTE so check-brand.sh
 * still finds it (a PT_LOAD alone does not satisfy check-brand.sh, which
 * only walks PT_NOTE segments). FLAGS(5) is R+X, with no write bit, so this
 * cannot also trip the WriteExec rule.
 */
PHDRS {
    combined PT_LOAD FLAGS(5) FILEHDR PHDRS;
    note PT_NOTE;
}
SECTIONS {
    . = 0x3FFEF000;
    .note.minixrs.ident : { *(.note.minixrs.ident) } :combined :note
    .text : { *(.text) } :combined
}
