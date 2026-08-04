package artifact

import "core:fmt"
import "core:mem"
import "core:os"
import "transcibr:transcript"

// This file is the impure half: it reads what the Engine left, writes bytes,
// and renames files. It decides nothing -- what an artifact is called is in
// naming.odin, what a Sidecar says is in sidecar.odin, and whether the Engine's
// output is usable is `transcibr:transcript`'s parser, which already answers
// ADR-0002's three questions (it parses, the Cue count is above zero, the
// offsets are monotonic) and already says what to DO about each answer.
//
// THE DISPOSITIONS ARE NOT REINVENTED HERE. `transcript.disposition_of` is the
// one table that knows which faults mean "quarantine it and re-run the whole
// Recording" and which mean "the Engine transcribed nothing and re-running
// transcribes nothing again". A second vocabulary in this package would be a
// copy of that table that nothing keeps in step with the eighteen-member
// enumeration it is about.
//
// A8 runs through all of it: the Engine's output, the Recording's own path and
// every answer the filesystem gives are outside this program, so every one is
// refused through a return value and reported against the Recording.

// Which of a Recording's three artifacts a refusal is about.
//
// An enumeration rather than the path itself, which is what this carried first:
// a borrowed path in a record that outlives the procedure that built it is a
// lifetime nobody can check, and what a caller actually needs is which of three
// things went wrong. The path is in the Names the caller already holds.
Artifact :: enum u8 {
	Transcript = 0,
	Engine_Output,
	Sidecar,
}

// How one Recording's artifacts could not be placed.
//
// A BARE ENUMERATION WITH ONE RENDERER, the shape `transcibr:engine` settled on
// and for the reasons recorded there: this repository has four full copies of
// the fault-report apparatus already (issue #33), and what a small vocabulary
// needs is a vocabulary and an exhaustive switch, which gives the identical
// compiler guard without the one failure mode a table brings -- a row that is
// present and EMPTY, which compiles and is found in front of a user.
Fault :: enum u8 {
	None = 0,
	// The Recording's own path names no file to make artifacts from (ADR-0008).
	Named_No_File,
	// What the filesystem says about the Recording is not something a Sidecar can
	// record: a modification time before 1970 is negative, and the record's format
	// carries a run of decimal digits with no sign. A8, and the ONE filesystem
	// answer that reaches the Sidecar unvalidated -- refused here, before any
	// artifact is published, because the Sidecar is written last and a refusal at
	// that point leaves a Recording two-thirds published with nothing vouching
	// for it.
	Not_Recordable,
	// What the Engine left could not be read back out of the scratch cache. Not
	// the same as output that is not what the Engine writes: this one never got
	// as far as having a shape.
	Output_Unreadable,
	// It is not what the Engine writes -- truncated, or written by something
	// else. It has been MOVED ASIDE and the Recording is to be re-run in full
	// (ADR-0002); this is not a permanent failure and must not be reported as
	// one. The reason travels in `Error.parse`.
	Output_Quarantined,
	// It parsed, and there is no Transcript to be made from it: the Engine
	// transcribed nothing, or nothing in it is speech. A HARD per-Recording
	// failure, because re-running transcribes nothing again -- which is why it is
	// told apart from the fault above rather than sharing it. The reason travels
	// in `Error.parse`.
	Nothing_Transcribed,
	// An artifact could not be written under its temporary name. `Error.which`
	// says which.
	Not_Written,
	// It was written and could not be moved into place. `Error.which` says which.
	Not_Placed,
}

// One refusal, with whatever the failing layer knew about it.
Error :: struct {
	fault: Fault,
	// Only for `.Not_Written` and `.Not_Placed`.
	which: Artifact,
	// Only for `.Output_Quarantined` and `.Nothing_Transcribed`. The name inside
	// it is BORROWED from the caller's own spelling of the Engine's output, so
	// the message is rendered while that string is still alive.
	parse: transcript.Parse_Error,
}

