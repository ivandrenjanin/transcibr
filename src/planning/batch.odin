package planning

import "core:mem"
import "core:slice"
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
@(private)
collided :: proc(
	inventory: []Found,
	allocator: mem.Allocator,
) -> (
	collision: Collision,
	yes: bool,
) {
	assert(allocator.procedure != nil, "the names outlive this procedure and need an allocator")
	defer assert(!yes || collision.left < collision.right, "a pair named in the wrong order")

	keys := artifact_keys(inventory, allocator)
	defer destroy_keys(keys, allocator)
	assert(
		len(keys) == len(inventory),
		"a Batch was keyed with more or fewer names than Recordings",
	)

	order := named_first(keys, allocator)
	defer delete(order, allocator)

	for at in 1 ..< len(order) {
		previous, current := order[at - 1], order[at]
		if len(keys[current]) == 0 || keys[previous] != keys[current] {
			continue
		}
		return paired(inventory, min(previous, current), max(previous, current), allocator), true
	}
	return {}, false
}

@(private)
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

// A Recording whose path names no file has an EMPTY key and never collides: it
// is refused on its own account, and two of them are not a pair (ADR-0008).
@(private)
artifact_keys :: proc(inventory: []Found, allocator: mem.Allocator) -> (keys: []string) {
	assert(allocator.procedure != nil, "the keys outlive this procedure and need an allocator")
	defer assert(len(keys) == len(inventory), "a Recording was keyed twice or not at all")

	keys = make([]string, len(inventory), allocator)
	for found, at in inventory {
		names, namable := artifact.names_of(found.source, allocator)
		defer artifact.destroy_names(names, allocator)
		if !namable {
			keys[at] = ""
			continue
		}
		keys[at] = strings.to_lower(names[.Transcript], allocator)
	}
	return keys
}

@(private)
destroy_keys :: proc(keys: []string, allocator: mem.Allocator) {
	assert(allocator.procedure != nil, "the keys are freed with the allocator that built them")

	for key in keys {
		delete(key, allocator)
	}
	delete(keys, allocator)
}

// Indices into `keys`, sorted so that equal keys stand next to each other. The
// index breaks a tie, so the pair a Batch is refused for is the same pair every
// time it is planned.
@(private)
named_first :: proc(keys: []string, allocator: mem.Allocator) -> (order: []int) {
	assert(allocator.procedure != nil, "the order outlives this procedure and needs an allocator")
	defer assert(len(order) == len(keys), "an order that names more or fewer keys than there are")

	order = make([]int, len(keys), allocator)
	for &index, at in order {
		index = at
	}

	sorted := keys
	slice.sort_by_with_data(order, proc(left: int, right: int, keys: rawptr) -> bool {
			named := (^[]string)(keys)^
			if named[left] != named[right] {
				return named[left] < named[right]
			}
			return left < right
		}, &sorted)
	return order
}
