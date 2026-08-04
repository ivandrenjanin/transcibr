package process

// This file is the progress display's own half of the Process contract: the
// chunks a child's diagnostic pipe hands back reassembled into lines, and -- in
// the second half of the file -- what the display should show given what the
// Engine has said and how long ago it last said anything.
//
// Pure like the rest of the package (ADR-0009). No clock is read here: every
// reading is HANDED IN, which is the shape `remaining_ms` in `transcibr:child`
// established and ADR-0018 wrote down, and it is what makes a child that has
// gone quiet, one that has gone silent and a deadline exactly reached into
// values a case can produce rather than states a test would have to wait for.

// The longest diagnostic line this package will hold, in bytes.
//
// FIXED AND NEVER GROWN, which is the point rather than a limitation. Everything
// on this stream is outside the program (A8), so a child that writes ten
// megabytes with no newline in it must cost a bounded amount of memory and
// degrade the progress bar -- not exhaust the machine, and not wedge the child
// by making the drain slower than the write.
//
// Sized against a PATH and not against what was measured, because the longest
// line the Engine writes is the startup banner and the banner quotes the audio's
// own path. The longest line in the fixture is the system-information line at
// 261 bytes; four kilobytes is fifteen times that and more than the extended
// path limit Windows itself documents.
MAX_DIAGNOSTIC_LINE :: 4096

// Whatever a child has said that has not yet become a whole line.
//
// A fixed array and no allocator, so a caller can keep one per running child on
// its own stack and there is nothing to free. The line it hands back is a VIEW
// INTO THIS RECORD and is only good until the next call -- a caller that needs
// to keep one clones it.
Line_Reader :: struct {
	held:     [MAX_DIAGNOSTIC_LINE]u8,
	count:    int,
	// True while the rest of a line too long to hold is being walked past.
	//
	// THE REST IS DROPPED AND THE FRONT IS NOT KEPT. A line this reader could not
	// hold is a line it has already failed to read, and the first four kilobytes
	// of one handed on as though whole is a reading nobody can trust -- the
	// truncation is invisible by the time anything downstream sees it.
	skipping: bool,
}

// Takes the next whole line out of `remaining`, holding whatever is left over
// for the chunk after it.
//
// `remaining` is advanced past everything consumed, so a caller loops until this
// answers false and then hands in the next chunk. False means the chunk ran out
// mid-line, which is the ordinary outcome: a read off an anonymous pipe ends
// wherever the kernel had bytes and nothing aligns that to a line.
next_line :: proc(r: ^Line_Reader, remaining: ^string) -> (line: string, ok: bool) {
	assert(r != nil, "there is nothing here to read a line into")
	assert(remaining != nil, "there is no chunk here to read a line out of")
	assert(r.count <= len(r.held), "the reader is holding more than it has room for")

	for len(remaining^) > 0 {
		c := remaining^[0]
		remaining^ = remaining^[1:]

		if c == '\n' {
			whole := !r.skipping
			held := trimmed(r.held[:r.count])
			r.count = 0
			r.skipping = false
			if whole {
				return held, true
			}
			continue
		}
		if r.skipping {
			continue
		}
		if r.count == len(r.held) {
			r.skipping = true
			r.count = 0
			continue
		}
		r.held[r.count] = c
		r.count += 1
	}
	return "", false
}

// Whatever is held behind no newline at all, once the child is gone.
//
// A child that exits without a final newline still said what it said, and the
// last thing a Recording's Engine says is the one most worth not dropping.
// Answers false the second time, so a caller that asks again is not handed the
// same line for ever.
last_line :: proc(r: ^Line_Reader) -> (line: string, ok: bool) {
	assert(r != nil, "there is nothing here to read a last line out of")
	assert(r.count <= len(r.held), "the reader is holding more than it has room for")

	if r.count == 0 {
		return "", false
	}
	// The negative space of the same case (A3): a line that was being SKIPPED
	// leaves nothing held, so there is no path where the tail of an oversized
	// line escapes here.
	assert(!r.skipping, "a line being walked past was held on to anyway")

	held := trimmed(r.held[:r.count])
	r.count = 0
	return held, true
}