// Turns one Recording's Engine output into the three artifacts that stand for a
// finished Recording, or says why it could not.
//
// THE WHOLE OF ADR-0002 IN ONE PROCEDURE, and that is the point of its being
// one: validate, then move. A caller that could move first has the discipline in
// its own hands, and the discipline is what the decision is.
//
// The order is fixed and the Sidecar is LAST. Planning treats a Recording as
// done only when its Sidecar says the settings still match (ADR-0003), so a
// Sidecar written before the artifacts it vouches for would report a Recording
// complete whose Transcript never landed -- and the next run would skip it, for
// ever. Everything before the Sidecar is re-doable by construction: a retained
// Engine output with no Sidecar beside it is a Recording nobody has finished,
// and the next run overwrites it.
//
// THE NAMES COME BACK WHICHEVER WAY THIS ENDS, except where the Recording's own
// path names no file at all, and they are always freed with destroy_names and
// the same allocator. One rule, and a caller reporting a failure has the paths
// to name in it.
//
// `rc.language` is filled in HERE and must be handed in empty: it is the one
// front matter fact the Engine's own output can settle (ADR-0001), this
// procedure is the one holding that output, and a caller that supplied it would
// be a second answer that could disagree.
complete :: proc(
	source: string,
	output: string,
	duration: Maybe(transcript.Millis),
	rc: transcript.Render_Context,
	made: Sidecar,
	allocator: mem.Allocator,
) -> (
	placed: Names,
	err: Error,
) {
	assert(len(source) > 0, "there is no Recording here to place artifacts beside")
	assert(len(output) > 0, "there is no Engine output here to make a Transcript from")
	assert(
		allocator.procedure != nil,
		"the artifacts outlive this procedure and need an allocator",
	)
	assert(
		len(rc.language) == 0,
		"the language is read out of the Engine's own output here and is not the caller's to supply",
	)

	names, namable := names_of(source, allocator)
	if !namable {
		return {}, Error{fault = .Named_No_File}
	}

	// BEFORE the Engine's output is read and long before anything is published.
	// `made` carries what `os.stat` answered about the Recording, and the Sidecar
	// is written LAST -- so a record this package cannot write has to be found
	// here or not at all. Found where it is written, the Transcript and the
	// retained output are already on the disk with nothing vouching for them.
	if !recordable(made) {
		return names, Error{fault = .Not_Recordable}
	}

	json_bytes, unreadable := os.read_entire_file_from_path(output, allocator)
	if unreadable != nil {
		return names, Error{fault = .Output_Unreadable}
	}
	defer delete(json_bytes, allocator)

	return names, rendered_and_placed(
		names,
		output,
		string(json_bytes),
		duration,
		rc,
		made,
		allocator,
	)
}

// The Transcript, rendered from the Engine's output and then placed with it.
//
// Split out of `complete` for rule F1's sake, and along the line that made the
// split honest: everything above it is about finding the bytes, and everything
// here is about what they turn out to be.
@(private)
rendered_and_placed :: proc(
	names: Names,
	output: string,
	json_text: string,
	duration: Maybe(transcript.Millis),
	rc: transcript.Render_Context,
	made: Sidecar,
	allocator: mem.Allocator,
) -> Error {
	rendered := rc
	// ALWAYS CLONED, including the word for nobody knowing, so there is one
	// lifetime rule and no fold at the call site (see transcript.parse_language).
	rendered.language = transcript.parse_language(json_text, allocator)
	defer delete(rendered.language, allocator)

	// The validation ADR-0002 asks for, and it is not a second implementation of
	// one: rendering parses, which is where "it parses, the Cue count is above
	// zero, the offsets are monotonic" is already checked and already named.
	markdown, parse_err := transcript.render_transcript(
		output,
		json_text,
		duration,
		rendered,
		allocator,
	)
	defer delete(markdown, allocator)
	if parse_err.fault != .None {
		return disposed_of(output, parse_err, allocator)
	}

	return placed_in_order(names, transmute([]u8)json_text, markdown, made, allocator)
}

// What ADR-0002 does with Engine output that is not usable, which is not one
// thing.
//
// The two dispositions come from `transcript.disposition_of` and are not decided
// here: "a validated JSON that fails to parse is treated as ABSENT -- quarantine
// it to `.json.bad` and re-run the full pipeline, rather than reporting a
// permanent failure", while "exit 0 but no or empty output is a hard
// per-Recording failure". Nothing in a fault's NAME says which side it falls on,
// which is exactly why that table exists.
@(private)
disposed_of :: proc(
	output: string,
	parse_err: transcript.Parse_Error,
	allocator: mem.Allocator,
) -> Error {
	assert(parse_err.fault != .None, "a parse that came through was disposed of as a failure")

	switch transcript.disposition_of(parse_err.fault) {
	case .Quarantine_And_Rerun:
		// BEST EFFORT, and the report is the same either way. What the move buys
		// is that the next run does not find a `.json` in the cache and take it
		// for finished work, and that a user has a file to be pointed at; a move
		// that Windows refuses because something still holds the file leaves the
		// Recording exactly as re-runnable as it already was, because the next
		// run's Engine writes over that name.
		quarantine(output, allocator)
		return Error{fault = .Output_Quarantined, parse = parse_err}
	case .Fail_The_Recording:
		// NOT quarantined, and that is the decision rather than an omission: the
		// Engine's output is exactly what the Engine produces from this Recording,
		// and moving it aside would set up a re-run that spends the GPU time to
		// produce it again.
		return Error{fault = .Nothing_Transcribed, parse = parse_err}
	}
	unreachable()
}

