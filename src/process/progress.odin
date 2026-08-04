package process

// A child's diagnostic pipe reassembled into lines, and what a Recording's
// progress display should show given what the Engine has said and when.

// Sized against a Windows extended path rather than against the fixture's
// longest line, 261 bytes: the Engine's banner quotes the audio's own path.
MAX_DIAGNOSTIC_LINE :: 4096

// The line handed back is a view into this record and is only good until the
// next call; a caller that needs to keep one clones it.
Line_Reader :: struct {
	held:     [MAX_DIAGNOSTIC_LINE]u8,
	count:    int,
	skipping: bool,
}

@(require_results)
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

@(require_results)
last_line :: proc(r: ^Line_Reader) -> (line: string, ok: bool) {
	assert(r != nil, "there is nothing here to read a last line out of")
	assert(r.count <= len(r.held), "the reader is holding more than it has room for")

	if r.count == 0 {
		return "", false
	}

	held := trimmed(r.held[:r.count])
	r.count = 0
	return held, true
}

// The Engine writes CRLF on Windows, and the carriage return is framing rather
// than content; it is taken off once, here, rather than by every reader.
@(private)
@(require_results)
trimmed :: proc(held: []u8) -> string {
	if len(held) > 0 && held[len(held) - 1] == '\r' {
		return string(held[:len(held) - 1])
	}
	return string(held)
}

FALLBACK_AFTER_MS :: i64(30_000)

// Why standard output is not drained as a second stream: ADR-0012.
QUIET_AFTER_MS :: i64(60_000)

// A cold Model load: 1.6 GB, about thirty seconds at fifty megabytes a second.
// The one legitimate silence that does not scale with the Recording, and so the
// one a floor is the right shape for.
SILENT_AFTER_MS :: i64(5 * 60 * 1000)

#assert(QUIET_AFTER_MS < SILENT_AFTER_MS)

#assert(FALLBACK_AFTER_MS < QUIET_AFTER_MS)

// Why the silence bound scales with the Recording: ADR-0012.
@(private)
@(require_results)
silent_after_ms :: proc(duration_ms: i64, floor_ms: i64) -> i64 {
	assert(floor_ms > 0, "a run given no time at all to break its silence")
	assert(duration_ms >= 0, "a Recording of negative length")

	given := max(floor_ms, duration_ms)
	assert(given >= floor_ms, "a Recording given less than a cold Model load costs")
	return given
}

// A hundred is a fact, and only the Engine's own reading or a finished output
// file supplies one.
ESTIMATE_CEILING :: 99

#assert(ESTIMATE_CEILING < 100)

// Why four, chosen to lag against two measured throughputs: ADR-0012.
DEFAULT_REALTIME_FACTOR :: f64(4)

#assert(DEFAULT_REALTIME_FACTOR > 0)

// The three bounds are an ordered chain -- fallback below quiet below silent --
// so they are handed in together or not at all.
Watch :: struct {
	factor:      f64,
	fallback_ms: i64,
	quiet_ms:    i64,
	silent_ms:   i64,
}

DEFAULT_WATCH :: Watch {
	factor      = DEFAULT_REALTIME_FACTOR,
	fallback_ms = FALLBACK_AFTER_MS,
	quiet_ms    = QUIET_AFTER_MS,
	silent_ms   = SILENT_AFTER_MS,
}

// Every reading is handed in, and all of them must come from one monotonic
// counter: a wall clock stepped backwards mid-Recording is a broken machine
// here rather than external input.
Tracker :: struct {
	duration_ms:      i64,
	said:             int,
	started_ns:       i64,
	last_byte_ns:     i64,
	last_progress_ns: i64,
}

Progress_Source :: enum u8 {
	Engine = 0,
	Estimate,
	Frozen,
}

Progress :: struct {
	percent: int,
	from:    Progress_Source,
	// An operating error rather than a fourth display state: the caller stops the
	// child and fails the Recording.
	silent:  bool,
}

@(require_results)
progress_says :: proc(from: Progress_Source) -> string {
	switch from {
	case .Estimate:
		return "(estimated)"
	case .Frozen:
		return "(waiting)"
	case .Engine:
	}
	return ""
}

@(require_results)
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

// Called for every drain that produced anything, whether or not any of it read
// as a line: a child writing a log this package cannot parse is still alive.
tracker_heard :: proc(tr: ^Tracker, bytes: int, now_ns: i64) {
	assert(tr != nil, "there is no Recording here to track")
	assert(bytes > 0, "a drain that read nothing was reported as the child talking")
	assert(now_ns >= tr.started_ns, "the monotonic counter went backwards over one Recording")

	tr.last_byte_ns = now_ns
}

tracker_said :: proc(tr: ^Tracker, said: Engine_Line, now_ns: i64) {
	assert(tr != nil, "there is no Recording here to track")
	assert(now_ns >= tr.started_ns, "the monotonic counter went backwards over one Recording")

	switch said.says {
	case .Progress:
		tr.said = max(tr.said, said.percent)
		tr.last_progress_ns = now_ns
	case .Duration:
		tr.duration_ms = said.duration_ms
	case .Nothing:
	}
}

@(require_results)
shown :: proc(tr: Tracker, now_ns: i64, watch := DEFAULT_WATCH) -> Progress {
	assert(now_ns >= tr.started_ns, "the monotonic counter went backwards over one Recording")
	assert(watch.factor > 0, "an Engine that runs at no speed at all finishes nothing")
	assert(tr.said >= 0, "a tracker holding a negative percentage")
	assert(
		watch.fallback_ms < watch.quiet_ms,
		"an estimate that stands in no sooner than the bar freezes never stands in at all",
	)
	assert(
		watch.quiet_ms < watch.silent_ms,
		"a bar that freezes no sooner than the run fails never freezes at all",
	)

	silent_ms := silent_after_ms(tr.duration_ms, watch.silent_ms)
	quiet_ns := now_ns - tr.last_byte_ns
	if quiet_ns >= watch.quiet_ms * 1_000_000 {
		return Progress {
			percent = tr.said,
			from = .Frozen,
			silent = quiet_ns >= silent_ms * 1_000_000,
		}
	}
	if now_ns - tr.last_progress_ns < watch.fallback_ms * 1_000_000 {
		return Progress{percent = tr.said, from = .Engine}
	}
	return Progress{percent = estimated(tr, now_ns, watch.factor), from = .Estimate}
}

@(private)
@(require_results)
estimated :: proc(tr: Tracker, now_ns: i64, factor: f64) -> int {
	assert(factor > 0, "an Engine that runs at no speed at all finishes nothing")
	assert(now_ns >= tr.started_ns, "the monotonic counter went backwards over one Recording")

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

// The multiple is sized against a CPU-only fallback rather than against
// anything measured on a GPU; the floor is what a cold Model load costs before
// any inference happens at all.
ENGINE_BOUND_FLOOR_MS :: i64(10 * 60 * 1000)
ENGINE_BOUND_MULTIPLE :: i64(4)

@(require_results)
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
