#+vet explicit-allocators
package main

import "core:fmt"
import "transcibr:artifact"
import "transcibr:pipeline"
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

// `--plan` and `--batch` read `--follow-reparse-points` the identical way
// (PR #67's review, finding 3); `--transcribe` names one Recording rather
// than a folder to walk and has no such option at all.
@(private)
@(require_results)
read_follow :: proc(into: ^bool, value: string) -> (ok: bool) {
	assert(into != nil, "there is nowhere here to read --follow-reparse-points into")

	switch value {
	case FOLLOW_YES:
		into^ = true
	case FOLLOW_NO:
		into^ = false
	case:
		return refuse("--follow-reparse-points takes %s, not %q.", FOLLOW_CHOICE, value)
	}
	return true
}

// `--engine-exe` is mandatory, the same as `--model-file`: the Engine is
// identified by its own SHA-256, exactly the way the Model is (ADR-0027's
// reopening clause, closed by issue #50), so there is no absent case for
// this package to decide about any more.
Plan_Options :: struct {
	root:    string,
	model:   string,
	engine:  string,
	prompt:  string,
	profile: transcript.Merge_Profile,
	follow:  bool,
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

	fmt.eprintfln("  identifying %s", o.engine)
	engine_digest, engine_named := engine_identified(o.engine)
	defer delete(string(engine_digest), context.allocator)
	if !engine_named {
		return OPERATING_ERROR
	}
	return report_plan(o, identified, engine_digest)
}

@(private)
@(require_results)
report_plan :: proc(
	o: Plan_Options,
	identified: artifact.Model,
	engine_digest: artifact.Digest,
) -> int {
	assert(len(o.root) > 0, "there is no folder here to walk")
	assert(len(identified.digest) > 0, "a Model nobody identified reached the plan")

	inventory, plan, runnable := planned(
		o.root,
		identified,
		engine_digest,
		o.engine,
		o.prompt,
		o.profile,
		o.follow,
	)
	defer planning.destroy_inventory(inventory, context.allocator)
	defer planning.destroy_plan(plan, context.allocator)

	print_plan(plan, inventory)
	return plan_verdict(plan, inventory, runnable)
}

// The walk and the plan it settles into, and nothing decided about either --
// `--plan` reports both unconditionally and `--batch` (`planned_and_run`,
// `src/cli/batch.odin`) only when `runnable` says no, so neither belongs
// inside this procedure (PR #67's review, finding 4). What both callers
// build `planning.Settings` from is exactly these seven arguments, so a field
// added there is a signature both call sites fail to compile against until
// it is threaded through -- never a silent mismatch between what `--plan`
// predicted and what `--batch` actually did.
@(private)
@(require_results)
planned :: proc(
	root: string,
	identified: artifact.Model,
	engine_digest: artifact.Digest,
	engine_path: string,
	prompt: string,
	profile: transcript.Merge_Profile,
	follow: bool,
) -> (
	inventory: planning.Inventory,
	plan: planning.Plan,
	runnable: bool,
) {
	assert(len(root) > 0, "there is no folder here to walk")
	assert(len(identified.digest) > 0, "a Model nobody identified reached the plan")
	assert(
		len(engine_digest) == artifact.DIGEST_CHARS,
		"an Engine nobody identified reached the plan",
	)
	assert(len(engine_path) > 0, "an Engine nobody named reached the plan")

	inventory = planning.discover(
		[]string{root},
		planning.Walk{on_progress = walked, follow_reparse_points = follow},
		context.allocator,
	)
	fmt.eprintln()

	plan, runnable = planning.plan_batch(
		inventory,
		planning.Settings {
			engine_version = engine_digest,
			engine_path = engine_path,
			model = identified,
			beam = artifact.ENGINE_DEFAULT_BEAM,
			merge_profile = transcript.profile_name(profile),
			prompt = prompt,
		},
		context.allocator,
	)
	return
}

@(private)
print_plan :: proc(plan: planning.Plan, inventory: planning.Inventory) {
	assert(
		len(plan.entries) == len(inventory.found),
		"a plan that lost a Recording on the way here",
	)

	for entry in plan.entries {
		pipeline.report_line(planning.plan_line(entry, context.allocator), context.allocator)
	}
	for note in inventory.notes {
		pipeline.report_fault(planning.note_line(note, context.allocator), context.allocator)
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
		assert(len(o.engine) > 0, "accepted a command line naming no Engine")
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

	for missing in ([?][2]string {
			{o.root, PLAN},
			{o.model, "--model-file"},
			{o.engine, "--engine-exe"},
		}) {
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
	case "--engine-exe":
		o.engine = value
	case "--prompt":
		o.prompt = value
	case "--follow-reparse-points":
		return read_follow(&o.follow, value)
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
