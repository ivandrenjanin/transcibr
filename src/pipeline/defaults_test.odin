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
