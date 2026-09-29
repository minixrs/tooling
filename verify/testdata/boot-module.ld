/* Fixture linker script for verify/selftest.sh.
 *
 * The shape of a minixrs boot module (the user.ld of every server, driver,
 * fs/mfs and userland/init): the text PT_LOAD carries no
 * FILEHDR/PHDRS, so the first PT_LOAD starts one page into the file and the
 * program header table at e_phoff = 64 lies in an unmapped prefix.
 *
 * The kernel accepts that — `load_into` computes a phdr VA only when some
 * segment covers the headers, and "none" is ordinary for an image that is
 * never exec'd and never reads an auxv. Only an exec'd musl program needs
 * AT_PHDR. So check-image.sh flags this by default and accepts it under
 * --boot-module, which is exactly the pair of verdicts selftest.sh asserts.
 *
 * `note` duplicates the note section into its own PT_NOTE so check-brand.sh
 * still finds it. FLAGS(5) is R+X with no write bit, so this cannot also trip
 * the WriteExec rule.
 */
PHDRS {
    text PT_LOAD FLAGS(5);
    note PT_NOTE;
}
SECTIONS {
    . = 0x00100000;
    .note.minixrs.ident : { *(.note.minixrs.ident) } :text :note
    .text : { *(.text) } :text
}
