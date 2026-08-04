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
