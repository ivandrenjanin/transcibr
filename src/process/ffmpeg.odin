package process

import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

// This file holds the two children that turn a Recording into audio: the exact
// argument lists ffmpeg and ffprobe are started with, and what the probe's
// answer means read back.
//
// It is here rather than beside the extraction because that is what this module
// IS -- "everything pure about driving a child process: the command line one is
// started with, and the output lines it writes read back as progress and
// duration" (CONTEXT.md). ffprobe is a child; its answer read back as a
// duration is this module's second half arriving early, for a different child
// from the one the spec's sentence names. What the answer is then USED for --
// refusing a Recording with no audio, measuring the produced audio against it --
// is the shell's, and lives in `transcibr:audio`.
//
// ffprobe ships in the same distribution as ffmpeg and is bundled with it
// (ADR-0013), so one file holds both.

// The audio the Engine reads: one channel at 16 kHz, signed 16 bits a sample.
//
// Held as constants, and spelled once. `transcibr:audio` checks the produced
// audio against these and ffmpeg is asked for them here, which is A4's paired
// write side and read side -- the same claim in two places. Spelled twice they
// drift, and the drift is silent: ffmpeg is asked for 16,000 while the check
// demands 44,100, and every Recording in the Batch fails for a reason that
// appears in neither.
//
// ALL THREE, because two of them were paired and the third was not: `pcm_s16le`
// was asked for and nothing read the bit depth back, so a WAV declaring eight
// bits a sample was accepted as the audio the Engine reads.
AUDIO_SAMPLE_RATE :: 16000
AUDIO_CHANNELS :: 1
AUDIO_BITS_PER_SAMPLE :: 16

// The same three numbers as ffmpeg spells them. Written out rather than
// formatted at every call: an argument list that allocated its own strings would
// make the caller free the strings as well as the slice, and the whole point of
// the borrowing rule below is that it does not have to.
//
// The depth's spelling is a CODEC NAME rather than a number, so the compiler
// cannot hold it against AUDIO_BITS_PER_SAMPLE the way it holds the other two.
// `s16` is the sixteen; `le` is the byte order the WAV walk decodes with.
@(private)
AUDIO_SAMPLE_RATE_ARGUMENT :: "16000"
@(private)
AUDIO_CHANNELS_ARGUMENT :: "1"
@(private)
AUDIO_SAMPLE_FORMAT_ARGUMENT :: "pcm_s16le"

// The numbers against their own spellings, held by the COMPILER. An edit to one
// and not the other is what this catches, and it catches it before a test runs.
#assert(AUDIO_SAMPLE_RATE == 16000)
#assert(AUDIO_CHANNELS == 1)
#assert(AUDIO_BITS_PER_SAMPLE == 16)

// What ffprobe is asked to print, and how.
//
// ONE `-show_entries`, not two: a second occurrence REPLACES the first rather
// than adding to it, so `format=duration -show_entries stream=codec_type` asks
// only for the codec types and the duration silently disappears.
//
// `stream=duration` is deliberately absent, and its absence is load-bearing: a
// stream duration prints under the same `duration=` key as the format duration,
// so asking for both produces two indistinguishable lines and the reader below
// cannot say which container it is holding.
@(private)
PROBE_ENTRIES :: "format=duration:stream=codec_type"

// `key=value` a line at a time, with no section headers around it. The
// alternative is `-of json`, which would put a JSON parser between transcibr and
// a duration -- and there is nothing in the answer that needs one.
@(private)
PROBE_FORMAT :: "default=noprint_wrappers=1"

// What one container probe said about a Recording.
Probe :: struct {
	// The container's own claim about how long the Recording is. Milliseconds
	// rather than seconds because it is carried with the job, written to the
	// Sidecar and compared against another duration -- and a float that has
	// been through a comparison is a value nobody can pin in a test.
	duration_ms:   i64,
	// How many audio streams the container declares. ZERO IS A LEGITIMATE
	// ANSWER and not a fault here: it is a fact about the Recording, and the
	// refusal that names the file belongs to the caller that knows the file's
	// name.
	audio_streams: int,
}

