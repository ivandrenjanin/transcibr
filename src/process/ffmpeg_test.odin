package process

import "core:strconv"
import "core:strings"
import "core:testing"

// Real ffprobe N-125907 output over a 0.2-second clip, committed byte for byte under
// `**/fixtures/** -text` so a checkout cannot rewrite its line endings.
@(private)
PROBE_VIDEO_AND_AUDIO :: #load("fixtures/ffprobe-video-and-audio.txt", string)
@(private)
PROBE_VIDEO_ONLY :: #load("fixtures/ffprobe-video-only.txt", string)

@(test)
a_real_probe_answer_yields_the_container_duration_and_its_audio_stream :: proc(t: ^testing.T) {
	probe, fault := read_probe(PROBE_VIDEO_AND_AUDIO)
	testing.expect_value(t, fault, Probe_Fault.None)

	testing.expect_value(t, probe.duration_ms, i64(200))
	testing.expect_value(t, probe.audio_streams, 1)
}

@(test)
a_real_probe_answer_for_a_source_with_no_audio_counts_no_audio_streams :: proc(t: ^testing.T) {
	probe, fault := read_probe(PROBE_VIDEO_ONLY)
	testing.expect_value(t, fault, Probe_Fault.None)

	testing.expect_value(t, probe.duration_ms, i64(200))
	testing.expect_value(t, probe.audio_streams, 0)
}

@(test)
a_probe_that_answered_nothing_at_all_is_refused :: proc(t: ^testing.T) {
	_, fault := read_probe("")
	testing.expect_value(t, fault, Probe_Fault.Said_Nothing)
}

@(test)
a_probe_that_could_not_time_the_container_is_refused :: proc(t: ^testing.T) {
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
	_, fault := read_probe("codec_type=audio\nduration=0.000000\n")
	testing.expect_value(t, fault, Probe_Fault.Duration_Not_Positive)
}

@(test)
a_container_too_short_to_round_to_a_millisecond_is_refused :: proc(t: ^testing.T) {
	_, tiny := read_probe("codec_type=audio\nduration=0.000375\n")
	testing.expect_value(t, tiny, Probe_Fault.Duration_Not_Positive)
	_, tinier := read_probe("codec_type=audio\nduration=0.000021\n")
	testing.expect_value(t, tinier, Probe_Fault.Duration_Not_Positive)
	_, half := read_probe("codec_type=audio\nduration=0.000499\n")
	testing.expect_value(t, half, Probe_Fault.Duration_Not_Positive)

	shortest, none := read_probe("codec_type=audio\nduration=0.000500\n")
	testing.expect_value(t, none, Probe_Fault.None)
	testing.expect_value(t, shortest.duration_ms, i64(1))
}

@(test)
carriage_returns_in_a_probe_answer_do_not_hide_the_duration :: proc(t: ^testing.T) {
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
each_number_ffmpeg_is_asked_for_is_the_number_the_check_demands :: proc(t: ^testing.T) {
	rate, rate_readable := strconv.parse_int(AUDIO_SAMPLE_RATE_ARGUMENT)
	testing.expect(t, rate_readable, "the rate ffmpeg is asked for is not a number")
	testing.expect_value(t, rate, AUDIO_SAMPLE_RATE)

	channels, channels_readable := strconv.parse_int(AUDIO_CHANNELS_ARGUMENT)
	testing.expect(t, channels_readable, "the channel count ffmpeg is asked for is not a number")
	testing.expect_value(t, channels, AUDIO_CHANNELS)

	testing.expect_value(t, AUDIO_SAMPLE_FORMAT_ARGUMENT, "pcm_s16le")
}

@(test)
a_recording_whose_path_needs_quoting_survives_the_command_line :: proc(t: ^testing.T) {
	arguments := extract_arguments(
		"C:\\my videos\\a talk.mp4",
		"C:\\cache\\1.wav.part",
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	line, err := build_command_line("C:\\ffmpeg\\bin\\ffmpeg.exe", arguments, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.None)

	testing.expect(
		t,
		strings.contains(line, "\"C:\\my videos\\a talk.mp4\""),
		"the Recording's path reached the command line unquoted",
	)
}
