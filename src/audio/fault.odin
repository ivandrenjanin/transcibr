// Package audio turns one Recording into the mono 16 kHz audio the Engine
// reads, and settles -- before any of that -- how long the Recording actually is
// and whether anything is still writing it.
//
// ONE PACKAGE FOR TWO OF THE SPEC'S SHELL MODULES, *probing* and *extraction*,
// which is a decision with a cost rather than a layout preference: see ADR-0018.
// In short, the probe exists only for the extraction -- it supplies the duration
// the produced audio is measured against and the two refusals that stop an
// extraction from starting -- and splitting them would put one test seam across
// two packages, which is exactly what ADR-0017 refuses.
//
// NAMED FOR THE PAIR AND NOT FOR EITHER HALF, which is ADR-0017's own rule
// applied here: `extract` was "a package whose name describes half its
// contents", the exact thing that decision refused when it renamed
// `command_line` to `process`. CONTEXT.md files Probe and Scratch cache under
// "Turning a recording into audio", and that is what this package does.
//
// Impure, and honestly so: it runs ffmpeg and ffprobe through `transcibr:child`,
// reads bytes off the disk and deletes files out of the scratch cache. But every
// DECISION it makes is a pure procedure whose inputs are handed in -- the chunk
// walk over a buffer, the two durations, the two readings of a source, the
// sweep's choice of what may go -- because ADR-0009 says this layer will never
// have a unit test, and a decision with a clock or a filesystem inside it cannot
// be checked. `remaining_ms` in `transcibr:child` is the same shape for the same
// reason.
//
// Nothing outside this program may crash it (A8). A container, a WAV, an exit
// code, a byte of ffmpeg's diagnostic output and every file in the cache are all
// from outside, so each is refused through `Error` and reported against the
// Recording that caused it. The assertions here are about this package's own
// state.
package audio

import "core:fmt"
import "core:mem"
import "transcibr:child"
import "transcibr:process"

// This file is the impure half: it starts ffprobe and ffmpeg through
// `transcibr:child`, reads what they produced off the disk, and deletes what the
// sweep chose. It decides nothing -- every decision it needs is a pure procedure
// in one of the files beside it, with a suite of its own.
//
// A8 runs through all of it. An exit code, a probe's answer, a produced WAV, a
// source that vanished mid-Batch, a cache directory that will not list: every
// one is outside this program, so every one is refused through `Error` and
// reported against the Recording that caused it. The Batch carries on
// (ADR-0002).

// How a Recording's audio could not be produced.
//
// A FOURTH FAULT VOCABULARY IN THIS REPOSITORY, and it is deliberately the small
// version of the shape the other three carry. `transcibr:child` says the near-
// clone in it "is the last one" and names the trigger for moving the shape into
// a package both import; this is that trigger arriving. What is here is the
// minimum that reports a failure a user can act on -- an enumeration, a table of
// sentences, one checked reader and one renderer -- and deliberately not the
// error record with a borrowed culprit or the disposition table, because the
// culprit is always the Recording, which the renderer is handed, and the
// disposition is always the same: this Recording fails and the Batch carries on.
Fault :: enum u8 {
	None = 0,
	// ADR-0002's own refusal, and it is checked before any work rather than
	// where it bites: the Engine cannot open a path carrying a non-ASCII byte.
	Cache_Path_Not_Ascii,
	Cache_Unusable,
	// The Recording is not there, or will not answer a stat.
	Source_Unreadable,
	// Something is still writing it (spec story 52).
	Still_Being_Written,
	// Two readings too close together to say, after the wait. Distinct from
	// the above: nothing was seen to move, and the caller is told that rather
	// than told the file is fine.
	Still_Unsettled,
	Probe_Not_Started,
	// The probe did not finish inside its bound (issue #27).
	Probe_Did_Not_Finish,
	// The probe finished and left nothing readable behind.
	Probe_Answer_Unreadable,
	// The probe's answer would not read as a duration. The reason travels in
	// `Error.probe`.
	Probe_Unreadable,
	// The Recording carries no audio at all, which is a per-Recording failure
	// naming the file rather than an empty Transcript.
	No_Audio_Stream,
	Extraction_Not_Started,
	Extraction_Did_Not_Finish,
	// ffmpeg finished and left nothing that can be read back. ADR-0002's "exit
	// code 0 means nothing" is why this is not conditioned on the exit code.
	Audio_Unreadable,
	// The produced audio would not walk. The reason travels in `Error.riff`.
	Audio_Malformed,
	// It walked, and it is not the mono 16 kHz that was asked for.
	Audio_Not_As_Asked_For,
	// It is not the length the container promised.
	Durations_Disagree,
	// The audio was produced and could not be moved into place.
	Audio_Not_Published,
}

// One refusal, with whatever the failing layer knew about it.
Error :: struct {
	fault: Fault,
	// Only for `.Probe_Unreadable` and `.Audio_Malformed`, whose reasons belong
	// to the packages that refused.
	probe: process.Probe_Fault,
	riff:  Riff_Fault,
	// Only for the two `_Not_Started` faults; the spawner names what it could
	// not do.
	child: child.Error,
	// The two durations, for `.Durations_Disagree`. Printed, because "the
	// audio is not the right length" is not something a user can act on and
	// "the container says 48 minutes and the audio is 12" is.
	said:  i64,
	got:   i64,
}

