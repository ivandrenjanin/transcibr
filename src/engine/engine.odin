// Package engine runs the Engine over one Recording's audio, reports how far it
// has got while it runs, and answers with what it left in the scratch cache.
//
// THE SPEC'S SHELL MODULE *Engine invocation*, one package for one module, which
// is ADR-0017 applied rather than narrowed. Named for its subject the way
// `transcibr:audio` is: what is in here is the INVOCATION and never the Engine,
// which is somebody else's program -- a directory of twenty-one libraries beside
// an executable -- and is named on a command line and nowhere else.
//
// Impure, and honestly so: it starts a child through `transcibr:child`, reads
// what the child said off a pipe and asks the filesystem what the child left
// behind. Every DECISION it needs is a pure procedure in `transcibr:process` --
// the argument list, one line read back, the fallback estimate, the watchdog's
// two bounds, the bound the whole invocation is given -- because ADR-0009 says
// this layer will never have a unit test, and a decision with a clock or a
// filesystem inside it cannot be checked. ADR-0018 is where that rule is
// written down, and a decision that turns up in this file belongs next door.
//
// Nothing outside this program may crash it (A8). The Engine's exit code, every
// byte of its diagnostic output, an executable path out of settings and whatever
// is or is not on the disk afterwards are all from outside, so each is refused
// through `Error` and reported against the Recording that caused it. The Batch
// carries on (ADR-0002).
package engine

import "core:fmt"
import "core:mem"
import "transcibr:child"
import "transcibr:process"

// Where the Engine's executable is.
//
// Handed in rather than resolved here, the shape `transcibr:audio` uses for
// ffmpeg: which Engine a Batch runs is a settings question, and ADR-0014 answers
// where it comes from. A shell module that went looking for one would be a
// second place that answer lives.
//
// A record of one field on purpose. The Engine is a DIRECTORY of libraries
// beside an executable, not a lone binary, and the day this has to carry that
// directory as well it gains a field rather than every caller a parameter.
Tools :: struct {
	engine: string,
}

// One Recording, as everything the Engine needs to be started on it.
//
// A record rather than five parameters, so a caller cannot get two paths the
// wrong way round -- and so `name` is visibly the artifact stem (ADR-0008) that
// the audio, the Engine's output and the Sidecar all share, rather than a
// filename invented here.
Job :: struct {
	// The mono 16 kHz audio `transcibr:audio` produced. ONE Recording's
	// (ADR-0002).
	audio:        string,
	// The scratch cache, ASCII-only. THE ONLY DIRECTORY THE ENGINE MAY WRITE
	// INTO (ADR-0002), and the ASCII rule is not this package's to check: it is
	// about the whole cache, it answers the same for every Recording in the
	// Batch, and `transcibr:audio`'s `open_cache` answers it once before any
	// Recording starts.
	cache:        string,
	// The stem every artifact of this Recording is named from.
	name:         string,
	// The weights to load.
	model:        string,
	// The container probe's answer, in milliseconds. What the fallback estimate
	// keys on until the Engine's own banner arrives, and what the bound is
	// derived from.
	container_ms: i64,
}

// What one Engine invocation left behind.
Transcribed :: struct {
	// The Engine's output, IN THE SCRATCH CACHE and not beside the Recording.
	// Owned by the caller and freed with `delete` and the allocator handed in.
	//
	// It is not validated here beyond existing and not being empty. ADR-0002's
	// full check -- parses, Cue count above zero, monotonic offsets -- and the
	// move into place belong to the ticket that owns artifact validation, and
	// running them here would put the decision about what a valid Transcript is
	// in the package that drives a subprocess.
	output:      string,
	// The length the run keyed on: the Engine's own startup banner where it said
	// one, and the container probe's answer otherwise. NEVER the scratch audio's
	// header (spec).
	duration_ms: i64,
}

