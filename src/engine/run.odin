package engine

import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import "transcibr:child"
import "transcibr:process"

// This file starts the Engine, drains what it says while it runs, and reads back
// what it left. It is kept thin enough to inspect by reading: every branch in it
// either calls a decision next door or reports what the world said.
//
// AND IT IS A NEAR-VERBATIM SECOND COPY OF `transcibr:audio`'s run.odin,
// deliberately and for now (issue #33). The poll loop, `drain`, `took`, the `Run`
// enumeration, the `Ending` record and the `stopped`/`finished` pair are that
// file's shape with a Recording's tracker standing where its settling reading
// goes; what genuinely differs is what one chunk MEANS to the caller and what a
// bound expiry is called afterwards.
//
// The fix is not in this file. It is lifting the machinery into `transcibr:child`
// -- which already owns start/wait/stop/read_diagnostics/close and has the only
// real child suite in this repository -- and that moves three packages at once,
// so it is its own change and its own review rather than a pass on issue #9.
// Recorded here rather than in a pull request comment because this is where the
// next person meets it. A THIRD copy is the point at which this stops being a
// deferral and starts being the design.

// How long each poll of a running Engine waits before draining again.
//
// A QUARTER OF A SECOND, the same as `transcibr:audio`'s and for the same two
// reasons. It has to stay well under the pipe filling, and the pipe is 64 KiB
// against an Engine that writes a few kilobytes over a whole Recording
// (ADR-0004). And it decides how often the display can move, which at four polls
// a second is far more often than a bar with a hundred positions can show.
@(private)
POLL_MS :: u32(250)

// How much is taken off the pipe at a time.
//
// ON THE STACK and never allocated: it lives inside one drain, and the lines
// read out of it are copied into the reader's own buffer before anything
// downstream sees them.
@(private)
DRAIN_BYTES :: 4096

// And how much ONE DRAIN may take in total before its caller is let back in.
//
// The ceiling that keeps the poll loop's own two bounds reachable: while a drain
// runs, neither the watchdog nor the run bound is checked, so a drain that never
// returned would be an Engine nothing ever stops. See `drain`.
//
// A MEGABYTE, which is sixteen times the 64 KiB pipe and four megabytes a second
// at four polls -- so a healthy Engine, which writes a few kilobytes over a whole
// Recording (ADR-0004), never reaches it, and one flooding the stream is drained
// far faster than it can be filled. A child that somehow writes faster than that
// blocks on its own pipe, which is throttling and not the wedge ADR-0004
// measured: the pipe is still being emptied every quarter of a second.
@(private)
MAX_DRAIN_BYTES :: 1 << 20

#assert(MAX_DRAIN_BYTES > DRAIN_BYTES)

// How one bounded run of the Engine ended.
@(private)
Run :: enum u8 {
	// It never started. `Ending.child` says why.
	Not_Started = 0,
	// It exited by itself.
	Finished,
	// It had to be stopped, and it stopped.
	Stopped,
	// It had to be stopped and WOULD NOT. It may still be running and may still
	// hold its output file open, which is why nothing may touch that file
	// (CLAUDE.md's rule on stopping a child).
	Unstoppable,
}

// Everything one run left the caller to decide with.
//
// THE EXIT CODE IS NOT IN HERE, and its absence is the decision: ADR-0002
// measured that exit code zero means nothing, so what settles a Recording is
// what the Engine actually produced. `transcibr:audio` records the same absence
// for the same reason.
@(private)
Ending :: struct {
	run:         Run,
	// True where the run was stopped because the Engine had gone SILENT rather
	// than because its bound ran out. Two different failures for the caller: one
	// is an Engine that is too slow for the time it was given, the other is one
	// that has stopped doing anything at all.
	silent:      bool,
	// The length the run keyed on: the Engine's banner where it said one, and
	// the container probe's answer otherwise.
	duration_ms: i64,
	child:       child.Error,
}

// The monotonic reading `transcibr:process`'s tracker counts in: nanoseconds
// since this invocation started, offset by one so the first reading is positive.
//
// A TICK AND NOT A WALL CLOCK, which that package requires and says why: a time
// service stepping the clock back mid-Recording would make the elapsed time
// negative, and that is one of the few readings in this program that comes from
// nowhere outside it.
@(private)
elapsed_ns :: proc(started: time.Tick) -> i64 {
	reading := 1 + i64(time.duration_nanoseconds(time.tick_since(started)))
	assert(reading > 0, "a monotonic counter that went backwards or has not started")
	return reading
}

