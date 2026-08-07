#+vet explicit-allocators
// --from-json's grammar (ADR-0038 Stage 6, the contraction): the fifth and
// last of the ticket's own migration sites, moved out of
// src/cli/main.odin's read_options/read_option. Render_Options embeds no
// Common_Options -- it shares no field spelling with the other four
// commands' grammar at all (--model and --engine are free text here, not
// --model-file/--engine-exe, and there is no --cache, no tools struct and no
// --prompt) -- so it keeps its own small struct, the same way Plan_Options
// keeps its own four-field subset rather than embedding a shape built for a
// different command.
//
// Its required-field sweep does not reuse required_fields_present's shared
// "%s names nothing." complaint either: --from-json's own refusal
// ("nothing to render.") predates the shared sweep, names no field, and must
// stay byte-identical to what src/cli/main.odin wrote before this migration
// (ADR-0038's own migration contract -- every refusal string and its
// ordering byte-identical before and after).
//
// The settling this procedure does after its read loop -- --source falling
// back to the json path, --model and --engine falling back to "unknown" --
// is the same kind of constant, no-import defaulting --profile's own
// DEFAULT_PROFILE already does inside every migrated command's grammar, not
// the tool/worker-ceiling defaulting ADR-0038 keeps in src/cli because that
// needs transcibr:audio or transcibr:pipeline behind it. Folding it in here
// leaves src/cli's own re_render with nothing left to decide -- argv in, a
// transcript.Render_Context out.
//
// Render_Options embeds transcript.Render_Context itself (`using rc`)
// rather than shadowing its fields under different names -- a former
// `source`/`model`/`engine` trio that src/cli/main.odin's own
// render_context_of then hand-copied onto Render_Context's
// `source_display`/`model`/`engine_version` (fix round 1, PR #253 finding
// 1). That copy was a second place the same four fields could be paired off
// wrong -- a swap of two lines compiled clean and was caught only by
// rebuilding the binary and diffing its output, never by `just test`.
// Assigning straight into the embedded Render_Context's own field names
// means the mapping happens exactly once, here, where
// read_render_options_accepts_a_well_formed_command_line already reds on a
// swap between two of these case arms.
package cliargs

import "transcibr:transcript"

FROM_JSON :: "--from-json"

NOTHING_TO_RENDER_COMPLAINT :: "nothing to render."

Render_Options :: struct {
	json_path: string,
	using rc:  transcript.Render_Context,
}

@(require_results)
read_render_options :: proc(
	arguments: []string,
) -> (
	o: Render_Options,
	ok: bool,
	refusal: Refusal,
) {
	defer if ok {
		assert(len(o.json_path) > 0, "accepted a command line with nothing to render")
		assert(len(o.source_display) > 0, "accepted a command line that settled no source")
		assert(len(o.model) > 0, "a model nobody named is UNKNOWN, never empty")
		assert(len(o.engine_version) > 0, "an engine nobody named is UNKNOWN, never empty")
	} else {
		assert(len(o.json_path) == 0, "refused a command line and kept what it asked for")
	}

	o.profile = transcript.DEFAULT_PROFILE

	pair_ok, pair_refusal := read_pairs(arguments, read_render_option, &o)
	if !pair_ok {
		return {}, false, pair_refusal
	}

	if len(o.json_path) == 0 {
		return {}, false, make_refusal(NOTHING_TO_RENDER_COMPLAINT)
	}
	if len(o.source_display) == 0 {
		o.source_display = o.json_path
	}
	o.model = transcript.named_or_unknown(o.model)
	o.engine_version = transcript.named_or_unknown(o.engine_version)
	return o, true, {}
}

@(private)
@(require_results)
read_render_option :: proc(
	name: string,
	value: string,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	assert(user != nil, "there is nowhere here to read an option into")
	o := cast(^Render_Options)user

	switch name {
	case FROM_JSON:
		o.json_path = value
	case "--source":
		o.source_display = value
	case "--model":
		o.model = value
	case "--engine":
		o.engine_version = value
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
