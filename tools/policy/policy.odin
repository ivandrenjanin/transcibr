#+vet explicit-allocators
// transcibr-policy reads Odin source the way the compiler reads it, and reports
// the four things CLAUDE.md's source policies ask about a file: where every
// procedure begins and ends (rule F1), every comment inside a procedure body
// (section 0), which procedures hand something back and which of those carry
// `@(require_results)` (rule F2), and the `#+vet` names the file declares above
// its `package` clause (rule M2).
//
// It answers from `core:odin/parser` and `core:odin/ast`, which ship with the
// pinned compiler. ADR-0028 records why: the same four questions used to be
// answered by a column-zero text scan written in PowerShell -- a second model of
// Odin, in a second language, that was silently wrong three times.
//
// The build runs this; it is not part of transcibr. `just check` builds it
// (`odin run tools/policy`) before the checks that read it and says so where
// it happens.
//
// This file holds the fault vocabulary, the shape of one file's facts, and the
// bounded read that produces them. collect.odin holds the walk that finds
// procedures, comments and tags; report.odin renders what the build reads;
// main.odin is the entry point.
package policy

import "base:runtime"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

// What one source file can be refused for.
//
// Operating errors, every one of them. A source file is external input (CLAUDE.md
// rule A8) and none of these may crash this program or pass as a clean read: a
// file the checks could not look at is a file the build must refuse, never one it
// reports nothing about.
Fault :: enum u8 {
	None = 0,
	Unreadable,
	Nested_Too_Deep,
	Not_Odin,
}

// One procedure, as the four policies need to see it.
//
// `declared_at` is the line rule F1 counts from -- the one carrying `::` -- and
// `body_ends` the line carrying the closing brace, so the span is what that rule
// measures with no arithmetic left to a caller that could do it differently.
//
// `attributable` is the difference between a procedure an attribute can sit on
// and one it cannot. `@(require_results)` goes above a `::` declaration; there is
// nowhere to write it for a procedure literal passed as an argument, and the
// compiler refuses it on a `:=` binding. Rules F1 and F2 may only demand what can
// be given, so they read this field.
//
// It is a claim about how the body was DECLARED and never about how it was
// named: `_ :: proc()` reads as a hole and takes an attribute like anything else,
// and conflating the two exempted it from both rules.
Procedure :: struct {
	name:         string,
	declared_at:  int,
	body_ends:    int,
	returns:      bool,
	annotated:    bool,
	attributable: bool,
}

// One comment inside a procedure body, with the procedure it sits in.
//
// STRICTLY inside: a comment on the declaration line or on the closing-brace line
// is not one, so the comment a procedure is allowed -- the one above it, saying
// why it exists -- is never read as a comment inside it.
Body_Comment :: struct {
	inside: string,
	line:   int,
	text:   string,
}

// Everything the build asks about one file, or the fault that stopped it being
// asked. A file with a fault carries no facts at all: a partial answer read as a
// complete one is the silence this whole program exists to end.
Source_Facts :: struct {
	procedures:       []Procedure,
	comments:         []Body_Comment,
	vet_tags:         []string,
	remove_all_lines: []int,
	fault:            Fault,
}

// The attribute rule F2 is about, spelled as the compiler's own sources spell it.
// Both `@(require_results)` and the bare `@require_results` parse to this one
// identifier, so there is no second spelling for a reader to miss.
REQUIRE_RESULTS :: "require_results"

// The file tag rule M2 is about. The compiler reads one only above the `package`
// clause, and several names may sit on one of these lines.
VET_TAG :: "#+vet"

// The import path and the procedure name the #97 ban is about: any
// `os.remove_all(...)` call expression, wherever the file's own import binds
// the local name `os` to `core:os`.
//
// The match is TEXTUAL against the imported package's own name, the same way
// requires_results reads an attribute's spelling rather than resolving what it
// binds to -- a second model of Odin's import resolution is the defect
// ADR-0028 is about, and this check does not need one to answer the question it
// asks. The residual: an import aliased away from `os` twice over --
// `import myos "core:os"` and a local `remove_all` of its own on some other
// package aliased `os` -- would not be told apart by a textual match. Neither
// shape appears anywhere in this repository today.
REMOVE_ALL_PACKAGE :: "core:os"
REMOVE_ALL_PROCEDURE :: "remove_all"

// What a procedure with no name of its own is called in a report. A literal
// passed as an argument has a body, and a comment inside that body is a comment
// inside a procedure body; it has no declaration for an attribute to sit above.
ANONYMOUS :: "<literal>"