// Runs the Engine over one Recording's audio and answers with what it left in
// the scratch cache.
//
// A8: every refusal here is an operating error against this one Recording, and
// the Batch carries on (ADR-0002). Nothing about the Engine's own behaviour --
// its exit code, its diagnostics, the file it did or did not write -- reaches an
// assertion.
transcribe :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	job: Job,
	report: Report,
	allocator: mem.Allocator,
	limits := DEFAULT_LIMITS,
) -> (
	produced: Transcribed,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(job.name) > 0, "a Recording with no artifact stem has nowhere to put its output")
	assert(len(job.cache) > 0, "the Engine may write into the scratch cache and nowhere else")
	assert(allocator.procedure != nil, "an Engine invocation needs an allocator to work in")
	// The container probe's answer, and a positive one: `transcibr:audio` refuses
	// a Recording whose container cannot be timed before any GPU time is spent on
	// it, so a Recording reaching here with no length is this program losing it
	// rather than a container nobody could read.
	assert(job.container_ms > 0, "a Recording nobody could time reached the Engine")

	prefix := fmt.aprintf("%s\\%s", job.cache, job.name, allocator = allocator)
	defer delete(prefix, allocator)
	// BEFORE anything is started, because the Engine's own answer to a path it
	// cannot open is to spend the GPU time, write nothing and exit zero
	// (ADR-0002) -- so a Recording refused here costs nothing, and one refused by
	// the Engine costs minutes and says nothing.
	if !openable_by_the_engine(job, prefix) {
		return {}, Error{fault = .Path_Not_Ascii}
	}
	arguments := process.engine_arguments(
		process.Engine_Job{model = job.model, audio = job.audio, prefix = prefix},
		allocator,
	)
	defer delete(arguments, allocator)

	ending := run_engine(group, tools.engine, arguments, job, report, limits, allocator)
	output := process.engine_output_path(prefix, allocator)
	defer if err.fault != .None {
		delete(output, allocator)
	}

	if refusal := refused(ending); refusal.fault != .None {
		return {}, refusal
	}
	// Past here the Engine is gone and what it left is transcibr's to read back.
	// The exit code is deliberately not consulted (ADR-0002).
	if missing := landed(output); missing != .None {
		return {}, Error{fault = missing}
	}
	return Transcribed{output = output, duration_ms = ending.duration_ms}, Error{}
}

// Whether every path this invocation is about to hand the Engine is one the
// Engine can open (ADR-0002).
//
// ALL THREE, and a check on one of them is a check on none: the Model comes from
// settings, the audio and the output prefix are both named from the Recording's
// own stem (ADR-0008), and any one of the three carrying a byte outside ASCII
// produces the same silent nothing at exit code zero.
//
// Three `if`s and not one conjunction, which is rule S2's own remedy: every case
// is visible, and the day one of them earns a fault of its own there is a line
// to put it on.
//
// THE SCRATCH CACHE IS NOT CHECKED HERE, and its absence is deliberate rather
// than an omission. It is one directory for the whole Batch, `open_cache`
// answers about it once before any Recording starts, and the prefix below is
// built from it -- so a cache the Engine cannot open is caught here too, by a
// Recording, after the Batch should already have refused to start.
@(private)
openable_by_the_engine :: proc(job: Job, prefix: string) -> bool {
	assert(len(prefix) > 0, "the Engine was given nowhere to write its output")

	if !process.ascii_only(job.model) {
		return false
	}
	if !process.ascii_only(job.audio) {
		return false
	}
	if !process.ascii_only(prefix) {
		return false
	}
	return true
}

// One ending, as the Recording's failure or as nothing at all.
//
// A SWITCH AND NOT THREE `if`s WITH AN ASSERT AFTER THEM, the shape
// `transcibr:audio` settled on: both cover the four endings, and only one of
// them makes a FIFTH ending a build failure rather than a crash on the Recording
// that first met it.
@(private)
refused :: proc(ending: Ending) -> Error {
	switch ending.run {
	case .Not_Started:
		return Error{fault = .Not_Started, child = ending.child}
	case .Unstoppable:
		// The output file is NOT touched and is not even asked about. The Engine
		// may still be running and may still hold it open, and CLAUDE.md's rule
		// for stopping a child is not to touch a file it had open until the wait
		// completes. The cache sweep takes it on age instead.
		return Error{fault = .Not_Stopped}
	case .Stopped:
		// Which of the two it was is what the caller can act on: an Engine too
		// slow for the time it was given is a Recording to re-run with a longer
		// bound, and one that stopped saying anything is a wedge (ADR-0012).
		return Error{fault = .Went_Silent if ending.silent else .Did_Not_Finish}
	case .Finished:
	// The Engine exited by itself, which says nothing about whether it did
	// anything (ADR-0002). The disk settles it.
	}
	return Error{}
}