// One assembled line with its carriage return taken off.
//
// The carriage return is FRAMING and not content: the Engine writes CRLF on
// Windows, so a reader downstream would otherwise be comparing against a byte
// nobody meant. Taken off exactly once, here, rather than by every reader
// remembering to.
@(private)
trimmed :: proc(held: []u8) -> string {
	if len(held) > 0 && held[len(held) - 1] == '\r' {
		return string(held[:len(held) - 1])
	}
	return string(held)
}

// How long the Engine may go without a readable progress line before the
// time-based estimate stands in, in milliseconds.
//
// KEYED ON THE ELAPSED TIME SINCE THE LAST LINE AND NEVER ON THEIR ABSENCE,
// which is ADR-0012's own sentence and the trap this whole file is written
// around: the Engine is silent on this subject for the whole of model load, and
// a rule that read "nothing said yet" as a failure would abort every healthy
// run. Nothing here fails on this bound. All it does is decide who supplies the
// number on the bar.
//
// Half a minute, against a legitimate gap between readings that the fixture puts
// at about a third of a second for a four-minute Recording and that scales with
// the Recording: a three-hour Recording at seventeen times realtime crosses a
// reading roughly every forty seconds, so the estimate does stand in between
// readings on a long one. That costs nothing, because the estimate is floored at
// whatever the Engine last said.
FALLBACK_AFTER_MS :: i64(30_000)

// How long nothing may arrive on any stream this program can see before the
// estimate stops moving, in milliseconds.
//
// "EITHER STREAM" IS ONE STREAM HERE, and that is ADR-0004 rather than a
// shortcut. Standard output goes to the null device, because the Engine writes
// every Cue to it during inference and an undrained pipe wedges the child --
// measured at 14,468 bytes for twenty minutes of audio against a pipe buffer of
// a few kilobytes. So the bytes on standard output are unobservable BY
// CONSTRUCTION, and standard error is the whole of what a watchdog can key on.
//
// What that costs is the thing to be honest about: an Engine part-way through
// inference is writing hard to a stream nobody can see while saying nothing on
// the one that can, and it is indistinguishable from a wedged one over any short
// window. What makes the window sound is the progress line -- the Engine crosses
// one every few per cent -- so the bound is sized against the longest legitimate
// gap between readings rather than against a byte trickle.
//
// A minute. The gap between readings is about forty seconds for a three-hour
// Recording at seventeen times realtime, and the corpus's longest is 168
// minutes. Beyond that the bar freezes between readings, which is cosmetic: a
// frozen bar is what ADR-0012 asks for over a confident one, and the estimate is
// floored at the Engine's last reading either way.
QUIET_AFTER_MS :: i64(60_000)

// ... and how long before the run is an operating error, in milliseconds.
//
// Five minutes, which is what the same reasoning gives with the headroom a
// FAILURE needs rather than a display state. The two legitimate silences to
// clear are a cold Model load -- 1.6 GB, measured at 1.07 seconds warm and about
// thirty seconds at fifty megabytes a second cold -- and one gap between
// readings, at about forty seconds for the longest Recording anyone has
// measured. This is six times the larger of them.
//
// A Recording that trips it is an operating error and not an assertion (A8): it
// fails on its own and the Batch carries on (ADR-0002).
SILENT_AFTER_MS :: i64(5 * 60 * 1000)

// The estimate must be able to stop moving BEFORE the run is failed, or the
// frozen bar ADR-0012 asks for is a state nothing can ever be in: the display
// would go straight from advancing confidently to a failed Recording, which is
// exactly the "hides the failure" outcome that decision names. Held by the
// compiler, because it is a relationship between two constants and not
// something a test would notice going wrong (A5).
#assert(QUIET_AFTER_MS < SILENT_AFTER_MS)

