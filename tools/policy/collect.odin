#+vet explicit-allocators
package policy

import "core:mem"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// This file finds things in a parsed file: every procedure with a body, every
// comment inside one of those bodies, and every `#+vet` name declared above the
// package clause.
//
// The descent is `ast.walk`, the compiler's own walker, called on each top-level
// statement. Writing a second walk here would put a second model of where a
// procedure can be declared beside the one the compiler maintains -- which is the
// defect ADR-0028 is about, reintroduced one language over. What that buys is the
// row the column-zero scan could never reach: a procedure declared inside a
// `when` block, nested inside another body, or passed as a literal is found by
// the same walk as one at column 0, with no special case for any of them.
//
// `ast.walk` panics on a node type it does not know, which is why a file that did
// not parse cleanly is never walked (see parse_into): the tree it would descend
// carries Bad_Expr and Bad_Stmt nodes, and a walker meeting one it cannot place
// is a crash rather than a wrong answer.

// What the walk is accumulating, and where it puts things.
//
// `named` is what stops a procedure being counted twice. The walk meets the
// declaration first and records the literal it holds; it then descends into that
// same literal as a child, and without this it would be recorded again -- once
// with its name and its attributes, once as an anonymous body.
Walk_State :: struct {
	found: [dynamic]Procedure,
	named: map[rawptr]bool,
	names: mem.Allocator,
}

// Every procedure in one file that has a body, in the order the walk meets them:
// outermost first, so a nested one always follows the procedure it sits in.
@(require_results)
collect_procedures :: proc(
	file: ^ast.File,
	tree: mem.Allocator,
	allocator: mem.Allocator,
) -> []Procedure {
	assert(file != nil, "asked for the procedures of no file at all")
	assert(
		allocator.procedure != nil,
		"the procedures outlive this walk and need a chosen allocator",
	)

	state := Walk_State {
		found = make([dynamic]Procedure, 0, len(file.decls), tree),
		named = make(map[rawptr]bool, len(file.decls), tree),
		names = allocator,
	}
	walker := ast.Visitor {
		visit = note_node,
		data  = &state,
	}
	for declaration in file.decls {
		ast.walk(&walker, declaration)
	}

	return slice.clone(state.found[:], allocator)
}

// One node of the walk. Returning the visitor is what carries the descent on into
// the node's children; returning nil stops it, and nil is only ever the answer to
// the nil node `ast.walk` passes after a node's children are done.
@(require_results)
note_node :: proc(walker: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	assert(walker != nil, "ast.walk called a visit procedure through no visitor")
	assert(walker.data != nil, "the walk carries no state to record anything into")

	state := (^Walk_State)(walker.data)
	#partial switch found in node.derived {
	case ^ast.Value_Decl:
		note_declared(state, found)
	case ^ast.Proc_Lit:
		note_literal(state, found)
	}
	return walker
}

// A procedure declared with a name: `f :: proc() { ... }`, wherever it sits.
//
// A declaration whose value is a procedure TYPE rather than a literal is not one
// of these and is recorded as nothing at all. A type has no body: no length for
// rule F1, no lines for section 0 to find a comment in, and the compiler REFUSES
// `@(require_results)` on one, so a demand for it there is a build nobody can
// make pass.
note_declared :: proc(state: ^Walk_State, declaration: ^ast.Value_Decl) {
	assert(state != nil, "asked to record a declaration into no state at all")
	assert(declaration != nil, "asked to record no declaration at all")

	assert(
		len(declaration.values) <= len(declaration.names),
		"a declaration with more values than names is a parser defect",
	)

	for value, index in declaration.values {
		literal, is_literal := value.derived.(^ast.Proc_Lit)
		if !is_literal {
			continue
		}
		if literal.body == nil {
			continue
		}
		state.named[rawptr(literal)] = true
		append(
			&state.found,
			Procedure {
				name = strings.clone(declared_name(declaration.names[index]), state.names),
				declared_at = declaration.pos.line,
				body_ends = literal.body.end.line,
				returns = hands_back(literal),
				annotated = requires_results(declaration),
				attributable = !declaration.is_mutable,
				is_test = has_attribute(declaration, TEST_ATTRIBUTE),
			},
		)
	}
}

