// No identity note — check-brand.sh must report MISSING (exit 1).

	.text
	.globl	_start
_start:
	wfe
	b	_start
