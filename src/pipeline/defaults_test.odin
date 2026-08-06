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

// Issue #94: `read_worker_count` (src/cli/batch.odin) used to refuse both
// `--extract-workers` and `--queue-depth` against `MAX_QUEUE_DEPTH` alone, so
// a future drop in `MAX_EXTRACT_WORKERS` below `MAX_QUEUE_DEPTH` would have
// let an over-ceiling `--extract-workers` value sail past the refusal and
// crash at `run_recordings`'s own assert instead. `worker_count_within_-`
// `ceiling` is what both the CLI refusal and this test now call, so the two
// can never drift back apart -- ADR-0009 keeps `src/cli` test-less, so this
// is where that pairing is held. Walking both ceilings independently, rather
// than only today's shared value of 2, is what proves the check is keyed to
// whichever ceiling is passed in and not to the other option's.
@(test)
worker_count_within_ceiling_checks_its_own_ceiling_and_not_the_others :: proc(t: ^testing.T) {
	for ceiling in ([]int{MAX_EXTRACT_WORKERS, MAX_QUEUE_DEPTH, 1, 5}) {
		testing.expectf(
			t,
			!worker_count_within_ceiling(0, ceiling),
			"zero workers passed against ceiling %d",
			ceiling,
		)
		for count in 1 ..= ceiling {
			testing.expectf(
				t,
				worker_count_within_ceiling(count, ceiling),
				"%d workers refused against a ceiling of %d",
				count,
				ceiling,
			)
		}
		testing.expectf(
			t,
			!worker_count_within_ceiling(ceiling + 1, ceiling),
			"%d workers passed against a ceiling of %d",
			ceiling + 1,
			ceiling,
		)
	}

	testing.expectf(
		t,
		worker_count_within_ceiling(MAX_EXTRACT_WORKERS, MAX_EXTRACT_WORKERS),
		"MAX_EXTRACT_WORKERS itself was refused against its own ceiling",
	)
	testing.expectf(
		t,
		worker_count_within_ceiling(MAX_QUEUE_DEPTH, MAX_QUEUE_DEPTH),
		"MAX_QUEUE_DEPTH itself was refused against its own ceiling",
	)
}

// Issue #94, fix round 1: `worker_count_within_ceiling` alone proves that
// expression is that expression -- it says nothing about WHICH ceiling
// `src/cli/batch.odin` hands each option, which is what the original defect
// was actually about. `WORKER_OPTION_CEILINGS` now holds that pairing, and
// `read_batch_option` looks an option's ceiling up in it by name instead of
// naming `MAX_EXTRACT_WORKERS`/`MAX_QUEUE_DEPTH` at the call site, so a
// mispairing can only live in the table -- where this test walks it.
@(test)
worker_option_ceilings_pair_each_option_with_its_own_max :: proc(t: ^testing.T) {
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

// Issue #111, fix round 4: `claim_health_watch` guards Batch reentrancy, a
// different invariant from `bump`'s ADR-0006 one-transcription-Worker assert
// (see the doc comment above `health_watch_claimed` in pipeline.odin, which
// names this test as this procedure's own cover, not `bump`'s). `src/cli` --
// `claim_health_watch`'s one caller -- is kept test-less by ADR-0009, so this
// is where the happy path is driven for real: each claim/release round checks
// the package-private `health_watch_claimed` flag directly, so a gutted
// `claim_health_watch` that never sets it, or a `release_health_watch` that
// never clears it, fails this test rather than passing for the wrong reason.
// This does not drive the refusal branch, which issue #22 keeps out of any
// test.
@(test)
claim_health_watch_can_be_claimed_again_once_released :: proc(t: ^testing.T) {
	claim_health_watch()
	testing.expect(t, health_watch_claimed, "claim_health_watch did not set the claim")
	release_health_watch()
	testing.expect(t, !health_watch_claimed, "release_health_watch did not clear the claim")

	claim_health_watch()
	testing.expect(
		t,
		health_watch_claimed,
		"claim_health_watch did not set the claim a second time",
	)
	release_health_watch()
	testing.expect(
		t,
		!health_watch_claimed,
		"release_health_watch did not clear the claim a second time",
	)
}
