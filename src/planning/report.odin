package planning

import "core:fmt"
import "core:mem"

// What a dry run prints. Here rather than in `src/cli`, because that package is
// named in `$OdinPackagesWithoutTests` and a sentence nothing can turn red is a
// sentence nobody is holding (ADR-0009).

// %q on every path, for the reason `src/audio` gives: a line reaches a user
// through a UTF-16 Win32 call, where a raw NUL cuts it off and a byte that is
// not UTF-8 converts the whole of it to nil -- and NTFS permits an unpaired
// surrogate in a filename.

// A switch and not a table, so an arm has to be spelled out before this will
// build at all. See CLAUDE.md, Odin notes: enumerated arrays and switches.
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
	case .Dated_Before_1970:
		return "the filesystem dates it before 1970, and no Sidecar can record a moment below zero"
	case .Directory_Not_Writable:
		return "nothing can be written into the directory it is in"
	}
	return ""
}

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
	return fmt.aprintf(
		"%-10s %q: %s (%v)",
		does,
		entry.found.source,
		says,
		entry.outcome.change,
		allocator = allocator,
	)
}

// Free it with `delete` and this allocator.
note_line :: proc(note: Walk_Note, allocator: mem.Allocator) -> (line: string) {
	assert(allocator.procedure != nil, "the line outlives this procedure and needs an allocator")
	defer assert(len(line) > 0, "a note rendered as nothing at all")

	says := note_says(note.note)
	assert(len(says) > 0, "a note was added to Note without a sentence")

	return fmt.aprintf("%-10s %q: %s", "report", note.path, says, allocator = allocator)
}

// Empty for a plan that came through, so a caller prints it or does not without
// asking a second question. Free it with `delete` and this allocator.
collision_line :: proc(plan: Plan, allocator: mem.Allocator) -> string {
	assert(allocator.procedure != nil, "the line outlives this procedure and needs an allocator")

	collision, raced := plan.collision.?
	if !raced {
		return ""
	}
	assert(collision.left < collision.right, "a pair named in the wrong order")
	assert(len(collision.name) > 0, "a pair that would share an artifact nobody named")

	return fmt.aprintf(
		"refused    %q and %q would both be written to %q -- this Batch will not start",
		plan.entries[collision.left].found.source,
		plan.entries[collision.right].found.source,
		collision.name,
		allocator = allocator,
	)
}