// The highest the ESTIMATE may ever read.
//
// A hundred is a fact, and only the Engine's own last reading or a finished
// output file supplies one. An estimate that reached it would announce a
// Transcript that does not exist for however long the run has left, which is the
// one thing a progress display must not be wrong about.
ESTIMATE_CEILING :: 99

#assert(ESTIMATE_CEILING < 100)

// How much slower than realtime the Engine is assumed to run, for the estimate.
//
// CHOSEN TO LAG AND NEVER TO LEAD. The measurements are 58 times realtime for
// this repository's fixture on an RTX 4070 Ti SUPER with `large-v3-turbo`, and
// about 17 times on the machine ADR-0012 was written against; a CPU-only
// fallback is far slower than either. An estimate that ran AHEAD would sit at
// the ceiling for most of a run and say nothing, while one that lags shows
// motion and is overtaken by the Engine's own next reading -- which is the floor
// it can never fall below.
//
// A defaulted parameter rather than a constant at the call site, the shape
// `Tolerance` has in `transcibr:audio`: a case hands in its own, and a caller
// that one day measures a real factor per machine has somewhere to put it.
DEFAULT_REALTIME_FACTOR :: f64(4)

#assert(DEFAULT_REALTIME_FACTOR > 0)

// The three numbers `shown` decides with, as one value.
//
// A RECORD RATHER THAN THREE DEFAULTED PARAMETERS, because two of them are a
// pair -- a quiet bound that reached its silent bound would make the frozen bar
// unobservable -- and a caller that could move one without the other would be
// able to spell that. Handed in, the shape ADR-0018 records for `Tolerance` in
// `transcibr:audio`: the shipped program takes DEFAULT_WATCH, and a case or a
// shell that needs a bound it can actually reach hands in its own.
Watch :: struct {
	factor:    f64,
	quiet_ms:  i64,
	silent_ms: i64,
}

DEFAULT_WATCH :: Watch {
	factor    = DEFAULT_REALTIME_FACTOR,
	quiet_ms  = QUIET_AFTER_MS,
	silent_ms = SILENT_AFTER_MS,
}

// Everything one Recording's progress display keys on.
//
// NO CLOCK IS READ IN THIS FILE. Every reading is handed in, which is the shape
// `remaining_ms` in `transcibr:child` established and ADR-0018 wrote down as the
// rule -- and it is what makes a child part-way through model load, one that has
// gone quiet and one that has gone silent into values a case produces rather
// than states a suite would have to wait five minutes for.
//
// The readings must all come from a MONOTONIC counter, and from the same one. A
// wall clock stepped backwards by a time service mid-Recording would make the
// elapsed time negative, and this is one of the few places in the program where
// that is a broken machine rather than external input: nothing outside transcibr
// supplies these.
Tracker :: struct {
	// How long the audio is, in milliseconds, or zero where nobody could say.
	// From the container probe before the Engine starts and from the Engine's own
	// startup banner once that arrives -- the spec's two sources, and NEVER the
	// scratch audio's header, which `transcibr:audio` makes a compile error by
	// giving that measurement a distinct type.
	duration_ms:      i64,
	// The highest percentage the Engine has said. Zero until it has said one,
	// which is the ordinary state for the whole of model load.
	said:             int,
	started_ns:       i64,
	// When a byte last arrived on a stream this program can see. The watchdog's
	// only input -- see QUIET_AFTER_MS for what "either stream" means once
	// standard output is the null device.
	last_byte_ns:     i64,
	// When a READABLE progress line last arrived, or when the run started if none
	// has. What the fallback keys on, and never their absence (ADR-0012).
	last_progress_ns: i64,
}

// Where the number on the bar came from.
Progress_Source :: enum u8 {
	// The Engine's own last reading stands. It is zero and unsaid until the
	// Engine has said one, which is the ordinary state during model load.
	Engine = 0,
	// The Engine has said nothing readable for FALLBACK_AFTER_MS, so the
	// time-based estimate is standing in (ADR-0012).
	Estimate,
	// Nothing has arrived on any stream this program can see for QUIET_AFTER_MS,
	// so the estimate has stopped moving rather than animating over a child that
	// may already be dead.
	Frozen,
}

