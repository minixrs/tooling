// Canonical minixrs identity note (docs/abi-note.md) + minimal entry point.
// Assembled for aarch64 ELF by verify/selftest.sh.

	.section .note.minixrs.ident, "a", %note
	.p2align 2
	.long	8		// namesz: "minixrs" + NUL
	.long	8		// descsz: abi_version + flags
	.long	1		// type:   NT_MINIXRS_IDENT
	.asciz	"minixrs"
	.long	1		// abi_version
	.long	0		// flags (reserved)

	.text
	.globl	_start
_start:
	wfe
	b	_start