// Everything one invocation is bounded by, as one value.
//
// TWO TUNABLES AT TWO ALTITUDES, which is the shape ADR-0018 records and the
// reason they travel together: the watchdog decides when an Engine that has
// stopped saying anything is a failure, and the run bound decides when one that
// is still saying things has had long enough. A caller that could move one
// without seeing the other is a caller that can spell a run whose watchdog fires
// after its bound, and then neither is what it says it is.
//
// Handed in the way `Tolerance` is in `transcibr:audio`: the shipped program
// takes DEFAULT_LIMITS and a case hands in bounds it can actually reach.
Limits :: struct {
	watch:    process.Watch,
	// How long the whole invocation is given, in milliseconds.
	//
	// ZERO IS THE RECORDING'S OWN BOUND -- process.transcribe_bound_ms of its
	// length -- and that is what the shipped program runs. It is a sentinel
	// rather than a defaulted parameter because the answer depends on the Job,
	// which arrives beside it; the same "zero where nobody could say" that
	// `Tracker.duration_ms` uses next door.
	//
	// A CASE IS THE OTHER CALLER. Derived, the bound is at least the ten-minute
	// floor a cold Model load costs, so nothing in a sweep could ever reach it
	// and `Fault.Did_Not_Finish` was a member no run produced.
	bound_ms: i64,
}

DEFAULT_LIMITS :: Limits {
	watch = process.DEFAULT_WATCH,
}

// What the caller is told while the Engine runs.
//
// A procedure and a pointer, because Odin's procedures do not capture: the
// pointer is whatever the caller needs to get back to, and this package never
// looks inside it. A zero value means nobody is watching, which is the ordinary
// case for a Batch nobody has open.
Report :: struct {
	on_progress: proc(shown: process.Progress, user: rawptr),
	user:        rawptr,
}

// How one Recording's transcription failed.
//
// A BARE ENUMERATION WITH ONE RENDERER, and deliberately not this repository's
// fifth copy of the fault-report shape. `src/child` says out loud that the
// second copy was meant to be the last, ADR-0018 records that the debt was
// already a ticket old at the fourth, and what that ADR blesses instead is the
// small version: a vocabulary and an exhaustive switch, which gives the
// identical compiler guard without the one failure mode a table brings -- a row
// that is present and EMPTY, which compiles and is found in front of a user.
// There is no disposition table either: every member here disposes the same way,
// which is that this Recording fails and the Batch carries on (ADR-0002).
//
// Declining the apparatus is not paying the debt down, and the debt is issue #33.
// The four full copies stay where they are, and what could be shared between them
// is the RENDERER CONTRACT rather than any vocabulary -- each package's faults
// are its own and have to stay so. That is the part worth getting wrong slowly:
// a shared enumeration is a generic error message in front of a user.
Fault :: enum u8 {
	None = 0,
	// One of the three paths this invocation would have handed the Engine
	// carries a byte outside ASCII, so the Engine could not open it (ADR-0002).
	//
	// REFUSED BEFORE THE CHILD STARTS, which is the whole value of it: the
	// Engine's own answer to such a path is to spend the GPU time, write nothing
	// and exit ZERO, and there is nothing in that a caller can act on.
	//
	// A PER-RECORDING FAULT AND NOT A BATCH-LEVEL ONE, which the other two ASCII
	// checks in this program are. The scratch cache is one directory for the
	// whole Batch and the Model is one file, so both are answered once, before
	// anything starts. This one is not: the artifact stem comes from the
	// RECORDING's own name (ADR-0008), so a Batch of ASCII-named Recordings and
	// one called `Bjoern.mp4` fails exactly that one and carries on.
	//
	// WHAT WOULD FIX IT PROPERLY is decoupling the scratch name from the artifact
	// stem: the Engine only ever sees paths inside the cache, so those could be
	// named from something injective and ASCII by construction while the
	// artifacts beside the Recording keep the Recording's own name. That is a
	// change to what ADR-0008 says a stem is, it moves three packages, and it is
	// not this ticket. Until then a Recording whose name carries a non-ASCII byte
	// fails loudly and by name, which is the whole of what ADR-0002 asks for and
	// is a great deal better than the silent nothing it replaces.
	Path_Not_Ascii,
	// The Engine would not start. The reason travels in `Error.child`, which
	// names what Windows said.
	Not_Started,
	// Its bound ran out (issue #27), or its diagnostic pipe stopped answering --
	// which is the same wedge arriving earlier, since an undrained pipe is what
	// stops the child dead (ADR-0004).
	Did_Not_Finish,
	// Nothing arrived on any stream this program can see for long enough that a
	// running Engine could not explain it. Distinct from `.Did_Not_Finish`
	// because it is what the caller is told about a wedge that would otherwise
	// hold the one GPU worker for the whole of the bound (ADR-0012, ADR-0006).
	Went_Silent,
	// It had to be stopped and WOULD NOT stop. Distinct because of what it
	// forbids: the Engine may still be running and may still hold its output
	// file open, so nothing here touches that file.
	Not_Stopped,
	// It finished and left nothing at all where it was told to write.
	//
	// NOT CONDITIONED ON THE EXIT CODE, which is ADR-0002's own measurement: "a
	// failed audio read is a `continue` that falls through to `return 0`, so a
	// truncated WAV yields success, one stderr line, and no output file". What
	// settles a Recording is what is on the disk.
	No_Output,
	// It left a file of no bytes at all, which is what a full disk or a Stop
	// press leaves behind -- the Engine opens its output with a TRUNCATING
	// stream (ADR-0002). Told apart from nothing at all because the next run must
	// not find it and take it for finished work.
	Output_Empty,
}

