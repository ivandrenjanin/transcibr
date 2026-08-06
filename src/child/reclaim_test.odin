#+vet explicit-allocators
package child

import "core:testing"
import "core:thread"

// `reclaim_for` is the exhaustive `child.Wait` -> (finished, reclaim) map
// every one-shot and worker-based bounded-call site used to spell as its own
// three-case switch (issue #66, findings 7 and 8). Exhaustive over `Wait`
// itself rather than over a caller's own vocabulary -- `transcript_state_of`
// in `transcibr:planning`'s `walk.odin` is the template -- so a member added
// to `Wait` fails the build here rather than silently falling through.
@(test)
reclaim_for_matches_the_documented_contract_for_every_wait_outcome :: proc(t: ^testing.T) {
	finished, reclaim := reclaim_for(.Finished)
	testing.expect(t, finished, "a finished wait was not reported finished")
	testing.expect(t, reclaim, "a finished thread was not reported safe to reclaim")

	finished, reclaim = reclaim_for(.Stopped)
	testing.expect(
		t,
		!finished,
		"a stopped wait was reported finished, but it never ran to completion",
	)
	testing.expect(t, reclaim, "a stopped thread, known idle, was not reported safe to reclaim")

	finished, reclaim = reclaim_for(.Unstoppable)
	testing.expect(t, !finished, "an unstoppable wait was reported finished")
	testing.expect(
		t,
		!reclaim,
		"an unstoppable thread -- possibly still writing into what it was given -- was reported safe to reclaim",
	)
}

@(private)
Reclaim_Instant_Job :: struct {
	done: bool,
}

@(private)
reclaim_instant_worker :: proc(data: rawptr) {
	job := (^Reclaim_Instant_Job)(data)
	assert(job != nil, "a reclaim test thread was started with no job to run")
	job.done = true
}

// Confirms `await_and_reclaim` actually calls through to `await_or_abandon`
// rather than merely existing beside it -- the wiring `reclaim_for`'s own
// pure-function test above cannot exercise.
@(test)
await_and_reclaim_joins_a_thread_that_finished_on_its_own :: proc(t: ^testing.T) {
	job: Reclaim_Instant_Job
	th := thread.create_and_start_with_data(&job, reclaim_instant_worker)
	if !testing.expect(t, th != nil, "a thread this case needed to start would not start") {
		return
	}

	finished, reclaim := await_and_reclaim(th, READ_TEST_RUN_BOUND_MS)
	testing.expect(t, finished, "a thread that ran to completion was not reported finished")
	testing.expect(t, reclaim, "a thread that ran to completion was not reported safe to reclaim")
	testing.expect(t, job.done, "a thread reported finished had not actually run its worker")

	if reclaim {
		thread.destroy(th)
	}
}