// What was wrong with a probe's answer.
//
// Every one is an OPERATING error (A8): the answer was written by ffprobe about
// a file transcibr did not write, so a Recording whose container cannot be timed
// fails on its own and the Batch carries on.
Probe_Fault :: enum u8 {
	None = 0,
	// Nothing at all. MEASURED: pointed at a file that is not media, ffprobe
	// exits 1, writes its diagnostic to standard error and leaves a zero-byte
	// answer. Distinct from every fault below, because it is the whole file
	// being unreadable rather than one thing about it being unknown.
	Said_Nothing,
	// Lines, but no `duration=` among them.
	No_Duration,
	// `duration=N/A`, which is ffprobe saying it cannot time this container --
	// measured against a raw MPEG-4 elementary stream. Apart from
	// `.Duration_Unreadable` because the answer is well formed and the
	// container is not, which is the difference between an ffprobe this
	// package has stopped understanding and a Recording that needs remuxing.
	Duration_Unknown,
	// A `duration=` carrying something that is not a number at all.
	Duration_Unreadable,
	// Zero, negative, or too large to be a Recording. Zero is the one that
	// matters: it would make every duration comparison downstream agree with
	// anything at all.
	Duration_Not_Positive,
}

// The longest Recording this package will believe a container about, in
// milliseconds: a thousand hours.
//
// Not a policy on Recording length -- it is the guard that stops a nonsense
// duration reaching the arithmetic downstream. The reference corpus's longest
// Recording is 168 minutes and its whole Batch is 75 hours, so this is more than
// thirteen times the largest Batch anyone has measured.
@(private)
LONGEST_CONTAINER_MS :: i64(1000 * 60 * 60 * 1000)

// Reads back what one container probe said.
//
// A8: every byte here came from ffprobe, so every refusal travels in `fault` and
// none of it reaches an assertion.
read_probe :: proc(output: string) -> (probe: Probe, fault: Probe_Fault) {
	if len(strings.trim_space(output)) == 0 {
		return {}, .Said_Nothing
	}

	said_duration := false
	remaining := output
	for line in strings.split_lines_iterator(&remaining) {
		// The trailing carriage return of a CRLF answer, which
		// split_lines_iterator leaves on the value: `1.5\r` parses as no
		// number at all. The fixtures are LF because that is what ffprobe
		// writes here, and nothing promises it stays that way.
		said := strings.trim_space(line)
		switch {
		case said == "codec_type=audio":
			probe.audio_streams += 1
		case strings.has_prefix(said, "duration="):
			probe.duration_ms, fault = read_duration(said[len("duration="):])
			if fault != .None {
				return {}, fault
			}
			said_duration = true
		}
	}

	if !said_duration {
		return {}, .No_Duration
	}
	assert(probe.duration_ms > 0, "a probe was accepted without a positive duration")
	assert(probe.audio_streams >= 0, "a probe counted a negative number of audio streams")
	return probe, .None
}

// One `duration=` value as whole milliseconds.
@(private)
read_duration :: proc(value: string) -> (duration_ms: i64, fault: Probe_Fault) {
	if value == "N/A" {
		return 0, .Duration_Unknown
	}

	seconds, readable := strconv.parse_f64(value)
	if !readable {
		return 0, .Duration_Unreadable
	}
	// Refused before the arithmetic rather than after: an infinity multiplied
	// by a thousand and cast to i64 is an implementation-defined number, and a
	// NaN compares false against every bound there is.
	if math.is_nan(seconds) || math.is_inf(seconds) {
		return 0, .Duration_Unreadable
	}
	// Bounded, not yet judged: what this stops is the multiplication below
	// walking into a cast no standard defines. Whether the duration is usable
	// is decided on the rounded value.
	if seconds < 0 || seconds > f64(LONGEST_CONTAINER_MS) / 1000 {
		return 0, .Duration_Not_Positive
	}

	// Rounded rather than truncated: ffprobe prints six decimals, and 0.2
	// seconds arrives as a binary fraction a hair under 200 milliseconds.
	rounded := i64(math.round(seconds * 1000))
	// THE ROUNDED VALUE IS WHAT IS REFUSED, and the seconds were only bounded.
	// A container of a handful of timescale ticks -- three samples at 8 kHz
	// prints as `duration=0.000375` -- is a positive number of seconds and a
	// zero number of milliseconds, so a guard applied before the rounding hands
	// a zero duration back with no fault on it. read_probe's postcondition then
	// fires on bytes ffprobe wrote, which is an assertion reached from outside
	// this program (A8) and a Batch that dies on one degenerate container
	// instead of failing that Recording and carrying on (ADR-0002).
	if rounded <= 0 {
		return 0, .Duration_Not_Positive
	}
	// The write side of read_probe's own assertion (A4): every duration that
	// leaves here without a fault is one that comparison downstream can divide
	// by and measure against.
	assert(rounded > 0, "a duration came back from the refusal above still not positive")
	return rounded, .None
}