// A procedure with no declaration of its own: a literal passed as an argument or
// stored in a field. Recorded because its body is a procedure body and section 0
// is about procedure bodies; never marked attributable, because there is nowhere
// to write an attribute for one.
note_literal :: proc(state: ^Walk_State, literal: ^ast.Proc_Lit) {
	assert(state != nil, "asked to record a literal into no state at all")
	assert(literal != nil, "asked to record no literal at all")

	if literal.body == nil {
		return
	}
	if state.named[rawptr(literal)] {
		return
	}
	append(
		&state.found,
		Procedure {
			name = strings.clone(ANONYMOUS, state.names),
			declared_at = literal.pos.line,
			body_ends = literal.body.end.line,
			returns = hands_back(literal),
		},
	)
}

// The name a declaration gives one of its values.
//
// `_` is one of these, and reporting it as one is the point. It reads as a hole,
// but an attribute sits above it perfectly well -- `@(require_results)` on
// `_ :: proc() -> bool` compiles clean under the full vet set, measured at the
// pin -- so rules F1 and F2 have every question about that body they have about
// any other. Read as nameless it was exempt from both, and the column-zero scan
// this replaced was not: its regex matched `_` like any other name.
//
// What is left unnamed is a value bound to something that is not an identifier at
// all. There is no spelling to report for one and nothing to look an attribute up
// by, and whether an attribute may sit there is a question about the `::`, which
// note_declared reads for itself.
@(require_results)
declared_name :: proc(name: ^ast.Expr) -> string {
	assert(name != nil, "a declaration with a hole where a name goes is a parser defect")
	identifier, is_identifier := name.derived.(^ast.Ident)
	if !is_identifier {
		return ANONYMOUS
	}
	assert(len(identifier.name) > 0, "an identifier spelled with no characters is a parser defect")
	return identifier.name
}

// Whether a procedure hands anything back.
//
// Read off the results field rather than off a `->` anywhere in the header, which
// is the case that separates this from a search for two characters: a parameter
// that is itself a procedure carries its own arrow one level in, and
// `f :: proc(cb: proc(x: int) -> int)` returns nothing at all.
@(require_results)
hands_back :: proc(literal: ^ast.Proc_Lit) -> bool {
	assert(literal != nil, "asked what no procedure at all hands back")
	assert(literal.type != nil, "a procedure literal with no type is a parser defect")
	if literal.type.results == nil {
		return false
	}
	return len(literal.type.results.list) > 0
}

// Whether `@(require_results)` sits above a declaration.
//
// Both spellings arrive here as the same identifier: odinfmt rewrites
// `@require_results` to the parenthesised form, and the compiler's own
// core\odin\parser\file_tags.odin writes the bare one, so a reader that knew only
// one spelling would be right only about files that had been formatted.
@(require_results)
requires_results :: proc(declaration: ^ast.Value_Decl) -> bool {
	assert(declaration != nil, "asked about the attributes of no declaration at all")
	return has_attribute(declaration, REQUIRE_RESULTS)
}

// Whether `name` sits among a declaration's own `@(...)` attributes, however
// many share the list and whatever else rides beside it: `@(test)`,
// `@(private, test)` and a `test` stacked on a line of its own above the
// declaration are the same fact to a reader that answers this, exactly the
// way `requires_results` already answered the same question for one fixed
// name before this generalised it (issue #174).
@(require_results)
has_attribute :: proc(declaration: ^ast.Value_Decl, name: string) -> bool {
	assert(declaration != nil, "asked about the attributes of no declaration at all")
	assert(len(name) > 0, "asked whether a declaration carries no attribute name at all")

	for attribute in declaration.attributes {
		assert(attribute != nil, "an attribute list holding a hole is a parser defect")
		for element in attribute.elems {
			if attribute_name(element) == name {
				return true
			}
		}
	}
	return false
}

// The name one element of an attribute list is spelled with: `require_results`
// out of `@(private, require_results)`, and `default_calling_convention` out of
// `@(default_calling_convention = "std")`.
@(require_results)
attribute_name :: proc(element: ^ast.Expr) -> string {
	assert(element != nil, "an attribute list holding a hole is a parser defect")

	#partial switch named in element.derived {
	case ^ast.Ident:
		return named.name
	case ^ast.Field_Value:
		assert(named.field != nil, "an attribute with a value and no name is a parser defect")
		key, is_identifier := named.field.derived.(^ast.Ident)
		if is_identifier {
			return key.name
		}
	}
	return ""
}

