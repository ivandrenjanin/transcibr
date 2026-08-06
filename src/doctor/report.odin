#+vet explicit-allocators
package doctor

// Every check in this package answers pass or fail with a reason a user can
// act on (the ticket's own acceptance line) -- one rendered message shape,
// shared by every Fault vocabulary here rather than respelled per file.

import "core:fmt"
import "core:mem"

// The renderer's answer when a Fault vocabulary's own lookup comes back
// empty -- report.odin's caller (combined_message) and health.odin's own
// (health_error_message, whose numbers-only shape cannot route through
// combined_message) both fall back to this instead of asserting on a gap in
// a switch, per #137/#139: an assert here fires on the first report of a
// fault that is already failing in front of somebody. Pinned by
// report_test.odin so emptying it cannot leave every caller's tests green.
NO_SENTENCE_FALLBACK :: "failed, but this build has no sentence for why"

@(require_results)
combined_message :: proc(
	subject: string,
	says: string,
	reason: string,
	allocator: mem.Allocator,
) -> string {
	assert(len(subject) > 0, "a refusal must name what it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	sentence := says
	if len(sentence) == 0 {
		sentence = NO_SENTENCE_FALLBACK
	}

	message: string
	if len(reason) > 0 {
		message = fmt.aprintf("%q: %s (%s)", subject, sentence, reason, allocator = allocator)
	} else {
		message = fmt.aprintf("%q: %s", subject, sentence, allocator = allocator)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}

// One line of a doctor Report: what was checked, whether it passed, and an
// actionable reason when it did not -- owned, and freed with delete and the
// allocator handed in whichever way the check ended, so a passing check that
// allocated no reason frees an empty string safely. `advisory` marks a check
// that is printed like any other but never turns `report_ok` false on its
// own (ADR-0011: GPU enumeration is diagnostic only, never the verdict).
// `skip` marks a check that never ran because an earlier one made its answer
// meaningless; it did not pass, so `ok` is false, and it did not fail either,
// so it never turns `report_ok` false -- whatever stopped it from running is
// already a failure of its own further up the report.
Check :: struct {
	name:     string,
	ok:       bool,
	reason:   string,
	advisory: bool,
	skip:     bool,
}

@(require_results)
passed :: proc(name: string, advisory := false) -> Check {
	assert(len(name) > 0, "a check with no name reports nothing a user can act on")
	return Check{name = name, ok = true, advisory = advisory}
}

@(require_results)
failed :: proc(name: string, reason: string, advisory := false) -> Check {
	assert(len(name) > 0, "a check with no name reports nothing a user can act on")
	assert(len(reason) > 0, "a failed check with no reason gives a user nothing to act on")
	return Check{name = name, ok = false, reason = reason, advisory = advisory}
}

@(require_results)
skipped :: proc(name: string, reason: string) -> Check {
	assert(len(name) > 0, "a check with no name reports nothing a user can act on")
	assert(len(reason) > 0, "a skipped check with no reason gives a user nothing to act on")
	return Check{name = name, ok = false, reason = reason, skip = true}
}

destroy_check :: proc(check: Check, allocator: mem.Allocator) {
	delete(check.reason, allocator)
}

// Every check this Batch's doctor ran, front to back -- `passed` and `failed`
// are the only two Check constructors, so a Report can never hold a Check
// answering neither. An advisory or skipped check is printed like any other
// but never turns this false on its own.
@(require_results)
report_ok :: proc(checks: []Check) -> bool {
	for check in checks {
		if check.advisory || check.skip {
			continue
		}
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
	if check.skip {
		return fmt.aprintf("SKIP  %s: %s", check.name, check.reason, allocator = allocator)
	}
	if check.advisory {
		return fmt.aprintf("INFO  %s: %s", check.name, check.reason, allocator = allocator)
	}
	return fmt.aprintf("FAIL  %s: %s", check.name, check.reason, allocator = allocator)
}
