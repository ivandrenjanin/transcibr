#+vet explicit-allocators
package main

// --doctor: the preflight check story 8 asks for. Every decision -- what
// passes, what an actionable reason says -- is transcibr:doctor's; what is
// here is argument reading, wiring the shared spawner, and a write.
//
// Issue #189: --doctor identifies the Engine binary the same way --batch,
// --plan and --transcribe already do, through the shared `engine_identified`
// (main.odin) -- never a second identification path -- so a doctor pass and
// a Batch pass over the same binary report the same digest (ADR-0037,
// ADR-0038). An unreadable binary is refused before any check runs, the same
// A8 shape run_batch_command already refuses one with.

import "transcibr:audio"
import "transcibr:child"
import "transcibr:doctor"
import "transcibr:pipeline"

DOCTOR :: "--doctor"

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

	engine_digest, engine_named := engine_identified(o.engine)
	defer delete(string(engine_digest), context.allocator)
	if !engine_named {
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
