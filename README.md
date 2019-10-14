# prettyll

"tries" to spit out a more readable llvm-IR for your eyes, ie. not for the
llvm-IR parser.

I wrote this after having nausea looking at bad ir from (bad) front ends.  The
parser in prettyll is far from a fully-fledged llvm-IR parser. For starters, it
relies on "hacky" regexes. Prettyll only works well with single instruction per
line llvm-IR. It mostly fails with "non-single" instruction per line IR (ie. a
split instruction, or a nested instruction).

The current implementation does the following IR transformations:
- Simvar: eliminates type-casting and load instructions by reducing
variables to their original name, not the casted one.

- Simgep: translates getelementptr instruction arguments to [idx0, idx1, ..] format.

- Demangle: demangles mangled C++ symbols.
