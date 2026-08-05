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
// `abandoning_a_read_repeatedly_does_not_accumulate_threads` already uses
// for the same instrument (`CreateToolhelp32Snapshot`) against this
// package's own concurrent sweep -- an exact `==` here flaked under that
// sweep the same way an exact match already flaked for that case (finding 7
// of the PR #64 review's second pass), so this reuses its `TOLERANCE`.
@(private)
WORKER_REUSE_JOBS :: 50

@(test)
a_worker_reused_across_many_jobs_does_not_grow_the_thread_count :: proc(t: ^testing.T) {
	baseline, counted := transcibr_thread_count()
	if !counted {
		return
	}

	w := spawn_worker()
	if !testing.expect(t, w != nil, "a worker this case needed to start would not start") {
		return
	}
	defer release_worker(w)

	after_spawn, counted_after_spawn := transcibr_thread_count()

	job: Increment_Job
	for _ in 0 ..< WORKER_REUSE_JOBS {
		wait := run_on_worker(w, increment_worker, &job, READ_TEST_RUN_BOUND_MS)
		testing.expect_value(t, wait, Wait.Finished)
	}
	testing.expect_value(t, job.value, WORKER_REUSE_JOBS)

	after_jobs, counted_after_jobs := transcibr_thread_count()
	if !counted_after_spawn || !counted_after_jobs {
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
@(test)
a_worker_abandons_a_job_that_cannot_finish_and_stays_usable_afterward :: proc(t: ^testing.T) {
	path, server, ok := pipe_with_no_writer(t, "workerbound", context.allocator)
	if !ok {
		return
	}
	defer delete(path, context.allocator)
	defer win32.CloseHandle(server)

	w := spawn_worker()
	if !testing.expect(t, w != nil, "a worker this case needed to start would not start") {
		return
	}
	defer release_worker(w)

	job := Pipe_Read_Job {
		path = path,
	}
	wait := run_on_worker(w, pipe_read_worker, &job, READ_SHORT_BOUND_MS)
	testing.expect_value(t, wait, Wait.Stopped)
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
