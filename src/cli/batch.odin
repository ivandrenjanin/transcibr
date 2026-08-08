#+vet explicit-allocators
package main

// --batch: the one command that runs a whole folder of Recordings end to
// end, resumable and interruptible. Discovery, planning, the sweep and the
// pipeline are all transcibr:planning's, transcibr:audio's and
// transcibr:pipeline's; what is here is argument reading, wiring the shared
// spawner and the Ctrl+C handler, and a write.

import "core:fmt"
import "core:sync"
import win32 "core:sys/windows"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:cliargs"
import "transcibr:engine"
import "transcibr:pipeline"
import "transcibr:planning"
import "transcibr:process"

// The two-field ceiling handoff ADR-0038's addendum resolves the ADR's own
// "ceiling-lookup placement" wrinkle with: cliargs' read loop now owns the
// per-option dispatch, so src/cli can no longer resolve a ceiling
// "immediately before" it the way the ADR's original sketch had -- both
// ceilings are resolved once, up front, into an enum-keyed Worker_Ceilings
// value the compiler checks for completeness at THIS composite literal.
// pipeline.MAX_EXTRACT_WORKERS and pipeline.MAX_QUEUE_DEPTH are already `::`
// constants, so this needs no runtime pipeline.worker_option_ceiling lookup
// at all -- an omission here (a Worker_Option member left unfilled) fails
// the build. A SWAP of the two rows below does not: the compiler checks
// completeness, not which value sits at which correctly-labelled key, so a
// swap of these two lines is caught by review alone, same as any other
// mis-copied value at a correct key (ADR-0038 addendum, PR #212 fix round 1).
BATCH_WORKER_CEILINGS :: cliargs.Worker_Ceilings {
	.Extract_Workers = pipeline.MAX_EXTRACT_WORKERS,
	.Queue_Depth     = pipeline.MAX_QUEUE_DEPTH,
}

// Issue #249 item 4: `run_batch_command` used to call `main.odin`'s shared,
// unparametrized `model_identified`/`engine_identified`, the last two
// callers of a pair the doctor/plan/transcribe convergence left otherwise
// unused. `process.BATCH_CANNOT_START` is `engine_identified_framed` and
// `model_identified_framed`'s own default framing (src/process/batch_setup.odin),
// so passing it here explicitly changes no byte `--batch` prints; it only
// means every command now identifies an Engine or a Model through the same
// one pair of procedures, each with its own named framing.
BATCH_ENGINE_REFUSAL_FRAMING :: process.BATCH_CANNOT_START
BATCH_MODEL_REFUSAL_FRAMING :: process.BATCH_CANNOT_START

// `using parsed: cliargs.Batch_Options` promotes root, follow, the worker
// counts and every Common_Options field straight through; `audio_tools` is
// the defaulted audio.Tools this package builds from `parsed.tools`' two
// bare strings after the grammar returns, the same shape
// `transcribe.odin`'s own `Transcribe_Options` already carries (fix round 1,
// PR #201 finding 3).
//
// Issue #75 Stage 6 (s3/s5b deposits, "two-tools convergence"): `using`
// promotes `parsed.tools` too, so `o.tools` and `o.audio_tools` used to sit
// side by side, one undefaulted and one defaulted, both reachable under the
// same field access shape -- reading `o.tools.ffmpeg` where `o.audio_tools`
// was meant compiled clean and read the wrong string. `run_batch_command`
// zeroes `o.tools` immediately after building `audio_tools` from it, so a
// stray read of the promoted field comes back empty rather than a
// plausible-looking, silently-wrong path.
Batch_Options :: struct {
	using parsed: cliargs.Batch_Options,
	audio_tools:  audio.Tools,
}

// Written only by the console control handler and read only by the pipeline's
// own admission loop (`sync.atomic_load`, `run_batch`'s `admit_jobs`) -- the
// identical cross-thread-flag shape `transcibr:planning`'s `Walk.cancelled`
// already uses for the same reason.
@(private)
cancel_requested: bool

