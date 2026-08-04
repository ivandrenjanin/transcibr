#+vet explicit-allocators
package policy

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// This file is the entry point: one file read, one report written, and nothing
// else. Everything worth testing is in policy.odin and collect.odin, which take
// source as text (ADR-0009's boundary, applied to a build tool).
//
// The files to read arrive in a FILE, one absolute path per line, rather than as
// arguments. Discovery belongs to scripts\common.ps1's Get-OdinSource, which is
// the one copy of it that the formatting sweep already asks; what this program
// has to be told is which files that discovery found. A request file also has no
// command-line length to run out of, and nothing to quote.

USAGE :: `usage:
  transcibr-policy <request-file>
      read every .odin file named in the request file -- one path per line --
      and write a report of what CLAUDE.md's source policies ask about each.`

// A request nobody can act on: no request file, or one that cannot be read. The
// build has no report to check and must say so rather than check an empty one.
REQUEST_ERROR :: 2

main :: proc() {
	assert(len(os.args) > 0, "a process started with no argv at all, not even its own name")

	if len(os.args) != 2 {
		fmt.eprintln(USAGE)
		os.exit(REQUEST_ERROR)
	}

	request, request_error := os.read_entire_file(os.args[1], context.allocator)
	if request_error != nil {
		fmt.eprintfln("cannot read the request file %s: %v", os.args[1], request_error)
		os.exit(REQUEST_ERROR)
	}
	defer delete(request, context.allocator)

	read := report_each(string(request), context.allocator)
	if read == 0 {
		fmt.eprintfln("the request file %s names no file at all", os.args[1])
		os.exit(REQUEST_ERROR)
	}
}

// Every path the request names, reported in the order it names them, and each
// one WRITTEN as it is finished rather than accumulated for the end.
//
// Accumulated, a report is lost with the program that holds it, and reading a
// file is what can still take this one down (see render_file). Written as it
// goes, what arrived before the crash is what says how far it got. How many were
// read comes back so that a request naming nothing is refused rather than
// answered with an empty report, which reads as a tree with nothing in it.
@(require_results)
report_each :: proc(request: string, allocator: mem.Allocator) -> (read: int) {
	assert(allocator.procedure != nil, "a report is built per file and needs a chosen allocator")

	rest := request
	for line in strings.split_lines_iterator(&rest) {
		path := strings.trim_space(line)
		if len(path) == 0 {
			continue
		}
		report_one(path, allocator)
		read += 1
	}

	return
}

// One file, NAMED and then read. The name goes out first and on its own, so a
// read this program does not survive still says which file it was reading.
//
// A file that cannot be read at all is reported as that fault rather than
// skipped: a check that quietly covers one file fewer than it was asked to
// reports the same green as one that covered them all.
report_one :: proc(path: string, allocator: mem.Allocator) {
	assert(len(path) > 0, "asked to read a file with no name")
	assert(allocator.procedure != nil, "a report is built here and needs a chosen allocator")

	report := strings.builder_make(allocator)
	defer strings.builder_destroy(&report)

	render_file(path, &report)
	fmt.print(strings.to_string(report))
	strings.builder_reset(&report)

	src, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {
		render_facts(Source_Facts{fault = .Unreadable}, &report)
		fmt.print(strings.to_string(report))
		return
	}
	defer delete(src, allocator)

	facts := read_source(path, string(src), allocator)
	defer facts_destroy(facts, allocator)
	render_facts(facts, &report)
	fmt.print(strings.to_string(report))
}