// Every comment sitting inside a procedure body, attributed to the innermost
// procedure that holds it.
//
// Every comment in the file arrives here: the parser records each one as it
// consumes it, whether it documents a declaration, trails code on its line, or
// sits inside a body. Which of them section 0 is about is decided by position
// alone, so a comment following code on its line counts exactly as one on a line
// of its own does.
@(require_results)
collect_body_comments :: proc(
	file: ^ast.File,
	procedures: []Procedure,
	tree: mem.Allocator,
	allocator: mem.Allocator,
) -> []Body_Comment {
	assert(file != nil, "asked for the comments of no file at all")
	assert(
		allocator.procedure != nil,
		"the comments outlive this walk and need a chosen allocator",
	)

	found := make([dynamic]Body_Comment, 0, len(file.comments), tree)
	for group in file.comments {
		assert(group != nil, "a comment group that is not there is a parser defect")
		for comment in group.list {
			holder, is_inside := innermost(procedures, comment.pos.line)
			if !is_inside {
				continue
			}
			append(
				&found,
				Body_Comment {
					inside = strings.clone(procedures[holder].name, allocator),
					line = comment.pos.line,
					text = one_line(comment.text, allocator),
				},
			)
		}
	}

	return slice.clone(found[:], allocator)
}

// Which procedure a line sits inside, innermost first.
//
// STRICTLY inside, which is what keeps the comment a procedure is allowed -- the
// one above it, saying why it exists -- from being read as one inside it. The
// closing-brace line is excluded at the other end for the same reason.
@(require_results)
innermost :: proc(procedures: []Procedure, line: int) -> (holder: int, is_inside: bool) {
	assert(line > 0, "a line number of zero is not a position in any file")

	holder = -1
	for procedure, index in procedures {
		if line <= procedure.declared_at {
			continue
		}
		if line >= procedure.body_ends {
			continue
		}
		if holder < 0 {
			holder = index
			is_inside = true
			continue
		}
		if procedure.declared_at > procedures[holder].declared_at {
			holder = index
		}
	}

	if is_inside {
		assert(holder >= 0, "reported a line as inside a procedure it could not name")
	}
	return
}

// A comment's own text, flattened to one line so it can be reported on one.
//
// A block comment runs on for as many lines as it likes and holds whatever
// somebody wrote in it, tabs included, and the report the build reads is one
// record per line with tabs between its fields.
@(require_results)
one_line :: proc(text: string, allocator: mem.Allocator) -> string {
	assert(len(text) > 0, "a comment token with no text is a tokenizer defect")
	assert(
		allocator.procedure != nil,
		"the text outlives this procedure and needs a chosen allocator",
	)

	head := text
	if cut := strings.index_any(head, "\r\n"); cut >= 0 {
		head = head[:cut]
	}
	head = strings.trim_space(head)

	flattened, rewritten := strings.replace_all(head, "\t", " ", allocator)
	if rewritten {
		return flattened
	}
	return strings.clone(head, allocator)
}

// Every line in one file where an `os.remove_all(...)` call expression
// appears -- the #97 review's own finding, not a rule any policy document
// states (see the justfile's `check` recipe comment above the call into this
// check).
//
// A file that never imports `core:os` is answered with no lines and no walk at
// all: nothing it could write can be a call through a name this never bound,
// and note_declared's own `named` map has no equivalent question to answer
// here, so there is nothing this walk would otherwise double-count.
@(require_results)
collect_remove_all_calls :: proc(
	file: ^ast.File,
	tree: mem.Allocator,
	allocator: mem.Allocator,
) -> []int {
	assert(file != nil, "asked for the remove_all calls of no file at all")
	assert(allocator.procedure != nil, "the lines outlive this walk and need a chosen allocator")

	found := make([dynamic]int, 0, 0, tree)

	os_name, has_os_import := os_import_name(file)
	if has_os_import {
		state := Remove_All_State {
			found   = &found,
			os_name = os_name,
		}
		walker := ast.Visitor {
			visit = note_remove_all_node,
			data  = &state,
		}
		for declaration in file.decls {
			ast.walk(&walker, declaration)
		}
	}

	return slice.clone(found[:], allocator)
}