// One refusal, with whatever the failing layer knew about it.
Error :: struct {
	fault: Fault,
	// Only for `.Not_Started`; the spawner names what it could not do.
	child: child.Error,
}

// What each fault reads as, without the Recording's name -- error_message
// supplies that, so no arm here can forget to.
//
// An exhaustive switch and not an enumerated array, for the reason `Cache_Fault`
// in `transcibr:audio` gives: the two give the SAME compiler guard, and only one
// of them can carry a row that is present and empty.
@(private)
fault_says :: proc(fault: Fault) -> string {
	switch fault {
	case .Path_Not_Ascii:
		return(
			"one of the paths this Recording would have handed the Engine carries a byte outside ASCII, which the Engine cannot open" \
		)
	case .Not_Started:
		return "the Engine could not be started"
	case .Did_Not_Finish:
		return "the Engine was stopped before it finished"
	case .Went_Silent:
		return "the Engine stopped producing any output at all and was stopped"
	case .Not_Stopped:
		return "the Engine would not finish and would not stop"
	case .No_Output:
		return "the Engine left no output at all, whatever it exited with"
	case .Output_Empty:
		return "the Engine left an empty output file"
	case .None:
	// The success value and not a fault. It has no sentence, and error_message
	// refuses it by name before ever asking for one.
	}
	return ""
}

// Renders one refusal as a line a Recording's failure row can carry, NAMING THE
// RECORDING.
//
// The path is printed with %q and not %s, for the reason `deliverable` gives in
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
		"the message outlives this procedure and needs a chosen allocator",
	)

	says := fault_says(err.fault)
	assert(len(says) > 0, "a fault was added to Fault without a sentence")
	// The one member that borrows its reason, checked against the record that
	// carries it (A4). `run_engine` only ever answers `.Not_Started` with the
	// spawner's own refusal in hand, so an empty one here is this package losing
	// it between the failure and the report -- and the crash belongs where it was
	// lost rather than inside the spawner's renderer, which has no idea who asked.
	if err.fault == .Not_Started {
		assert(err.child.fault != .None, "an Engine that would not start named no reason")
	}

	message: string
	if err.fault == .Not_Started {
		// The spawner's own report, appended rather than replaced: it names what
		// Windows said, and this names the Recording it was said about.
		reason := child.error_message(err.child, allocator)
		defer delete(reason, allocator)
		message = fmt.aprintf("%q: %s (%s)", source, says, reason, allocator = allocator)
	} else {
		message = fmt.aprintf("%q: %s", source, says, allocator = allocator)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}
