package audio

import "core:mem"
import "core:slice"

// Which of the scratch cache's contents a sweep at Batch start may take. Why
// there is a floor under the two ceilings: ADR-0023.

// The name is borrowed from the caller's listing and never owned.
Cache_Entry :: struct {
	name:   string,
	bytes:  i64,
	age_ns: i64,
}

Sweep_Limits :: struct {
	max_bytes:    i64,
	max_age_ns:   i64,
	spare_age_ns: i64,
}

// Where these three numbers come from: ADR-0023.
DEFAULT_SWEEP_LIMITS :: Sweep_Limits {
	max_bytes    = 20 * 1024 * 1024 * 1024,
	max_age_ns   = i64(7 * 24 * 60 * 60) * 1_000_000_000,
	spare_age_ns = i64(60 * 60) * 1_000_000_000,
}

#assert(DEFAULT_SWEEP_LIMITS.spare_age_ns < DEFAULT_SWEEP_LIMITS.max_age_ns)

// Indices into `entries`, ascending. The caller owns the returned slice and
// frees it with `delete` and the same allocator; the names inside `entries` are
// untouched.
sweep_choice :: proc(
	entries: []Cache_Entry,
	limits: Sweep_Limits,
	allocator: mem.Allocator,
) -> (
	taken: []int,
) {
	assert(limits.max_bytes >= 0, "a cache cannot be allowed a negative number of bytes")
	assert(limits.spare_age_ns >= 0, "a floor cannot protect files of a negative age")
	assert(
		limits.spare_age_ns < limits.max_age_ns,
		"a floor above the age ceiling makes the age ceiling unreachable",
	)
	assert(allocator.procedure != nil, "the answer outlives this procedure and needs an allocator")

	order := oldest_first(entries, allocator)
	defer delete(order, allocator)

	total := i64(0)
	for e in entries {
		total += e.bytes
	}

	chosen := make([dynamic]int, 0, len(entries), allocator)
	for index in order {
		entry := entries[index]
		if entry.age_ns < limits.spare_age_ns {
			continue
		}
		if entry.age_ns > limits.max_age_ns || total > limits.max_bytes {
			append(&chosen, index)
			total -= entry.bytes
		}
	}

	slice.sort(chosen[:])
	shrink(&chosen)
	return chosen[:]
}

// `slice.sort_by_with_indices` looks like the exact fit and is not: it finishes
// by reordering the caller's own listing, and the answer here is indices into
// that listing.
@(private)
oldest_first :: proc(entries: []Cache_Entry, allocator: mem.Allocator) -> []int {
	assert(allocator.procedure != nil, "the order outlives this procedure and needs an allocator")

	order := make([]int, len(entries), allocator)
	for &index, at in order {
		index = at
	}

	listing := entries
	slice.sort_by_with_data(order, proc(left: int, right: int, listing: rawptr) -> bool {
			entries := (^[]Cache_Entry)(listing)^
			if entries[left].age_ns != entries[right].age_ns {
				return entries[left].age_ns > entries[right].age_ns
			}
			return left < right
		}, &listing)
	return order
}