// ADR-0011's runtime half, lent out to the pipeline through `Health_Watch`
// and read and written there by the single transcription Worker.
// `run_the_batch` below resets it between Batches, from this thread rather
// than the Worker's, which is why the reset is an atomic store like the
// flag's own two accesses. `pipeline.Health_Watch`'s doc comment carries the
// whole story, including the `pipeline.bump` assert that holds ADR-0006's
// one-transcription-Worker invariant.
@(private)
gpu_health_checked: bool

// Set by the same Worker at the moment it aborts the Batch for an unhealthy
// GPU, distinct from `cancel_requested` -- which an operator's Ctrl+C also
// sets, and which `pipeline.batch_succeeded` reads as a successful stop on
// its own. Threaded into `Health_Watch.unhealthy` and read back through
// `pipeline.Summary.unhealthy`, which `batch_succeeded` now folds into its
// own verdict -- a round-4 review found the two endings told apart by a
// second check living here in `src/cli` instead, untested (ADR-0009 keeps
// this package to a bool-to-exit-code map) and unheld by anything: removing
// it left the full suite green.
@(private)
gpu_health_unhealthy: bool

// `"system"`, because Windows calls this from a thread transcibr never
// started, on no context of this program's own -- and needs none: an atomic
// store is `proc "contextless"`-safe, and nothing else happens here.
@(private)
@(require_results)
console_ctrl_handler :: proc "system" (dw_ctrl_type: win32.DWORD) -> win32.BOOL {
	switch dw_ctrl_type {
	case win32.CTRL_C_EVENT,
	     win32.CTRL_BREAK_EVENT,
	     win32.CTRL_CLOSE_EVENT,
	     win32.CTRL_LOGOFF_EVENT,
	     win32.CTRL_SHUTDOWN_EVENT:
		sync.atomic_store(&cancel_requested, true)
		return win32.BOOL(true)
	}
	return win32.BOOL(false)
}

@(require_results)
run_batch_command :: proc(arguments: []string) -> int {
	assert(len(arguments) > 0, "no arguments at all is the version banner, settled before this")
	assert(
		arguments[0] == cliargs.BATCH,
		"main dispatched a command line that does not open with --batch",
	)

	parsed, parsed_ok, refusal := cliargs.read_batch_options(arguments, BATCH_WORKER_CEILINGS)
	if !parsed_ok {
		_ = refuse(refusal)
		return USAGE_ERROR
	}

	o := Batch_Options {
		parsed      = parsed,
		audio_tools = audio_tools_of(parsed.tools),
	}
	o.tools = {}
	defaulted_batch(&o)
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
	if !swept_cache(o.cache) {
		return OPERATING_ERROR
	}

	identified, named := model_identified_framed(o.model, BATCH_MODEL_REFUSAL_FRAMING)
	defer artifact.destroy_model(identified, context.allocator)
	if !named {
		return OPERATING_ERROR
	}

	engine_digest, engine_named := engine_identified_framed(o.engine, BATCH_ENGINE_REFUSAL_FRAMING)
	defer delete(string(engine_digest), context.allocator)
	if !engine_named {
		return OPERATING_ERROR
	}

	return planned_and_run(&group, o, identified, engine_digest)
}

// Best-effort by construction (ADR-0023): a scratch cache another worker is
// actively using is not an error, so only a cache that will not even OPEN
// stops the Batch before it starts.
@(private)
@(require_results)
swept_cache :: proc(cache: string) -> bool {
	assert(len(cache) > 0, "there is no scratch cache here to open")

	if refused := audio.open_cache(cache, context.allocator); refused != .None {
		pipeline.report_fault(
			audio.cache_error_message(refused, cache, context.allocator),
			context.allocator,
		)
		return false
	}
	taken, fault := audio.sweep_cache(cache, audio.DEFAULT_SWEEP_LIMITS, context.allocator)
	if fault != .None {
		pipeline.report_fault(
			audio.cache_error_message(fault, cache, context.allocator),
			context.allocator,
		)
		return false
	}
	fmt.eprintfln("  swept %d stale file(s) from %s", taken, cache)
	return true
}

