#+vet explicit-allocators
package pipeline

// The orderings issue #74 asks to be held by a test rather than by a comment
// alone: `DEFAULT_JOIN_BOUND_MS` sits above any real transcribe bound and
// below what `child.await_or_abandon` will accept at all. `bound_expressible`
// is `child`'s own private guard against `WaitForSingleObject`'s INFINITE
// sentinel (issue #27); this test holds the same DWORD ceiling without
// reaching across the package boundary for a private procedure.

import win32 "core:sys/windows"
import "core:testing"
import "transcibr:process"

// One full day of audio -- far beyond what a real Batch transcribes in one
// Recording, and still nowhere near `process.LONGEST_CONTAINER_MS`.
@(private)
A_LONG_REAL_RECORDING_MS :: i64(24 * 60 * 60 * 1000)

@(test)
the_join_bound_default_outlasts_a_real_transcribe_bound_and_stays_inside_what_child_will_accept :: proc(
	t: ^testing.T,
) {
	real_bound := process.transcribe_bound_ms(A_LONG_REAL_RECORDING_MS)
	testing.expectf(
		t,
		DEFAULT_JOIN_BOUND_MS > real_bound,
		"the join bound %d does not outlast a full day of audio's own transcribe bound %d",
		DEFAULT_JOIN_BOUND_MS,
		real_bound,
	)

	ceiling := i64(max(win32.DWORD))
	testing.expectf(
		t,
		DEFAULT_JOIN_BOUND_MS < ceiling,
		"the join bound %d does not fit under what WaitForSingleObject can express (%d)",
		DEFAULT_JOIN_BOUND_MS,
		ceiling,
	)

	margin := ceiling - DEFAULT_JOIN_BOUND_MS
	testing.expectf(
		t,
		margin > ceiling / 20,
		"the join bound %d sits only %d below the ceiling, thinner than the 5%% this test holds",
		DEFAULT_JOIN_BOUND_MS,
		margin,
	)
}

// Issue #94, fix round 1: `worker_count_within_ceiling` alone (relocated to
// `transcibr:process` with ADR-0038's batch migration, #75; its own test now
// lives at `src/process/worker_ceiling_test.odin`) proves that expression is
// that expression -- it says nothing about WHICH ceiling an option name
// resolves to, which is what the original defect was actually about.
// `WORKER_OPTION_CEILINGS` still holds that pairing, and `worker_option_-`
// `ceiling` still looks a name up in it here, so a mispairing in THIS table
// can only live here -- where this test walks it.
//
// Issue #192: the two `== MAX_EXTRACT_WORKERS` / `== MAX_QUEUE_DEPTH` value
// comparisons below are unfirable on their own -- both constants are 2 today,
// so an entry-swap mutation that hands `--extract-workers` the queue depth's
// ceiling and vice versa produces the exact same two integers and neither
// comparison can tell the difference. The value checks stay, because they
// are still correct and will start pulling their weight the day the two
// constants diverge, but they are not what this test leans on to catch a
// swap. The two `WORKER_OPTION_CEILINGS[i].name` checks below are: they pin
// each entry's NAME to its expected array position, and two distinct option
// strings are never equal to each other regardless of what their ceilings
// happen to be, so a swap of the table's two entries flips a name comparison
// even while the ceilings stay numerically indistinguishable.
//
// ADR-0038's batch migration (#75) landed the structural close this comment
// used to point ahead to: `src/cliargs` now dispatches `--extract-workers`
// and `--queue-depth` through its own enum-keyed `Worker_Ceilings`
// (`[Worker_Option]int`), built as a package-level constant in
// `src/cli/batch.odin` directly from `MAX_EXTRACT_WORKERS`/
// `MAX_QUEUE_DEPTH` -- a composite literal the compiler refuses to build
// incomplete, which is what actually makes a swapped or missing pairing
// unbuildable for the grammar's own dispatch. `WORKER_OPTION_CEILINGS` and
// `worker_option_ceiling` are no longer called from `src/cli` after this
// migration; they stay, tested, as `pipeline`'s own record of the pairing --
// this test's name-position pins are what still catch a swap of THIS table,
// which the structural close in `cliargs` does not reach.
@(test)
worker_option_ceilings_pair_each_option_with_its_own_max :: proc(t: ^testing.T) {
	testing.expectf(
		t,
		len(WORKER_OPTION_CEILINGS) == 2,
		"WORKER_OPTION_CEILINGS holds %d entries, not the two ADR-0006 names",
		len(WORKER_OPTION_CEILINGS),
	)
	testing.expectf(
		t,
		WORKER_OPTION_CEILINGS[0].name == "--extract-workers",
		"WORKER_OPTION_CEILINGS[0] is named %q, not --extract-workers -- an entry swap",
		WORKER_OPTION_CEILINGS[0].name,
	)
	testing.expectf(
		t,
		WORKER_OPTION_CEILINGS[1].name == "--queue-depth",
		"WORKER_OPTION_CEILINGS[1] is named %q, not --queue-depth -- an entry swap",
		WORKER_OPTION_CEILINGS[1].name,
	)

	extract_ceiling, extract_found := worker_option_ceiling("--extract-workers")
	testing.expect(t, extract_found, "--extract-workers has no ceiling registered")
	testing.expectf(
		t,
		extract_ceiling == MAX_EXTRACT_WORKERS,
		"--extract-workers is paired with ceiling %d, not MAX_EXTRACT_WORKERS (%d)",
		extract_ceiling,
		MAX_EXTRACT_WORKERS,
	)

	queue_ceiling, queue_found := worker_option_ceiling("--queue-depth")
	testing.expect(t, queue_found, "--queue-depth has no ceiling registered")
	testing.expectf(
		t,
		queue_ceiling == MAX_QUEUE_DEPTH,
		"--queue-depth is paired with ceiling %d, not MAX_QUEUE_DEPTH (%d)",
		queue_ceiling,
		MAX_QUEUE_DEPTH,
	)

	_, unknown_found := worker_option_ceiling("--not-a-real-option")
	testing.expect(t, !unknown_found, "an unregistered option name found a ceiling anyway")
}
