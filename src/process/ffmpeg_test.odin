package process

import "core:strings"
import "core:testing"

// The two children that turn a Recording into audio: the exact argument lists
// they are started with, and what the probe's answer means.
//
// THE FIXTURES ARE REAL PROBE OUTPUT, captured from ffprobe N-125907 against a
// 0.2-second clip and committed byte for byte under `**/fixtures/** -text`. They
// pin the shape this design bets on the way ADR-0001's Engine JSON pins its own:
// an ffprobe upgrade that stops printing `codec_type=` or renames `duration=`
// fails HERE, rather than showing up as Recordings that mysteriously report no
// audio stream.
@(private)
PROBE_VIDEO_AND_AUDIO :: #load("fixtures/ffprobe-video-and-audio.txt", string)
@(private)
PROBE_VIDEO_ONLY :: #load("fixtures/ffprobe-video-only.txt", string)

@(test)
a_real_probe_answer_yields_the_container_duration_and_its_audio_stream :: proc(t: ^testing.T) {
	probe, fault := read_probe(PROBE_VIDEO_AND_AUDIO)
	testing.expect_value(t, fault, Probe_Fault.None)

	// The clip was made 0.2 seconds long; ffprobe prints `duration=0.200000`.
	testing.expect_value(t, probe.duration_ms, i64(200))
	testing.expect_value(t, probe.audio_streams, 1)
}

@(test)
a_real_probe_answer_for_a_source_with_no_audio_counts_no_audio_streams :: proc(t: ^testing.T) {
	// The same clip muxed without its audio stream. The duration is still
	// there, which is the point: "no audio" is not "unreadable", and the two
	// have to be told apart by the count and never by the absence of a
	// duration.
	probe, fault := read_probe(PROBE_VIDEO_ONLY)
	testing.expect_value(t, fault, Probe_Fault.None)

	testing.expect_value(t, probe.duration_ms, i64(200))
	testing.expect_value(t, probe.audio_streams, 0)
}

@(test)
a_probe_that_answered_nothing_at_all_is_refused :: proc(t: ^testing.T) {
	// MEASURED: pointed at a file that is not media, ffprobe exits 1, writes
	// its diagnostic to standard error and leaves a ZERO-BYTE answer file. A
	// reader that took an empty answer as "no audio streams and no duration"
	// would report the wrong fault for every unreadable Recording there is.
	_, fault := read_probe("")
	testing.expect_value(t, fault, Probe_Fault.Said_Nothing)
}

@(test)
a_probe_that_could_not_time_the_container_is_refused :: proc(t: ^testing.T) {
	// MEASURED against a raw MPEG-4 video elementary stream: ffprobe prints
	// the codec type and `duration=N/A`. It is a live answer rather than a
	// hypothetical, and it must not read as a zero-length Recording.
	_, fault := read_probe("codec_type=video\nduration=N/A\n")
	testing.expect_value(t, fault, Probe_Fault.Duration_Unknown)
}

@(test)
a_probe_that_said_something_but_never_said_how_long_is_refused :: proc(t: ^testing.T) {
	_, fault := read_probe("codec_type=audio\n")
	testing.expect_value(t, fault, Probe_Fault.No_Duration)
}

@(test)
a_duration_that_is_not_a_number_is_refused :: proc(t: ^testing.T) {
	_, fault := read_probe("codec_type=audio\nduration=about a minute\n")
	testing.expect_value(t, fault, Probe_Fault.Duration_Unreadable)
}

@(test)
a_container_of_no_length_at_all_is_refused :: proc(t: ^testing.T) {
	// A zero-length container is not a Recording, and it is the value that
	// would make every duration comparison downstream agree with anything.
	_, fault := read_probe("codec_type=audio\nduration=0.000000\n")
	testing.expect_value(t, fault, Probe_Fault.Duration_Not_Positive)
}

@(test)
carriage_returns_in_a_probe_answer_do_not_hide_the_duration :: proc(t: ^testing.T) {
	// The fixtures are LF because that is what ffprobe writes on this machine.
	// Nothing promises it stays that way, and a value carrying a trailing \r
	// parses as no number at all.
	probe, fault := read_probe("codec_type=audio\r\nduration=61.500000\r\n")
	testing.expect_value(t, fault, Probe_Fault.None)
	testing.expect_value(t, probe.duration_ms, i64(61500))
}