// Whether the Engine's output is there and has anything in it.
//
// NO ALLOCATOR AND ONE OPEN, so the length belongs to the same file the handle
// does: a stat taken separately can name a file something has replaced in
// between.
@(private)
landed :: proc(output: string) -> Fault {
	assert(len(output) > 0, "there is nowhere here to look for the Engine's output")

	handle, unopenable := os.open(output)
	if unopenable != nil {
		return .No_Output
	}
	defer os.close(handle)

	length, unmeasurable := os.file_size(handle)
	if unmeasurable != nil {
		return .No_Output
	}
	// Both halves (A3): a file that is not there at all, and one that is there
	// and says nothing. The second is what a full disk leaves, and the next run
	// must not find it and take it for finished work (ADR-0002).
	if length == 0 {
		return .Output_Empty
	}
	return .None
}

// Starts the Engine and drains it until it exits, its bound runs out, or it
// stops saying anything at all.
@(private)
run_engine :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	job: Job,
	report: Report,
	limits: Limits,
	allocator: mem.Allocator,
) -> (
	ending: Ending,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(arguments) > 0, "the Engine was started with no arguments at all")

	// The Recording's own bound where nobody named one, which is every caller but
	// a case. Worked out BEFORE the child starts, so a bound nobody could compute
	// is a crash with no child running rather than one holding the GPU.
	bound_ms := limits.bound_ms
	if bound_ms <= 0 {
		bound_ms = process.transcribe_bound_ms(job.container_ms)
	}
	assert(bound_ms > 0, "an Engine given no time at all cannot transcribe anything")

	c, refusal := child.start(group, executable, arguments, allocator)
	if refusal.fault != .None {
		return Ending{run = .Not_Started, child = refusal}
	}
	defer child.close(&c)

	started := time.tick_now()
	tracker := process.tracker_start(job.container_ms, elapsed_ns(started))
	reader: process.Line_Reader
	// What the display was last told, and a reading no `shown` can answer, so the
	// first poll always paints. See `tell`.
	painted := process.Progress {
		percent = UNPAINTED,
	}
	for {
		if !drain(&c, &tracker, &reader, started) {
			// A pipe that cannot be read IS the wedge ADR-0004 measured,
			// arriving early: an undrained pipe stops the Engine dead with no
			// error anywhere, so polling to the bound would turn a failure
			// detectable in milliseconds into hours of nothing happening.
			return stopped(&c, false, tracker.duration_ms)
		}
		// ONE CLOCK READING, and both bounds keyed on it. The watchdog and the run
		// bound read two different instants either side of a console write, so a
		// display that took a moment to paint moved one of them and not the other
		// and the two were answering about different runs. The cost of reading it
		// before the wait below is that the bound is honoured to within one poll,
		// which is already this loop's whole resolution.
		now_ns := elapsed_ns(started)
		now := process.shown(tracker, now_ns, limits.watch)
		tell(report, now, &painted)
		if now.silent {
			return stopped(&c, true, tracker.duration_ms)
		}
		if child.wait(&c, POLL_MS) {
			return finished(&c, &tracker, &reader, started, report, limits.watch, &painted)
		}
		if now_ns / 1_000_000 > bound_ms {
			return stopped(&c, false, tracker.duration_ms)
		}
	}
}

// The last drain, after the Engine has exited.
//
// The pipe outlives the child that wrote to it, and the readings worth having
// most are the ones written just before exit -- the last progress line and the
// timings behind it. A caller that stopped at the exit would show a Recording
// frozen at whatever the second-to-last poll caught.
@(private)
finished :: proc(
	c: ^child.Child,
	tracker: ^process.Tracker,
	reader: ^process.Line_Reader,
	started: time.Tick,
	report: Report,
	watch: process.Watch,
	painted: ^process.Progress,
) -> Ending {
	assert(c != nil, "there is no child here to read out")
	assert(tracker != nil, "there is no Recording here to track")

	// The answer is not read: whatever is left is a bonus, and an Engine that has
	// already exited cannot be wedged by a pipe nobody drained.
	_ = drain(c, tracker, reader, started)
	tell(report, process.shown(tracker^, elapsed_ns(started), watch), painted)
	return Ending{run = .Finished, duration_ms = tracker.duration_ms}
}

