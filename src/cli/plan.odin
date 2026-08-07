#+vet explicit-allocators
package main

import "core:fmt"
import "transcibr:artifact"
import "transcibr:cliargs"
import "transcibr:pipeline"
import "transcibr:planning"
import "transcibr:transcript"

// The dry run: walk a folder tree and print what a Batch would do to it,
// spending no GPU time at all. Every decision, every sentence and every refusal
// is `transcibr:planning`'s; what is here is argument reading and a write.

// Issue #216, item 1: `--plan` used to identify the Engine through
// `main.odin`'s shared `engine_identified`, which built its refusal by
// calling `artifact.engine_error_message` with no framing of its own -- so
// an unreadable Engine told a `--plan` user "the Batch cannot start" when no
// Batch was ever asked for (measured byte-identical to merge-base at the
// #237 review). `plan_engine_identified` below is the #237 doctor shape's
// second call site: it calls the same `artifact.identify_engine` hasher
// `engine_identified` does (ADR-0037's digest-agreement property is about
// the hasher, not the cli wrapper), but supplies `--plan`'s own framing
// rather than inheriting the Batch's. `main.odin` is fenced under #75-s5b,
// so this is a second call site here rather than a parameter added to the
// shared one.
PLAN_ENGINE_REFUSAL_FRAMING :: "--plan cannot verify this Engine"

// The same shape as `main.odin`'s `engine_identified`, with one deliberate
// difference: the framing passed to `artifact.engine_error_message`. See the
// issue #216 note above for why this is a second call site and not a second
// hasher.
@(private)
@(require_results)
plan_engine_identified :: proc(path: string) -> (identified: artifact.Digest, ok: bool) {
	assert(len(path) > 0, "there is no Engine here to identify")

	unidentified: artifact.Engine_Fault
	identified, unidentified = artifact.identify_engine(path, context.allocator)
	if unidentified == .None {
		return identified, true
	}

	message := artifact.engine_error_message(
		unidentified,
		path,
		context.allocator,
		PLAN_ENGINE_REFUSAL_FRAMING,
	)
	assert(len(message) > 0, "an Engine was refused and nothing said why")
	pipeline.report_fault(message, context.allocator)
	return identified, false
}

// `--engine-exe` is mandatory, the same as `--model-file`: the Engine is
// identified by its own SHA-256, exactly the way the Model is (ADR-0027's
// reopening clause, closed by issue #50), so there is no absent case for
// this package to decide about any more.
Plan_Options :: cliargs.Plan_Options

@(require_results)
plan_batch :: proc(arguments: []string) -> int {
	assert(len(arguments) > 0, "no arguments at all is the version banner, settled before this")
	assert(
		arguments[0] == cliargs.PLAN,
		"main dispatched a command line that does not open with --plan",
	)

	o, ok, refusal := cliargs.read_plan_options(arguments)
	if !ok {
		_ = refuse_cliargs(refusal)
		return USAGE_ERROR
	}

	fmt.eprintfln("  identifying %s", o.model)
	identified, named := model_identified(o.model)
	defer artifact.destroy_model(identified, context.allocator)
	if !named {
		return OPERATING_ERROR
	}

	fmt.eprintfln("  identifying %s", o.engine)
	engine_digest, engine_named := plan_engine_identified(o.engine)
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
