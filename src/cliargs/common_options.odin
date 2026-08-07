#+vet explicit-allocators
// Common_Options holds the six fields every migrated command's grammar reads
// identically today (src/cli's read_common_option, ADR-0038): model, engine,
// cache, tools, prompt and profile. Batch_Options and Transcribe_Options
// embed it with `using` once their commands migrate; Plan_Options does not,
// because it has no cache field and no tools field and must go on refusing
// --cache, --ffmpeg and --ffprobe by name rather than silently accepting
// them into fields a shared struct happens to carry (A8, ADR-0038).
package cliargs

import "transcibr:transcript"

// A two-string tools struct of its own, not audio.Tools: importing
// transcibr:audio would pull transcibr:child in behind it, which this
// package's import closure (transcript and process only) rules out
// (ADR-0038).
Tools :: struct {
	ffmpeg:  string,
	ffprobe: string,
}

Common_Options :: struct {
	model:   string,
	engine:  string,
	cache:   string,
	tools:   Tools,
	prompt:  string,
	profile: transcript.Merge_Profile,
}

// Command-agnostic -- every migrated command's reader falls through to this
// same complaint on an option name it does not recognize -- so it belongs
// beside Common_Options rather than inside one command's own file (s3
// deposit 4, PR #201 review).
UNKNOWN_OPTION_COMPLAINT :: "unknown option %q."
