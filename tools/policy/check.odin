#+vet explicit-allocators
// This file turns one file's facts into the verdicts CLAUDE.md's source
// policies ask for, computed here directly -- ADR-0028's argument, read Odin
// with Odin, carried one step further, so nothing downstream re-parses this
// program's own report to decide pass or fail. Six collect_*_violations
// procedures compute those verdicts: five read Source_Facts, and
// collect_network_violations reads raw source text instead, because the
// network-confinement check has no need of a parse. Before #152's justfile
// migration these verdicts were computed by scripts\common.ps1's
// Assert-Odin* procedures instead, reading that report back in a second
// language.
//
// The file-tag roster is here too: CLAUDE.md rule M2's other half, the names
// every file a scope covers must declare on a `#+vet` line above its own
// `package` clause. Before #152, this roster lived in scripts\common.ps1's
// $OdinFileVetTags, which this program already read every file's tags to
// check against.
package policy

import "core:fmt"
import "core:mem"
import "core:strings"

// CLAUDE.md rule F1: "checkable by machine and has no exceptions without a
// maintainer decision recorded at the site."
MAX_PROCEDURE_LINES :: 70

// The one scope a vet-tag requirement can be declared for today. A name whose
// scope is not `.Every` has nothing here to resolve it, which is refused
// rather than silently applied to no file at all -- see required_vet_tags.
Vet_Tag_Scope :: enum u8 {
	Every,
}

Vet_Tag_Requirement :: struct {
	name:  string,
	scope: Vet_Tag_Scope,
}

// A name starting with `!` turns a vet check OFF; declared for every file, it
// would disable that check across the whole repository in silence. None does
// today (issue #45 is the ticket that would add one), and required_vet_tags
// refuses the combination if that ever changes without this comment moving
// with it.
vet_tag_roster := []Vet_Tag_Requirement{{name = "explicit-allocators", scope = .Every}}

// One thing wrong with one file, at the line that says so.
Violation :: struct {
	file:    string,
	line:    int,
	message: string,
}

// CLONES `file`: a violation must outlive whatever buffer its caller found
// the name in, and every caller here reads from a slice or a scratch string
// this program frees before the violations are ever reported.
@(require_results)
make_violation :: proc(
	file: string,
	line: int,
	message: string,
	allocator: mem.Allocator,
) -> Violation {
	assert(len(file) > 0, "a violation nobody can locate is not a violation about anything")
	assert(len(message) > 0, "a violation with nothing to say is not a violation")
	return Violation{file = strings.clone(file, allocator), line = line, message = message}
}

// The `#+vet` names ROSTER declares for `scope`, refusing the two ways that
// scope's requirement can be silent (CLAUDE.md rule M2): a name that turns a
// check off, declared for every file, and a scope this switch carries no arm
// for. Panics rather than returning an error: a malformed roster is a defect
// in this program's own data, not in the tree it is reading, and nothing
// external can trigger either branch (rule A8's boundary is source files, not
// this package's own constants).
@(require_results)
required_vet_tags :: proc(roster: []Vet_Tag_Requirement, allocator: mem.Allocator) -> []string {
	assert(
		allocator.procedure != nil,
		"the required names outlive this call and need a chosen allocator",
	)

	required := make([dynamic]string, 0, len(roster), allocator)
	for tag in roster {
		if len(tag.name) > 0 && tag.name[0] == '!' && tag.scope == .Every {
			panic("a +vet name that turns a check off must not be scoped to every file")
		}
		switch tag.scope {
		case .Every:
			append(&required, tag.name)
		}
	}
	return required[:]
}