@(private)
@(require_results)
planned_and_run :: proc(
	group: ^child.Job_Object,
	o: Batch_Options,
	identified: artifact.Model,
	engine_digest: artifact.Digest,
) -> int {
	assert(group != nil, "a child started outside a job object outlives transcibr")

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
	if !runnable {
		print_plan(plan, inventory)
		return plan_verdict(plan, inventory, runnable)
	}

	return run_the_batch(group, o, identified, engine_digest, plan)
}

@(private)
@(require_results)
run_the_batch :: proc(
	group: ^child.Job_Object,
	o: Batch_Options,
	identified: artifact.Model,
	engine_digest: artifact.Digest,
	plan: planning.Plan,
) -> int {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(o.extract_workers > 0, "run_recordings' own ceiling assert is unpaired without this")
	assert(o.queue_depth > 0, "run_recordings' own ceiling assert is unpaired without this")

	sync.atomic_store(&cancel_requested, false)
	sync.atomic_store(&gpu_health_checked, false)
	sync.atomic_store(&gpu_health_unhealthy, false)
	win32.SetConsoleCtrlHandler(console_ctrl_handler, true)
	defer win32.SetConsoleCtrlHandler(console_ctrl_handler, false)

	summary := pipeline.run_recordings(
		plan,
		pipeline.Batch_Options {
			group = group,
			tools = pipeline.Tools {
				audio = o.audio_tools,
				engine = engine.Tools{engine = o.engine},
			},
			cache = o.cache,
			model = identified,
			prompt = o.prompt,
			engine_version = string(engine_digest),
			profile = o.profile,
			config = pipeline.Config {
				extract_workers = o.extract_workers,
				queue_depth = o.queue_depth,
				join_bound_ms = pipeline.DEFAULT_JOIN_BOUND_MS,
			},
			health = pipeline.Health_Watch {
				checked = &gpu_health_checked,
				abort = &cancel_requested,
				unhealthy = &gpu_health_unhealthy,
			},
		},
		context.allocator,
		&cancel_requested,
		pipeline.RECORDING_STAGES,
	)

	fmt.eprintfln(
		"  %d transcribed, %d re-rendered, %d failed, %d refused, %d skipped, %d cancelled",
		summary.transcribed,
		summary.rerendered,
		summary.failed,
		summary.refused,
		summary.skipped,
		summary.cancelled,
	)
	if !pipeline.batch_succeeded(summary) {
		return OPERATING_ERROR
	}
	return 0
}

// Called AFTER cliargs.read_batch_options returns, matching
// `transcribe.odin`'s own tool default: `--ffmpeg ""` is an ordinary shell
// invocation with an unset variable in it, and a default set only before the
// grammar's own read loop is overwritten by the empty value -- the grammar
// itself defaults neither the tools, the worker counts nor the follow flag
// (ADR-0038's import-closure section: `pipeline.DEFAULT_EXTRACT_WORKERS` and
// `pipeline.DEFAULT_QUEUE_DEPTH` are pipeline wiring, not grammar).
@(private)
defaulted_batch :: proc(o: ^Batch_Options) {
	assert(o != nil, "there is nothing here to put a default into")
	defer {
		assert(o.extract_workers > 0, "a default that was put back is still zero")
		assert(o.queue_depth > 0, "a default that was put back is still zero")
	}

	audio.defaulted_tools(&o.audio_tools)
	if o.extract_workers == 0 {
		o.extract_workers = pipeline.DEFAULT_EXTRACT_WORKERS
	}
	if o.queue_depth == 0 {
		o.queue_depth = pipeline.DEFAULT_QUEUE_DEPTH
	}
}
