package process

import "core:strings"
import "core:testing"

// The Engine's own half of the Process contract: the one command line it is
// started with, and the diagnostic lines it writes back read as progress and as
// a duration.
//
// THE FIXTURE IS ONE REAL RUN, captured byte for byte off the standard error of
// whisper.cpp v1.9.1 cuBLAS transcribing a 253.9-second Recording with
// `ggml-large-v3-turbo`, and committed under `**/fixtures/** -text` so a
// checkout cannot rewrite its CRLF endings. It pins this coupling the way
// ADR-0001's Engine JSON pins the schema: a release that renames the progress
// callback or reshapes the startup banner fails HERE, in a test, rather than
// as a bar that mysteriously never moves.
@(private)
ENGINE_STDERR :: #load("fixtures/engine-stderr.txt", string)

@(test)
the_real_engine_output_reads_as_the_progress_it_reported :: proc(t: ^testing.T) {
	// Fed through the same assembler the spawner uses, in SEVEN-BYTE chunks:
	// nothing about a pipe read aligns to a line, and a case that handed whole
	// lines in would be testing the case rather than the reader.
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

	// ELEVEN READINGS AND NOT TWENTY, and they are not 5% apart. ADR-0012 said
	// "hardcoded 5% steps, so any recording produces exactly twenty of them";
	// this fixture is that claim measured, and it says otherwise -- the callback
	// fires when a decoded segment CROSSES the next step, and reports where the
	// crossing landed. See the correction recorded in that ADR.
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
	// ADR-0002: "Never pass more than one input file per invocation." The Engine
	// takes a list -- `whisper-cli [options] file0 file1 ...` -- and one
	// invocation over two Recordings writes ONE output prefix, so the second
	// Recording's Cues land in the first Recording's file or nowhere.
	arguments := engine_arguments(
		Engine_Job {
			model = "C:\\models\\ggml-large-v3-turbo.bin",
			audio = "C:\\cache\\lecture.wav",
			prefix = "C:\\cache\\lecture",
		},
		context.allocator,
	)
	defer delete(arguments, context.allocator)

	// Counted BOTH ways (CLAUDE.md rule A3): one `-f`, and no argument standing
	// on its own where the Engine would read it as a second file0. Counting only
	// the flag passes a list that names one file after `-f` and another after
	// everything else.
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
	// MEASURED against whisper.cpp v1.9.1's own help: `-pp, --print-progress
	// [false]` and `-oj, --output-json [false]`. BOTH default off, so a command
	// line that forgets either is an Engine that runs perfectly and produces
	// neither the output ADR-0001 parses nor the progress ADR-0012 reads.
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
	// ADR-0002: the Engine "appends `.json` to whatever prefix it is given", which
	// is why it cannot be pointed at a `.part` name and why transcibr has to know
	// where to go and look afterwards. MEASURED: `-of C:\tmp\transcibr\cache\recording`
	// wrote `C:\tmp\transcibr\cache\recording.json`.
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

	// The other half: the path transcibr goes back to afterwards is that prefix
	// plus the extension the ENGINE chose, spelled in exactly one place.
	produced := engine_output_path("C:\\cache\\lecture", context.allocator)
	defer delete(produced, context.allocator)
	testing.expect_value(t, produced, "C:\\cache\\lecture.json")
}

// -------------------------------------------------------- one progress line --
//
// Every case below hands in a LINE, which is what the assembler next door
// produces and what the Engine writes one of per reading. The bytes in the
// first are copied out of the fixture, padding included: the Engine prints the
// number in a three-wide field, so `  10%` and ` 100%` are the same line with
// different amounts of space in the middle of it.

@(test)
a_real_progress_line_reads_as_a_percentage :: proc(t: ^testing.T) {
	said := read_engine_line("whisper_print_progress_callback: progress =  42%")
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 42)
}

@(test)
the_engines_last_progress_line_reads_as_a_hundred :: proc(t: ^testing.T) {
	// The one line whose number fills the field, so the space in front of it is
	// one byte rather than two. A reader that split on a fixed column would read
	// this as 10.
	said := read_engine_line("whisper_print_progress_callback: progress = 100%")
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 100)
}

@(test)
a_progress_line_that_still_carries_its_carriage_return_reads :: proc(t: ^testing.T) {
	// The fixture is CRLF, which is what the Engine writes on Windows. The
	// assembler strips the carriage return, and this reader does not depend on
	// its having done so -- a reading that vanished on one stray byte is exactly
	// the coupling ADR-0012 warns this whole file is.
	said := read_engine_line("whisper_print_progress_callback: progress =  21%\r")
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 21)
}

@(test)
a_progress_line_behind_a_colour_code_still_reads :: proc(t: ^testing.T) {
	// The Engine has a `-pc` flag and nothing promises what a later release
	// colours. An escape sequence in front of the reading is a byte sequence this
	// reader has no business understanding, so it is walked past rather than
	// matched: the mark is looked for ANYWHERE in the line and not at its start.
	said := read_engine_line("\x1b[32mwhisper_print_progress_callback: progress =  75%")
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 75)
}

@(test)
a_percentage_past_a_hundred_is_refused :: proc(t: ^testing.T) {
	// REFUSED AND NOT CLAMPED (A8). Clamped to 100 it would say the Recording is
	// finished, which is the one thing a progress display must not be wrong
	// about; refused, the fallback takes over and the bar keeps moving.
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
	// Eight shapes of not-a-number, and they are not one case repeated: `nan` is
	// what a C program prints when it divides by zero, `1_0` and `+7` are the two
	// spellings `strconv.parse_int` would have ACCEPTED and read as ten and seven,
	// `0x10` is the prefix its base inference would have taken, and a float is
	// what a release that stopped rounding the reading would write.
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
	// A read off the pipe ends wherever the kernel had bytes, so half a line is
	// ordinary rather than exotic -- the assembler holds the rest until the next
	// chunk, and until then what it has is this.
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
	// Two threads writing one stream, which is what the Engine's own logging
	// callback and its progress callback are. The reading in front is truncated
	// by the line that landed on top of it, so what this must not do is answer 4.
	said := read_engine_line(
		"whisper_print_progress_callback: progress =  4whisper_print_progress_callback: progress =  50%",
	)
	testing.expect_value(t, said.says, Engine_Says.Nothing)
}

@(test)
the_lines_the_engine_writes_around_its_progress_read_as_nothing :: proc(t: ^testing.T) {
	// Most of what arrives on this stream is the model-load log, and none of it
	// is a reading. Copied out of the fixture rather than invented, because a
	// reader loose enough to find a number in one of these is a bar that jumps
	// about during model load.
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