// The deepest bracket nesting any file in this repository reaches, and the
// shallowest nesting measured to overflow the parser's stack. Both are measured
// against the pin, dev-2026-07-nightly:819fdc7, and both are here so that
// MAX_SOURCE_DEPTH below is checked against them rather than merely asserted to
// be reasonable.
//
// The overflow is 62 nested parentheses in a debug build -- `x := (((...1...)))`
// -- which is the shallowest BRACKET shape measured: nested blocks survive 200
// and nested calls 100.
//
// It is not the worst shape the parser has, and this counter does not claim to
// bound one. A chain of `^` in a type carries no bracket at all and overflows at
// about eighty of them, counted depth ONE; `+` chains and `if`/`else if` chains
// go at about 1600. What covers those is render_file, which names a file before
// reading it: the residual is a crash that says which file, never a silent wrong
// answer and never an anonymous death over a tree of seventy-odd.
DEEPEST_IN_TREE :: 7
SHALLOWEST_OVERFLOW :: 62

// How deeply a file may nest brackets before it is refused unread.
//
// `core:odin/parser` is a recursive descent with NO depth limit, exactly like
// `core:encoding/json` (CLAUDE.md, Odin notes): nesting deep enough runs the
// thread off its stack and takes the process down, with no error return to catch.
// So the depth is bounded BEFORE the parse, counted with the compiler's own
// tokenizer, which is iterative and allocates nothing.
//
// Unlike the JSON case there is no order of magnitude to be had. That limit sits
// a tenth of the way to a crash measured at 751 levels; here the crash is at 62,
// so a bound with that much headroom would refuse ordinary Odin. What is left is
// a bound comfortably above every file in this repository and comfortably below
// the overflow -- a guard against the pathological file, not a proof.
//
// The residual is loud rather than silent, and NAMED, which is what makes it
// acceptable: a file that overflows the stack anyway kills this program, a policy
// tool that died is a build that failed, and the file it was reading has already
// been written out. What is NOT true of it is that odinfmt would go down on the
// same file first -- measured at the pin, odinfmt formats the eighty-caret file
// without complaint and survives 400 nested parentheses, where this overflows at
// 62.
MAX_SOURCE_DEPTH :: 32

#assert(MAX_SOURCE_DEPTH > DEEPEST_IN_TREE)
#assert(MAX_SOURCE_DEPTH < SHALLOWEST_OVERFLOW)

// `core:odin/tokenizer` fills its keyword table lazily behind a double-checked
// lock that never re-checks: two threads calling `tokenizer.init` for the first
// time both find the flag unset, both take the spin lock, and the second runs
// keyword_lut_init over an already-filled table, where its own
// `assert(entry.kind == .Invalid, name)` fires. Measured at the pin, roughly one
// run in three of this package's test sweep.
//
// This program is single-threaded and never meets it. `odin test` runs twelve
// threads by default and meets it constantly -- and a test that trips an
// assertion takes the whole runner down with no summary and no report (issue
// #22), so this cannot be left to chance. The table is therefore filled here,
// before main and before any test thread exists, by tokenizing nothing at all.
// `contextless` because Odin refuses an `@(init)` procedure that is not, and the
// context is built here rather than inherited for the same reason a Win32 window
// procedure builds one (CLAUDE.md rule S3): there is none to inherit. Nothing
// below it allocates -- the keyword table is a global array and the scan of an
// empty source reads no bytes -- so the default context is the whole of what this
// needs.
@(init)
fill_the_keyword_table :: proc "contextless" () {
	context = runtime.default_context()
	scanner: tokenizer.Tokenizer
	tokenizer.init(&scanner, "", "", nil)
	assert(tokenizer.scan(&scanner).kind == .EOF, "an empty source tokenized to something")
}

// What a fault says, in the words the build prints beside the file's name.
//
// A switch rather than an enumerated array, and the success value is refused by
// name: nothing reports a fault that did not happen, and an arm returning a
// plausible-looking empty string for one is how a file with no fault comes to be
// named in a refusal. See CLAUDE.md, Odin notes: enumerated arrays and switches.
@(require_results)
fault_says :: proc(fault: Fault) -> string {
	assert(fault != Fault.None, "asked what a file with no fault says about itself")
	switch fault {
	case .None:
		return ""
	case .Unreadable:
		return "cannot be read at all"
	case .Nested_Too_Deep:
		return "nests brackets deeper than the parser this reads with survives"
	case .Not_Odin:
		return "does not parse as Odin; the compiler names the line and the reason"
	}
	assert(false, "a fault with no words for it")
	return ""
}

