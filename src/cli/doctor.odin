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
// Batch was ever asked for. `--plan` and `--transcribe` migrated to
// `engine_identified_framed` (src/cli/engine_identify.odin) at #245's
// review; issue #249 item 4 closed the last gap -- `--doctor` calls the same
// shared helper below rather than a byte-identical private copy of its own,
// and `--batch` (`src/cli/batch.odin`) now passes its own framing to it too,
// so `main.odin` no longer carries a second, unparametrized pair of
// wrappers beside it.
//
// Issue #75 Stage 5b: --doctor's grammar (Doctor_Options, read_doctor_options,
// read_doctor_option) moved to transcibr:cliargs, the fifth and last of the
// ruled-in migration sites (ADR-0038's ruling comment on #75). `DOCTOR` is
// now `cliargs.DOCTOR`, declared once, so main.odin's dispatch and this
// file's own command wiring cannot drift the way #75's stage-5 deposit
// measured for `BATCH` (main.odin no longer holds a second `--doctor`
// spelling of its own to drift against cliargs' copy). `using parsed:
// cliargs.Doctor_Options` promotes model, engine and the two-string tools
// struct straight through; `audio_tools` is the defaulted audio.Tools this
// package builds from `parsed.tools`' two bare strings after the grammar
// returns, the same shape `batch.odin`'s and `transcribe.odin`'s own
// Options structs already carry.

import "transcibr:audio"
import "transcibr:child"
import "transcibr:cliargs"
import "transcibr:crashlog"
import "transcibr:doctor"
import "transcibr:pipeline"

// Issue #249 item 5: an unreadable Engine used to be reported twice -- the
// preflight "engine" row on stdout (`doctor.engine_check`, its own
// spawn-probe vocabulary) and this identity refusal on stderr
// (`artifact.Engine_Fault`'s hash-read vocabulary), two different sentences
// for the same underlying fact. Both streams stay: the preflight row is
// diagnostic detail a script never has to parse, and the identity refusal on
// stderr is the one line `an_unreadable_engine_refusal_names_doctor_and_not_the_batch`
// (src/doctor/identity_cli_test.odin) already pins for automation. Pointing
// the stderr line back at the row above is the "one voice" the ticket asks
// for without reshaping either vocabulary or the shared
// `engine_identified_framed` helper both --doctor and --plan/--transcribe
// now call.
DOCTOR_ENGINE_REFUSAL_FRAMING :: "--doctor cannot verify this Engine -- see the engine row above"

// Issue #75 Stage 6 ("two-tools convergence"): `run_doctor` zeroes the
// promoted `tools` field right after `audio_tools` is built from it -- see
// `batch.odin`'s own `Batch_Options` comment for why.
Doctor_Options :: struct {
	using parsed: cliargs.Doctor_Options,
	audio_tools:  audio.Tools,
}

// Unlike TRANSCRIBE, PLAN and BATCH, this flag names no Recording or folder
// of its own, so `main` strips it before handing the rest of the command
// line here -- every remaining argument is a plain name/value pair, with
// nothing at position zero standing in for a value it does not have.
@(require_results)
run_doctor :: proc(arguments: []string) -> int {
	parsed, parsed_ok, refusal := cliargs.read_doctor_options(arguments)
	if !parsed_ok {
		_ = refuse(refusal)
		return USAGE_ERROR
	}

	o := Doctor_Options {
		parsed      = parsed,
		audio_tools = audio_tools_of(parsed.tools),
	}
	o.tools = {}
	audio.defaulted_tools(&o.audio_tools)
	assert(
		len(o.audio_tools.ffmpeg) > 0,
		"accepted a command line that unset ffmpeg's own default",
	)
	assert(
		len(o.audio_tools.ffprobe) > 0,
		"accepted a command line that unset ffprobe's own default",
	)

	group, opened := job_object_opened()
	defer child.job_object_close(&group)
	if !opened {
		return OPERATING_ERROR
	}

	checks := doctor.run_preflight(
		&group,
		doctor.Options {
			ffmpeg = o.audio_tools.ffmpeg,
			ffprobe = o.audio_tools.ffprobe,
			engine = o.engine,
			model = o.model,
		},
		context.allocator,
	)
	defer doctor.destroy_report(checks, context.allocator)

	for check in checks {
		pipeline.report_line(doctor.render_check(check, context.allocator), context.allocator)
	}

	engine_digest, engine_named := engine_identified_framed(
		o.engine,
		DOCTOR_ENGINE_REFUSAL_FRAMING,
	)
	defer delete(string(engine_digest), context.allocator)
	if !engine_named {
		crashlog.note(.Warn, "doctor", "the Engine could not be verified")
		return OPERATING_ERROR
	}
	pipeline.report_line(
		doctor.render_engine_identity(engine_digest, context.allocator),
		context.allocator,
	)

	if !doctor.report_ok(checks) {
		crashlog.note(.Warn, "doctor", "one or more checks failed")
		return OPERATING_ERROR
	}
	crashlog.note(.Info, "doctor", "all checks passed")
	return 0
}