// The three artifacts, in the one order that makes the Sidecar's presence mean
// something.
@(private)
placed_in_order :: proc(
	names: Names,
	json_bytes: []u8,
	markdown: string,
	made: Sidecar,
	allocator: mem.Allocator,
) -> Error {
	assert(len(markdown) > 0, "a Transcript of nothing at all reached the placement")

	// The Engine's own bytes, retained so a re-render costs seconds rather than
	// GPU hours (ADR-0003) -- and byte for byte, because a re-render has to
	// produce the Transcript the original run would have (spec story 44).
	if err := publish(names.engine_output, json_bytes, .Engine_Output, allocator);
	   err.fault != .None {
		return err
	}
	if err := publish(names.transcript, transmute([]u8)markdown, .Transcript, allocator);
	   err.fault != .None {
		return err
	}

	// LAST. Its presence is what a later run reads as "this Recording is
	// genuinely complete", so nothing may be outstanding when it lands.
	text := sidecar_text(made, allocator)
	defer delete(text, allocator)
	return publish(names.sidecar, transmute([]u8)text, .Sidecar, allocator)
}

// Writes one artifact under a temporary name and moves it into place in one
// step.
//
// ATOMIC, and the whole of what makes it so is where the temporary name is:
// part_of puts it in the artifact's OWN directory, so the rename is always
// within one volume. `core:os`'s rename is `MoveFileExW` with
// `MOVEFILE_REPLACE_EXISTING` and no `MOVEFILE_COPY_ALLOWED` -- within a volume
// that is atomic and replaces whatever was there, and across one it FAILS rather
// than quietly becoming a copy and a delete. This never asks it to cross one:
// the bytes reach the destination's volume before the artifact has a name, which
// is why a scratch cache on another drive costs a copy and never an atomicity.
//
// Nothing half-written is left behind on any failing path.
publish :: proc(
	destination: string,
	bytes: []u8,
	which: Artifact,
	allocator: mem.Allocator,
) -> (
	err: Error,
) {
	assert(len(destination) > 0, "there is nowhere here to publish an artifact to")
	assert(allocator.procedure != nil, "a temporary name needs an allocator to be built in")

	part := part_of(destination, os.get_pid(), allocator)
	defer delete(part, allocator)
	// The half-written file, removed on every failing path. Left where it is, the
	// next run's sweep would take it on age eventually -- and until then a
	// directory beside a Recording would carry a file nobody can explain.
	defer if err.fault != .None {
		os.remove(part)
	}

	if !wrote(part, bytes) {
		return Error{fault = .Not_Written, which = which}
	}
	if os.rename(part, destination) != nil {
		return Error{fault = .Not_Placed, which = which}
	}
	return Error{}
}

// Every byte of an artifact, on the disk under the name it was given.
//
// WHO CLOSES WHAT: this procedure opens the handle and this procedure closes it,
// on every path out, and the close is not deferred. Its answer matters -- a
// write that only fails at close is a full disk, which is spec story 54 -- and a
// `defer` would throw that answer away.
//
// The byte count is checked as well as the error, because a platform that
// reported one without the other still wrote less than the artifact.
//
// FLUSHED BEFORE THE RENAME. The rename is atomic in the file SYSTEM, which is
// not the same as the bytes being on the disk: without this, a power loss
// between the two leaves the artifact under its final name with a hole in it,
// and a Sidecar beside it saying the Recording is finished. Three flushes per
// Recording, against a Recording that took minutes on a GPU.
@(private)
wrote :: proc(path: string, bytes: []u8) -> bool {
	assert(len(path) > 0, "there is nowhere here to write an artifact")

	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	if unopenable != nil {
		return false
	}
	if written, unwritable := os.write(handle, bytes); unwritable != nil || written != len(bytes) {
		os.close(handle)
		return false
	}
	if os.sync(handle) != nil {
		os.close(handle)
		return false
	}
	return os.close(handle) == nil
}

