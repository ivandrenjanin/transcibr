#+vet explicit-allocators
// --plan's grammar (ADR-0038 Stage 5): Plan_Options does NOT embed
// Common_Options -- the ADR's own plan-specific clause keeps its own
// four-field subset (model, engine, prompt, profile) copied by hand, because
// embedding would give Plan_Options a live cache field and a live tools
// field there is no reader for, and the day some future edit adds one by
// accident is the day `--plan --cache X` stops being refused without anyone
// deciding it should (A8). read_plan_option's case: falls through to the
// same UNKNOWN_OPTION_COMPLAINT every other migrated command's does, so
// --cache, --ffmpeg and --ffprobe are refused byte-identically to every
// other name outside this grammar's vocabulary, pinned in
// plan_options_test.odin -- exactly the way src/cli/plan.odin's own
// read_plan_option refused them before this migration.
package cliargs

import "transcibr:transcript"

PLAN :: "--plan"

Plan_Options :: struct {
	root:    string,
	model:   string,
	engine:  string,
	prompt:  string,
	profile: transcript.Merge_Profile,
	follow:  bool,
}

@(require_results)
read_plan_options :: proc(arguments: []string) -> (o: Plan_Options, ok: bool, refusal: Refusal) {
	defer if ok {
		assert(len(o.root) > 0, "accepted a command line with no folder to walk")
		assert(len(o.model) > 0, "accepted a command line naming no Model")
		assert(len(o.engine) > 0, "accepted a command line naming no Engine")
	} else {
		assert(len(o.root) == 0, "refused a command line and kept what it asked for")
	}

	o.profile = transcript.DEFAULT_PROFILE

	pair_ok, pair_refusal := read_pairs(arguments, read_plan_option, &o)
	if !pair_ok {
		return {}, false, pair_refusal
	}

	fields_ok, fields_refusal := required_fields_present(
		[]Required_Field{{o.root, PLAN}, {o.model, "--model-file"}, {o.engine, "--engine-exe"}},
	)
	if !fields_ok {
		return {}, false, fields_refusal
	}
	return o, true, {}
}

@(private)
@(require_results)
read_plan_option :: proc(
	name: string,
	value: string,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	assert(user != nil, "there is nowhere here to read an option into")
	o := cast(^Plan_Options)user

	switch name {
	case PLAN:
		o.root = value
	case "--model-file":
		o.model = value
	case "--engine-exe":
		o.engine = value
	case "--prompt":
		o.prompt = value
	case "--follow-reparse-points":
		return read_follow(&o.follow, value)
	case "--profile":
		profile, known, profile_refusal := parse_profile(value)
		if !known {
			return false, profile_refusal
		}
		o.profile = profile
	case:
		return false, make_refusal(UNKNOWN_OPTION_COMPLAINT, Refusal_Arg(name))
	}
	return true, {}
}
