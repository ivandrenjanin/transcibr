#+vet explicit-allocators
// A Refusal is data, not a built string: it carries the pinned complaint
// format string and up to MAX_REFUSAL_ARGS interpolated values, so a refuser
// on the far side of the fence can still call fmt.eprintf on argv-owned
// bytes without cliargs ever allocating or writing to a stream itself
// (ADR-0038).
package cliargs

// Refusal_Arg holds its value inside the union's own storage, never a pointer
// to somewhere else -- copying a Refusal copies these bytes with it. A
// string arm is only ever safe to store here when its backing bytes outlive
// the Refusal that carries it: an argv slice or a compile-time constant,
// never a frame-local formatting buffer (ADR-0038).
Refusal_Arg :: union {
	string,
	int,
}

MAX_REFUSAL_ARGS :: 3

Refusal :: struct {
	complaint: string,
	args:      [MAX_REFUSAL_ARGS]Refusal_Arg,
	arg_count: int,
}

@(require_results)
make_refusal :: proc(complaint: string, args: ..Refusal_Arg) -> Refusal {
	assert(len(complaint) > 0, "a refusal without a complaint explains nothing")
	assert(len(args) <= MAX_REFUSAL_ARGS, "a refusal carries more arguments than refuse can print")

	r: Refusal
	r.complaint = complaint
	r.arg_count = len(args)
	for arg, i in args {
		r.args[i] = arg
	}
	return r
}