// Stops an Engine that has to go, and says whether it went.
//
// The answer is the one thing the caller has to know: CLAUDE.md's rule for
// stopping a child is "do not touch any file the child had open until the wait
// completes", and `stop` returning false is exactly the report that it did not.
@(private)
stopped :: proc(c: ^child.Child, silent: bool, duration_ms: i64) -> Ending {
	assert(c != nil, "there is no child here to stop")

	return Ending {
		run = .Stopped if child.stop(c) else .Unstoppable,
		silent = silent,
		duration_ms = duration_ms,
	}
}

// Everything the Engine has said so far, read into the tracker. False means the
// pipe could not be read.
//
// tracker_heard is called for EVERY read that produced bytes, whether or not any
// of them read as a line: the watchdog's question is whether the child is alive,
// and an Engine writing its model-load log is alive whether or not this program
// understands a word of it (ADR-0012).
//
// BOUNDED, and it was THE ONE UNBOUNDED LOOP IN A BOUNDED RUN. It used to stop
// only on a pipe error, on end of stream, or on a pipe that happened to be empty
// when it was asked -- and while it ran, neither the watchdog nor the run bound
// in the poll loop above was reached. An Engine that entered a diagnostic loop
// would therefore never be stopped at all: the wedge that holds a Batch for ever
// (issue #27) and holds the one GPU worker with it (ADR-0006), arriving on the
// one stream this program can actually see. What stops it is a ceiling on how
// much one drain may take before its caller is let back in to look at its
// bounds; whatever is left stays in the pipe for the next poll, a quarter of a
// second later.
@(private)
drain :: proc(
	c: ^child.Child,
	tracker: ^process.Tracker,
	reader: ^process.Line_Reader,
	started: time.Tick,
) -> (
	readable: bool,
) {
	assert(c != nil, "there is no child here to read")
	assert(tracker != nil, "there is no Recording here to track")
	assert(reader != nil, "there is nowhere to assemble the child's lines")

	buffer: [DRAIN_BYTES]u8 = ---
	taken := 0
	for taken < MAX_DRAIN_BYTES {
		read, at_end, reading := child.read_diagnostics(c, buffer[:])
		if reading.fault != .None {
			return false
		}
		if read > 0 {
			assert(read <= len(buffer), "the pipe wrote past the end of the buffer it was given")
			took(tracker, reader, string(buffer[:read]), elapsed_ns(started))
			taken += read
		}
		if at_end {
			// Whatever the Engine wrote with no newline behind it is still what
			// it said, and the last thing it says is the last reading there is.
			if line, held := process.last_line(reader); held {
				process.tracker_said(tracker, process.read_engine_line(line), elapsed_ns(started))
			}
			return true
		}
		if read == 0 {
			return true
		}
	}
	// The ceiling, and not end of stream: whatever is still in the pipe is read by
	// the next poll. Nothing is dropped and nothing is at an end, so the caller is
	// told the pipe is readable -- which it is.
	assert(taken >= MAX_DRAIN_BYTES, "a drain left its loop with room to spare")
	return true
}

// One chunk off the pipe, as bytes the watchdog counts and lines the display
// reads.
@(private)
took :: proc(tracker: ^process.Tracker, reader: ^process.Line_Reader, chunk: string, now_ns: i64) {
	assert(tracker != nil, "there is no Recording here to track")
	assert(len(chunk) > 0, "a read that took nothing was reported as the Engine talking")

	process.tracker_heard(tracker, len(chunk), now_ns)
	remaining := chunk
	for {
		line, ok := process.next_line(reader, &remaining)
		if !ok {
			return
		}
		process.tracker_said(tracker, process.read_engine_line(line), now_ns)
	}
}

// A percentage no `shown` can ever answer, so the first poll of a run always
// paints. Below zero, which `tell` refuses on the way in.
@(private)
UNPAINTED :: -1

#assert(UNPAINTED < 0)

// Tells whoever is watching, where anybody is AND anything has changed.
//
// ONLY ON A CHANGE. This is called four times a second for the whole of a
// Recording, and the display it drives repaints one line: a three-hour Recording
// is 43,200 console writes to show the forty-odd distinct frames a bar with a
// hundred positions and three annotations can have. The reading is compared
// whole -- the percentage, where the number came from, and whether the run has
// gone silent -- so a bar that stopped moving but started saying `(waiting)` is
// still a change and is still painted.
@(private)
tell :: proc(report: Report, shown: process.Progress, painted: ^process.Progress) {
	assert(painted != nil, "there is nowhere to remember what the display was last told")
	assert(shown.percent >= 0, "a display was handed a negative percentage")
	assert(shown.percent <= 100, "a display was handed a percentage past a hundred")

	if shown == painted^ {
		return
	}
	painted^ = shown
	if report.on_progress == nil {
		return
	}
	report.on_progress(shown, report.user)
}
