#+vet explicit-allocators
package process

import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

// The Engine's command line, and one line of its diagnostic output read back as
// progress or as a duration. Those diagnostics are human-readable text and not a
// contract, so a line this reader cannot read answers `.Nothing` (ADR-0012).

Engine_Job :: struct {
	model:  string,
	// ONE Recording's: the Engine takes a list of files and writes one output
	// prefix (ADR-0002).
	audio:  string,
	// Without an extension; the Engine appends its own (ADR-0002).
	prefix: string,
	// Empty is the Engine's own default -- no initial prompt at all -- and adds
	// no `--prompt` flag; the Engine has no way to spell "an explicit, empty
	// prompt" that differs from omitting the flag, so there is nothing to record
	// by sending one. Never length-bounded here: `build_command_line`'s own
	// `.Too_Long` (src/process/command_line.odin) already refuses a command
	// line no `CreateProcessW` could accept, whatever argument pushed it there,
	// and is what A8 asks this external text be checked against (finding 1 of
	// PR #67's round-2 review).
	prompt: string,
}

// Chosen by the Engine and not by transcibr: it appends this to whatever prefix it
// is given (ADR-0002).
ENGINE_OUTPUT_SUFFIX :: ".json"

// The caller owns the returned slice and frees it with `delete` and the same
// allocator; the strings in it are borrowed and outlive nothing the caller does not
// already hold. Why these flags, and why not `-bs`, `-np` or `-l`: ADR-0012. Why
// `--prompt` is conditional and not a ninth fixed flag: verified against
// `whisper-cli.exe --help` at the installed Engine, the flag takes free text with
// no short form and no flag at all is how whisper.cpp spells "no initial prompt."
@(require_results)
engine_arguments :: proc(job: Engine_Job, allocator: mem.Allocator) -> (arguments: []string) {
	assert(allocator.procedure != nil, "an argument list needs an allocator to be built in")
	assert(len(job.model) > 0, "the Engine was given no Model to load")
	assert(len(job.audio) > 0, "there is no audio here for the Engine to read")
	assert(len(job.prefix) > 0, "the Engine was given nowhere to write its output")

	count := 8
	if len(job.prompt) > 0 {
		count += 2
	}
	arguments = make([]string, count, allocator)
	arguments[0] = "-m"
	arguments[1] = job.model
	arguments[2] = "-oj"
	arguments[3] = "-pp"
	arguments[4] = "-of"
	arguments[5] = job.prefix
	arguments[6] = "-f"
	arguments[7] = job.audio
	if len(job.prompt) > 0 {
		arguments[8] = "--prompt"
		arguments[9] = job.prompt
	}

	for argument in arguments {
		assert(len(argument) > 0, "the argument list left a slot empty")
	}
	assert(
		len(arguments) == 8 || len(arguments) == 10,
		"the argument list grew by something other than the whole --prompt pair",
	)
	return arguments
}

// Why a path outside ASCII is refused before the Engine is started, and why the
// rule sits beside this argument list rather than beside ffmpeg's: ADR-0025.
@(require_results)
ascii_only :: proc(path: string) -> bool {
	for at in 0 ..< len(path) {
		if path[at] >= 0x80 {
			return false
		}
	}
	return true
}

// The caller owns the answer and frees it with `delete` and the same allocator.
@(require_results)
engine_output_path :: proc(prefix: string, allocator: mem.Allocator) -> string {
	assert(len(prefix) > 0, "a prefix of nothing names the extension and nothing else")
	assert(
		allocator.procedure != nil,
		"the path outlives this procedure and needs a chosen allocator",
	)

	produced := strings.concatenate({prefix, ENGINE_OUTPUT_SUFFIX}, allocator)
	assert(len(produced) > len(prefix), "the Engine's extension was not appended at all")
	assert(
		strings.has_suffix(produced, ENGINE_OUTPUT_SUFFIX),
		"the Engine's output was named without the extension the Engine appends",
	)
	return produced
}

// `.Nothing` is the ordinary answer and never a fault: most of what the Engine
// writes has no reading here, and a fault vocabulary would report a failure forty
// times per healthy Recording.
Engine_Says :: enum u8 {
	Nothing = 0,
	Progress,
	Duration,
}

Engine_Line :: struct {
	says:        Engine_Says,
	// 0..100, and only where `says` is `.Progress`.
	percent:     int,
	// Only where `says` is `.Duration`.
	duration_ms: i64,
}

// Looked for anywhere in the line rather than anchored to its start: an escape
// sequence in front of the reading, and the tail of another thread's line landing
// on top of it, are both shapes this stream really produces.
@(private)
PROGRESS_MARK :: "whisper_print_progress_callback: progress ="

@(require_results)
read_engine_line :: proc(line: string) -> Engine_Line {
	if said, ok := read_progress(line); ok {
		return checked(said)
	}
	if said, ok := read_banner(line); ok {
		return checked(said)
	}
	return Engine_Line{}
}

