package audio

import "core:mem"
import "core:slice"

// This file holds one decision, and it is the one in this package that DELETES
// FILES: which of the scratch cache's contents a sweep at Batch start may take.
//
// The spec asks for a size and an age ceiling, because a run that fails every
// Recording must not accumulate audio indefinitely. Ceilings alone are not
// enough to make a delete safe, though, and the reason is ADR-0002: the cache is
// not a spoil heap but the working directory of anything currently running --
// an extraction's `.part` and the Engine's output are both written there while
// they are being written. A ceiling that took the oldest file until the total
// fitted would, on a machine with a second transcibr window open, take the audio
// another worker was at that moment writing.
//
// So there are three numbers and not two, and the third is a FLOOR: nothing
// younger than it is taken, whatever either ceiling says. It is what makes the
// answer safe rather than merely bounded.
//
// It is not the only thing standing between a running worker and a delete. The
// sweep that acts on this answer is best-effort by construction -- Windows
// refuses to delete a file another process holds open without sharing delete
// permission, and that refusal is logged and stepped over rather than failing
// the Batch. The floor is the part that does not depend on the other process
// having opened the file in any particular way.

// One file in the scratch cache, as the sweep sees it.
//
// The name is BORROWED and never owned: it is the caller's own listing, and the
// caller is what deletes the file afterwards. Nothing here reads the file, or
// the clock, or the filesystem -- an age is handed in, which is what makes this
// decision checkable at ages no clock will produce on request.
Cache_Entry :: struct {
	name:   string,
	bytes:  i64,
	age_ns: i64,
}

// The ceilings a sweep works to, and the floor it will not go under.
Sweep_Limits :: struct {
	// How large the cache may be in total before its oldest contents go.
	max_bytes:    i64,
	// How old anything in it may be, whatever the total is.
	max_age_ns:   i64,
	// And what nothing younger than may be taken, whatever either ceiling
	// says. See the file comment: this is the whole difference between a
	// bounded cache and a sweep that destroys the run it is starting.
	spare_age_ns: i64,
}

// What a Batch sweeps to unless it is told otherwise. sweep_test.odin pins all
// three; the reasoning is there beside the numbers.
DEFAULT_SWEEP_LIMITS :: Sweep_Limits {
	// A little over two of the reference corpus's whole Batches: 75 hours of
	// mono 16 kHz signed 16-bit PCM at 32,000 bytes a second is 8.6 GB.
	max_bytes    = 20 * 1024 * 1024 * 1024,
	// Long enough that a Batch interrupted over a weekend resumes against its
	// own extracted audio rather than extracting it all again.
	max_age_ns   = i64(7 * 24 * 60 * 60) * 1_000_000_000,
	// An extraction of the corpus's longest Recording takes minutes, and the
	// Engine writes its output at the end of one transcription -- so a cache
	// file something is still using is minutes old at the very most, and an
	// hour is an order of magnitude of headroom over that.
	spare_age_ns = i64(60 * 60) * 1_000_000_000,
}

// The one relationship between the three that has to hold, held by the COMPILER
// (A5). sweep_choice asserts it of whatever limits it is handed; this asserts it
// of the shipped ones, at the definition, before a test runs.
#assert(DEFAULT_SWEEP_LIMITS.spare_age_ns < DEFAULT_SWEEP_LIMITS.max_age_ns)

// Which of the cache's contents the sweep may take, as indices into `entries`,
// ascending.
//
// Indices rather than names, because the caller already holds the listing and a
// second copy of a path is a second thing that can be wrong about which file is
// about to be deleted.
//
// The caller owns the returned slice and frees it with `delete` and the same
// allocator. The names inside `entries` are untouched.
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
		// THE FLOOR, checked before either ceiling and never after. Both
		// ceilings below are reasons to delete; this is the one rule that says
		// no, and a rule that only applies where nothing else already decided
		// is not a floor at all.
		if entry.age_ns < limits.spare_age_ns {
			continue
		}
		if entry.age_ns > limits.max_age_ns || total > limits.max_bytes {
			append(&chosen, index)
			total -= entry.bytes
		}
	}

	// Ascending, so the answer does not depend on the order the ceilings
	// happened to reach the entries in -- the caller deletes them, and a
	// deletion order nobody chose is a deletion order nobody can reproduce.
	slice.sort(chosen[:])
	// Shrunk to what was actually chosen, so the slice handed back is the whole
	// of its own allocation. `delete` frees `len` items, and this was made at
	// `cap` -- harmless under Odin's heap allocator, and wrong the day ADR-0010
	// gives a worker a size-classed allocator of its own.
	shrink(&chosen)
	return chosen[:]
}

// The entries, oldest first, as indices into the caller's own listing.
//
// Indices and not a second array of ages: `slice.sort_by_with_data` takes the
// `user_data: rawptr` that lets a captureless comparator reach the entries it is
// ordering, so nothing has to be copied out beside the index to be compared.
//
// `slice.sort_by_with_indices` looks like the exact fit and is not: it finishes
// by calling `sort_from_permutation_indices` on the data, which reorders the
// caller's own listing -- and the answer here is indices INTO that listing, so
// every one of them would then name a different file.
@(private)
oldest_first :: proc(entries: []Cache_Entry, allocator: mem.Allocator) -> []int {
	assert(allocator.procedure != nil, "the order outlives this procedure and needs an allocator")

	order := make([]int, len(entries), allocator)
	for &index, at in order {
		index = at
	}

	// A local, because the comparator needs its address and a parameter is
	// immutable.
	listing := entries
	slice.sort_by_with_data(
		order,
		proc(left: int, right: int, listing: rawptr) -> bool {
			entries := (^[]Cache_Entry)(listing)^
			if entries[left].age_ns != entries[right].age_ns {
				return entries[left].age_ns > entries[right].age_ns
			}
			// The tie broken by position, so two files of the same age are always
			// taken in the same order. The sort is not stable, and a sweep whose
			// answer depends on where it happened to leave a tie is one nobody can
			// reproduce.
			return left < right
		},
		&listing,
	)
	return order
}
