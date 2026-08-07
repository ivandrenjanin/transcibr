#+vet explicit-allocators
// The generalized pair-off read loop: the byte-identical shape measured at
// five src/cli sites (ADR-0038) -- walk arguments two at a time, a name and
// the value after it, refusing a trailing name with nothing after it. Each
// migrated command supplies its own single-option dispatcher as
// read_one/user; the loop itself decides nothing about any option name.
package cliargs

// user mirrors the callback+userdata shape transcibr:process and
// transcibr:engine already use for their own callbacks (process.Progress,
// engine.Report) rather than a closure, so a caller with state to thread
// through owns exactly where that state lives.
Option_Reader :: proc(name: string, value: string, user: rawptr) -> (ok: bool, refusal: Refusal)

NO_VALUE_AFTER_NAME_COMPLAINT :: "%q stands at the end of the command line with no value after it."

@(require_results)
read_pairs :: proc(
	arguments: []string,
	read_one: Option_Reader,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	assert(read_one != nil, "there is nothing here to dispatch a single option to")
	defer if ok {
		assert(refusal.arg_count == 0, "a loop that finished clean still carries a stale refusal")
	} else {
		assert(len(refusal.complaint) > 0, "a loop refused and said nothing about why")
	}

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			return false, make_refusal(NO_VALUE_AFTER_NAME_COMPLAINT, Refusal_Arg(name))
		}
		read_ok, read_refusal := read_one(name, arguments[at + 1], user)
		if !read_ok {
			return false, read_refusal
		}
	}
	return true, {}
}
