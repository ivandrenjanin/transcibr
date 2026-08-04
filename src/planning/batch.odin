#+vet explicit-allocators
package planning

import "core:mem"
import "core:strings"
import "transcibr:artifact"

// The whole Batch: every Recording decided, and the one property no single
// Recording can answer about itself.

Entry :: struct {
	// Borrowed from the inventory handed in, which outlives the plan.
	found:   Found,
	outcome: Outcome,
}

// The pair ADR-0008 asks the plan to name, as indices into the inventory in the
// order it was given, `left` always the earlier of the two.
Collision :: struct {
	left:  int,
	right: int,
	// The artifact both Recordings would write, spelled as it would ACTUALLY be
	// written: the folded key is what the comparison runs on, and reporting that
	// would show a user a path their directory is not called. Owned by the Plan.
	name:  string,
}

Plan :: struct {
	entries:   []Entry,
	collision: Maybe(Collision),
}

// The entries come back whichever way this ends, so a dry run still reports what
// it found; `ok` is false when the Batch must not run. Free with destroy_plan
// and the same allocator.
//
// The whole INVENTORY and never its `found` alone. A plan handed the slice
// cannot see that the walk was cancelled or left a directory unread, so the one
// thing that stops a Batch running over a short file list would live entirely in
// caller discipline -- and the only caller that asks is `src/cli`, the package
// nothing can turn red (ADR-0009).
@(require_results)
plan_batch :: proc(
	inventory: Inventory,
	settings: Settings,
	allocator: mem.Allocator,
) -> (
	plan: Plan,
	ok: bool,
) {
	assert(allocator.procedure != nil, "the plan outlives this procedure and needs an allocator")
	assert(len(settings.merge_profile) > 0, "a Batch naming no Merge Profile decides nothing")
	defer assert(
		len(plan.entries) == len(inventory.found),
		"a Batch was planned with more or fewer Recordings than it was given",
	)

	entries := make([]Entry, len(inventory.found), allocator)
	for found, at in inventory.found {
		entries[at] = Entry {
			found   = found,
			outcome = decide(found, settings),
		}
	}
	plan.entries = entries

	collision, raced := collided(inventory.found, allocator)
	if raced {
		plan.collision = collision
		return plan, false
	}
	if _, incomplete := left_unlooked_at(inventory); incomplete {
		return plan, false
	}
	return plan, true
}

destroy_plan :: proc(plan: Plan, allocator: mem.Allocator) {
	assert(allocator.procedure != nil, "a plan is freed with the allocator that built it")

	if collision, named := plan.collision.?; named {
		delete(collision.name, allocator)
	}
	delete(plan.entries, allocator)
}

// Folded, because NTFS is case-insensitive by default: `INTERVIEW.md` and
// `interview.md` are one file, and a plan that told them apart would hand two
// Recordings one output path on the filesystem this program runs on.
//
// A map from the folded name to the FIRST Recording that claimed it, walked in
// the inventory's own order. The pair a Batch is refused for is therefore the
// same pair every time it is planned, and `left < right` holds by construction
// rather than by a comparator that had to break a tie to make it so.
@(private)
@(require_results)
collided :: proc(
	inventory: []Found,
	allocator: mem.Allocator,
) -> (
	collision: Collision,
	yes: bool,
) {
	assert(allocator.procedure != nil, "the names outlive this procedure and need an allocator")
	defer if yes {
		assert(collision.left < collision.right, "a pair named in the wrong order")
	}

	claimed := make(map[string]int, len(inventory), allocator)
	defer {
		for key in claimed {
			delete(key, allocator)
		}
		delete(claimed)
	}

	for found, at in inventory {
		key, namable := artifact_key(found.source, allocator)
		if !namable {
			continue
		}
		if first, taken := claimed[key]; taken {
			delete(key, allocator)
			return paired(inventory, first, at, allocator), true
		}
		claimed[key] = at
	}
	return {}, false
}

@(private)
@(require_results)
paired :: proc(
	inventory: []Found,
	left, right: int,
	allocator: mem.Allocator,
) -> (
	collision: Collision,
) {
	assert(left < right, "a pair named in the wrong order")
	defer assert(len(collision.name) > 0, "a pair that would share an artifact nobody named")

	names, namable := artifact.names_of(inventory[left].source, allocator)
	defer artifact.destroy_names(names, allocator)
	assert(namable, "a Recording that named no file was paired with one that did")

	return Collision {
		left = left,
		right = right,
		name = strings.clone(names[.Transcript], allocator),
	}
}

// A Recording whose path names no file has NO key and never collides: it is
// refused on its own account, and two of them are not a pair (ADR-0008). The
// answer is owned; free it with `delete` and the same allocator.
@(private)
@(require_results)
artifact_key :: proc(source: string, allocator: mem.Allocator) -> (key: string, namable: bool) {
	assert(len(source) > 0, "there is no Recording here to name an artifact for")
	assert(allocator.procedure != nil, "the key outlives this procedure and needs an allocator")

	names, named := artifact.names_of(source, allocator)
	defer artifact.destroy_names(names, allocator)
	if !named {
		return "", false
	}
	return strings.to_lower(names[.Transcript], allocator), true
}