// What the display should show, and what the watchdog makes of the silence
// behind it.
Progress :: struct {
	// 0..100.
	percent: int,
	from:    Progress_Source,
	// Nothing on any stream this program can see for SILENT_AFTER_MS. AN
	// OPERATING ERROR AND NOT A DISPLAY STATE, which is why it is a field of its
	// own rather than a fourth source: the caller stops the child and fails the
	// Recording, and the Batch carries on (ADR-0002).
	silent:  bool,
}

// What a display says beside the percentage about where the number came from.
//
// HERE AND NOT IN THE SHELL THAT PRINTS IT. ADR-0009 puts every decision worth
// testing in the core, and `scripts\test.ps1` requires `src/cli` to collect zero
// tests -- so a three-arm table living there would be one nothing could hold to
// account, including its own emptiness.
//
// The Engine's own reading says NOTHING, which is the decision rather than an
// oversight: it is the ordinary case, and a bar annotated on every line teaches
// a reader to stop reading the annotation. What has to be visible is the two
// that are not ordinary.
progress_says :: proc(from: Progress_Source) -> string {
	switch from {
	case .Estimate:
		return "(estimated)"
	case .Frozen:
		return "(no output)"
	case .Engine:
	// The ordinary case, and the one that says nothing. Stated rather than left
	// as a fallthrough, so a fourth source is a build failure here.
	}
	return ""
}

// Starts tracking one Recording's progress.
//
// `duration_ms` is the container probe's answer, or zero where the container
// could not be timed -- which is not a refusal here: the Engine's banner may
// still supply one, and until something does, the estimate has nothing to key on
// and says so by not moving.
tracker_start :: proc(duration_ms: i64, now_ns: i64) -> Tracker {
	assert(duration_ms >= 0, "a Recording of negative length")
	assert(now_ns > 0, "a monotonic counter that has not started")

	return Tracker {
		duration_ms = duration_ms,
		started_ns = now_ns,
		last_byte_ns = now_ns,
		last_progress_ns = now_ns,
	}
}

// Bytes arrived on a stream this program can see.
//
// Called for EVERY drain that produced anything, whether or not any of it read
// as a line -- the watchdog's question is whether the child is alive, and a
// child writing its model-load log is alive whether or not this package
// understands a word of it.
tracker_heard :: proc(tr: ^Tracker, bytes: int, now_ns: i64) {
	assert(tr != nil, "there is no Recording here to track")
	assert(bytes > 0, "a drain that read nothing was reported as the child talking")
	assert(now_ns >= tr.started_ns, "the monotonic counter went backwards over one Recording")

	tr.last_byte_ns = now_ns
}

// One line, read back.
tracker_said :: proc(tr: ^Tracker, said: Engine_Line, now_ns: i64) {
	assert(tr != nil, "there is no Recording here to track")
	assert(now_ns >= tr.started_ns, "the monotonic counter went backwards over one Recording")

	switch said.says {
	case .Progress:
		// The HIGHEST reading stands, and a reading that went backwards is not
		// refused and not asserted against (A8): the fixture's readings do rise
		// and nothing promises a release will not restart the count part-way, and
		// a bar that dropped from 52 to 40 reads as a Recording being done again.
		// The line still counted as a line, which is what stops the fallback
		// standing in over a perfectly healthy Engine.
		tr.said = max(tr.said, said.percent)
		tr.last_progress_ns = now_ns
	case .Duration:
		// The banner wins over the container probe once it arrives: it is about
		// the audio the Engine is ACTUALLY working through, and that is what the
		// estimate is an estimate of.
		tr.duration_ms = said.duration_ms
	case .Nothing:
	// Most of what arrives. Not a reading, and deliberately not a byte either
	// -- tracker_heard is what says the child is alive, so that a stream of
	// lines nobody can read still holds the watchdog off.
	}
}