// The deepest run of unclosed brackets in one source, counted with the
// compiler's OWN tokenizer.
//
// The tokenizer is what already knows where a string, a raw string, a rune
// literal and a comment end, which is the whole reason it is used rather than a
// byte scan. INLINE_SPECIALS in src\transcript\render.odin is three string
// literals joined, one of them a double-quoted backtick and one a raw string
// holding a bracket; a scan counting brackets by hand reads that bracket, and
// every bracket in transcribed speech, as nesting.
//
// The count has a FLOOR at zero, because a closer with nothing open closes
// nothing. Allowed to go negative it DEFLATES: a run of stray closers ahead of a
// deep nest brings the peak back under the bound and hands the parser the one
// shape the bound exists to keep away from it. Any truncated or badly merged
// source is that file, and a source file is external input (rule A8).
@(require_results)
nesting_depth :: proc(name: string, src: string) -> (deepest: int) {
	assert(len(name) > 0, "a source nobody can name is a source nothing can report")
	scanner: tokenizer.Tokenizer
	tokenizer.init(&scanner, src, name, nil)

	depth := 0
	for {
		token := tokenizer.scan(&scanner)
		if token.kind == .EOF {
			break
		}
		#partial switch token.kind {
		case .Open_Paren, .Open_Bracket, .Open_Brace:
			depth += 1
			if depth > deepest {
				deepest = depth
			}
		case .Close_Paren, .Close_Bracket, .Close_Brace:
			if depth > 0 {
				depth -= 1
			}
		}
	}

	assert(deepest >= depth, "a run left open at the end is deeper than the deepest counted")
	return
}

// One file parsed onto an arena the caller throws away whole.
//
// The parser takes its allocator from the context and frees nothing it builds, so
// the tree lives on `tree` and dies with it -- the same shape `parse_cues` uses
// for `core:encoding/json` and for the same reason.
//
// `err` and `warn` are silenced because this program's standard error is the
// build's, and a syntax error here is already going to be reported by the
// compiler moments later, against the same file, with the line and the reason.
// What this has to do is refuse the file rather than read half of it.
@(require_results)
parse_into :: proc(file: ^ast.File, tree: mem.Allocator) -> bool {
	assert(file != nil, "asked to parse into no file at all")
	assert(tree.procedure != nil, "the tree is thrown away whole and needs an arena to live on")

	context.allocator = tree
	reader := parser.default_parser()
	reader.err = nil
	reader.warn = nil

	parsed := parser.parse_file(&reader, file)
	if file.syntax_error_count > 0 {
		return false
	}
	return parsed
}

// Everything the build asks about one file, or the fault that stopped it being
// asked.
//
// The source arrives as TEXT rather than as a path, which is what makes this
// program's own reader testable in Odin: every shape the checks turn on -- a
// procedure type, a `where` clause, a raw string holding a `}` at column 0, an
// attribute quoted inside one -- is a string literal in policy_test.odin and not
// a fixture somebody has to plant on a disk.
@(require_results)
read_source :: proc(name: string, src: string, allocator: mem.Allocator) -> (facts: Source_Facts) {
	assert(len(name) > 0, "a file's facts nobody can locate are not facts about anything")
	assert(
		allocator.procedure != nil,
		"the facts outlive this procedure and need a chosen allocator",
	)

	if nesting_depth(name, src) > MAX_SOURCE_DEPTH {
		return Source_Facts{fault = .Nested_Too_Deep}
	}

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)
	tree := mem.dynamic_arena_allocator(&scratch)

	file := ast.File {
		fullpath = name,
		src      = src,
	}
	if !parse_into(&file, tree) {
		return Source_Facts{fault = .Not_Odin}
	}

	found := collect_procedures(&file, tree, allocator)
	return Source_Facts {
		procedures = found,
		comments = collect_body_comments(&file, found, tree, allocator),
		vet_tags = collect_vet_tags(&file, tree, allocator),
		remove_all_lines = collect_remove_all_calls(&file, tree, allocator),
	}
}

// Everything read_source handed back, given back to the allocator it came from.
// Paired with the read (CLAUDE.md rule A4), and it asserts the negative space the
// read promises: a file with a fault carries no facts.
facts_destroy :: proc(facts: Source_Facts, allocator: mem.Allocator) {
	assert(allocator.procedure != nil, "facts cannot be returned to an allocator nobody chose")
	if facts.fault != Fault.None {
		assert(len(facts.procedures) == 0, "a refused file was handed back with procedures in it")
	}

	for procedure in facts.procedures {
		delete(procedure.name, allocator)
	}
	delete(facts.procedures, allocator)

	for comment in facts.comments {
		delete(comment.inside, allocator)
		delete(comment.text, allocator)
	}
	delete(facts.comments, allocator)

	for tag in facts.vet_tags {
		delete(tag, allocator)
	}
	delete(facts.vet_tags, allocator)

	delete(facts.remove_all_lines, allocator)
}