// What each fault reads as, without the Recording's name -- error_message
// supplies that, so no entry here can forget to.
//
// An enumerated array rather than a switch, for the reason the FAULT tables in
// `transcibr:process` and `transcibr:child` give: add a Fault and leave this
// alone and the COMPILER refuses the build with `Unhandled enumerated array
// case`.
@(private, rodata)
FAULT := [Fault]string {
	// Three rows are deliberately empty and fault_says refuses each by name:
	// `.None` is the success value, and the other two carry a reason belonging
	// to the package that produced it.
	.None                      = "",
	.Probe_Unreadable          = "",
	.Audio_Malformed           = "",
	.Cache_Path_Not_Ascii      = "the scratch cache is under a path the Engine cannot open, because it carries a byte outside ASCII",
	.Cache_Unusable            = "the scratch cache could not be created or listed",
	.Source_Unreadable         = "the Recording could not be read",
	.Still_Being_Written       = "the Recording is still being written to",
	.Still_Unsettled           = "the Recording could not be shown to have stopped changing",
	.Probe_Not_Started         = "ffprobe could not be started",
	.Probe_Did_Not_Finish      = "ffprobe did not finish inside the time it was given",
	.Probe_Answer_Unreadable   = "ffprobe left nothing readable behind",
	.No_Audio_Stream           = "the Recording carries no audio stream at all",
	.Extraction_Not_Started    = "ffmpeg could not be started",
	.Extraction_Did_Not_Finish = "ffmpeg did not finish inside the time it was given",
	.Audio_Unreadable          = "the audio ffmpeg was asked for is not there to read",
	.Audio_Not_As_Asked_For    = "the audio ffmpeg produced is not the mono 16 kHz it was asked for",
	.Durations_Disagree        = "the audio is not the length the Recording's container says it is",
	.Audio_Not_Published       = "the audio was produced and could not be moved into place",
}

// One fault's sentence, checked. The one place the table is read.
@(private)
fault_says :: proc(fault: Fault) -> string {
	assert(fault != .None, "the success value is not a fault and says nothing")
	assert(
		fault != .Probe_Unreadable,
		"a refused probe answer is reported by the package that read it",
	)
	assert(fault != .Audio_Malformed, "malformed audio is reported by the walk that refused it")

	says := FAULT[fault]
	assert(len(says) > 0, "a fault was added to Fault without a row in FAULT")
	return says
}

// Renders one refusal as a line a Recording's failure row can carry, NAMING THE
// RECORDING. Every acceptance criterion this package answers to says "naming the
// file", and this is the one place that happens.
//
// The path is printed with %q and not %s, which doubles every backslash in a
// Windows path and is worth it for the reason `deliverable` gives in
// `transcibr:process`: a refusal reaches a user through a UTF-16 Win32 call, a
// raw NUL cuts the line off where it is printed, and a byte that is not UTF-8
// makes the whole line convert to nil. NTFS permits an unpaired surrogate in a
// filename, so that is a path a Recording can really have.
//
// The allocator is explicit and never defaulted: the line outlives this
// procedure and may be read by a worker other than the one that produced it
// (ADR-0010). Free it with `delete` and the same allocator.
error_message :: proc(err: Error, source: string, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a Recording that came through")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	message: string
	switch err.fault {
	case .Probe_Unreadable:
		message = fmt.aprintf(
			"%q: its container could not be timed (%v)",
			source,
			err.probe,
			allocator = allocator,
		)
	case .Audio_Malformed:
		message = fmt.aprintf(
			"%q: the audio produced from it would not read (%v)",
			source,
			err.riff,
			allocator = allocator,
		)
	case .Durations_Disagree:
		message = fmt.aprintf(
			"%q: %s -- %d ms against %d ms",
			source,
			fault_says(err.fault),
			err.said,
			err.got,
			allocator = allocator,
		)
	case .Probe_Not_Started, .Extraction_Not_Started:
		reason := child.error_message(err.child, allocator)
		defer delete(reason, allocator)
		message = fmt.aprintf(
			"%q: %s (%s)",
			source,
			fault_says(err.fault),
			reason,
			allocator = allocator,
		)
	case .None,
	     .Cache_Path_Not_Ascii,
	     .Cache_Unusable,
	     .Source_Unreadable,
	     .Still_Being_Written,
	     .Still_Unsettled,
	     .Probe_Did_Not_Finish,
	     .Probe_Answer_Unreadable,
	     .No_Audio_Stream,
	     .Extraction_Did_Not_Finish,
	     .Audio_Unreadable,
	     .Audio_Not_As_Asked_For,
	     .Audio_Not_Published:
		message = fmt.aprintf("%q: %s", source, fault_says(err.fault), allocator = allocator)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}

// Whether every byte of a path is ASCII.
//
// ADR-0002's rule, and the only pure decision in this file. The Engine is
// `int main(int, char**)` under MSVC, so argv reaches it in the system ANSI code
// page and a path carrying anything else fails to open with no output at all --
// and a non-ASCII Windows ACCOUNT NAME is enough, since the cache sits under
// %LOCALAPPDATA%. ffmpeg does not have the bug, which is exactly why the check
// is on the whole cache here rather than beside the Engine: extraction looks
// clean while only transcription fails.
ascii_only :: proc(path: string) -> bool {
	for at in 0 ..< len(path) {
		if path[at] >= 0x80 {
			return false
		}
	}
	return true
}
