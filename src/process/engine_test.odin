#+vet explicit-allocators
package process

import "core:strings"
import "core:testing"

// One real run of whisper.cpp v1.9.1 cuBLAS, captured byte for byte off standard
// error and committed under `**/fixtures/** -text` so a checkout cannot rewrite its
// CRLF endings.
@(private)
ENGINE_STDERR :: #load("fixtures/engine-stderr.txt", string)

@(test)
the_real_engine_output_reads_as_the_progress_it_reported :: proc(t: ^testing.T) {
	r: Line_Reader
	readings := make([dynamic]int, context.allocator)
	defer delete(readings)

	remaining := ENGINE_STDERR
	for len(remaining) > 0 {
		chunk := remaining[:min(7, len(remaining))]
		remaining = remaining[len(chunk):]
		for {
			line, ok := next_line(&r, &chunk)
			if !ok {
				break
			}
			if said := read_engine_line(line); said.says == .Progress {
				append(&readings, said.percent)
			}
		}
	}

	expected := [?]int{10, 21, 27, 33, 42, 52, 64, 75, 85, 94, 100}
	if !testing.expect_value(t, len(readings), len(expected)) {
		return
	}
	for want, at in expected {
		testing.expect_value(t, readings[at], want)
	}
}

@(test)
the_engine_is_handed_exactly_one_input_file :: proc(t: ^testing.T) {
	arguments := engine_arguments(
		Engine_Job {
			model = "C:\\models\\ggml-large-v3-turbo.bin",
			audio = "C:\\cache\\lecture.wav",
			prefix = "C:\\cache\\lecture",
		},
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	inputs := 0
	for argument, at in arguments {
		if argument == "-f" {
			inputs += 1
			if !testing.expect(t, at + 1 < len(arguments), "-f names no file after it") {
				return
			}
			testing.expect_value(t, arguments[at + 1], "C:\\cache\\lecture.wav")
		}
	}
	testing.expect_value(t, inputs, 1)
	testing.expect_value(t, len(arguments), 8)
}

@(test)
the_engine_is_asked_for_json_and_for_progress :: proc(t: ^testing.T) {
	arguments := engine_arguments(
		Engine_Job{model = "m.bin", audio = "a.wav", prefix = "out"},
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	json, progress, model := false, false, false
	for argument, at in arguments {
		switch argument {
		case "-oj":
			json = true
		case "-pp":
			progress = true
		case "-m":
			model = at + 1 < len(arguments) && arguments[at + 1] == "m.bin"
		}
	}
	testing.expect(t, json, "the Engine was not asked for JSON, so there is nothing to parse")
	testing.expect(t, progress, "the Engine was not asked for progress, so the bar never moves")
	testing.expect(t, model, "the Engine was not told which Model to load")
}

@(test)
the_engine_is_pointed_at_a_prefix_and_appends_the_extension_itself :: proc(t: ^testing.T) {
	arguments := engine_arguments(
		Engine_Job{model = "m.bin", audio = "a.wav", prefix = "C:\\cache\\lecture"},
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	prefixed := false
	for argument, at in arguments {
		if argument == "-of" {
			prefixed = at + 1 < len(arguments) && arguments[at + 1] == "C:\\cache\\lecture"
		}
	}
	testing.expect(t, prefixed, "the Engine was not told where to write its output")

	produced := engine_output_path("C:\\cache\\lecture", context.allocator)
	defer delete(produced, context.allocator)
	testing.expect_value(t, produced, "C:\\cache\\lecture.json")
}

// The failure scenario PR #67's round-2 review named directly: `--prompt` is
// recorded in a Sidecar but never reaches the Engine unless this passes.
@(test)
a_job_with_a_prompt_gets_the_flag_and_its_own_text :: proc(t: ^testing.T) {
	arguments := engine_arguments(
		Engine_Job {
			model = "m.bin",
			audio = "a.wav",
			prefix = "out",
			prompt = "Kubernetes, Grafana, Prometheus",
		},
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	testing.expect_value(t, len(arguments), 10)
	flagged := false
	for argument, at in arguments {
		if argument == "--prompt" {
			flagged = true
			testing.expectf(
				t,
				at + 1 < len(arguments) && arguments[at + 1] == "Kubernetes, Grafana, Prometheus",
				"--prompt was not immediately followed by the Job's own prompt",
			)
		}
	}
	testing.expect(t, flagged, "a Job carrying a prompt produced no --prompt flag at all")
}

@(test)
a_job_with_no_prompt_gets_no_prompt_flag_at_all :: proc(t: ^testing.T) {
	arguments := engine_arguments(
		Engine_Job{model = "m.bin", audio = "a.wav", prefix = "out"},
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	testing.expect_value(t, len(arguments), 8)
	for argument in arguments {
		testing.expect(t, argument != "--prompt", "an unset prompt still produced a --prompt flag")
	}
}

// A prompt is free text a user typed, and goes through the same command-line
// quoting every other argument does -- spaces, quotes, trailing backslashes,
// tabs and non-ASCII among them, the exact cases `command_line_test.odin`
// already measured `build_command_line` against.
@(test)
a_prompt_goes_through_the_same_quoting_every_argument_gets :: proc(t: ^testing.T) {
	cases := make([dynamic]string, 0, context.allocator)
	defer delete(cases)
	append(&cases, ..WHITESPACE_CASES)
	append(&cases, ..QUOTE_AND_BACKSLASH_CASES)
	append(&cases, ..NON_ASCII_CASES)

	for prompt, i in cases {
		arguments := engine_arguments(
			Engine_Job{model = "m.bin", audio = "a.wav", prefix = "out", prompt = prompt},
			context.allocator,
		)
		defer delete(arguments, context.allocator)

		if !testing.expectf(
			t,
			len(arguments) == 10 && arguments[8] == "--prompt" && arguments[9] == prompt,
			"prompt case %d: the --prompt pair was not built as expected",
			i,
		) {
			continue
		}
		expect_round_trip(t, EXE, arguments, tprint_case("engine-prompt", i, "round-trip"))
	}
}

@(test)
the_real_engine_output_reports_one_duration_and_no_other :: proc(t: ^testing.T) {
	r: Line_Reader
	durations := make([dynamic]i64, context.allocator)
	defer delete(durations)

	remaining := ENGINE_STDERR
	for {
		line, ok := next_line(&r, &remaining)
		if !ok {
			break
		}
		if said := read_engine_line(line); said.says == .Duration {
			append(&durations, said.duration_ms)
		}
	}

	if !testing.expect_value(t, len(durations), 1) {
		return
	}
	testing.expect_value(t, durations[0], i64(253_949))
}

@(private)
REAL_BANNER :: "main: processing 'C:\\tmp\\transcibr\\recording.wav' (4063182 samples, 253.9 sec), 4 threads, 1 processors, 5 beams + best of 5, lang = en, task = transcribe, timestamps = 1 ..."

@(test)
the_real_startup_banner_reads_as_the_audios_length :: proc(t: ^testing.T) {
	said := read_engine_line(REAL_BANNER)
	testing.expect_value(t, said.says, Engine_Says.Duration)

	testing.expect_value(t, said.duration_ms, i64(253_949))
}

@(test)
the_banner_and_the_container_probe_answer_the_same_length :: proc(t: ^testing.T) {
	banner := read_engine_line(REAL_BANNER)
	probed, fault := read_probe("codec_type=audio\nduration=253.948844\n")
	testing.expect_value(t, fault, Probe_Fault.None)

	gap := banner.duration_ms - probed.duration_ms
	testing.expectf(
		t,
		gap >= -1 && gap <= 1,
		"the banner says %d ms and the container says %d ms",
		banner.duration_ms,
		probed.duration_ms,
	)
}

@(test)
a_banner_whose_path_carries_the_marker_still_reads :: proc(t: ^testing.T) {
	said := read_engine_line(
		"main: processing 'C:\\my samples, 2019\\talk.wav' (32000 samples, 2.0 sec), 4 threads",
	)
	testing.expect_value(t, said.says, Engine_Says.Duration)
	testing.expect_value(t, said.duration_ms, i64(2_000))
}

@(test)
a_banner_only_half_of_which_reads_is_refused :: proc(t: ^testing.T) {
	for line in ([?]string {
			"main: processing 'a.wav' (many samples, 253.9 sec), 4 threads",
			"main: processing 'a.wav' (9999999999999999999999999999999999999999 samples, 1.0 sec)",
			"main: processing 'a.wav' (4063182 samples, about four minutes sec), 4 threads",
		}) {
		said := read_engine_line(line)
		testing.expectf(t, said.says == .Nothing, "%q read as a duration", line)
	}
}

@(test)
a_banner_whose_two_numbers_disagree_is_refused :: proc(t: ^testing.T) {
	said := read_engine_line("main: processing 'a.wav' (16000 samples, 900.0 sec), 4 threads")
	testing.expect_value(t, said.says, Engine_Says.Nothing)
	testing.expect_value(t, said.duration_ms, i64(0))
}

@(test)
a_signed_number_is_refused :: proc(t: ^testing.T) {
	_, ok := read_natural("-5")
	testing.expect(t, !ok, "a leading '-' still read as a natural number")
}

@(test)
a_sample_count_that_rounds_to_no_time_at_all_is_refused :: proc(t: ^testing.T) {
	_, ok := samples_ms("1")
	testing.expect(
		t,
		!ok,
		"a sample count that rounds to zero milliseconds still read as a duration",
	)
}

@(test)
a_banner_that_reports_no_audio_at_all_is_refused :: proc(t: ^testing.T) {
	for line in ([?]string {
			"main: processing 'a.wav' (0 samples, 0.0 sec), 4 threads",
			"main: processing 'a.wav' ( samples,  sec), 4 threads",
			"main: processing 'a.wav' (7 samples, 0.0004 sec), 4 threads",
		}) {
		said := read_engine_line(line)
		testing.expectf(t, said.says == .Nothing, "%q read as a duration", line)
	}
}

@(test)
a_banner_claiming_more_audio_than_there_can_be_is_refused :: proc(t: ^testing.T) {
	said := read_engine_line(
		"main: processing 'a.wav' (999999999999 samples, 62500000.0 sec), 4 threads",
	)
	testing.expect_value(t, said.says, Engine_Says.Nothing)
}

@(test)
a_line_that_is_not_a_banner_reads_as_no_duration :: proc(t: ^testing.T) {
	for line in ([?]string {
			"main: processing 'a.wav' (4063182 samples), 4 threads",
			"read_audio_data: reading audio data from 'C:\\tmp\\transcibr\\recording.wav' ...",
			"whisper_print_timings:   sample time =  1038.30 ms /  3407 runs",
			" samples,  sec)",
		}) {
		said := read_engine_line(line)
		testing.expectf(t, said.says == .Nothing, "%q read as a duration", line)
	}
}

@(test)
a_real_progress_line_reads_as_a_percentage :: proc(t: ^testing.T) {
	said := read_engine_line("whisper_print_progress_callback: progress =  42%")
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 42)
}

@(test)
the_engines_last_progress_line_reads_as_a_hundred :: proc(t: ^testing.T) {
	said := read_engine_line("whisper_print_progress_callback: progress = 100%")
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 100)
}

@(test)
a_progress_line_that_still_carries_its_carriage_return_reads :: proc(t: ^testing.T) {
	said := read_engine_line("whisper_print_progress_callback: progress =  21%\r")
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 21)
}

@(test)
a_progress_line_behind_a_colour_code_still_reads :: proc(t: ^testing.T) {
	said := read_engine_line("\x1b[32mwhisper_print_progress_callback: progress =  75%")
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 75)
}

@(test)
a_percentage_past_a_hundred_is_refused :: proc(t: ^testing.T) {
	said := read_engine_line("whisper_print_progress_callback: progress = 101%")
	testing.expect_value(t, said.says, Engine_Says.Nothing)
	testing.expect_value(t, said.percent, 0)
}

@(test)
a_negative_percentage_is_refused :: proc(t: ^testing.T) {
	said := read_engine_line("whisper_print_progress_callback: progress =  -5%")
	testing.expect_value(t, said.says, Engine_Says.Nothing)
}

@(test)
a_percentage_that_is_not_a_number_is_refused :: proc(t: ^testing.T) {
	for reading in ([?]string{"nan", "12.5", "lots", "", "1e3", "0x10", "1_0", "+7"}) {
		line := strings.concatenate(
			{"whisper_print_progress_callback: progress = ", reading, "%"},
			context.allocator,
		)
		defer delete(line, context.allocator)

		said := read_engine_line(line)
		testing.expectf(t, said.says == .Nothing, "%q read as a percentage", reading)
	}
}

@(test)
a_progress_line_the_pipe_cut_in_half_is_refused :: proc(t: ^testing.T) {
	for cut in ([?]string {
			"whisper_print_progress_callback: progr",
			"whisper_print_progress_callback: progress =",
			"whisper_print_progress_callback: progress =  4",
		}) {
		said := read_engine_line(cut)
		testing.expectf(t, said.says == .Nothing, "%q read as a percentage", cut)
	}
}

@(test)
two_progress_lines_interleaved_read_as_nothing :: proc(t: ^testing.T) {
	said := read_engine_line(
		"whisper_print_progress_callback: progress =  4whisper_print_progress_callback: progress =  50%",
	)
	testing.expect_value(t, said.says, Engine_Says.Nothing)
}

@(test)
the_lines_the_engine_writes_around_its_progress_read_as_nothing :: proc(t: ^testing.T) {
	for line in ([?]string {
			"whisper_model_load: n_vocab       = 51866",
			"whisper_init_state: kv self size  =   10.49 MB",
			"whisper_print_timings:     load time =  1073.75 ms",
			"whisper_model_load:        CUDA0 total size =  1623.92 MB",
			"",
		}) {
		said := read_engine_line(line)
		testing.expectf(t, said.says == .Nothing, "%q read as something", line)
	}
}

@(test)
a_path_transcibr_can_direct_the_engine_at_is_accepted :: proc(t: ^testing.T) {
	testing.expect(t, ascii_only("C:\\Users\\drenj\\AppData\\Local\\transcibr\\cache"))
	testing.expect(t, ascii_only("C:\\models\\ggml-large-v3.bin"))
	testing.expect(t, ascii_only(""))
}

@(test)
a_path_the_engine_could_not_open_is_refused :: proc(t: ^testing.T) {
	testing.expect(t, !ascii_only("C:\\Users\\Bj\u00f6rn\\AppData\\Local\\transcibr\\cache"))
	testing.expect(t, !ascii_only("D:\\\u5f55\u97f3\\cache"))
	testing.expect(t, !ascii_only("C:\\models\\ggml-large-v3-t\u00fcrkce.bin"))
}
