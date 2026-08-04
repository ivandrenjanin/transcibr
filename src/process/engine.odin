package process

import "core:mem"
import "core:strings"

// This file holds the Engine: the exact argument list it is started with, and
// what one line of the diagnostic output it writes back means read as progress
// or as a duration. The half of the module the spec's own sentence names --
// "interprets Engine output lines into progress and duration events" -- with the
// display's own bookkeeping in progress.odin next door.
//
// EVERY BYTE READ HERE CAME FROM THE ENGINE, and the Engine's diagnostics are
// human-readable text rather than a contract: a release reformats them without
// warning, two threads interleave them, a colour code arrives in front of one, a
// line is cut in half by the pipe. So A8 is the whole shape of this file -- no
// reading refuses anything, nothing reaches an assertion, and a line this reader
// does not understand answers `.Nothing` and degrades the progress bar instead
// of failing the run (ADR-0012).

// What the Engine is told to do with one Recording's audio.
//
// A record and not three parameters, because all three are paths: handed in
// positionally, a model and an audio file the wrong way round is a command line
// that spells perfectly and an Engine that refuses for a reason nothing here can
// see.
Engine_Job :: struct {
	// The weights the Engine loads. Interchangeable; the Engine is not.
	model:  string,
	// The mono 16 kHz audio `transcibr:audio` produced -- ONE Recording's, and
	// the singular is ADR-0002's rule rather than a convenience. The Engine takes
	// a list (`whisper-cli [options] file0 file1 ...`) and writes ONE output
	// prefix, so a second Recording in the same invocation has nowhere of its own
	// for its Cues to go.
	audio:  string,
	// `<cache>\<name>`, WITHOUT an extension. The Engine appends `.json` to
	// whatever prefix it is given (ADR-0002) -- which is why it cannot be pointed
	// at a `.part` name, and why the path transcibr goes back to afterwards comes
	// from engine_output_path rather than from anywhere else.
	prefix: string,
}

// The extension the ENGINE chooses, spelled once.
//
// Not transcibr's to pick: `output_json` opens the prefix it was given with this
// appended and a truncating stream, so a Stop press or a full disk leaves a
// truncated file under its final name (ADR-0002). That is the whole reason the
// Engine writes into a scratch cache and transcibr moves what it produced.
ENGINE_OUTPUT_SUFFIX :: ".json"

// The arguments the Engine is started with for one Recording.
//
// The caller owns the returned slice and frees it with `delete` and the same
// allocator. THE STRINGS IN IT ARE BORROWED, never owned -- this package's own
// constants and the caller's own three paths -- so there is nothing in it to
// free but the slice, and nothing in it outlives what the caller already holds.
// The same rule probe_arguments and extract_arguments next door keep.
//
// What is deliberately NOT here:
//
//   `-bs`. Beam search stays at the Engine default (spec), and `-bs` is the BEAM
//   size rather than a batch size -- there is no batch-size setting to reduce.
//
//   `-np`, the Engine's "no prints" flag. It would suppress the startup banner,
//   and the banner is one of the two places a duration may come from (ADR-0012).
//   Standard output is the null device already (ADR-0004), so there is nothing
//   for it to save.
//
//   `-l`. Which language a Recording is in is a settings question and no ticket
//   owns it yet; the Engine's own default stands until one does.
engine_arguments :: proc(job: Engine_Job, allocator: mem.Allocator) -> (arguments: []string) {
	assert(allocator.procedure != nil, "an argument list needs an allocator to be built in")
	// The three paths' CONTENTS are external and are refused by
	// build_command_line, which is the boundary (A8). What is asserted here is
	// that a caller handed over a job at all: the prefix is built from the
	// scratch cache and the artifact stem, both transcibr's own, so an empty one
	// is this program losing it rather than a user typing it.
	assert(len(job.model) > 0, "the Engine was given no Model to load")
	assert(len(job.audio) > 0, "there is no audio here for the Engine to read")
	assert(len(job.prefix) > 0, "the Engine was given nowhere to write its output")

	arguments = make([]string, 8, allocator)
	arguments[0] = "-m"
	arguments[1] = job.model
	// MEASURED against whisper.cpp v1.9.1's own help: both of these default to
	// false. Without `-oj` the Engine spends the GPU time and writes no file at
	// all; without `-pp` it runs in silence and the progress bar never moves.
	arguments[2] = "-oj"
	arguments[3] = "-pp"
	arguments[4] = "-of"
	arguments[5] = job.prefix
	// LAST, and exactly once. Anything after `-f`'s value would be read as a
	// second input file, which is the one thing ADR-0002 forbids outright.
	arguments[6] = "-f"
	arguments[7] = job.audio

	// The postcondition that catches an index nobody filled -- extract_arguments'
	// own check, for the same reason: an empty string in the middle of a command
	// line builds, spells, and makes the Engine refuse a Recording for a reason
	// that appears nowhere.
	for argument in arguments {
		assert(len(argument) > 0, "the argument list left a slot empty")
	}
	return arguments
}

