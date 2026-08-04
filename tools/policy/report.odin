#+vet explicit-allocators
package policy

import "core:fmt"
import "core:strings"

// This file renders one file's facts as the lines scripts\common.ps1 reads back.
//
// One record per line, fields separated by tabs, the first field naming the kind
// of record. A `file` record opens a block and every record after it belongs to
// that file, so a path is written once however many procedures it holds.
//
// Tab-separated and not JSON, because the reader is PowerShell 5.1 and
// ConvertFrom-Json there returns a PSCustomObject per record for a report that is
// a thousand records long. `-split` on a tab is the whole parser.

RECORD_FILE :: "file"
RECORD_FAULT :: "fault"
RECORD_PROCEDURE :: "proc"
RECORD_COMMENT :: "comment"
RECORD_TAG :: "tag"

// A boolean as the report spells one. Written rather than printed through `%v`,
// which spells it `true` and `false` and would put the reader's answer at the
// mercy of PowerShell's own idea of what those words mean.
@(require_results)
flag :: proc(set: bool) -> string {
	if set {
		return "1"
	}
	return "0"
}

// One file's name, opening the block every record after it belongs to.
//
// Rendered apart from the facts because it is written BEFORE the file is read.
// Reading one is what can still take this program down: `core:odin/parser`
// recurses on shapes no bracket count bounds -- a chain of `^` in a type runs the
// thread off its stack at about eighty of them, counted depth one -- and a stack
// overflow has no error return to catch. A name already written is the whole of
// what says which file that was. scripts\common.ps1's Get-OdinSourceFact reads
// the last one when the tool exits non-zero.
render_file :: proc(name: string, into: ^strings.Builder) {
	assert(len(name) > 0, "asked to report on a file with no name")
	assert(into != nil, "asked to render a report into nothing at all")
	assert(
		strings.index_byte(name, '\t') < 0,
		"a path holding a tab cannot be reported field by field",
	)

	fmt.sbprintfln(into, "%s\t%s", RECORD_FILE, name)
}

// One file's facts, appended to the report being built.
//
// A file with a fault renders its fault and nothing else, which is the shape
// read_source hands back: a refused file has no facts, and a reader that saw a
// `file` record with no `proc` records after it and no `fault` between them would
// read a refusal as a file with no procedures in it.
render_facts :: proc(facts: Source_Facts, into: ^strings.Builder) {
	assert(into != nil, "asked to render a report into nothing at all")

	if facts.fault != Fault.None {
		assert(len(facts.procedures) == 0, "a refused file was rendered with procedures in it")
		fmt.sbprintfln(into, "%s\t%v\t%s", RECORD_FAULT, facts.fault, fault_says(facts.fault))
		return
	}

	for procedure in facts.procedures {
		fmt.sbprintfln(
			into,
			"%s\t%s\t%d\t%d\t%s\t%s\t%s",
			RECORD_PROCEDURE,
			procedure.name,
			procedure.declared_at,
			procedure.body_ends,
			flag(procedure.returns),
			flag(procedure.annotated),
			flag(procedure.attributable),
		)
	}
	for comment in facts.comments {
		fmt.sbprintfln(
			into,
			"%s\t%d\t%s\t%s",
			RECORD_COMMENT,
			comment.line,
			comment.inside,
			comment.text,
		)
	}
	for tag in facts.vet_tags {
		fmt.sbprintfln(into, "%s\t%s", RECORD_TAG, tag)
	}
}
