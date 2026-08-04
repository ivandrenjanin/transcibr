package process

import "core:testing"

// The Engine's own half of the Process contract: the one command line it is
// started with, and the diagnostic lines it writes back read as progress and as
// a duration.

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