// The local name one file's own import binds `core:os` to, and whether it
// imports it at all -- a file that never imports it cannot call anything
// through a name this ban means.
@(require_results)
os_import_name :: proc(file: ^ast.File) -> (name: string, found: bool) {
	assert(file != nil, "asked for the os import of no file at all")

	for declaration in file.imports {
		assert(declaration != nil, "an import list holding a hole is a parser defect")
		path := strings.trim(declaration.fullpath, `"`)
		if path != REMOVE_ALL_PACKAGE {
			continue
		}
		if len(declaration.name.text) > 0 {
			return declaration.name.text, true
		}
		return default_import_name(path), true
	}
	return "", false
}

// The local name an import binds when the source writes no explicit alias --
// the last path component, which is the convention every import in this
// repository already follows (`import "core:os"` reads as `os`).
@(require_results)
default_import_name :: proc(path: string) -> string {
	assert(len(path) > 0, "an import path with no text is a parser defect")

	cut := strings.last_index_any(path, ":/")
	if cut < 0 {
		return path
	}
	return path[cut + 1:]
}

// What the remove_all walk is accumulating: the lines found so far, and the
// local name this file's own import binds `core:os` to.
Remove_All_State :: struct {
	found:   ^[dynamic]int,
	os_name: string,
}

// One node of the remove_all walk, in the same shape note_node walks
// procedures: returning the visitor carries the descent into a node's
// children, and nil stops it.
@(require_results)
note_remove_all_node :: proc(walker: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	assert(walker != nil, "ast.walk called a visit procedure through no visitor")
	assert(walker.data != nil, "the walk carries no state to record anything into")

	state := (^Remove_All_State)(walker.data)
	#partial switch found in node.derived {
	case ^ast.Call_Expr:
		if is_remove_all_call(found, state.os_name) {
			append(state.found, found.pos.line)
		}
	}
	return walker
}

// Whether one call expression is `<os_name>.remove_all(...)`.
//
// `os_name` is what the file's own import bound, never the literal text
// `"os"` -- a file that imports `core:os` under a different local name is
// matched under that name and not under the convention every other file
// happens to follow.
@(require_results)
is_remove_all_call :: proc(call: ^ast.Call_Expr, os_name: string) -> bool {
	assert(call != nil, "asked whether no call expression at all is a remove_all call")
	assert(len(os_name) > 0, "asked to match against no import name at all")
	assert(call.expr != nil, "a call expression with no callee is a parser defect")

	selector, is_selector := call.expr.derived.(^ast.Selector_Expr)
	if !is_selector {
		return false
	}
	assert(selector.field != nil, "a selector with no field is a parser defect")
	if selector.field.name != REMOVE_ALL_PROCEDURE {
		return false
	}

	target, is_ident := selector.expr.derived.(^ast.Ident)
	if !is_ident {
		return false
	}
	return target.name == os_name
}

// One `defer` this file registers, wherever it sits, that this walk can name
// a container for: `f(X, ...)` where `X` is a plain identifier. A defer whose
// argument is a field access, an alias, or anything else with no single name
// is not one of these -- see collect_defer_order_issues.
Defer_Call :: struct {
	line:      int,
	proc_name: string,
	arg:       string,
}

// A `defer` that walks or derefs an identifier, registered in the same block
// AHEAD of a later `defer` that deletes or frees that same identifier.
// Odin's own defers run LIFO, so the later-registered free fires FIRST and
// the walk this records then runs on freed memory -- issue #219's class,
// fixed by hand three times before this check existed (main.odin's own
// `violations`/`delete` pair among them, #184).
//
// `line` is the WALKING defer's own line: the one that reads freed memory,
// and the one ground truth (the #178 review's six pre-fix hits) reports
// against.
Defer_Order_Issue :: struct {
	line:      int,
	walk_proc: string,
	free_proc: string,
	free_line: int,
	arg:       string,
}

// Every `defer` frees a container by name: the two builtins that hold this
// class, `delete` and `free`, matched the same way is_remove_all_call
// matches a selector's own field -- against the name the call was written
// with, never against what it resolves to.
DEFER_FREE_NAMES :: []string{"delete", "free"}

@(require_results)
is_freeing_call :: proc(name: string) -> bool {
	assert(len(name) > 0, "asked whether no proc name at all frees its argument")
	for freeing in DEFER_FREE_NAMES {
		if name == freeing {
			return true
		}
	}
	return false
}

