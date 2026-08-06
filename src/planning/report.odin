#+vet explicit-allocators
package planning

import "core:fmt"
import "core:mem"
import "core:strings"
import "transcibr:artifact"

// What a dry run prints. Here rather than in `src/cli`, because that package is
// named in `TEST_LESS_SRC_PACKAGES` and a sentence nothing can turn red is a
// sentence nobody is holding (ADR-0009).

// %q on every path, for the reason `src/audio` gives: a line reaches a user
// through a UTF-16 Win32 call, where a raw NUL cuts it off and a byte that is
// not UTF-8 converts the whole of it to nil -- and NTFS permits an unpaired
// surrogate in a filename.

// A switch and not a table, so an arm has to be spelled out before this will
// build at all. See CLAUDE.md, Odin notes: enumerated arrays and switches.
//
// Private like every other `*_says` in this repository: what leaves this package
// is a whole LINE, so nothing outside can assemble one of its own out of the
// pieces and have it drift from the one the suite holds.
@(private)
@(require_results)
decision_says :: proc(decision: Decision) -> string {
	switch decision {
	case .Transcribe:
		return "transcribe"
	case .Re_Render:
		return "re-render"
	case .Skip:
		return "skip"
	case .Refuse:
		return "refuse"
	}
	return ""
}

@(private)
@(require_results)
reason_says :: proc(reason: Reason) -> string {
	switch reason {
	case .Nothing_Recorded:
		return "nothing has been recorded for it yet"
	case .Up_To_Date:
		return "its Transcript was made with these settings"
	case .Settings_Changed:
		return "the settings it was made with have changed"
	case .Transcript_Missing:
		return "its Transcript is not there"
	case .Provenance_Unknown:
		return "no Sidecar says what the artifacts beside it were made with"
	case .Names_No_File:
		return "it names no file to make artifacts from"
	case .Foreign_Transcript:
		return "there is a Markdown file beside it that transcibr did not write"
	case .Transcript_Unreadable:
		return "its Transcript could not be read, and this walk will not guess what it is"
	case .Dated_Before_1970:
		return "the filesystem dates it before 1970, and no Sidecar can record a moment below zero"
	case .Directory_Not_Writable:
		return "nothing can be written into the directory it is in"
	}
	return ""
}

@(private)
@(require_results)
change_says :: proc(change: artifact.Change) -> string {
	switch change {
	case .None:
		return "nothing"
	case .Source:
		return "the Recording itself"
	case .Engine_Version:
		return "the Engine version"
	case .Model:
		return "the Model"
	case .Beam:
		return "the beam width"
	case .Prompt:
		return "the prompt"
	case .Container_Duration:
		return "the container's duration"
	case .Merge_Profile:
		return "the Merge Profile"
	}
	return ""
}

@(private)
@(require_results)
note_says :: proc(what: Note) -> string {
	switch what {
	case .Root_Unreadable:
		return "is not a directory this Batch can walk"
	case .Directory_Unreadable:
		return "could not be listed, and has NOT been taken for empty"
	case .Reparse_Point_Not_Followed:
		return "is a reparse point and was not followed"
	case .Too_Deep:
		return "is deeper than this Batch walks, and nothing under it was looked at"
	}
	return ""
}

// One Recording's row in a dry run. Free it with `delete` and this allocator.
@(require_results)
plan_line :: proc(entry: Entry, allocator: mem.Allocator) -> (line: string) {
	assert(len(entry.found.source) > 0, "a plan row for a Recording with no path at all")
	assert(allocator.procedure != nil, "the line outlives this procedure and needs an allocator")
	defer assert(len(line) > 0, "a plan row rendered as nothing at all")

	does := decision_says(entry.outcome.decision)
	assert(len(does) > 0, "a decision was added to Decision without a word")
	says := reason_says(entry.outcome.reason)
	assert(len(says) > 0, "a reason was added to Reason without a sentence")

	if entry.outcome.change == .None {
		return fmt.aprintf("%-10s %q: %s", does, entry.found.source, says, allocator = allocator)
	}
	changed := change_says(entry.outcome.change)
	assert(len(changed) > 0, "a member was added to Change without words")
	return fmt.aprintf(
		"%-10s %q: %s (%s)",
		does,
		entry.found.source,
		says,
		changed,
		allocator = allocator,
	)
}

// Free it with `delete` and this allocator.
@(require_results)
note_line :: proc(note: Walk_Note, allocator: mem.Allocator) -> (line: string) {
	assert(allocator.procedure != nil, "the line outlives this procedure and needs an allocator")
	defer assert(len(line) > 0, "a note rendered as nothing at all")

	says := note_says(note.note)
	assert(len(says) > 0, "a note was added to Note without a sentence")

	return fmt.aprintf("%-10s %q: %s", "report", note.path, says, allocator = allocator)
}

// A walk that was stopped left no note to name, so the sentence names none.
@(private)
STOPPED_PART_WAY :: "this walk was stopped before it finished; the plan above is partial."

// Why the walk did not see the whole tree, or EMPTY where it did -- so a caller
// prints it or does not without asking a second question, which is
// `collision_line`'s shape and is here for the same reason. Free it with
// `delete` and this allocator.
//
// The note is rendered through its own sentence and never as `%v`: the CLI
// printed the enumeration member, so a cancelled walk read
// "this walk did not see the whole tree (Root_Unreadable)" over a root it had
// read perfectly well, and no reader of that line could tell those two apart.
@(require_results)
incomplete_line :: proc(inventory: Inventory, allocator: mem.Allocator) -> string {
	assert(allocator.procedure != nil, "the line outlives this procedure and needs an allocator")

	short, incomplete := left_unlooked_at(inventory)
	if !incomplete {
		return ""
	}
	left_out, named := short.?
	if !named {
		return strings.clone(STOPPED_PART_WAY, allocator)
	}

	says := note_says(left_out.note)
	assert(len(says) > 0, "a note was added to Note without a sentence")
	return fmt.aprintf(
		"this walk did not see the whole tree: %q %s. The plan above is partial.",
		left_out.path,
		says,
		allocator = allocator,
	)
}

// Empty for a plan that came through, so a caller prints it or does not without
// asking a second question. Free it with `delete` and this allocator.
@(require_results)
collision_line :: proc(plan: Plan, allocator: mem.Allocator) -> string {
	assert(allocator.procedure != nil, "the line outlives this procedure and needs an allocator")

	collision, raced := plan.collision.?
	if !raced {
		return ""
	}
	assert(collision.left < collision.right, "a pair named in the wrong order")
	assert(len(collision.name) > 0, "a pair that would share an artifact nobody named")
	assert(collision.right < len(plan.entries), "a pair named outside the plan it was found in")

	return fmt.aprintf(
		"refused    %q and %q would both be written to %q -- this Batch will not start",
		plan.entries[collision.left].found.source,
		plan.entries[collision.right].found.source,
		collision.name,
		allocator = allocator,
	)
}
