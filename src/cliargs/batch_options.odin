#+vet explicit-allocators
// --batch's grammar (ADR-0038 Stage 4): Batch_Options embeds Common_Options
// via `using`, built entirely from the stage-2 helpers (read_pairs,
// required_fields_present, parse_profile) the same way read_transcribe_-
// options is (Stage 3), plus this command's own extras -- the folder to
// walk, the resumability follow flag, and the two worker-count options bound
// to their own ceiling through Worker_Ceilings (worker_options.odin). It
// does not default the two-string Tools, the worker counts or the follow
// flag -- that stays src/cli's job, run after this procedure returns, the
// same place `audio.defaulted_tools`/`defaulted_batch` runs today (ADR-0038's
// import-closure section).
package cliargs

import "transcibr:process"
import "transcibr:transcript"

BATCH :: "--batch"

Batch_Options :: struct {
	using common:    Common_Options,
	root:            string,
	follow:          bool,
	extract_workers: int,
	queue_depth:     int,
}

FOLLOW_YES :: "yes"
FOLLOW_NO :: "no"
FOLLOW_CHOICE :: FOLLOW_YES + "|" + FOLLOW_NO

UNKNOWN_FOLLOW_COMPLAINT :: "--follow-reparse-points takes %s, not %q."
WORKER_COUNT_COMPLAINT :: "%s takes a whole number from 1 to %d, not %q."

// Three digits: generous against any machine's real core or disk count, and
// what refuses a mistyped, absurdly large value before it ever reaches
// process.worker_count_within_ceiling -- process.read_natural's own
// max_digits precedent (process/engine.odin's MAX_NATURAL_DIGITS,
// artifact/sidecar.odin's MAX_SIDECAR_DIGITS), applied here by name instead
// of the bare literal src/cli/batch.odin used to pass (routing item 3, #75).
MAX_WORKER_COUNT_DIGITS :: 3

#assert(MAX_WORKER_COUNT_DIGITS < process.MAX_NATURAL_DIGITS)

@(private)
Batch_Pair_User :: struct {
	o:        ^Batch_Options,
	ceilings: Worker_Ceilings,
}

@(require_results)
read_batch_options :: proc(
	arguments: []string,
	ceilings: Worker_Ceilings,
) -> (
	o: Batch_Options,
	ok: bool,
	refusal: Refusal,
) {
	assert(
		ceilings[.Extract_Workers] > 0,
		"a ceiling of zero admits no extract-workers count at all",
	)
	assert(ceilings[.Queue_Depth] > 0, "a ceiling of zero admits no queue-depth count at all")
	defer if ok {
		assert(len(o.root) > 0, "accepted a command line with no folder to walk")
		assert(len(o.model) > 0, "accepted a command line naming no Model")
		assert(len(o.engine) > 0, "accepted a command line naming no Engine")
		assert(len(o.cache) > 0, "accepted a command line naming no scratch cache")
	} else {
		assert(len(o.root) == 0, "refused a command line and kept what it asked for")
	}

	o.profile = transcript.DEFAULT_PROFILE

	pair_user := Batch_Pair_User {
		o        = &o,
		ceilings = ceilings,
	}
	pair_ok, pair_refusal := read_pairs(arguments, read_batch_option, &pair_user)
	if !pair_ok {
		return {}, false, pair_refusal
	}

	fields_ok, fields_refusal := required_fields_present(
		[]Required_Field {
			{o.root, BATCH},
			{o.model, "--model-file"},
			{o.engine, "--engine-exe"},
			{o.cache, "--cache"},
		},
	)
	if !fields_ok {
		return {}, false, fields_refusal
	}
	return o, true, {}
}

@(private)
@(require_results)
read_batch_option :: proc(
	name: string,
	value: string,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	assert(user != nil, "there is nowhere here to read an option into")
	pu := cast(^Batch_Pair_User)user
	o := pu.o

	switch name {
	case BATCH:
		o.root = value
	case "--model-file":
		o.model = value
	case "--engine-exe":
		o.engine = value
	case "--cache":
		o.cache = value
	case "--ffmpeg":
		o.tools.ffmpeg = value
	case "--ffprobe":
		o.tools.ffprobe = value
	case "--prompt":
		o.prompt = value
	case "--profile":
		profile, known, profile_refusal := parse_profile(value)
		if !known {
			return false, profile_refusal
		}
		o.profile = profile
	case "--follow-reparse-points":
		return read_follow(&o.follow, value)
	case "--extract-workers":
		return read_batch_worker_option(
			&o.extract_workers,
			name,
			value,
			pu.ceilings[.Extract_Workers],
		)
	case "--queue-depth":
		return read_batch_worker_option(&o.queue_depth, name, value, pu.ceilings[.Queue_Depth])
	case:
		return false, make_refusal(UNKNOWN_OPTION_COMPLAINT, Refusal_Arg(name))
	}
	return true, {}
}

@(private)
@(require_results)
read_follow :: proc(into: ^bool, value: string) -> (ok: bool, refusal: Refusal) {
	assert(into != nil, "there is nowhere here to read --follow-reparse-points into")

	switch value {
	case FOLLOW_YES:
		into^ = true
	case FOLLOW_NO:
		into^ = false
	case:
		return false, make_refusal(
			UNKNOWN_FOLLOW_COMPLAINT,
			Refusal_Arg(FOLLOW_CHOICE),
			Refusal_Arg(value),
		)
	}
	return true, {}
}

// Why not `strconv.parse_int`, which takes `_`, a sign and overflows in
// silence: CLAUDE.md, Odin notes.
@(private)
@(require_results)
read_batch_worker_option :: proc(
	into: ^int,
	name: string,
	value: string,
	ceiling: int,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	assert(into != nil, "there is nowhere here to read a worker count into")
	assert(ceiling > 0, "a ceiling of zero admits no worker count at all")

	count, readable := read_worker_count(value, ceiling)
	if !readable {
		return false, make_refusal(
			WORKER_COUNT_COMPLAINT,
			Refusal_Arg(name),
			Refusal_Arg(ceiling),
			Refusal_Arg(value),
		)
	}
	into^ = count
	return true, {}
}

@(private)
@(require_results)
read_worker_count :: proc(value: string, ceiling: int) -> (count: int, ok: bool) {
	assert(ceiling > 0, "a ceiling of zero admits no worker count at all")

	parsed, readable := process.read_natural(value, MAX_WORKER_COUNT_DIGITS)
	if !readable || parsed <= 0 || !process.worker_count_within_ceiling(int(parsed), ceiling) {
		return 0, false
	}
	return int(parsed), true
}
