#+vet explicit-allocators
package main

// --doctor: the preflight check story 8 asks for. Every decision -- what
// passes, what an actionable reason says -- is transcibr:doctor's; what is
// here is argument reading, wiring the shared spawner, and a write.
//
// Issue #189: --doctor identifies the Engine binary the same way --batch,
// --plan and --transcribe already do, through `artifact.identify_engine` --
// the same private `digest_of_bounded` hasher every one of them calls,
// never a second one -- so a doctor pass and a Batch pass over the same
// binary report the same digest (ADR-0037, ADR-0038).
//
// Fix round 1, finding 1: identifying the Engine runs AFTER `run_preflight`
// and its five rows print, and refuses OPERATING_ERROR only once they are
// already on the user's screen. `run.odin`'s own contract ("Every check runs
// even after an earlier one fails, so a user sees every actionable reason at
// once") held for the five Checks, but an unreadable Engine binary used to
// return before any of them ran at all -- suppressing the whole report on
// exactly the run --doctor exists for. An unreadable binary is still refused
// with OPERATING_ERROR, the same A8 shape run_batch_command already refuses
// one with; only the ORDER changed.
//
// Issue #216: `--doctor` used to identify through `main.odin`'s shared
// `engine_identified`, which built its refusal by calling
// `artifact.engine_error_message` with no framing of its own -- so an
// unreadable Engine told a doctor-pass user "the Batch cannot start" when no
// Batch was ever asked for. `doctor_engine_identified` below calls the same
// `artifact.identify_engine` hasher `engine_identified` does (the ADR-0037
// property above is unchanged: it is the hasher, not the cli wrapper, that
// has to be the one path), but supplies `--doctor`'s own framing rather than
// inheriting the Batch's. `main.odin` is fenced under #75-s5; `--plan` and
// `--transcribe` still route through its unparametrized `engine_identified`
// and keep the Batch's framing until their own fenced files migrate (#75
// deposit comment, PR body).

import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:doctor"
import "transcibr:pipeline"

DOCTOR :: "--doctor"

DOCTOR_ENGINE_REFUSAL_FRAMING :: "--doctor cannot verify this Engine"

// The same shape as `main.odin`'s `engine_identified`, with one deliberate
// difference: the framing passed to `artifact.engine_error_message`. See the
// issue #216 note above for why this is a second call site and not a second
// hasher.
@(private)
@(require_results)
doctor_engine_identified :: proc(path: string) -> (identified: artifact.Digest, ok: bool) {
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
		DOCTOR_ENGINE_REFUSAL_FRAMING,
	)
	assert(len(message) > 0, "an Engine was refused and nothing said why")
	pipeline.report_fault(message, context.allocator)
	return identified, false
}

// Unlike TRANSCRIBE, PLAN and BATCH, this flag names no Recording or folder
// of its own, so `main` strips it before handing the rest of the command
// line here -- every remaining argument is a plain name/value pair, with
// nothing at position zero standing in for a value it does not have.
@(require_results)
run_doctor :: proc(arguments: []string) -> int {
	o, ok := read_doctor_options(arguments)
	if !ok {
		return USAGE_ERROR
	}

	group, opened := job_object_opened()
	defer child.job_object_close(&group)
	if !opened {
		return OPERATING_ERROR
	}

	checks := doctor.run_preflight(
		&group,
		doctor.Options {
			ffmpeg = o.tools.ffmpeg,
			ffprobe = o.tools.ffprobe,
			engine = o.engine,
			model = o.model,
		},
		context.allocator,
	)
	defer doctor.destroy_report(checks, context.allocator)

	for check in checks {
		pipeline.report_line(doctor.render_check(check, context.allocator), context.allocator)
	}

	engine_digest, engine_named := doctor_engine_identified(o.engine)
	defer delete(string(engine_digest), context.allocator)
	if !engine_named {
		return OPERATING_ERROR
	}
	pipeline.report_line(
		doctor.render_engine_identity(engine_digest, context.allocator),
		context.allocator,
	)

	if !doctor.report_ok(checks) {
		return OPERATING_ERROR
	}
	return 0
}

Doctor_Options :: struct {
	model:  string,
	engine: string,
	tools:  audio.Tools,
}

@(private)
@(require_results)
read_doctor_options :: proc(arguments: []string) -> (o: Doctor_Options, ok: bool) {
	defer if ok {
		assert(len(o.model) > 0, "accepted a command line naming no Model")
		assert(len(o.engine) > 0, "accepted a command line naming no Engine")
		assert(len(o.tools.ffmpeg) > 0, "accepted a command line that unset ffmpeg's own default")
		assert(
			len(o.tools.ffprobe) > 0,
			"accepted a command line that unset ffprobe's own default",
		)
	} else {
		assert(len(o.model) == 0, "refused a command line and kept what it asked for")
	}

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			return {}, refuse("%q stands at the end of the command line with no value after it.", name)
		}
		if !read_doctor_option(&o, name, arguments[at + 1]) {
			return {}, false
		}
	}

	audio.defaulted_tools(&o.tools)
	for missing in ([?][2]string{{o.model, "--model-file"}, {o.engine, "--engine-exe"}}) {
		if len(missing[0]) == 0 {
			return {}, refuse("%s names nothing.", missing[1])
		}
	}
	return o, true
}

@(private)
@(require_results)
read_doctor_option :: proc(o: ^Doctor_Options, name, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")

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
		return refuse("unknown option %q.", name)
	}
	return true
}