// What the display should show now.
//
// The order of the three answers is the decision. Silence is read FIRST, because
// a number that keeps climbing over a child that has stopped producing bytes is
// worse than a frozen one -- ADR-0012's own words, and the reason that decision
// exists at all.
shown :: proc(tr: Tracker, now_ns: i64, watch := DEFAULT_WATCH) -> Progress {
	assert(now_ns >= tr.started_ns, "the monotonic counter went backwards over one Recording")
	assert(watch.factor > 0, "an Engine that runs at no speed at all finishes nothing")
	assert(tr.said >= 0, "a tracker holding a negative percentage")
	// The pair, checked wherever a caller hands one in -- the compile-time form
	// below only covers the constants this package chose (A4).
	assert(
		watch.quiet_ms < watch.silent_ms,
		"a bar that freezes no sooner than the run fails never freezes at all",
	)

	quiet_ns := now_ns - tr.last_byte_ns
	if quiet_ns >= watch.quiet_ms * 1_000_000 {
		return Progress {
			percent = tr.said,
			from = .Frozen,
			silent = quiet_ns >= watch.silent_ms * 1_000_000,
		}
	}
	if now_ns - tr.last_progress_ns < FALLBACK_AFTER_MS * 1_000_000 {
		return Progress{percent = tr.said, from = .Engine}
	}
	return Progress{percent = estimated(tr, now_ns, watch.factor), from = .Estimate}
}

// The time-based estimate, floored at what the Engine last said.
//
// The floor is applied BEFORE the ceiling, so an Engine that has already said a
// hundred keeps it: the ceiling is a rule about what an ESTIMATE may claim, not
// about what the Engine may report.
@(private)
estimated :: proc(tr: Tracker, now_ns: i64, factor: f64) -> int {
	assert(factor > 0, "an Engine that runs at no speed at all finishes nothing")
	assert(now_ns >= tr.started_ns, "the monotonic counter went backwards over one Recording")

	// Nothing to divide by. A container that could not be timed and a banner that
	// never arrived leave the last reading standing, which is honest -- a number
	// invented from nothing would be the confident bar ADR-0012 refuses.
	if tr.duration_ms <= 0 {
		return tr.said
	}
	expected_ns := f64(tr.duration_ms) * 1e6 / factor
	percent := int(f64(now_ns - tr.started_ns) / expected_ns * 100)

	if percent < tr.said {
		return tr.said
	}
	if percent > ESTIMATE_CEILING {
		return ESTIMATE_CEILING
	}
	return percent
}

// How long one Engine invocation is given before it is stopped, in
// milliseconds.
//
// A bound and never INFINITE, which is issue #27's rule: an Engine wedged in a
// driver call holds a Batch for ever, and one GPU worker means it holds every
// Recording behind it too (ADR-0006).
//
// FOUR TIMES REALTIME PLUS A FLOOR, and both parts earn their place. The
// multiple is against a CPU-only fallback rather than against anything measured
// on a GPU -- the fixture ran at 58 times realtime and ADR-0012's machine at 17,
// so this is more than an order of magnitude of headroom on either. The floor is
// what a cold Model load costs before any inference happens at all, and without
// it a two-minute Recording would be given eight minutes for a load that can
// take one of them.
ENGINE_BOUND_FLOOR_MS :: i64(10 * 60 * 1000)
ENGINE_BOUND_MULTIPLE :: i64(4)

transcribe_bound_ms :: proc(duration_ms: i64) -> i64 {
	assert(duration_ms >= 0, "a Recording of negative length")
	assert(
		duration_ms <= LONGEST_CONTAINER_MS,
		"a Recording longer than this package will believe reached the bound",
	)

	bound := ENGINE_BOUND_FLOOR_MS + duration_ms * ENGINE_BOUND_MULTIPLE
	assert(bound >= ENGINE_BOUND_FLOOR_MS, "a bound below the floor a cold Model load needs")
	assert(bound > duration_ms, "an Engine given less time than the Recording lasts")
	return bound
}
