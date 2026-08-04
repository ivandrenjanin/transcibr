#+vet explicit-allocators
package process

import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

// The two children that turn a Recording into audio: the argument lists ffmpeg and
// ffprobe are started with, and the probe's answer read back. ffprobe ships in the
// same distribution as ffmpeg and is bundled with it (ADR-0013), so one file holds both.

// The audio the Engine reads, spelled once for the ffmpeg arguments here and for the
// check `transcibr:audio` makes on the produced WAV. Why all three, the bit depth
// included: ADR-0022.
AUDIO_SAMPLE_RATE :: 16000
AUDIO_CHANNELS :: 1
AUDIO_BITS_PER_SAMPLE :: 16

// Written out rather than formatted at every call: an argument list that allocated
// its own strings would make the caller free the strings as well as the slice.
@(private)
AUDIO_SAMPLE_RATE_ARGUMENT :: "16000"
@(private)
AUDIO_CHANNELS_ARGUMENT :: "1"
@(private)
AUDIO_SAMPLE_FORMAT_ARGUMENT :: "pcm_s16le"

// The numbers against the literals their spellings carry, held by the compiler: an
// edit to one and not the other fails before a test runs.
#assert(AUDIO_SAMPLE_RATE == 16000)
#assert(AUDIO_CHANNELS == 1)
#assert(AUDIO_BITS_PER_SAMPLE == 16)

// Why one `-show_entries`, and why `stream=duration` is absent: ADR-0022.
@(private)
PROBE_ENTRIES :: "format=duration:stream=codec_type"

// Not `-of json`: nothing in the answer needs a JSON parser between transcibr and a
// duration.
@(private)
PROBE_FORMAT :: "default=noprint_wrappers=1"

Probe :: struct {
	// Milliseconds rather than seconds because it is carried with the job, written
	// to the Sidecar and compared against another duration.
	duration_ms:   i64,
	// Zero is a legitimate answer and not a fault here: the refusal that names the
	// file belongs to the caller that knows the file's name.
	audio_streams: int,
}

// Every one is an operating error, and every one is measured; see ADR-0022.
Probe_Fault :: enum u8 {
	None = 0,
	Said_Nothing,
	No_Duration,
	Duration_Unknown,
	Duration_Unreadable,
	Duration_Not_Positive,
}

// A thousand hours: not a policy on Recording length but the guard that stops a
// nonsense duration reaching the arithmetic downstream, and thirteen times the
// 75-hour whole Batch of the reference corpus.
@(private)
LONGEST_CONTAINER_MS :: i64(1000 * 60 * 60 * 1000)

@(require_results)
read_probe :: proc(output: string) -> (probe: Probe, fault: Probe_Fault) {
	if len(strings.trim_space(output)) == 0 {
		return {}, .Said_Nothing
	}

	said_duration := false
	remaining := output
	for line in strings.split_lines_iterator(&remaining) {
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

@(private)
@(require_results)
read_duration :: proc(value: string) -> (duration_ms: i64, fault: Probe_Fault) {
	if value == "N/A" {
		return 0, .Duration_Unknown
	}

	seconds, readable := strconv.parse_f64(value)
	if !readable {
		return 0, .Duration_Unreadable
	}
	if math.is_nan(seconds) || math.is_inf(seconds) {
		return 0, .Duration_Unreadable
	}
	rounded, usable := milliseconds_of(seconds)
	if !usable {
		return 0, .Duration_Not_Positive
	}
	return rounded, .None
}

// Shared by the two sources a duration may come from -- ffprobe's `duration=` and
// the Engine's startup banner -- so a rounding or a ceiling cannot hold in one and
// not the other. NaN and infinity are refused by each caller before this.
@(private)
@(require_results)
milliseconds_of :: proc(seconds: f64) -> (duration_ms: i64, ok: bool) {
	if seconds < 0 || seconds > f64(LONGEST_CONTAINER_MS) / 1000 {
		return 0, false
	}

	rounded := i64(math.round(seconds * 1000))
	if rounded <= 0 {
		return 0, false
	}
	return rounded, true
}

// `answer` is a file and not a pipe: ADR-0004 sends every child's standard output to
// the null device, and ffprobe prints its answer there like everything else. The
// caller owns the returned slice; the strings in it are borrowed and outlive nothing
// the caller does not already hold.
@(require_results)
probe_arguments :: proc(
	source: string,
	answer: string,
	allocator: mem.Allocator,
) -> (
	arguments: []string,
) {
	assert(allocator.procedure != nil, "an argument list needs an allocator to be built in")
	assert(len(source) > 0, "there is no Recording here to probe")
	assert(len(answer) > 0, "a probe with nowhere to write its answer says nothing")

	arguments = make([]string, 10, allocator)
	arguments[0] = "-v"
	arguments[1] = "error"
	arguments[2] = "-show_entries"
	arguments[3] = PROBE_ENTRIES
	arguments[4] = "-of"
	arguments[5] = PROBE_FORMAT
	arguments[6] = "-o"
	arguments[7] = answer
	arguments[8] = "-i"
	arguments[9] = source
	return arguments
}

// The same borrowing rule as probe_arguments: the caller frees the slice and nothing
// in it.
@(require_results)
extract_arguments :: proc(
	source: string,
	destination: string,
	allocator: mem.Allocator,
) -> (
	arguments: []string,
) {
	assert(allocator.procedure != nil, "an argument list needs an allocator to be built in")
	assert(len(source) > 0, "there is no Recording here to extract from")
	assert(len(destination) > 0, "an extraction with nowhere to write produces nothing")

	arguments = make([]string, 21, allocator)
	arguments[0] = "-nostdin"
	arguments[1] = "-hide_banner"
	arguments[2] = "-loglevel"
	arguments[3] = "error"
	arguments[4] = "-y"
	arguments[5] = "-i"
	arguments[6] = source
	copy(arguments[7:], OUTPUT_ARGUMENTS[:])
	arguments[20] = destination

	for argument in arguments {
		assert(len(argument) > 0, "the argument list left a slot empty")
	}
	return arguments
}

// Everything between the input and the destination. What each of these defends
// against, measured: ADR-0022.
@(private, rodata)
OUTPUT_ARGUMENTS := [13]string {
	"-vn",
	"-sn",
	"-dn",
	"-map",
	"0:a:0",
	"-ac",
	AUDIO_CHANNELS_ARGUMENT,
	"-ar",
	AUDIO_SAMPLE_RATE_ARGUMENT,
	"-c:a",
	AUDIO_SAMPLE_FORMAT_ARGUMENT,
	"-f",
	"wav",
}