// CLAUDE.md rule F1, for every procedure an attribute could sit on: measured
// from the line carrying `::` through the closing brace, comments and blanks
// included.
collect_length_violations :: proc(file: string, facts: Source_Facts, into: ^[dynamic]Violation) {
	assert(len(file) > 0, "asked to measure the procedures of no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	for procedure in facts.procedures {
		if !procedure.attributable {
			continue
		}
		length := procedure.body_ends - procedure.declared_at + 1
		if length > MAX_PROCEDURE_LINES {
			message := fmt.aprintf(
				"%s is %d lines, over CLAUDE.md rule F1's %d-line limit",
				procedure.name,
				length,
				MAX_PROCEDURE_LINES,
				allocator = into.allocator,
			)
			append(into, make_violation(file, procedure.declared_at, message, into.allocator))
		}
	}
}

// CLAUDE.md section 0: no comment inside a procedure body, said in the code or
// said above the procedure instead.
collect_comment_violations :: proc(file: string, facts: Source_Facts, into: ^[dynamic]Violation) {
	assert(len(file) > 0, "asked to check the comments of no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	for body_comment in facts.comments {
		message := fmt.aprintf(
			"comment inside %s (CLAUDE.md section 0): %s",
			body_comment.inside,
			body_comment.text,
			allocator = into.allocator,
		)
		append(into, make_violation(file, body_comment.line, message, into.allocator))
	}
}

// CLAUDE.md section 0: an in-repo comment cites a construct by NAME, never
// by line number -- the same rule the Odin notes section already applies to
// `core`, carried to every in-repo comment (issue #235). A line drifts on
// the very next edit to the file it names; a name does not. Reach is
// `.odin` files only, because `facts` comes from `discover_odin_files`
// (fix round 2 finding 1): a non-Odin file such as the repository's own
// justfile can still carry a line-number cite in its comments and this
// check will never see it. That is a scope decision, not an oversight --
// migrate any such cite by hand when found.
collect_line_number_cite_violations :: proc(
	file: string,
	facts: Source_Facts,
	into: ^[dynamic]Violation,
) {
	assert(len(file) > 0, "asked to check the line-number cites of no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	for cite in facts.line_number_cites {
		message := fmt.aprintf(
			"comment cites %q by line number, not by name (CLAUDE.md section 0, issue #235)",
			cite.text,
			allocator = into.allocator,
		)
		append(into, make_violation(file, cite.line, message, into.allocator))
	}
}

// CLAUDE.md rule F2: every procedure that hands something back, and can carry
// the attribute at all, carries `@(require_results)`.
collect_result_violations :: proc(file: string, facts: Source_Facts, into: ^[dynamic]Violation) {
	assert(len(file) > 0, "asked to check the results of no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	for procedure in facts.procedures {
		if !procedure.attributable || !procedure.returns || procedure.annotated {
			continue
		}
		message := fmt.aprintf(
			"%s hands back an answer with no @(require_results) (CLAUDE.md rule F2)",
			procedure.name,
			allocator = into.allocator,
		)
		append(into, make_violation(file, procedure.declared_at, message, into.allocator))
	}
}

// CLAUDE.md rule M2: every name `required` names must appear among the file's
// own `#+vet` tags, matched case-sensitively the way the compiler matches it.
collect_vet_tag_violations :: proc(
	file: string,
	facts: Source_Facts,
	required: []string,
	into: ^[dynamic]Violation,
) {
	assert(len(file) > 0, "asked to check the vet tags of no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	for name in required {
		declared := false
		for tag in facts.vet_tags {
			if tag == name {
				declared = true
				break
			}
		}
		if !declared {
			message := fmt.aprintf(
				"does not declare #+vet %s (CLAUDE.md rule M2)",
				name,
				allocator = into.allocator,
			)
			append(into, make_violation(file, 1, message, into.allocator))
		}
	}
}

// Issue #97/#105: no `os.remove_all(...)` call expression anywhere in the
// tree, whatever local name a file's own import binds `core:os` to.
collect_remove_all_violations :: proc(
	file: string,
	facts: Source_Facts,
	into: ^[dynamic]Violation,
) {
	assert(len(file) > 0, "asked to check the remove_all calls of no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	for line in facts.remove_all_lines {
		message := strings.clone(
			"os.remove_all(...) call, which can fault on a core:testing runner thread over a non-empty directory (issue #97)",
			into.allocator,
		)
		append(into, make_violation(file, line, message, into.allocator))
	}
}