@(private)
@(require_results)
checked :: proc(said: Engine_Line) -> Engine_Line {
	assert(said.says != .Nothing, "a line that said nothing was handed back as a reading")

	switch said.says {
	case .Progress:
		assert(said.percent >= 0, "a progress reading below zero")
		assert(said.percent <= 100, "a progress reading past a hundred")
		assert(said.duration_ms == 0, "a progress reading carried a duration as well")
	case .Duration:
		assert(said.duration_ms > 0, "a duration reading of no time at all")
		assert(
			said.duration_ms <= LONGEST_CONTAINER_MS,
			"a duration reading past the longest Recording this package will believe",
		)
		assert(said.percent == 0, "a duration reading carried a percentage as well")
	case .Nothing:
	}
	return said
}

@(private)
@(require_results)
read_progress :: proc(line: string) -> (said: Engine_Line, ok: bool) {
	mark := strings.index(line, PROGRESS_MARK)
	if mark < 0 {
		return {}, false
	}

	reading := strings.trim_space(line[mark + len(PROGRESS_MARK):])
	if !strings.has_suffix(reading, "%") {
		return {}, false
	}
	percent, readable := read_natural(strings.trim_space(reading[:len(reading) - 1]))
	if !readable {
		return {}, false
	}
	if percent > 100 {
		return {}, false
	}
	return Engine_Line{says = .Progress, percent = int(percent)}, true
}

// Why not `strconv.parse_int`, which takes `_` and a sign and overflows in silence:
// CLAUDE.md, Odin notes.
@(require_results)
read_natural :: proc(text: string, max_digits := MAX_NATURAL_DIGITS) -> (value: i64, ok: bool) {
	assert(max_digits > 0, "a number of no digits at all is not a number")

	if len(text) == 0 || len(text) > max_digits {
		return 0, false
	}
	for at in 0 ..< len(text) {
		digit := text[at]
		if digit < '0' || digit > '9' {
			return 0, false
		}
		if value > (max(i64) - i64(digit - '0')) / 10 {
			return 0, false
		}
		value = value * 10 + i64(digit - '0')
	}
	assert(value >= 0, "a run of decimal digits added up to a negative number")
	return value, true
}

// Twelve, because what is read here is multiplied by a thousand downstream: the
// product stays under 10^15 and nowhere near i64's ceiling, so a number too large to
// be meant is refused on its value rather than wrapped into a plausible small one.
MAX_NATURAL_DIGITS :: 12

#assert(MAX_NATURAL_DIGITS < 19)

// The banner's two fixed fields, and not the `main: processing` prefix in front of
// them: that prefix is a procedure name a release is free to change, and the path
// between the markers is a Recording's own name.
@(private)
SAMPLES_MARK :: " samples, "
@(private)
SECONDS_MARK :: " sec)"

// Why a second rather than the 50 ms the banner's one decimal place forces: ADR-0012.
@(private)
BANNER_AGREEMENT_MS :: i64(1000)

@(private)
@(require_results)
read_banner :: proc(line: string) -> (said: Engine_Line, ok: bool) {
	mark := strings.last_index(line, SAMPLES_MARK)
	if mark < 0 {
		return {}, false
	}
	rest := line[mark + len(SAMPLES_MARK):]
	close := strings.index(rest, SECONDS_MARK)
	if close < 0 {
		return {}, false
	}

	from_samples, counted := samples_ms(line[:mark])
	from_seconds, timed := seconds_ms(rest[:close])
	if !counted || !timed {
		return {}, false
	}
	if !banner_agrees(from_samples, from_seconds) {
		return {}, false
	}
	return Engine_Line{says = .Duration, duration_ms = from_samples}, true
}

@(private)
@(require_results)
banner_agrees :: proc(from_samples, from_seconds: i64) -> bool {
	assert(from_samples > 0, "a sample count that was refused was compared anyway")
	assert(from_seconds > 0, "a seconds reading that was refused was compared anyway")

	gap := from_samples - from_seconds
	if gap < 0 {
		gap = -gap
	}
	return gap <= BANNER_AGREEMENT_MS
}

@(private)
@(require_results)
samples_ms :: proc(head: string) -> (duration_ms: i64, ok: bool) {
	at := len(head)
	for at > 0 && head[at - 1] >= '0' && head[at - 1] <= '9' {
		at -= 1
	}
	samples, readable := read_natural(head[at:])
	if !readable || samples <= 0 {
		return 0, false
	}

	rounded := (samples * 1000 + AUDIO_SAMPLE_RATE / 2) / AUDIO_SAMPLE_RATE
	if rounded <= 0 || rounded > LONGEST_CONTAINER_MS {
		return 0, false
	}
	return rounded, true
}

@(private)
@(require_results)
seconds_ms :: proc(text: string) -> (duration_ms: i64, ok: bool) {
	seconds, readable := strconv.parse_f64(strings.trim_space(text))
	if !readable {
		return 0, false
	}
	if math.is_nan(seconds) || math.is_inf(seconds) {
		return 0, false
	}
	return milliseconds_of(seconds)
}
