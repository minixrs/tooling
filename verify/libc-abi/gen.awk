# gen.awk — turn the ABI manifest into a C emitter, a Rust emitter, and a
# label file, all describing the same ordered table of u64 entries.
#
#   awk -v c=OUT.c -v rs=OUT.rs -v labels=OUT.labels -f gen.awk items.list
#
# Entry i of both tables is described by line i of the label file, which is
# what lets compare.sh name the manifest line behind a mismatch.

function entry(label, cexpr, rsexpr) {
    cbody = cbody "    (unsigned long long)(" cexpr "),\n"
    rsbody = rsbody "    (" rsexpr ") as u64,\n"
    print label > labels
    n++
}

function aggregate(ctype,    i, parts, rf, cf) {
    entry(FNR ": sizeof " $2, "sizeof(" ctype ")", "size_of::<libc::" $2 ">()")
    entry(FNR ": alignof " $2, "_Alignof(" ctype ")", "align_of::<libc::" $2 ">()")
    for (i = 3; i <= NF; i++) {
        rf = $i; cf = $i
        if (split($i, parts, "=") == 2) { rf = parts[1]; cf = parts[2] }
        entry(FNR ": offsetof " $2 "." rf, \
              "offsetof(" ctype ", " cf ")", \
              "offset_of!(libc::" $2 ", " rf ")")
        # The field's own width: an offset alone misses a field narrowed into
        # trailing padding, or one whose successor's padding absorbs it.
        entry(FNR ": sizeof " $2 "." rf, \
              "sizeof(((" ctype " *)0)->" cf ")", \
              "fsize(|s: &libc::" $2 "| &s." rf ")")
    }
}

/^[ \t]*(#|$)/ { next }

$1 == "include" { includes = includes "#include " $2 "\n"; next }

$1 == "int" || $1 == "type" {
    entry(FNR ": sizeof " $2, "sizeof(" $2 ")", "size_of::<libc::" $2 ">()")
    entry(FNR ": alignof " $2, "_Alignof(" $2 ")", "align_of::<libc::" $2 ">()")
    if ($1 == "int")
        entry(FNR ": signedness " $2, "(" $2 ")-1 < 0", "(!(0 as libc::" $2 ")) < (0 as libc::" $2 ")")
    next
}

$1 == "const"   { entry(FNR ": value " $2, $2, "libc::" $2); next }
$1 == "struct"  { aggregate("struct " $2); next }
$1 == "union"   { aggregate("union " $2); next }
$1 == "typedef" { aggregate($2); next }

{ printf "gen.awk: %s:%d: unknown kind '%s'\n", FILENAME, FNR, $1 > "/dev/stderr"; bad = 1 }

END {
    if (bad) exit 2
    printf "#include <stddef.h> /* offsetof, which this file emits */\n%s\n__attribute__((section(\".minixrs_abi\"), used))\nconst unsigned long long minixrs_abi_table[%d] = {\n%s};\n", includes, n, cbody > c
    printf "#![no_std]\n#![allow(unused_comparisons, clippy::all)]\nuse core::mem::{align_of, offset_of, size_of};\n\n// The size of the field a projection closure selects.\nconst fn fsize<T, F>(_: fn(&T) -> &F) -> usize {\n    size_of::<F>()\n}\n\n#[used]\n#[no_mangle]\n#[link_section = \".minixrs_abi\"]\npub static minixrs_abi_table: [u64; %d] = [\n%s];\n", n, rsbody > rs
}