// The arguments ffprobe is started with to time one Recording.
//
// `answer` is where ffprobe writes what it found. A FILE and not a pipe, which
// is not a preference: ADR-0004 sends every child's standard output to the null
// device, because the Engine floods that stream during inference and an
// undrained pipe wedges it. ffprobe prints its answer to standard output like
// everything else, so `-o` is what lets one spawner serve both children.
//
// The caller owns the returned slice and frees it with `delete` and the same
// allocator. THE STRINGS IN IT ARE BORROWED, never owned: they are this
// package's own constants and the caller's own two paths, so there is nothing
// in it to free but the slice itself -- and nothing in it outlives what the
// caller already holds.
probe_arguments :: proc(
	source: string,
	answer: string,
	allocator: mem.Allocator,
) -> (
	arguments: []string,
) {
	assert(allocator.procedure != nil, "an argument list needs an allocator to be built in")

	arguments = make([]string, 10, allocator)
	arguments[0] = "-v"
	arguments[1] = "error"
	arguments[2] = "-show_entries"
	arguments[3] = PROBE_ENTRIES
	arguments[4] = "-of"
	arguments[5] = PROBE_FORMAT
	arguments[6] = "-o"
	arguments[7] = answer
	// LAST, and after `-o`: ffmpeg's option parser binds every option to the
	// file that follows it, so an input named before its options is an input
	// with none of them.
	arguments[8] = "-i"
	arguments[9] = source
	return arguments
}

// The arguments ffmpeg is started with to extract one Recording's audio.
//
// The same borrowing rule as probe_arguments: the caller frees the slice and
// nothing in it.
extract_arguments :: proc(
	source: string,
	destination: string,
	allocator: mem.Allocator,
) -> (
	arguments: []string,
) {
	assert(allocator.procedure != nil, "an argument list needs an allocator to be built in")

	arguments = make([]string, 21, allocator)
	// Standard input is the null device already (ADR-0004), so this is belt
	// and braces -- and cheap belt: ffmpeg reads standard input for
	// interactive keys and an ffmpeg that decided to prompt would hang a
	// worker (issue #27).
	arguments[0] = "-nostdin"
	arguments[1] = "-hide_banner"
	arguments[2] = "-loglevel"
	arguments[3] = "error"
	// The destination is transcibr's own `.part` file, which a previous
	// interrupted run may have left behind; without this ffmpeg asks whether
	// to overwrite it, on a standard input that is the null device.
	arguments[4] = "-y"
	arguments[5] = "-i"
	arguments[6] = source
	copy(arguments[7:], OUTPUT_ARGUMENTS[:])
	arguments[20] = destination
	return arguments
}

// Everything between the input and the destination: the options that describe
// the file being written.
//
// A package-level array rather than something extract_arguments spells inline,
// which keeps that procedure inside rule F1's limit and puts the reasoning
// beside the arguments it is about.
@(private, rodata)
OUTPUT_ARGUMENTS := [13]string {
	// No video, no subtitles, no data. A container's cover art is a video
	// stream, and without these ffmpeg tries to put it in a WAV.
	"-vn",
	"-sn",
	"-dn",
	// The FIRST audio stream and only it. A Recording with a commentary track
	// has two, and ffmpeg's default choice between them is by bitrate -- so a
	// silent high-bitrate track would win.
	"-map",
	"0:a:0",
	"-ac",
	AUDIO_CHANNELS_ARGUMENT,
	"-ar",
	AUDIO_SAMPLE_RATE_ARGUMENT,
	"-c:a",
	AUDIO_SAMPLE_FORMAT_ARGUMENT,
	// Stated rather than inferred from the destination's extension: the
	// destination is a `.part` file, and ffmpeg would have no idea what to make
	// of that.
	"-f",
	"wav",
}
