// Identity note with an unknown abi_version — check-brand.sh must report
// UNSUPPORTED (exit 2).

	.section .note.minixrs.ident, "a", %note
	.p2align 2
	.long	8		// namesz
	.long	8		// descsz
	.long	1		// type: NT_MINIXRS_IDENT
	.asciz	"minixrs"
	.long	99		// abi_version — unknown on purpose
	.long	0		// flags

	.text
	.globl	_start
_start:
	wfe
	b	_start