// Every place in one file where a `defer` that walks or derefs an
// identifier is registered ahead of a later `defer`, in the SAME block,
// that deletes or frees that identifier.
//
// Scoped to the known shape (CLAUDE.md rule A2's discipline, generalised to
// a whole check rather than one assertion): same-identifier pairs, where
// "same identifier" means the call's first argument is written as the exact
// same plain identifier both times. What this deliberately does not see:
// a DIFFERENT scope (a nested block's own defer pair is read as that
// block's own scope, never paired with an outer one), an ALIAS (`t := tree;
// defer walk(t)` beside `defer delete(tree)` names two different tokens),
// and a FIELD ACCESS (`defer walk(state.tree)` has no single identifier for
// this to key on at all). Precision over recall: a check that reached for
// any of those would need to resolve what a name binds to, which is the
// second model of Odin ADR-0028 exists to keep this program from building.
@(require_results)
collect_defer_order_issues :: proc(
	file: ^ast.File,
	tree: mem.Allocator,
	allocator: mem.Allocator,
) -> []Defer_Order_Issue {
	assert(file != nil, "asked for the defer order of no file at all")
	assert(allocator.procedure != nil, "the issues outlive this walk and need a chosen allocator")

	found := make([dynamic]Defer_Order_Issue, 0, 0, tree)
	state := Defer_Order_State {
		found = &found,
		tree  = tree,
		text  = allocator,
	}
	walker := ast.Visitor {
		visit = note_defer_order_node,
		data  = &state,
	}
	for declaration in file.decls {
		ast.walk(&walker, declaration)
	}

	return slice.clone(found[:], allocator)
}

// What the defer-order walk is accumulating, and where the reported
// strings are allocated: `tree` for scratch work this program throws away
// with the parse, `text` for the strings a Defer_Order_Issue hands back --
// the same split note_declared makes between `state.names` and the tree
// arena, and for the same reason: the tree dies with read_source's scratch
// arena, and a reported string has to outlive that.
Defer_Order_State :: struct {
	found: ^[dynamic]Defer_Order_Issue,
	tree:  mem.Allocator,
	text:  mem.Allocator,
}

// One node of the defer-order walk: only a block's own direct statements
// are ever gathered as a scope, so a Block_Stmt is the only node this reads
// for anything -- descent into a nested block still happens (returning the
// visitor carries it on), and that nested block is read as its own scope
// when the walk reaches it as its own node.
@(require_results)
note_defer_order_node :: proc(walker: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	assert(walker != nil, "ast.walk called a visit procedure through no visitor")
	assert(walker.data != nil, "the walk carries no state to record anything into")

	state := (^Defer_Order_State)(walker.data)
	#partial switch found in node.derived {
	case ^ast.Block_Stmt:
		note_block_defers(state, found)
	}
	return walker
}

// One block's own defer-call pairs: every `defer` among its direct
// statements that names a container, checked pairwise for a walk registered
// ahead of a later free on the same identifier.
note_block_defers :: proc(state: ^Defer_Order_State, block: ^ast.Block_Stmt) {
	assert(state != nil, "asked to record a block's defers into no state at all")
	assert(block != nil, "asked to record the defers of no block at all")

	calls := make([dynamic]Defer_Call, 0, 0, state.tree)
	for stmt in block.stmts {
		call, is_named := named_defer_call(stmt)
		if is_named {
			append(&calls, call)
		}
	}

	for walk, i in calls {
		if is_freeing_call(walk.proc_name) {
			continue
		}
		free, has_free := later_free_of(calls[i + 1:], walk.arg)
		if !has_free {
			continue
		}
		append(
			state.found,
			Defer_Order_Issue {
				line = walk.line,
				walk_proc = strings.clone(walk.proc_name, state.text),
				free_proc = strings.clone(free.proc_name, state.text),
				free_line = free.line,
				arg = strings.clone(walk.arg, state.text),
			},
		)
	}
}

// The first later defer in `rest` that frees `arg`, if there is one.
@(require_results)
later_free_of :: proc(rest: []Defer_Call, arg: string) -> (free: Defer_Call, found: bool) {
	assert(len(arg) > 0, "asked for a free of no identifier at all")
	for candidate in rest {
		if !is_freeing_call(candidate.proc_name) {
			continue
		}
		if candidate.arg != arg {
			continue
		}
		return candidate, true
	}
	return {}, false
}

