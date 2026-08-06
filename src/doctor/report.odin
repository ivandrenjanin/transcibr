#+vet explicit-allocators
package doctor

// Every check in this package answers pass or fail with a reason a user can
// act on (the ticket's own acceptance line) -- one rendered message shape,
// shared by every Fault vocabulary here rather than respelled per file.

import "core:fmt"
import "core:mem"

@(require_results)
combined_message :: proc(
	subject: string,
	says: string,
	reason: string,
	allocator: mem.Allocator,
) -> string {
	assert(len(subject) > 0, "a refusal must name what it is reported against")
	assert(len(says) > 0, "a refusal said nothing at all")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	message: string
	if len(reason) > 0 {
		message = fmt.aprintf("%q: %s (%s)", subject, says, reason, allocator = allocator)
	} else {
		message = fmt.aprintf("%q: %s", subject, says, allocator = allocator)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}

// One line of a doctor Report: what was checked, whether it passed, and an
// actionable reason when it did not -- owned, and freed with delete and the
// allocator handed in whichever way the check ended, so a passing check that
// allocated no reason frees an empty string safely.
Check :: struct {
	name:   string,
	ok:     bool,
	reason: string,
}

@(require_results)
passed :: proc(name: string) -> Check {
	assert(len(name) > 0, "a check with no name reports nothing a user can act on")
	return Check{name = name, ok = true}
}

@(require_results)
failed :: proc(name: string, reason: string) -> Check {
	assert(len(name) > 0, "a check with no name reports nothing a user can act on")
	assert(len(reason) > 0, "a failed check with no reason gives a user nothing to act on")
	return Check{name = name, ok = false, reason = reason}
}

destroy_check :: proc(check: Check, allocator: mem.Allocator) {
	delete(check.reason, allocator)
}

// Every check this Batch's doctor ran, front to back -- `passed` and `failed`
// are the only two Check constructors, so a Report can never hold a Check
// answering neither.
@(require_results)
report_ok :: proc(checks: []Check) -> bool {
	for check in checks {
		if !check.ok {
			return false
		}
	}
	return true
}

destroy_report :: proc(checks: []Check, allocator: mem.Allocator) {
	for check in checks {
		destroy_check(check, allocator)
	}
	delete(checks, allocator)
}

@(require_results)
render_check :: proc(check: Check, allocator: mem.Allocator) -> string {
	assert(len(check.name) > 0, "a check with no name reports nothing a user can act on")
	assert(allocator.procedure != nil, "the line outlives this procedure and needs an allocator")
	if !check.ok {
		assert(
			len(check.reason) > 0,
			"a failed check with no reason gives a user nothing to act on",
		)
	}

	if check.ok {
		return fmt.aprintf("PASS  %s", check.name, allocator = allocator)
	}
	return fmt.aprintf("FAIL  %s: %s", check.name, check.reason, allocator = allocator)
}