// Issue #219's class: a `defer` that walks or derefs a container registered
// ahead of a later `defer`, in the same scope, that deletes or frees it.
// Odin's own defers run LIFO, so the later-registered free fires FIRST and
// the walk this reports then runs on freed memory -- silently, the way
// #184's main.odin pair did before it was fixed by hand.
collect_defer_order_violations :: proc(
	file: string,
	facts: Source_Facts,
	into: ^[dynamic]Violation,
) {
	assert(len(file) > 0, "asked to check the defer order of no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	for issue in facts.defer_order {
		message := fmt.aprintf(
			"defer %s(%s, ...) reads %s after defer %s(%s, ...) at line %d frees it (LIFO order; issue #219's class)",
			issue.walk_proc,
			issue.arg,
			issue.arg,
			issue.free_proc,
			issue.arg,
			issue.free_line,
			allocator = into.allocator,
		)
		append(into, make_violation(file, issue.line, message, into.allocator))
	}
}

// README.md's Network access claim (issue #58): all network code lives in
// one file, and the name appears nowhere else under `src/`, in any case.
// Case-insensitive because the Win32 headers' own capitalisation --
// `WinHttpOpen` -- is what a real caller writes, and a case-sensitive match
// would refuse only the spelling nobody uses. A literal substring, checked
// over raw text rather than through read_source: the claim is about what the
// file SAYS, not about its syntax, so a file that fails to parse is still
// checked here.
NETWORK_CODE_NAME :: "winhttp"
NETWORK_CODE_FILE :: "src/net/winhttp.odin"

collect_network_violations :: proc(relative: string, src: string, into: ^[dynamic]Violation) {
	assert(len(relative) > 0, "asked to check the network confinement of no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	if !strings.has_prefix(relative, "src/") || relative == NETWORK_CODE_FILE {
		return
	}
	lowered := strings.to_lower(src, into.allocator)
	defer delete(lowered, into.allocator)
	if strings.contains(lowered, NETWORK_CODE_NAME) {
		message := fmt.aprintf(
			"'%s' appears outside %s (README.md, Network access)",
			NETWORK_CODE_NAME,
			NETWORK_CODE_FILE,
			allocator = into.allocator,
		)
		append(into, make_violation(relative, 0, message, into.allocator))
	}
}

// Every message a run of collect_violations allocated, given back to the
// allocator it came from. Paired with the collection (CLAUDE.md rule A4): the
// dynamic array itself is the caller's to `delete`, since it may have been
// built with `make` under a capacity this procedure never chose.
violations_destroy :: proc(violations: [dynamic]Violation, allocator: mem.Allocator) {
	assert(
		allocator.procedure != nil,
		"a violation's message cannot be freed to an allocator nobody chose",
	)
	for one in violations {
		delete(one.file, allocator)
		delete(one.message, allocator)
	}
}

// Every verdict this program computes about one file's facts, appended in the
// order CLAUDE.md states the rules: section 0 (the body-comment ban, then
// issue #235's line-number-cite ban), rule F1, rule F2, rule M2, then the
// #97/#105 ban, then issue #219's defer-order class -- all riding the same
// read.
collect_violations :: proc(
	file: string,
	facts: Source_Facts,
	required_tags: []string,
	into: ^[dynamic]Violation,
) {
	assert(len(file) > 0, "asked to check no file at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	collect_comment_violations(file, facts, into)
	collect_line_number_cite_violations(file, facts, into)
	collect_length_violations(file, facts, into)
	collect_result_violations(file, facts, into)
	collect_vet_tag_violations(file, facts, required_tags, into)
	collect_remove_all_violations(file, facts, into)
	collect_defer_order_violations(file, facts, into)
}
