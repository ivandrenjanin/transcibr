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
import "transcibr:pipeline"
import "transcibr:planning"
import "transcibr:process"
import "transcibr:transcript"

BATCH :: "--batch"

// One or two extraction workers feeding exactly one transcription worker
// through a bounded channel of depth one or two (ADR-0006) -- the shipped
// defaults, overridable per Batch because a machine's disk and GPU are not
// this program's to assume.
DEFAULT_EXTRACT_WORKERS :: 1
DEFAULT_QUEUE_DEPTH :: 2

// How long shutdown waits for a worker to go idle once the last job has been
// admitted, before treating it as wedged rather than merely still working.
// Forty-five days is comfortably above any real Recording's own transcribe
// bound -- `process.transcribe_bound_ms` of even a full day of audio is a
// handful of days -- and comfortably below what `child.await_or_abandon`
// will accept at all.
BATCH_JOIN_BOUND_MS :: i64(45 * 24 * 60 * 60 * 1000)

Batch_Options :: struct {
	root:            string,
	model:           string,
	engine:          string,
	cache:           string,
	engine_version:  string,
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
		reason := child.error_message(opening, context.allocator)
		defer delete(reason, context.allocator)
		fmt.eprintln(reason)
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
		message := audio.cache_error_message(refused, cache, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return false
	}
	taken, fault := audio.sweep_cache(cache, audio.DEFAULT_SWEEP_LIMITS, context.allocator)
	if fault != .None {
		message := audio.cache_error_message(fault, cache, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
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
	sync.atomic_store(&cancel_requested, false)
	win32.SetConsoleCtrlHandler(console_ctrl_handler, true)
	defer win32.SetConsoleCtrlHandler(console_ctrl_handler, false)

	summary := pipeline.run_recordings(
		plan,
		pipeline.Batch_Options {
			group = group,
			tools = pipeline.Tools {
				ffmpeg = o.tools.ffmpeg,
				ffprobe = o.tools.ffprobe,
				engine = o.engine,
			},
			cache = o.cache,
			model = identified,
			prompt = o.prompt,
			engine_version = o.engine_version,
			profile = o.profile,
			config = pipeline.Config {
				extract_workers = o.extract_workers,
				queue_depth = o.queue_depth,
				join_bound_ms = BATCH_JOIN_BOUND_MS,
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
	if summary.failed > 0 || summary.refused > 0 {
		return OPERATING_ERROR
	}
	return 0
}

// Why not `strconv.parse_int`, which takes `_`, a sign and overflows in
// silence: CLAUDE.md, Odin notes. Three digits is generous against any
// machine's real core or disk count and refuses a mistyped, absurdly large
// one before it ever reaches `chan.create`.
//
// The ceiling used to be 64 for both `--extract-workers` and `--queue-depth`,
// silently contradicting the one spec sentence pipeline.run_recordings now
// asserts: ADR-0006 bounds a real Batch to one or two of each. Sharing
// `pipeline.MAX_QUEUE_DEPTH` here rather than a second copy of the number 2
// is what keeps a value outside it a refusal at the command line (A8) instead
// of a crash at that assertion -- both options take the same ceiling because
// ADR-0006 gives both the same bound.
@(private)
@(require_results)
read_worker_count :: proc(value: string) -> (count: int, ok: bool) {
	parsed, readable := process.read_natural(value, 3)
	if !readable || parsed <= 0 || parsed > i64(pipeline.MAX_QUEUE_DEPTH) {
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
		assert(len(o.engine_version) > 0, "an Engine nobody named is UNKNOWN, never empty")
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

@(private)
@(require_results)
read_batch_option :: proc(o: ^Batch_Options, name, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")

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
	case "--engine-version":
		o.engine_version = value
	case "--prompt":
		o.prompt = value
	case "--extract-workers":
		return read_batch_worker_option(&o.extract_workers, "--extract-workers", value)
	case "--queue-depth":
		return read_batch_worker_option(&o.queue_depth, "--queue-depth", value)
	case "--profile":
		profile, known := transcript.profile_named(value)
		if !known {
			return refuse("no merge profile called %q.", value)
		}
		o.profile = profile
	case "--follow-reparse-points":
		return read_batch_follow_option(o, value)
	case:
		return refuse("unknown option %q.", name)
	}
	return true
}

@(private)
@(require_results)
read_batch_worker_option :: proc(into: ^int, name, value: string) -> (ok: bool) {
	assert(into != nil, "there is nowhere here to read a worker count into")

	count, readable := read_worker_count(value)
	if !readable {
		return refuse(
			"%s takes a whole number from 1 to %d, not %q.",
			name,
			pipeline.MAX_QUEUE_DEPTH,
			value,
		)
	}
	into^ = count
	return true
}

@(private)
@(require_results)
read_batch_follow_option :: proc(o: ^Batch_Options, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")

	switch value {
	case FOLLOW_YES:
		o.follow = true
	case FOLLOW_NO:
		o.follow = false
	case:
		return refuse("--follow-reparse-points takes %s, not %q.", FOLLOW_CHOICE, value)
	}
	return true
}

// Called AFTER the loop that reads the command line, matching
// `transcribe.odin`'s own `defaulted`: `--ffmpeg ""` is an ordinary shell
// invocation with an unset variable in it, and a default set only before the
// loop is overwritten by the empty value.
@(private)
defaulted_batch :: proc(o: ^Batch_Options) {
	assert(o != nil, "there is nothing here to put a default into")
	defer {
		assert(len(o.tools.ffmpeg) > 0, "a default that was put back is still empty")
		assert(len(o.tools.ffprobe) > 0, "a default that was put back is still empty")
		assert(len(o.engine_version) > 0, "a default that was put back is still empty")
		assert(o.extract_workers > 0, "a default that was put back is still zero")
		assert(o.queue_depth > 0, "a default that was put back is still zero")
	}

	if len(o.tools.ffmpeg) == 0 {
		o.tools.ffmpeg = FFMPEG
	}
	if len(o.tools.ffprobe) == 0 {
		o.tools.ffprobe = FFPROBE
	}
	if len(o.engine_version) == 0 {
		o.engine_version = transcript.UNKNOWN
	}
	if o.extract_workers == 0 {
		o.extract_workers = DEFAULT_EXTRACT_WORKERS
	}
	if o.queue_depth == 0 {
		o.queue_depth = DEFAULT_QUEUE_DEPTH
	}
}
