#+vet explicit-allocators
package child

import "base:runtime"
import "core:os"
import win32 "core:sys/windows"
import "core:testing"

@(private)
Increment_Job :: struct {
	value: int,
}

@(private)
increment_worker :: proc(data: rawptr) {
	job := (^Increment_Job)(data)
	assert(job != nil, "an increment job ran with no job to increment")
	job.value += 1
}

@(test)
a_worker_runs_a_job_and_stays_reusable_afterward :: proc(t: ^testing.T) {
	w := spawn_worker()
	if !testing.expect(t, w != nil, "a worker this case needed to start would not start") {
		return
	}
	defer release_worker(w)

	job: Increment_Job
	wait := run_on_worker(w, increment_worker, &job, READ_TEST_RUN_BOUND_MS)

	testing.expect_value(t, wait, Wait.Finished)
	testing.expect_value(t, job.value, 1)
}

// The whole of finding 3's claim: one worker, run repeatedly, is one OS
// thread rather than one per job. Run enough jobs through the public
// `run_on_worker` seam that "a fresh thread every job" and "one thread
// reused" cannot read the same under sibling noise, the identical reasoning
// `abandoning_a_read_repeatedly_does_not_accumulate_threads_when_the_thread_probe_succeeds`
// already uses
// for the same instrument (`CreateToolhelp32Snapshot`) against this
// package's own concurrent sweep -- an exact `==` here flaked under that
// sweep the same way an exact match already flaked for that case (finding 7
// of the PR #64 review's second pass), so this reuses its `TOLERANCE`.
@(private)
WORKER_REUSE_JOBS :: 50

@(test)
a_worker_reused_across_many_jobs_does_not_grow_the_thread_count_when_the_thread_probe_succeeds :: proc(
	t: ^testing.T,
) {
	raw_baseline, baseline_counted := transcibr_thread_count()
	baseline, baseline_ok := report_thread_count_probe(
		t,
		raw_baseline,
		baseline_counted,
		"at baseline",
	)
	if !baseline_ok {
		return
	}

	w := spawn_worker()
	if !testing.expect(t, w != nil, "a worker this case needed to start would not start") {
		return
	}
	defer release_worker(w)

	raw_after_spawn, after_spawn_counted := transcibr_thread_count()

	job: Increment_Job
	for _ in 0 ..< WORKER_REUSE_JOBS {
		wait := run_on_worker(w, increment_worker, &job, READ_TEST_RUN_BOUND_MS)
		testing.expect_value(t, wait, Wait.Finished)
	}
	testing.expect_value(t, job.value, WORKER_REUSE_JOBS)

	raw_after_jobs, after_jobs_counted := transcibr_thread_count()

	after_spawn, ok_spawn := report_thread_count_probe(
		t,
		raw_after_spawn,
		after_spawn_counted,
		"after spawning the worker",
	)
	after_jobs, ok_jobs := report_thread_count_probe(
		t,
		raw_after_jobs,
		after_jobs_counted,
		"after running the jobs",
	)
	if !ok_spawn || !ok_jobs {
		return
	}

	testing.expectf(
		t,
		abs(after_jobs - after_spawn) <= TOLERANCE,
		"%d jobs on one worker moved the thread count from %d to %d (spawned at baseline %d, tolerance %d)",
		WORKER_REUSE_JOBS,
		after_spawn,
		after_jobs,
		baseline,
		TOLERANCE,
	)
}

// Mirrors `a_read_that_cannot_finish_is_abandoned_at_its_bound`, one layer
// up: the same named-pipe-with-no-writer technique, run through a worker's
// job instead of a one-shot thread, proving the bound and the cancellation
// this package already relies on both survive being generalised to a
// reusable thread.
@(private)
Pipe_Read_Job :: struct {
	path: string,
	read: bool,
}

@(private)
pipe_read_worker :: proc(data: rawptr) {
	job := (^Pipe_Read_Job)(data)
	assert(job != nil, "a pipe-read job ran with no job to read into")

	bytes, _ := os.read_entire_file_from_path(job.path, runtime.heap_allocator())
	delete(bytes, runtime.heap_allocator())
	job.read = true
}

// The same worker, handed an ordinary job right after an abandonment, must
// still run it -- this is the "spawn a replacement only when a job is
// actually abandoned" contract issue #65's follow-up review asks for.
//
// PR #64's fourth review found this case itself violating the precondition
// it exists to pin: `defer release_worker(w)` ran unconditionally, so a
// `.Stopped` regressing to `.Unstoppable` (`testing.expect_value` records the
// mismatch and carries on rather than stopping the case) fell through to
// handing a SECOND job to a wedged worker and then joining it -- a join that
// never returns, because the worker was still blocked inside the first job's
// `ReadFile` with nothing left to unblock it. `w.wedged` now turns that same
// mutation into an assertion failure instead of a hang (`worker.odin`), but
// this case does not lean on that backstop: it checks `wait` itself and
// returns before either handing a second job to `w` or releasing it, and it
// closes `server` -- which unblocks a `ReadFile` still pending on the first
// job, wedged worker or not -- before any attempt to join `w`'s thread.
@(test)
a_worker_abandons_a_job_that_cannot_finish_and_stays_usable_afterward :: proc(t: ^testing.T) {
	path, server, ok := pipe_with_no_writer(t, "workerbound", context.allocator)
	if !ok {
		return
	}
	defer delete(path, context.allocator)

	w := spawn_worker()
	if !testing.expect(t, w != nil, "a worker this case needed to start would not start") {
		win32.CloseHandle(server)
		return
	}

	job := Pipe_Read_Job {
		path = path,
	}
	wait := run_on_worker(w, pipe_read_worker, &job, READ_SHORT_BOUND_MS)
	win32.CloseHandle(server)

	if !testing.expect_value(t, wait, Wait.Stopped) {
		return
	}
	defer release_worker(w)

	testing.expect(
		t,
		job.read,
		"`.Stopped` means the job function ran to completion, cancelled read and all",
	)

	second: Increment_Job
	again := run_on_worker(w, increment_worker, &second, READ_TEST_RUN_BOUND_MS)
	testing.expect_value(t, again, Wait.Finished)
	testing.expect_value(t, second.value, 1)
}
