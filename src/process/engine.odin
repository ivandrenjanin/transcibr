package process

import "core:math"
import "core:mem"
import "core:strconv"
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
//
// WHICH PUTS THIS FILE UNDER A1's AVERAGE, at 21 assertions across 11
// procedures, and the carve-out is recorded here rather than left for a reader
// to work out. Six of those procedures -- read_engine_line, read_progress,
// read_banner, samples_ms, seconds_ms and ascii_only -- carry NONE, and every
// one of them takes a string somebody outside this program wrote. A8 forbids
// asserting on it, so an assertion in any of them would be a line the Engine can
// crash this program with, which is the one thing this whole file exists to
// prevent. A1's own wording is the licence: "pure leaf math may carry fewer when
// its callers carry more", and the callers do -- `checked` holds seven over what
// these hand back, and `transcribe_bound_ms` and `shown` next door hold the rest
// of the way in. Raising the count here would mean putting assertions where A8
// forbids them, which is a worse file that counts better.
//
// The numbers above were 19 and 10 and named four, and none of the three was
// right; they are counted here rather than remembered.

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

// Whether every byte of a path is ASCII, which is whether the Engine can be
// given it at all.
//
// ADR-0002's rule, MEASURED: `whisper-cli` is `int main(int, char**)` under
// MSVC, so argv reaches it in the system ANSI code page and a path carrying a
// byte outside ASCII fails to open with no output at all -- at exit code zero,
// which is the fourth of that decision's four measurements and the reason none
// of this can be left to the child to report. A non-ASCII Windows ACCOUNT NAME
// is enough on its own, since the scratch cache sits under %LOCALAPPDATA%.
//
// IT IS ABOUT THE ENGINE AND NOT ABOUT CHILDREN IN GENERAL, which is why it sits
// in this file beside engine_arguments rather than in ffmpeg.odin next door.
// ffmpeg does NOT have the bug -- it re-reads `GetCommandLineW()` -- so probing
// and extraction look perfectly clean while only transcription fails, and a
// reader who found this rule beside the other two argument lists would draw
// exactly the wrong conclusion about which children it constrains.
//
// It lives here rather than in either caller because it now has three: the
// scratch cache is checked once per Batch by `transcibr:audio`, the Model once
// per Batch by `transcibr:artifact`, and the three paths one invocation is about
// to be handed are checked by `transcibr:engine` before the child starts. One
// question, one answer -- and this is the package whose whole subject is what a
// child is started with.
//
// The empty path is ASCII, which is the honest answer and never the useful one:
// a caller with nothing in hand has a different complaint, and every one of the
// three above states it separately.
ascii_only :: proc(path: string) -> bool {
	for at in 0 ..< len(path) {
		if path[at] >= 0x80 {
			return false
		}
	}
	return true
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
		return checked(said)
	}
	if said, ok := read_banner(line); ok {
		return checked(said)
	}
	return Engine_Line{}
}

// One reading, checked at the one place both readers leave through.
//
// The read side (A4) of what the two readers promise on the way out, and the
// reason it is here rather than repeated in each of them. What it checks is that
// `says` and the fields AGREE: a consumer switches on `says` and reads the field
// that member names, so a `.Progress` carrying a duration or a `.Duration`
// carrying a percentage is one reading being read as the other -- silently, and
// with a plausible number in it.
//
// Not a check on the Engine (A8). Every refusal has already happened above; this
// is a check on this package's own two readers, so a failure here is a bug in
// one of them and never a line the Engine wrote.
@(private)
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
	// Refused by the assertion above, which names it. Stated here so the switch
	// is exhaustive rather than #partial, which would let a fourth member go
	// unchecked in silence.
	}
	return said
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
// reports success. Every one of those is a byte the Engine can write, and every
// one of them is a byte a corrupt Sidecar can carry too.
//
// EXPORTED, AND THE CEILING IS THE CALLER'S. `transcibr:artifact` had a
// character-for-character copy of this loop down to the assertion string,
// because a Sidecar's reader wants exactly these three refusals -- and it could
// not simply call this one, because the ceilings are not the same number and
// cannot be: twelve digits is a bound on what this file's arithmetic does with a
// reading, and a Sidecar carries a nanosecond moment, which is nineteen. So the
// ceiling is a parameter with this file's own as its default, and the overflow
// check is done BEFORE the multiplication rather than left to the ceiling, which
// is the whole difference between a refusal and a wrap once nineteen digits are
// allowed.
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

// The most decimal digits a number on this stream may carry.
//
// Twelve, which is a bound on the ARITHMETIC and not an opinion about anything
// the Engine prints. What is read here is multiplied by a thousand downstream:
// twelve digits is under 10^12, so that product is under 10^15 and nowhere near
// i64's 9.2 x 10^18. A number too large to be meant is then refused on its
// VALUE by whichever reader wanted it, which is a refusal, rather than wrapped
// into a plausible small one, which is not.
//
// Exported with read_natural, because it is that procedure's default and a
// caller in another package cannot be handed a default it cannot see.
MAX_NATURAL_DIGITS :: 12

#assert(MAX_NATURAL_DIGITS < 19)

