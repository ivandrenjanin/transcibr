package main

import "core:fmt"
import "transcibr:artifact"
import "transcibr:planning"
import "transcibr:transcript"

// The dry run: walk a folder tree and print what a Batch would do to it,
// spending no GPU time at all. Every decision, every sentence and every refusal
// is `transcibr:planning`'s; what is here is argument reading and a write.

PLAN :: "--plan"

// The whole vocabulary `--follow-reparse-points` accepts, and the same constant
// the usage block prints, so what is offered and what is read cannot drift. A
// value outside it is REFUSED and never read as `no`: `--follow-reparse-points
// true` quietly doing the opposite of what it says is external input
// reinterpreted rather than rejected, which rule A8 forbids.
FOLLOW_YES :: "yes"
FOLLOW_NO :: "no"
FOLLOW_CHOICE :: FOLLOW_YES + "|" + FOLLOW_NO

// `engine_version` is NOTHING where the command line did not name one, and is
// never defaulted to UNKNOWN here. `transcibr:planning` is what decides what an
// unnamed Engine means, because this package collects no tests and a decision
// nothing can turn red is a decision nobody is holding (ADR-0009).
Plan_Options :: struct {
	root:           string,
	model:          string,
	engine_version: Maybe(string),
	prompt:         string,
	profile:        transcript.Merge_Profile,
	follow:         bool,
}

@(require_results)
plan_batch :: proc(arguments: []string) -> int {
	assert(len(arguments) > 0, "no arguments at all is the version banner, settled before this")
	assert(arguments[0] == PLAN, "main dispatched a command line that does not open with --plan")

	o, ok := read_plan_options(arguments)
	if !ok {
		return USAGE_ERROR
	}

	fmt.eprintfln("  identifying %s", o.model)
	identified, named := model_identified(o.model)
	defer artifact.destroy_model(identified, context.allocator)
	if !named {
		return OPERATING_ERROR
	}
	return report_plan(o, identified)
}

@(private)
@(require_results)
report_plan :: proc(o: Plan_Options, identified: artifact.Model) -> int {
	assert(len(o.root) > 0, "there is no folder here to walk")
	assert(len(identified.digest) > 0, "a Model nobody identified reached the plan")

	inventory := planning.discover(
		[]string{o.root},
		planning.Walk{on_progress = walked, follow_reparse_points = o.follow},
		context.allocator,
	)
	defer planning.destroy_inventory(inventory, context.allocator)
	fmt.eprintln()

	plan, runnable := planning.plan_batch(
		inventory,
		planning.Settings {
			engine_version = o.engine_version,
			model = identified,
			beam = artifact.ENGINE_DEFAULT_BEAM,
			merge_profile = transcript.profile_name(o.profile),
			prompt = o.prompt,
		},
		context.allocator,
	)
	defer planning.destroy_plan(plan, context.allocator)

	print_plan(plan, inventory)
	return plan_verdict(plan, inventory, runnable)
}

@(private)
print_plan :: proc(plan: planning.Plan, inventory: planning.Inventory) {
	assert(
		len(plan.entries) == len(inventory.found),
		"a plan that lost a Recording on the way here",
	)

	for entry in plan.entries {
		line := planning.plan_line(entry, context.allocator)
		defer delete(line, context.allocator)
		fmt.println(line)
	}
	for note in inventory.notes {
		line := planning.note_line(note, context.allocator)
		defer delete(line, context.allocator)
		fmt.eprintln(line)
	}
}

// A cancelled walk and a refused plan are both failures: what the first found is
// true and incomplete, and acting on either as though it were the whole Batch is
// the silently short file list ADR-0009 names. Both come back as `runnable`
// being false, and both sentences are `transcibr:planning`'s.
@(private)
@(require_results)
plan_verdict :: proc(plan: planning.Plan, inventory: planning.Inventory, runnable: bool) -> int {
	assert(len(plan.entries) == len(inventory.found), "a plan that lost a Recording")

	if runnable {
		return 0
	}

	said := false
	for line in ([?]string {
			planning.collision_line(plan, context.allocator),
			planning.incomplete_line(inventory, context.allocator),
		}) {
		defer delete(line, context.allocator)
		if len(line) == 0 {
			continue
		}
		fmt.eprintln(line)
		said = true
	}
	assert(said, "a Batch was refused and nothing said what refused it")
	return OPERATING_ERROR
}

// See CLAUDE.md, Odin notes: core:fmt integer padding.
@(private)
walked :: proc(progress: planning.Progress, user: rawptr) {
	assert(progress.directories > 0, "progress reported before a single directory had been read")
	assert(progress.recordings >= 0, "a walk reported a negative number of Recordings")

	fmt.eprintf(
		"\r  walking %d directories, %d Recordings            ",
		progress.directories,
		progress.recordings,
	)
}

@(private)
@(require_results)
read_plan_options :: proc(arguments: []string) -> (o: Plan_Options, ok: bool) {
	defer if ok {
		assert(len(o.root) > 0, "accepted a command line with no folder to walk")
		assert(len(o.model) > 0, "accepted a command line naming no Model")
	} else {
		assert(len(o.root) == 0, "refused a command line and kept what it asked for")
	}

	o.profile = transcript.DEFAULT_PROFILE

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			return {}, refuse("%q stands at the end of the command line with no value after it.", name)
		}
		if !read_plan_option(&o, name, arguments[at + 1]) {
			return {}, false
		}
	}

	for missing in ([?][2]string{{o.root, PLAN}, {o.model, "--model-file"}}) {
		if len(missing[0]) == 0 {
			return {}, refuse("%s names nothing.", missing[1])
		}
	}
	return o, true
}

// `--follow-reparse-points` takes a value like every other option here, because
// the loop above pairs a name with the argument after it and a flag that took
// none would swallow the option behind it.
@(private)
@(require_results)
read_plan_option :: proc(o: ^Plan_Options, name, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")
	assert(len(name) > 0, "an option with no name at all reached the reader")

	switch name {
	case PLAN:
		o.root = value
	case "--model-file":
		o.model = value
	case "--engine-version":
		o.engine_version = value
	case "--prompt":
		o.prompt = value
	case "--follow-reparse-points":
		switch value {
		case FOLLOW_YES:
			o.follow = true
		case FOLLOW_NO:
			o.follow = false
		case:
			return refuse("--follow-reparse-points takes %s, not %q.", FOLLOW_CHOICE, value)
		}
	case "--profile":
		profile, known := transcript.profile_named(value)
		if !known {
			return refuse("no merge profile called %q.", value)
		}
		o.profile = profile
	case:
		return refuse("unknown option %q.", name)
	}
	return true
}