@(test)
a_probe_answer_with_two_audio_streams_counts_both :: proc(t: ^testing.T) {
	probe, fault := read_probe("codec_type=audio\ncodec_type=audio\nduration=1.000000\n")
	testing.expect_value(t, fault, Probe_Fault.None)
	testing.expect_value(t, probe.audio_streams, 2)
}

// ------------------------------------------------------- the argument lists --

@(test)
the_probe_is_asked_for_exactly_the_two_things_it_is_read_for :: proc(t: ^testing.T) {
	arguments := probe_arguments("C:\\clips\\one.mp4", "C:\\cache\\one.probe", context.allocator)
	defer delete(arguments, context.allocator)

	expected := []string {
		"-v",
		"error",
		"-show_entries",
		"format=duration:stream=codec_type",
		"-of",
		"default=noprint_wrappers=1",
		"-o",
		"C:\\cache\\one.probe",
		"-i",
		"C:\\clips\\one.mp4",
	}
	testing.expect_value(t, len(arguments), len(expected))
	for want, at in expected {
		testing.expect_value(t, arguments[at], want)
	}
}

@(test)
the_extraction_asks_for_mono_16_khz_signed_16_bit_pcm :: proc(t: ^testing.T) {
	arguments := extract_arguments(
		"C:\\clips\\one.mp4",
		"C:\\cache\\one.wav.part",
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	expected := []string {
		"-nostdin",
		"-hide_banner",
		"-loglevel",
		"error",
		"-y",
		"-i",
		"C:\\clips\\one.mp4",
		"-vn",
		"-sn",
		"-dn",
		"-map",
		"0:a:0",
		"-ac",
		"1",
		"-ar",
		"16000",
		"-c:a",
		"pcm_s16le",
		"-f",
		"wav",
		"C:\\cache\\one.wav.part",
	}
	testing.expect_value(t, len(arguments), len(expected))
	for want, at in expected {
		testing.expect_value(t, arguments[at], want)
	}
}

@(test)
what_the_extraction_asks_for_is_what_the_produced_audio_is_checked_against :: proc(t: ^testing.T) {
	// The write side of a claim `transcibr:extract` checks on the read side
	// (A4). Spelled twice they drift, and the drift is silent: ffmpeg is asked
	// for 16 kHz, the check demands 44.1, and every Recording fails for a
	// reason nobody can find.
	arguments := extract_arguments("in.mp4", "out.wav", context.allocator)
	defer delete(arguments, context.allocator)

	rate := false
	channels := false
	for argument, at in arguments {
		if argument == "-ar" {
			rate = arguments[at + 1] == AUDIO_SAMPLE_RATE_ARGUMENT
		}
		if argument == "-ac" {
			channels = arguments[at + 1] == AUDIO_CHANNELS_ARGUMENT
		}
	}
	testing.expect(t, rate, "the extraction does not ask for the rate the constant names")
	testing.expect(
		t,
		channels,
		"the extraction does not ask for the channel count the constant names",
	)
	testing.expect_value(t, AUDIO_SAMPLE_RATE, 16000)
	testing.expect_value(t, AUDIO_CHANNELS, 1)
}

@(test)
a_recording_whose_path_needs_quoting_survives_the_command_line :: proc(t: ^testing.T) {
	// The two builders hand their answers to build_command_line next door, and
	// a Recording under `C:\my videos\` is the ordinary case rather than the
	// adversarial one.
	arguments := extract_arguments(
		"C:\\my videos\\a talk.mp4",
		"C:\\cache\\1.wav.part",
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	line, err := build_command_line("C:\\ffmpeg\\bin\\ffmpeg.exe", arguments, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.None)

	// Quoted, because it holds a space -- and the quoting is what stops ffmpeg
	// reading the first word of a folder name.
	testing.expect(
		t,
		strings.contains(line, "\"C:\\my videos\\a talk.mp4\""),
		"the Recording's path reached the command line unquoted",
	)
}