// The Engine's startup banner names the audio it is about to process and says
// how long it is, twice:
//
//	main: processing 'C:\tmp\transcibr\recording.wav' (4063182 samples, 253.9 sec), 4 threads, ...
//
// ONE OF THE TWO PLACES A DURATION MAY COME FROM (spec, ADR-0012). The other is
// the container probe next door. The scratch audio's own header is neither, and
// `transcibr:audio` gives that measurement a distinct type so that reaching for
// it is a compile error rather than a rule to remember.
//
// The two markers, and NOT the `main: processing` prefix. What anchors this
// reading is the pair of fixed fields; the prefix in front of them is a
// procedure name that a release is free to change, and the path between them is
// a Recording's name rather than anything this program chose.
@(private)
SAMPLES_MARK :: " samples, "
@(private)
SECONDS_MARK :: " sec)"

// How far apart the banner's two numbers may be and still be one length, in
// milliseconds.
//
// The Engine prints the seconds to ONE DECIMAL, so the two differ by up to fifty
// milliseconds by construction -- 4,063,182 samples is 253.948875 seconds and
// the banner says `253.9 sec`. A second is twenty times that, and what it is
// really guarding is a banner this reader has stopped understanding: two numbers
// that are not two spellings of one duration mean a field moved or a unit
// changed, and a duration read out of a line that changed meaning is worse than
// no duration at all, because the fallback estimate keys on it.
@(private)
BANNER_AGREEMENT_MS :: i64(1000)

// The audio's length out of one startup banner.
@(private)
read_banner :: proc(line: string) -> (said: Engine_Line, ok: bool) {
	// Found from the END of the line, because the path in front of the marker is
	// a Recording's own name and may contain the marker itself --
	// `C:\my samples, 2019\talk.wav` does. The real one is always the last: what
	// follows it is the Engine's own fixed text.
	mark := strings.last_index(line, SAMPLES_MARK)
	if mark < 0 {
		return {}, false
	}
	rest := line[mark + len(SAMPLES_MARK):]
	close := strings.index(rest, SECONDS_MARK)
	if close < 0 {
		return {}, false
	}

	// BOTH, AND THEY MUST AGREE, and neither stands in for the other.
	//
	// This read one where the other was unreadable for the length of one test
	// run, on the reasoning that a reformatted field should not cost the duration
	// outright -- and it accepted a forty-digit sample count next to `1.0 sec` as
	// one second of audio, which is the shape an interleaved line leaves behind.
	// The redundancy that ADR-0012 actually asks for is not INSIDE this line: it
	// is the banner OR the container probe, and the probe has already answered by
	// the time the Engine starts. So a banner half of which this reader cannot
	// read is a banner it has stopped understanding, and the probe's answer
	// stands.
	from_samples, counted := samples_ms(line[:mark])
	from_seconds, timed := seconds_ms(rest[:close])
	if !counted || !timed {
		return {}, false
	}
	if !banner_agrees(from_samples, from_seconds) {
		return {}, false
	}
	// The sample count is what is kept, and the precision runs that way round:
	// the seconds are one decimal place and 49 ms short of the truth on the
	// fixture's own Recording.
	return Engine_Line{says = .Duration, duration_ms = from_samples}, true
}

// Whether the banner's two numbers are one length said twice.
@(private)
banner_agrees :: proc(from_samples, from_seconds: i64) -> bool {
	assert(from_samples > 0, "a sample count that was refused was compared anyway")
	assert(from_seconds > 0, "a seconds reading that was refused was compared anyway")

	gap := from_samples - from_seconds
	if gap < 0 {
		gap = -gap
	}
	return gap <= BANNER_AGREEMENT_MS
}

// The run of digits at the end of the banner's first half, as milliseconds.
//
// AUDIO_SAMPLE_RATE and not a number spelled here, which is the third consumer
// of that constant and the point of its being one: ffmpeg is asked for 16 kHz in
// this same file, `transcibr:audio` requires the produced audio to carry it, and
// this divides by it. Spelled again, a change to the rate would leave every
// Recording's banner reporting a length nothing else agrees with.
@(private)
samples_ms :: proc(head: string) -> (duration_ms: i64, ok: bool) {
	at := len(head)
	for at > 0 && head[at - 1] >= '0' && head[at - 1] <= '9' {
		at -= 1
	}
	samples, readable := read_natural(head[at:])
	if !readable || samples <= 0 {
		return 0, false
	}

	// Rounded rather than truncated, for read_duration's own reason next door: a
	// sample count is exact and the millisecond it lands between is not.
	rounded := (samples * 1000 + AUDIO_SAMPLE_RATE / 2) / AUDIO_SAMPLE_RATE
	if rounded <= 0 || rounded > LONGEST_CONTAINER_MS {
		return 0, false
	}
	return rounded, true
}

// The banner's printed seconds, as milliseconds.
@(private)
seconds_ms :: proc(text: string) -> (duration_ms: i64, ok: bool) {
	seconds, readable := strconv.parse_f64(strings.trim_space(text))
	if !readable {
		return 0, false
	}
	// Refused before the arithmetic: an infinity multiplied by a thousand and
	// cast to i64 is a number no standard defines, and a NaN compares false
	// against every bound there is.
	if math.is_nan(seconds) || math.is_inf(seconds) {
		return 0, false
	}
	return milliseconds_of(seconds)
}