// Moves a piece of Engine output that is not what the Engine writes aside, and
// says whether it went.
//
// `.json.bad`, which ADR-0002 names outright. The rename REPLACES an existing
// one, which matters more than it looks: a Recording that fails the same way
// twice must not fail on the quarantine the second time, because that would turn
// a re-runnable Recording into a permanent failure -- the exact shape this whole
// decision exists to prevent.
quarantine :: proc(path: string, allocator: mem.Allocator) -> bool {
	assert(len(path) > 0, "there is nothing here to move aside")
	assert(allocator.procedure != nil, "a quarantine name needs an allocator to be built in")

	aside := quarantined(path, allocator)
	defer delete(aside, allocator)
	return os.rename(path, aside) == nil
}

// What each fault reads as, without the Recording's name -- error_message
// supplies that, so no arm here can forget to.
@(private)
fault_says :: proc(fault: Fault) -> string {
	switch fault {
	case .Named_No_File:
		return "it names no file to make artifacts from"
	case .Not_Recordable:
		return "the filesystem dates it before 1970, and no Sidecar can record a moment below zero"
	case .Output_Unreadable:
		return "what the Engine left could not be read back"
	case .Output_Quarantined:
		return(
			"what the Engine left is not what the Engine writes; it has been moved aside and this Recording will be done again from the start" \
		)
	case .Nothing_Transcribed:
		return "the Engine transcribed nothing that could be made into a Transcript"
	case .Not_Written:
		return "could not be written"
	case .Not_Placed:
		return "was written and could not be moved into place"
	case .None:
	// The success value and not a fault. It has no sentence, and error_message
	// refuses it by name before ever asking for one.
	}
	return ""
}

// Which artifact a placement failure was about, as the words that go in front of
// the sentence.
@(private)
artifact_says :: proc(which: Artifact) -> string {
	switch which {
	case .Transcript:
		return "its Transcript"
	case .Engine_Output:
		return "its retained Engine output"
	case .Sidecar:
		return "its Sidecar"
	}
	return ""
}

// Renders one refusal as a line a Recording's failure row can carry, NAMING THE
// RECORDING.
//
// The path is printed with %q for the reason the renderers in `transcibr:audio`
// and `transcibr:engine` give: a refusal reaches a user through a UTF-16 Win32
// call, a raw NUL cuts the line off where it is printed, and a byte that is not
// UTF-8 makes the whole line convert to nil.
//
// The allocator is explicit and never defaulted: the line outlives this
// procedure and may be read by a worker other than the one that produced it
// (ADR-0010). Free it with `delete` and the same allocator.
error_message :: proc(err: Error, source: string, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a Recording that came through")
	assert(len(source) > 0, "a refusal must name the Recording it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	says := fault_says(err.fault)
	assert(len(says) > 0, "a fault was added to Fault without a sentence")

	message: string
	switch err.fault {
	case .Not_Written, .Not_Placed:
		which := artifact_says(err.which)
		assert(len(which) > 0, "an artifact was added to Artifact without a name")
		message = fmt.aprintf("%q: %s %s", source, which, says, allocator = allocator)
	case .Output_Quarantined, .Nothing_Transcribed:
		message = borrowed_message(err, source, says, allocator)
	case .None, .Named_No_File, .Not_Recordable, .Output_Unreadable:
		message = fmt.aprintf("%q: %s", source, says, allocator = allocator)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}

// The two refusals whose REASON belongs to the parser, with that reason on the
// end.
//
// Split out for rule F1's sake, the shape `transcibr:audio`'s own renderer uses:
// error_message is one arm per shape of line, and this is the shape that has to
// borrow.
@(private)
borrowed_message :: proc(
	err: Error,
	source: string,
	says: string,
	allocator: mem.Allocator,
) -> string {
	// The one member pair that borrows, checked against the record that carries
	// it (A4): `disposed_of` only ever answers these two with the parser's own
	// report in hand, so an empty one here is this package losing it between the
	// failure and the row.
	assert(err.parse.fault != .None, "a Recording refused for its output named no reason")

	reason := transcript.error_message(err.parse, allocator)
	defer delete(reason, allocator)
	return fmt.aprintf("%q: %s (%s)", source, says, reason, allocator = allocator)
}
