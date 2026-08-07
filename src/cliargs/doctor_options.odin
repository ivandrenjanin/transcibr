#+vet explicit-allocators
// --doctor's grammar (ADR-0038 Stage 5b, issue #75's fifth ruled-in
// migration site): Doctor_Options does NOT embed Common_Options -- the
// ADR's Plan_Options precedent applies here too. Doctor has no cache field,
// no prompt field and no profile field, so --cache, --prompt and --profile
// fall through read_doctor_option's case: exactly like any other name
// outside this grammar's vocabulary, the same deliberate refusal
// Plan_Options keeps for the fields it does not carry (A8). Doctor keeps its
// own two-string Tools -- the same struct Batch_Options and
// Transcribe_Options carry, read directly here rather than through
// Common_Options, since Common_Options also carries cache/prompt/profile
// fields Doctor has no reader for.
//
// read_doctor_option must NOT assert that name is non-empty: an empty argv
// token is external input (A8), refused through UNKNOWN_OPTION_COMPLAINT
// like any other unrecognized name -- and src/cli/doctor.odin's deleted
// reader already took this shape before migration (it carried no such
// assert), so there is no crash-to-refusal divergence to declare here, only
// the byte-identical unknown-option refusal pinned by
// doctor_options_test.odin's read_doctor_options_refuses_an_empty_option_name.
package cliargs

DOCTOR :: "--doctor"

Doctor_Options :: struct {
	model:  string,
	engine: string,
	tools:  Tools,
}

@(require_results)
read_doctor_options :: proc(
	arguments: []string,
) -> (
	o: Doctor_Options,
	ok: bool,
	refusal: Refusal,
) {
	defer if ok {
		assert(len(o.model) > 0, "accepted a command line naming no Model")
		assert(len(o.engine) > 0, "accepted a command line naming no Engine")
	} else {
		assert(len(o.model) == 0, "refused a command line and kept what it asked for")
	}

	pair_ok, pair_refusal := read_pairs(arguments, read_doctor_option, &o)
	if !pair_ok {
		return {}, false, pair_refusal
	}

	fields_ok, fields_refusal := required_fields_present(
		[]Required_Field{{o.model, "--model-file"}, {o.engine, "--engine-exe"}},
	)
	if !fields_ok {
		return {}, false, fields_refusal
	}
	return o, true, {}
}

@(private)
@(require_results)
read_doctor_option :: proc(
	name: string,
	value: string,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	assert(user != nil, "there is nowhere here to read an option into")
	o := cast(^Doctor_Options)user

	switch name {
	case "--model-file":
		o.model = value
	case "--engine-exe":
		o.engine = value
	case "--ffmpeg":
		o.tools.ffmpeg = value
	case "--ffprobe":
		o.tools.ffprobe = value
	case:
		return false, make_refusal(UNKNOWN_OPTION_COMPLAINT, Refusal_Arg(name))
	}
	return true, {}
}
