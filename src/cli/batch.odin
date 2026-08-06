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
import "transcibr:engine"
import "transcibr:pipeline"
import "transcibr:planning"
import "transcibr:process"
import "transcibr:transcript"

BATCH :: "--batch"

Batch_Options :: struct {
	root:            string,
	model:           string,
	engine:          string,
	cache:           string,
	engine_version:  Maybe(string),
	prompt:          string,
	profile:         transcript.Merge_Profile,
	follow:          bool,
	tools:           audio.Tools,
	extract_workers: int,
	queue_depth:     int,
}

// Written only by the console control handler and read only by the pipeline's
// own admission loop (`sync.atomic_load`, `run_batch`'s `admit_jobs`) -- the
// identical cross-thread-flag shape `transcibr:planning`'s `Walk.cancelled`
// already uses for the same reason.
@(private)
cancel_requested: bool

// ADR-0011's runtime half: written only by the transcription Worker,
// sequentially -- see `pipeline.Health_Watch`'s own doc comment for why that
// needs no atomics of its own.
@(private)
gpu_health_checked: bool

// The A4 partner to `bump`'s assert in `src/pipeline/pipeline.odin` (commit
// 1c67c11): that one catches a second transcription Worker at the one place
// its own count changes, from inside the pipeline that spawns it. This one
// catches the shape of race `gpu_health_checked` itself cannot survive --
// two Batches reaching for the same non-atomic flag at once -- at the flag's
// own site, checked and held for exactly as long as `run_the_batch` is
// lending its address out through `Health_Watch.checked`.
@(private)
gpu_health_watch_in_use: bool

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
	assert(arguments[0] == BATCH, "main dispatched a command line that does not open with --batch")

	o, ok := read_batch_options(arguments)
	if !ok {
		return USAGE_ERROR
	}

	group, opening := child.job_object_open()
	defer child.job_object_close(&group)
	if opening.fault != .None {
		pipeline.report_fault(child.error_message(opening, context.allocator), context.allocator)
		return OPERATING_ERROR
	}
	if !swept_cache(o.cache) {
		return OPERATING_ERROR
	}

	identified, named := model_identified(o.model)
	defer artifact.destroy_model(identified, context.allocator)
	if !named {
		return OPERATING_ERROR
	}

	return planned_and_run(&group, o, identified)
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
) -> int {
	assert(group != nil, "a child started outside a job object outlives transcibr")

	inventory, plan, runnable := planned(
		o.root,
		identified,
		o.engine_version,
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

	return run_the_batch(group, o, identified, plan)
}

@(private)
@(require_results)
run_the_batch :: proc(
	group: ^child.Job_Object,
	o: Batch_Options,
	identified: artifact.Model,
	plan: planning.Plan,
) -> int {
	assert(
		!gpu_health_watch_in_use,
		"ADR-0006's one transcription Worker is asserted, not merely intended",
	)
	gpu_health_watch_in_use = true
	defer gpu_health_watch_in_use = false

	sync.atomic_store(&cancel_requested, false)
	gpu_health_checked = false
	sync.atomic_store(&gpu_health_unhealthy, false)
	win32.SetConsoleCtrlHandler(console_ctrl_handler, true)
	defer win32.SetConsoleCtrlHandler(console_ctrl_handler, false)

	summary := pipeline.run_recordings(
		plan,
		pipeline.Batch_Options {
			group = group,
			tools = pipeline.Tools{audio = o.tools, engine = engine.Tools{engine = o.engine}},
			cache = o.cache,
			model = identified,
			prompt = o.prompt,
			engine_version = pipeline.settled_engine_version(o.engine_version),
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

// Why not `strconv.parse_int`, which takes `_`, a sign and overflows in
// silence: CLAUDE.md, Odin notes. Three digits is generous against any
// machine's real core or disk count and refuses a mistyped, absurdly large
// one before it ever reaches `chan.create`.
//
// `--extract-workers` used to be refused against `pipeline.MAX_QUEUE_DEPTH`
// regardless of `ceiling` -- the shared constant happened to equal
// `pipeline.MAX_EXTRACT_WORKERS` today, so nothing was reachable, but a
// future drop in either ceiling independently of the other would have let an
// over-ceiling value sail past this refusal and crash at
// `pipeline.run_recordings`'s own assert instead (issue #94). Taking
// `ceiling` as a parameter, and `pipeline.worker_count_within_ceiling` doing
// the actual check, is what keeps a value outside EITHER OPTION'S OWN ceiling
// a refusal here (A8) instead of a crash at that assertion.
@(private)
@(require_results)
read_worker_count :: proc(value: string, ceiling: int) -> (count: int, ok: bool) {
	parsed, readable := process.read_natural(value, 3)
	if !readable || parsed <= 0 || !pipeline.worker_count_within_ceiling(int(parsed), ceiling) {
		return 0, false
	}
	return int(parsed), true
}

@(private)
@(require_results)
read_batch_options :: proc(arguments: []string) -> (o: Batch_Options, ok: bool) {
	defer if ok {
		assert(len(o.root) > 0, "accepted a command line with no folder to walk")
		assert(len(o.model) > 0, "accepted a command line naming no Model")
		assert(len(o.engine) > 0, "accepted a command line naming no Engine")
		assert(len(o.cache) > 0, "accepted a command line naming no scratch cache")
		assert(len(o.tools.ffmpeg) > 0, "accepted a command line that unset ffmpeg's own default")
		assert(
			len(o.tools.ffprobe) > 0,
			"accepted a command line that unset ffprobe's own default",
		)
		assert(
			o.extract_workers > 0,
			"accepted a command line that unset its worker-count default",
		)
		assert(o.queue_depth > 0, "accepted a command line that unset its queue-depth default")
	} else {
		assert(len(o.root) == 0, "refused a command line and kept what it asked for")
	}

	o.profile = transcript.DEFAULT_PROFILE

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			return {}, refuse("%q stands at the end of the command line with no value after it.", name)
		}
		if !read_batch_option(&o, name, arguments[at + 1]) {
			return {}, false
		}
	}

	defaulted_batch(&o)
	for missing in ([?][2]string {
			{o.root, BATCH},
			{o.model, "--model-file"},
			{o.engine, "--engine-exe"},
			{o.cache, "--cache"},
		}) {
		if len(missing[0]) == 0 {
			return {}, refuse("%s names nothing.", missing[1])
		}
	}
	return o, true
}

// `--batch`'s own cases are BATCH, the worker-count pair and
// `--follow-reparse-points`; everything else falls through to
// `read_common_option`, the grammar `--transcribe` reads the identical way
// (PR #67's review, finding 2).
@(private)
@(require_results)
read_batch_option :: proc(o: ^Batch_Options, name, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")

	switch name {
	case BATCH:
		o.root = value
	case "--extract-workers":
		return read_batch_worker_option(&o.extract_workers, name, value)
	case "--queue-depth":
		return read_batch_worker_option(&o.queue_depth, name, value)
	case "--follow-reparse-points":
		return read_follow(&o.follow, value)
	case:
		return read_common_option(
			&o.model,
			&o.engine,
			&o.cache,
			&o.tools,
			&o.engine_version,
			&o.prompt,
			&o.profile,
			name,
			value,
		)
	}
	return true
}

@(private)
@(require_results)
read_batch_worker_option :: proc(into: ^int, name, value: string) -> (ok: bool) {
	assert(into != nil, "there is nowhere here to read a worker count into")

	ceiling, registered := pipeline.worker_option_ceiling(name)
	assert(registered, "no ceiling registered for a worker option this switch dispatches")

	count, readable := read_worker_count(value, ceiling)
	if !readable {
		return refuse("%s takes a whole number from 1 to %d, not %q.", name, ceiling, value)
	}
	into^ = count
	return true
}

// Called AFTER the loop that reads the command line, matching
// `transcribe.odin`'s own tool default: `--ffmpeg ""` is an ordinary shell
// invocation with an unset variable in it, and a default set only before the
// loop is overwritten by the empty value.
@(private)
defaulted_batch :: proc(o: ^Batch_Options) {
	assert(o != nil, "there is nothing here to put a default into")
	defer {
		assert(o.extract_workers > 0, "a default that was put back is still zero")
		assert(o.queue_depth > 0, "a default that was put back is still zero")
	}

	audio.defaulted_tools(&o.tools)
	if o.extract_workers == 0 {
		o.extract_workers = pipeline.DEFAULT_EXTRACT_WORKERS
	}
	if o.queue_depth == 0 {
		o.queue_depth = pipeline.DEFAULT_QUEUE_DEPTH
	}
}
