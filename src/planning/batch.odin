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
	// The artifact both Recordings would write. Owned by the Plan.
	name:  string,
}

Plan :: struct {
	entries:   []Entry,
	collision: Maybe(Collision),
}

// The entries come back whichever way this ends, so a dry run still reports what
// it found; `ok` is false when the Batch must not run. Free with destroy_plan
// and the same allocator.
plan_batch :: proc(
	inventory: []Found,
	settings: Settings,
	allocator: mem.Allocator,
) -> (
	plan: Plan,
	ok: bool,
) {
	assert(allocator.procedure != nil, "the plan outlives this procedure and needs an allocator")
	assert(len(settings.merge_profile) > 0, "a Batch naming no Merge Profile decides nothing")
	defer assert(
		len(plan.entries) == len(inventory),
		"a Batch was planned with more or fewer Recordings than it was given",
	)

	entries := make([]Entry, len(inventory), allocator)
	for found, at in inventory {
		entries[at] = Entry {
			found   = found,
			outcome = decide(found, settings),
		}
	}
	plan.entries = entries

	collision, raced := collided(inventory, allocator)
	if raced {
		plan.collision = collision
		return plan, false
	}
	return plan, true
}

destroy_plan :: proc(plan: Plan, allocator: mem.Allocator) {
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

	order := named_first(keys, allocator)
	defer delete(order, allocator)

	for at in 1 ..< len(order) {
		previous, current := order[at - 1], order[at]
		if len(keys[current]) == 0 || keys[previous] != keys[current] {
			continue
		}
		return Collision {
				left = min(previous, current),
				right = max(previous, current),
				name = strings.clone(keys[current], allocator),
			},
			true
	}
	return {}, false
}

// A Recording whose path names no file has an EMPTY key and never collides: it
// is refused on its own account, and two of them are not a pair (ADR-0008).
@(private)
artifact_keys :: proc(inventory: []Found, allocator: mem.Allocator) -> []string {
	assert(allocator.procedure != nil, "the keys outlive this procedure and need an allocator")

	keys := make([]string, len(inventory), allocator)
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
	for key in keys {
		delete(key, allocator)
	}
	delete(keys, allocator)
}

// Indices into `keys`, sorted so that equal keys stand next to each other. The
// index breaks a tie, so the pair a Batch is refused for is the same pair every
// time it is planned.
@(private)
named_first :: proc(keys: []string, allocator: mem.Allocator) -> []int {
	assert(allocator.procedure != nil, "the order outlives this procedure and needs an allocator")

	order := make([]int, len(keys), allocator)
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