// Where the Engine will have written its output, given the prefix it was handed.
//
// The caller owns the answer and frees it with `delete` and the same allocator.
// The one place ENGINE_OUTPUT_SUFFIX is appended, which is what makes the write
// side and the read side of ADR-0002's rule the same claim rather than two.
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

// What one line of the Engine's diagnostic output turned out to say.
//
// `.Nothing` is the ORDINARY answer and never a fault: the model-load log, the
// system-information line, the timings at the end and every blank line between
// them are all lines this package has no reading for, and there are far more of
// them than there are readings. A fault vocabulary here would report a failure
// forty times per healthy Recording.
Engine_Says :: enum u8 {
	Nothing = 0,
	Progress,
	Duration,
}

// One line, read back. Which member carries anything follows from `says` and is
// never guessed at from whether a field happens to be zero: a progress line of
// `0%` is a reading, and so is a duration of nothing at all -- which is why the
// latter is refused before it can be one.
Engine_Line :: struct {
	says:        Engine_Says,
	// 0..100, and only where `says` is `.Progress`.
	percent:     int,
	// Only where `says` is `.Duration`.
	duration_ms: i64,
}

// The Engine's progress line, as v1.9.1 spells it:
//
//	whisper_print_progress_callback: progress =  42%
//
// LOOKED FOR ANYWHERE IN THE LINE and not anchored to its start, which costs
// nothing and buys two of the shapes this stream really produces: an escape
// sequence in front of the reading, and the tail of another thread's line
// landing on top of it. The number is printed in a three-wide field, so the run
// of spaces in the middle is one, two or three bytes and is not a column.
@(private)
PROGRESS_MARK :: "whisper_print_progress_callback: progress ="

// Reads one line of the Engine's diagnostic output.
//
// A8 IS THE WHOLE OF THIS PROCEDURE. Every byte came from the Engine, whose
// diagnostics are human-readable text and not a contract, so there is no refusal
// to report and nothing to assert on: a line this reader does not understand
// answers `.Nothing`, the tracker next door notices that nothing has been said
// for a while, and the fallback keeps the bar moving (ADR-0012).
read_engine_line :: proc(line: string) -> Engine_Line {
	if said, ok := read_progress(line); ok {
		return said
	}
	return Engine_Line{}
}

// The percentage out of one progress line.
@(private)
read_progress :: proc(line: string) -> (said: Engine_Line, ok: bool) {
	mark := strings.index(line, PROGRESS_MARK)
	if mark < 0 {
		return {}, false
	}

	// trim_space and not a fixed offset: it takes the field's padding off the
	// front and a CRLF's carriage return off the back, and neither of those is
	// something this reader should have to know the width of.
	reading := strings.trim_space(line[mark + len(PROGRESS_MARK):])
	if !strings.has_suffix(reading, "%") {
		return {}, false
	}
	percent, readable := read_natural(strings.trim_space(reading[:len(reading) - 1]))
	if !readable {
		return {}, false
	}
	// REFUSED AND NOT CLAMPED, and the upper end is the one that matters: clamped
	// to a hundred, a reading the Engine never meant would say the Recording is
	// finished, and a bar that reaches the end and stays there for an hour is
	// worse than one that stopped being believed.
	if percent > 100 {
		return {}, false
	}
	return Engine_Line{says = .Progress, percent = int(percent)}, true
}

// A whole non-negative number, strictly.
//
// STRICTER THAN `strconv.parse_int` ON PURPOSE, in three ways that all matter
// here. That procedure accepts `_` as a digit separator, so `1_0` reads as ten;
// it accepts a leading sign, so a negative percentage arrives as a negative
// number rather than as a refusal; and it OVERFLOWS SILENTLY -- `value *= base`
// with no check -- so a forty-digit number answers something arbitrary and
// reports success. Every one of those is a byte the Engine can write.
//
// The digit ceiling is what closes the overflow, before the multiplication
// rather than after it: see MAX_NATURAL_DIGITS.
@(private)
read_natural :: proc(text: string) -> (value: i64, ok: bool) {
	if len(text) == 0 || len(text) > MAX_NATURAL_DIGITS {
		return 0, false
	}
	for at in 0 ..< len(text) {
		digit := text[at]
		if digit < '0' || digit > '9' {
			return 0, false
		}
		value = value * 10 + i64(digit - '0')
	}
	assert(value >= 0, "a run of decimal digits added up to a negative number")
	return value, true
}

// The most decimal digits a number on this stream may carry.
//
// Twelve, which is a bound on the ARITHMETIC and not an opinion about anything
// the Engine prints. What is read here is multiplied by a thousand downstream:
// twelve digits is under 10^12, so that product is under 10^15 and nowhere near
// i64's 9.2 x 10^18. A number too large to be meant is then refused on its
// VALUE by whichever reader wanted it, which is a refusal, rather than wrapped
// into a plausible small one, which is not.
@(private)
MAX_NATURAL_DIGITS :: 12

#assert(MAX_NATURAL_DIGITS < 19)