// One statement, read as a `defer` whose payload is a plain call naming a
// container as its first argument -- `defer for x in xs {...}`, `defer if
// ... {...}`, and a defer with no arguments at all carry no such name and
// answer `false`, never a guess.
@(require_results)
named_defer_call :: proc(stmt: ^ast.Stmt) -> (call: Defer_Call, found: bool) {
	assert(stmt != nil, "asked to read no statement at all as a defer")

	defer_stmt, is_defer := stmt.derived.(^ast.Defer_Stmt)
	if !is_defer {
		return {}, false
	}
	assert(defer_stmt.stmt != nil, "a defer with no statement to run is a parser defect")

	expr_stmt, is_expr := defer_stmt.stmt.derived.(^ast.Expr_Stmt)
	if !is_expr {
		return {}, false
	}
	assert(expr_stmt.expr != nil, "an expression statement with no expression is a parser defect")

	invocation, is_call_expr := expr_stmt.expr.derived.(^ast.Call_Expr)
	if !is_call_expr {
		return {}, false
	}

	name, has_name := defer_callee_name(invocation)
	if !has_name {
		return {}, false
	}
	arg, has_arg := defer_first_arg_name(invocation)
	if !has_arg {
		return {}, false
	}
	return Defer_Call{line = defer_stmt.pos.line, proc_name = name, arg = arg}, true
}

// The name a defer's own call was written with: the bare identifier for
// `delete(...)`, or the field for a qualified call like
// `testkit.remove_cache(...)`. A callee that is neither -- a call through
// an expression this cannot name -- answers `false`.
@(require_results)
defer_callee_name :: proc(call: ^ast.Call_Expr) -> (name: string, found: bool) {
	assert(call != nil, "asked for the callee of no call at all")
	assert(call.expr != nil, "a call expression with no callee is a parser defect")

	#partial switch callee in call.expr.derived {
	case ^ast.Ident:
		return callee.name, true
	case ^ast.Selector_Expr:
		assert(callee.field != nil, "a selector with no field is a parser defect")
		return callee.field.name, true
	}
	return "", false
}

// A call's first argument, read as the plain identifier it names -- never a
// field access, an index, or anything else with no single name to key a
// pair on.
@(require_results)
defer_first_arg_name :: proc(call: ^ast.Call_Expr) -> (name: string, found: bool) {
	assert(call != nil, "asked for the first argument of no call at all")
	if len(call.args) == 0 {
		return "", false
	}
	identifier, is_ident := call.args[0].derived.(^ast.Ident)
	if !is_ident {
		return "", false
	}
	return identifier.name, true
}

// The `#+vet` names one file declares for itself.
//
// Read off the file's TAGS, which the parser collects only from above the package
// clause -- the only place the compiler reads one. A `#+vet` line below the
// clause is a syntax error the parser refuses the whole file for, and one quoted
// inside the doc comment above it is a comment and never a tag, so neither can be
// credited to a file that does not carry it.
@(require_results)
collect_vet_tags :: proc(
	file: ^ast.File,
	tree: mem.Allocator,
	allocator: mem.Allocator,
) -> []string {
	assert(file != nil, "asked for the vet tags of no file at all")
	assert(allocator.procedure != nil, "the names outlive this walk and need a chosen allocator")

	found := make([dynamic]string, 0, len(file.tags), tree)
	for tag in file.tags {
		names, is_vet := vet_tag_names(tag.text)
		if !is_vet {
			continue
		}
		for name in strings.fields(names, tree) {
			append(&found, strings.clone(name, allocator))
		}
	}

	return slice.clone(found[:], allocator)
}

// What a file tag declares, where the tag is a `#+vet` one.
//
// The prefix has to be followed by whitespace or by nothing at all: `#+vetted` is
// not a misspelling of this tag, it is a different tag, and reading its remainder
// as a list of vet names would credit a file with names nobody wrote.
@(require_results)
vet_tag_names :: proc(text: string) -> (names: string, is_vet: bool) {
	assert(len(text) > 0, "a file tag with no text is a parser defect")

	if !strings.has_prefix(text, VET_TAG) {
		return "", false
	}
	names = text[len(VET_TAG):]
	if len(names) == 0 {
		return names, true
	}
	if names[0] == ' ' {
		return names, true
	}
	if names[0] == '\t' {
		return names, true
	}
	return "", false
}
