# A child is spawned with the handles it may inherit named, and every loop over one is bounded

Every child is created with a `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` naming **exactly two handles** —
its own null device and the write end of its own diagnostic pipe — and every loop that reads one has
a ceiling on it. ADR-0004 settled that the spawner is hand-rolled and that stopping a child means
stopping a tree. This ADR is what that spawn had to become once two of them could overlap, and what
the readers above it had to become so that a bound is ever reached at all.

## Handle inheritance is all-or-nothing, and that was the concurrent-spawn trap

`bInheritHandles = TRUE` is not a statement about the handles a child was *given*. Without an
attribute list it hands the child **every inheritable handle this process holds at that instant** —
which, for two spawns overlapping by microseconds, includes the write end of the *other* child's
diagnostic pipe. That pipe then never reports end of stream, because a live process is still holding
it open, so a caller draining until end of stream waits forever on a child that exited an hour ago.

**Measured, before the handle list existed:** the suite's own six concurrent cases turned the
end-of-stream case red, and **only under concurrency**. Run alone it passed every time, which is the
signature of the bug and the reason it survived review — the window between `CreatePipe` and the
parent closing its copy of the write end is microseconds wide, and nothing in a single-threaded run
is ever inside it.

With the list in place inheritance is those two handles whatever else is open. **No lock, no
ordering rule, and no window are involved** — which is the property worth having, because a
mitigation built on locking the spawn path is a mitigation that scales with worker count.

`a_child_inherits_nothing_but_the_streams_it_was_given` in `src/child/child_test.odin` is what pins
it, and its shape is dictated by the same window. Spawning two children and watching is *not* a test
of this: the package closes its copy of a write end the moment the child has one, so a second spawn
started afterwards has nothing left to inherit and passes whatever the flags say. The case therefore
**stands the window still** — it opens an inheritable pipe of its own, holds it open across a spawn,
and requires that the child did not come away with it. A case that has to hit a window is a case
that passes by luck.

A handle list that cannot be built is a refusal (`Fault.No_Handle_List`), not a fallback. The only
fallback available is unlisted inheritance, which is the defect above.

## What this retired in ADR-0006

ADR-0006's last consequence used to read:

> Concurrent spawns leak each other's inheritable pipe handles unless handled (see ADR-0004), and
> the mitigation partially re-serialises the very path this pipeline exists to parallelise. That is
> a further argument for **one** extract worker rather than two.

**The mitigation serialises nothing.** It is a per-spawn attribute list, built and destroyed inside
`create_hidden`, and two spawns may run at once with no relationship to each other. The
cross-reference was wrong as well: ADR-0004 does not mention handle inheritance, the attribute list,
or this measurement anywhere.

That sentence has been corrected where it stood, so the argument for one extract worker no longer
rests on a cost that does not exist. Nothing else in ADR-0006 was affected — the one-GPU-worker
invariant and the bounded queue are argued from throughput and disk, and stand on their own.

## The list stores an address, not a copy, and that dictates the procedure's shape

`UpdateProcThreadAttribute` keeps the **address** of the handle array, not its contents. So the
`Handle_List` record must outlive `CreateProcessW` and must not be moved after the update call has
seen it. It is declared in the caller's frame and filled through a pointer rather than returned by
value, and that is not a taste in argument style:

**Returning it by value copies the array into the caller's frame and leaves the list pointing at a
dead one — a defect with no diagnostic**, because the stale bytes are usually still the right
handles. A refactor to a by-value return reads as a cleanup, passes review, and usually still works.
That is exactly the failure mode this section exists to make expensive to reintroduce.

Two smaller shapes fall out of the same call and are recorded here because each looks wrong on
sight:

- The attribute-list buffer is `[]rawptr` and not `[]u8`. Windows returns a required size **in
  bytes** and says nothing about alignment, while a byte slice is aligned to 1. Pointer-element
  storage gives a structure full of pointers the alignment it needs; the byte count is rounded up
  into elements at the `make`.
- The first `InitializeProcThreadAttributeList` call is **expected to fail**. Asking for a list that
  fits nowhere is the documented way to be told how large one must be, so the answer read is `size`
  and never the return value. A `size` of zero is the refusal.

## No unbounded loop over a child

`src/engine/run.odin`'s diagnostic drain was **the one unbounded loop inside a bounded run**. It
stopped only on a pipe error, on end of stream, or on a pipe that happened to be empty when asked —
and while it ran, neither the watchdog nor the run bound in the poll loop above it was reached. An
Engine that entered a diagnostic loop was therefore never stopped at all: the wedge that holds a
Batch for ever (issue #27) and holds the one GPU worker with it (ADR-0006), arriving on the one
stream this program can actually see.

The fix is `MAX_DRAIN_BYTES :: 1 << 20` — a ceiling on how much **one** drain may take before its
caller is let back in to look at its bounds. Whatever is left stays in the pipe for the next poll, a
quarter of a second later (`POLL_MS :: u32(250)`). Nothing is dropped and nothing is at an end, so
the caller is told the pipe is readable, which it is.

The megabyte is arithmetic against two measured quantities rather than a tuned number:

| quantity | value | where it comes from |
|---|---|---|
| diagnostic pipe | 64 KiB | `child.DIAGNOSTIC_PIPE_BYTES` |
| one drain's ceiling | 1 MiB | 16× the pipe |
| poll interval | 250 ms | `POLL_MS`, four polls a second |
| sustained drain rate | 4 MB/s | ceiling × polls |
| a healthy Engine's stderr | a few kilobytes per Recording | ADR-0004, ADR-0012 |

So a healthy Engine never reaches the ceiling, and one flooding the stream is drained far faster
than it can be filled. **A child that somehow writes faster than 4 MB/s blocks on its own pipe,
which is throttling and not the wedge ADR-0004 measured** — the pipe is still being emptied every
quarter of a second, and the child is not stopped dead with nothing to show for it.

`DRAIN_BYTES :: 4096` is the stack buffer one drain reads through, and
`#assert(MAX_DRAIN_BYTES > DRAIN_BYTES)` holds the relationship in checked code rather than in this
paragraph.

`an_engine_that_floods_its_diagnostic_stream_is_still_stopped_at_its_bound` exercises it: a stand-in
that types a **1 MiB** flood file to stderr and then waits, run under `EXPIRING_LIMITS` whose
`bound_ms` is **500**, and required to come back `Fault.Did_Not_Finish`. **It does not pin the
ceiling** — mutating `MAX_DRAIN_BYTES` away leaves it green, because an unbounded drain still runs
out of flood to read and hands control back the same way, which is a distinction found only by
mutating the code and watching what stays green. What it proves is the other half: that a flood on
the diagnostic stream does not stop the bound from being reached.
`child.a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood` is the one case in the tree that
pins `MAX_DRAIN_BYTES` itself, by holding the pipe fed with a steady trickle for long enough that the
ceiling, and not the flood running out, is what ends the drain.

**This reasoning had a live second consumer, closed by issue #33.** `src/audio/run.odin` used to
carry its own `drain`, an unbounded shape discarding what ffmpeg says at `-loglevel error` in a
`for {}` with no ceiling — a smaller exposure than the Engine's, since ffmpeg says almost nothing
unless a Recording fails to decode, but the same loop and a near-verbatim copy of the Engine's own.
The lift moved both copies into `transcibr:child.run_bounded`, which `src/audio/run.odin` and
`src/engine/run.odin` both call today; `src/audio/run.odin` has no drain of its own left to
duplicate.

## Every child the suite starts is bounded, as a rule rather than a habit

`odin test` runs what it builds, so a test that starts a child which never exits wedges the sweep
behind `scripts\common.ps1`'s ten-minute ceiling **with nothing naming the case that did it** (issue
#27). Every bound in `src/child/child_test.odin` is load-bearing for that reason, and every
long-lived child is one told to wait for a signal nobody sends, so it ends by itself even if the
suite never gets to it.

Two of those bounds are discriminations rather than budgets, and both were measured against an
impostor.

**`STOP_BOUND :: u32(3_000)`, chosen against a stop that does not stop.** With stop's own
thirty-second default, a stop that terminated only the child and not the tree still **passed** — it
waited twenty-five seconds for the process the child had started to finish on its own, and then
everything the case asked was true. Correct on that child and useless on a real one: the Engine
holds its output for hours, so "eventually it finished by itself" is not stopping. Terminating a job
object ends its members in microseconds, so three seconds passes the mechanism and fails the
impostor.

**`FREED_BOUND :: 3 * time.Second`, and it is not slack in the claim.** What it absorbs is somebody
*else* opening the file in the instant after the child let go — real-time virus scanning opens a
file when its last handle closes, which is exactly this moment, and no amount of asserting harder
wins that race. Without it the case failed **about one sweep in three**. It does not weaken the
discrimination: three seconds is an **eighth** of the twenty-five the child would still be holding
the file if stop had come back early.

## The count of three is the reliable half of the file case, and the file is the other half

`HOLDERS_OF_THE_FILE :: u32(3)` is meaningless without the finding that produced it.

`cmd /c (waitfor /t N NAME) > path` **opens the redirect before it starts waitfor**, so the file
reads as held while `cmd.exe` alone holds it — and in that instant there is no grandchild to leave
behind, so a stop reduced to ADR-0004's literal process-only rule passes. Probed with a poll tight
enough to see the window:

| observation | result |
|---|---|
| file first read as held with the job holding **two** processes | 12 runs of 12 |
| third process arrived after | about 1.2 ms |
| the literal-rule mutant passed | **4 of 12 runs** |

Whether a five-millisecond poll lands inside a window that closes in about 1.2 ms is luck, and it
was measured as such. So the case waits on the **count** and treats the file as only the other half
of the claim. The three members at the state the case needs are `cmd.exe`, its `conhost.exe`, and
the `waitfor.exe` cmd starts — **read back by name from the job's process-id list, not counted from
a diagram**.

The file remains in the case because it is the consequence a caller cares about: ADR-0002 has
transcibr move, delete or re-run against the artifacts of a stopped Recording, and against a file
something still holds that is a sharing violation or a half-written file. It is the job's own
counter that is the claim.

## A recorded null result: the second wait is not measurable by the file case

Keep `TerminateJobObject` and **delete stop's subsequent wait for the job to empty**, and
`a_stopped_child_has_let_go_of_the_file_it_held` still passes — **16 runs of 16 run alone, and 4 of
4 under the suite's six concurrent cases**. `TerminateJobObject` is `TerminateProcess` applied to
every member, so on this machine everything the child started is already gone by the time the
child's own process object signals; the counter reads 0 whether stop looked or not.

Pinning the second wait therefore requires **withholding the terminate** instead, which is what
`stop_is_false_while_something_the_child_started_is_still_running` does. The child is
`cmd /c start /b waitfor ...`, which returns leaving a grandchild running and still in the job, and
stop is handed a `DuplicateHandle` view carrying `JOB_OBJECT_QUERY` (**0x0004**) and *not*
`JOB_OBJECT_TERMINATE` (**0x0008**) — so it may ask what the job holds and may not end it. `false`
is then the only correct answer, and it can only come from the wait: with the wait deleted, stop has
nothing left to answer from but the child's process object, which signalled long before.

**Stated non-claim: nothing here measures that a grandchild ever survives a real
`TerminateJobObject`.** It does not on this machine and may on a loaded one. That is the hazard, not
the claim; the claim is that after the child has gone, stop asks the job object, and a job object
that has not emptied is not a stop.

This null result is recorded rather than left implicit because without it a future reader deletes
the second wait, sees a green suite, and **has no way to know it was already proven green**.

## The console-window criterion has no automated test, and that is a finding

The criterion ADR-0004 exists for is "no console window appears, from a windowed binary". The
obvious proxy is `GetConsoleProcessList` — start a child, ask whether it joined this process's
console, require that it did not. Measured against a spike that spawned the same child five ways:

| spawn | on this console |
|---|---|
| no flags, no std handles | **TRUE** |
| `STARTF_USESTDHANDLES` alone | false |
| handle list | false |
| `CREATE_NO_WINDOW` alone | false |
| `CREATE_NO_WINDOW` + handle list | false |

**Redirecting the standard handles is what takes a child off that list.** So the proxy stays green
with `CREATE_NO_WINDOW` deleted — measured that way too, on this suite, before the case was
withdrawn. A case that cannot fail on the edit it exists to catch is a comment with a runtime cost.

What holds the flag instead is the compiler:
`#assert(CREATION_FLAGS & win32.CREATE_NO_WINDOW != 0)`. It restates the line above it and that is
the point of it — **measured: with `CREATE_NO_WINDOW` deleted, `scripts\test.ps1` reports
`Compile time assertion` against that line and collects zero tests.** It claims only that the flag
is still in the word, which is the part a refactor can quietly drop, and it fires wherever the
package is compiled — today the sweep and not `scripts\build.ps1`, because the only target built so
far does not import it yet (issue #15).

What replaced the proxy is a hand-run harness that **is** the criterion rather than a proxy for it: a
GUI-subsystem binary started with no console of its own spawns the same child twice, once through
this package and once through `core:os.process_start`. Through `core:os` a visible window appears;
through this package none does. The pull request records the runs. The windowed binary is issue #15
and does not exist yet, so this stays a hand verification until it does.

## A read is bounded by the same shape, not by a third drain

Issue #27's second half: `--from-json CON` never returns. `CON` names the Windows console device, so
the path opens fine and then blocks on `ReadFile` forever, even with this process's own stdin
pointed at the null device — because `CreateFile("CON", ...)` opens a *new* handle onto the console,
independent of whatever this process inherited as standard input. `AUX`, `COM1`, `CONIN$` and
lowercase `con` all hang the same way; `PRN`, `NUL`, `LPT1` and `con.json` do not, which is exactly
why this is bounded as a read and not special-cased by name — the reserved names do not even agree
with each other on whether they hang, and a network share or a named pipe with nothing writing to it
block by the identical mechanism without naming anything reserved at all.

`child.read_bounded` (`src/child/read.odin`) answers this the same way `run_bounded` answers a child
that will not exit: wait up to a wall-clock ceiling, and past it, cancel and join whatever has not
finished (see below). Waiting up to the ceiling is one exact `win32.WaitForSingleObject` call and not a
poll loop — an earlier version of this bound polled `thread.is_done` every `READ_POLL`, and because
Windows quantizes `time.sleep` to its own roughly 15.6 ms timer period, that cost at least one
quantized sleep on very nearly every call, healthy reads included: measured over 150 Recordings through
the public `--plan` seam, 85 ms before this bound existed at all against 7,573 ms with the poll loop in
front of it (PR #64's second review, finding 2). `READ_BOUND_MS :: 30_000` sits beside `STOP_BOUND_MS`
for the same reason the two are the
same order of magnitude — both answer "how long does transcibr wait for something outside it to
answer" — and is grounded rather than assumed: the committed fixture is 2,335 bytes of Engine JSON for
30,356 ms of audio, and scaled to the corpus's longest Recording (168 minutes, `docs/spec/`) at the
same segment density that comes to about 760 KiB. Even a pessimistic 8 MiB, several times denser than
the fixture, only needs 267 KiB/s sustained over the bound to land inside it — well below what "slow
but still answering" means for a share. `child.a_worst_case_sized_engine_output_reads_well_within_its_bound`
pins this against real disk I/O, using `READ_BOUND_MS` itself rather than a shortened stand-in, which
the ceiling test below does not.

**A read cannot be polled the way a child's diagnostic pipe is.** `PeekNamedPipe` lets `drain_bounded`
ask "is there anything to read" without blocking, but that answer does not exist for an arbitrary
`ReadFile` against a console handle or a stalled network share — there is no non-blocking peek that
works uniformly across every device a path can name. Overlapped I/O (`FILE_FLAG_OVERLAPPED` plus
`GetOverlappedResultEx` and a timeout) was considered and rejected for the same reason a blacklist
was: console handles do not reliably honour it, so the one motivating case would still block. The read
therefore runs on its own thread, and what this package waits on is *that thread's own Win32 handle*,
through `win32.WaitForSingleObject(t.win32_thread, bound_ms)` — an exact wait rather than a poll,
because a signalled handle wakes the call the instant the thread exits.

**`await_or_abandon` reaches `t.win32_thread`, a field `core:thread` never meant to hand out.**
`Thread_Os_Specific` (`core:thread`'s Windows-only file) is declared `#+private`, and `Thread` embeds
it with `using specific: Thread_Os_Specific`. `#+private` in Odin restricts the *identifier*
`Thread_Os_Specific` to `core:thread` — it says nothing about the fields `using` promotes onto
`Thread` itself, which stays a public type. So `t.win32_thread` compiles from outside the package,
today, on this compiler pin, without `core:thread` ever deciding to export a Win32 handle. Nothing
enforces that this keeps compiling: a future `core:thread` that renames the field, drops the `using`,
or moves the promotion behind its own `#+private` boundary turns `t.win32_thread` into an unresolved
identifier — a compile error naming this file, not a silent wrong answer, because there is no
`win32_thread`-shaped fallback for the compiler to reach for instead. That is the whole of why this is
recorded rather than fixed: the fix would be vendoring or reimplementing `core:thread`'s Windows
thread creation, which trades a loud, bounded risk (a build break, fixed by reading whatever
`core:thread` renamed the field to) for a maintenance burden with no expiry. `CancelSynchronousIo`
needs this exact handle for the identical reason — see below — so the reliance is not new with
`WaitForSingleObject`, only newly load-bearing for the bound itself rather than only for cancelling
past it (PR #64's second review, finding 6).

**A read that hits its bound is cancelled and joined, not simply abandoned.** The first version of
this ADR abandoned a read thread outright past its bound, on the reasoning that `stop` already
accepts a child left running rather than forced, and `TerminateThread` abandons whatever locks the
thread held mid-use (CLAUDE.md's own notes on this repository's test runner, measured against this
toolchain). Review of the PR that first shipped this (PR #64, before it merged) found that reasoning
understated its own cost by an order of magnitude and pointed at a fix: `CancelSynchronousIo`
(`src/child/win32.odin`) is the Win32 primitive built for exactly this — it cancels a *pending
synchronous* I/O call on another thread from outside it, without `TerminateThread`'s lock-abandonment
hazard, because the target thread's own blocked syscall is what returns, carrying `ERROR_-`
`OPERATION_ABORTED`, rather than the thread being cut off mid-instruction.

**What the original design missed, measured with `CreateToolhelp32Snapshot`:** eight reads abandoned
against a named pipe nobody was writing to took this process's own thread count from 5 to 13 — exactly
+1 per read, retained for the life of the process. That is at minimum four heap blocks per abandoned
read (`Read_Job`, its cloned path, whatever bytes were read so far, and the `Thread` struct
`core:thread` itself allocates — the fourth already named in the PR body but not in this ADR's prose),
a live OS thread and its default 1 MiB reserved stack, the Win32 thread handle (closed only by `_join`,
which abandonment skips), and — because the thread is blocked *inside* `os.read_entire_file_from_path`,
after the file has been opened — an open Win32 file handle on the wedged path, which collides directly
with issue #12's stale-file sweep and `artifact.quarantine`: `os.rename` is refused by Windows while
another handle still holds the file open.

`await_or_abandon` (`src/child/read.odin`) is the fix: past `bound_ms`, it calls
`CancelSynchronousIo(t.win32_thread)` in a short poll loop (`CANCEL_BOUND_MS`, 5 s — measured against
eight concurrent cancellations joining in 6.5 ms total, so five seconds is margin and not the expected
cost) until the thread reports done, then joins it exactly as a read that finished on its own is
joined. **Cancel, then join, then free — the same terminate/wait/close discipline `stop` already uses
for a whole child, one layer down, with no leak in the case this ADR's own measurement exercises.**
Only if a thread will not stop even once asked — a case nothing measured here has produced — does it
fall back to the original abandonment, on `job_allocator`'s heap, for the process's remaining life;
`Wait` (`.Finished` / `.Stopped` / `.Unstoppable`) is what names the three outcomes, deliberately
matching `Run`'s own vocabulary for a process one layer up.

`child.abandoning_a_read_repeatedly_does_not_accumulate_threads_when_the_thread_probe_succeeds` is
what pins the fix: a hundred
abandoned reads, run one after another through the public `read_bounded` seam, must not leave this
process's own thread count more than `TOLERANCE` above its baseline — measured with the identical
`CreateToolhelp32Snapshot` technique the review used, so the claim and the proof use the same
instrument. Not an exact match: this suite runs every package's tests across twelve concurrent
threads, and a sibling case transiently holding a thread of its own during this case's window can move
the count either direction by a handful. `ROUNDS :: 100` and `TOLERANCE :: 8` are sized against each
other rather than picked separately — PR #64's third review (finding 2) proved the sizing by mutation:
skipping cancellation on one call in four leaks roughly a quarter of `ROUNDS` every run, which
`TOLERANCE` must not be able to absorb. At the round count this ADR shipped with first (25), it could:
the mutation leaked 6 threads against a tolerance of 8. At 100 it leaks roughly 25, more than three
times the tolerance, while a clean run's own delta does not move.

`child.a_read_that_cannot_finish_is_abandoned_at_its_bound` is the case that discriminates the bound
itself, and it does not depend on a Windows device name: it opens a named pipe server end
(`CreateNamedPipeW`) that nobody ever writes to or connects a reader's other end against, which blocks
a `ReadFile` by the same mechanism `CON` does, on any filesystem. **Mutating the bound check out of
`await_bounded` turns this case from a 300 ms pass into a hang the test harness kills at its own
timeout** — measured directly, with `-TestName` and a short `-TimeoutSeconds` rather than the sweep's
default ten minutes, specifically so proving the negative could not itself become the next hang this
ADR is about.

**The same `await_or_abandon` is now the general mechanism for bounding any blocking call transcibr
does not control, not only a read.** `src/artifact/model.odin`'s `digest_of_bounded` bounds hashing a
`--model-file` on a one-shot thread, the same shape `read_bounded` uses. `src/planning/walk.odin`'s
`directory_listing_bounded`, `transcript_state_bounded` and `sidecar_at` bound a directory listing, a
Transcript-head read and a Sidecar read discovery makes — issue #27's read half was not fully closed
by the Engine-output and `--from-json` reads alone, and these three are the ones reachable from
hand-typed input and the walk. `src/child/child.odin`'s package doc was widened to say so.

**A walk of hundreds of Recordings does not pay for a one-shot thread per bounded call.** PR #64's
third review (finding 3) measured `--plan` 3–3.8x slower than before this ADR's own `await_or_abandon`
existed, scaling linearly with the size of the archive: `looked_at` created and joined a fresh thread
for the Transcript-head read AND the Sidecar read, and `walk_one` did the same for the directory
listing, for every Recording and every directory — 2N+D create/join pairs over an archive of N
Recordings across D directories, almost all of them for the dominant case where neither file exists.
`src/child/worker.odin`'s `Worker` is the fix: one persistent OS thread for the whole walk, waited on
with its own pair of auto-reset events (`wake`, `done`) rather than the thread's own win32 handle,
since a persistent thread never exits between jobs the way a one-shot thread's handle signals on. Past
`bound_ms` the same `CancelSynchronousIo` escalation `await_or_abandon` uses applies to the worker's
own thread, and `.Unstoppable` means the worker itself — not only the job — is no longer safe to reuse:
`planning`'s `run_bounded` spawns a replacement only then, preserving the bound exactly while cutting
the create/join cost to one thread per walk rather than one per bounded call.

**A wedged worker leaks more than a one-shot read's `Unstoppable` does, and this ADR said nothing
about the difference until PR #64's fourth review measured it.** `release_worker` is never safe to
call once `.Unstoppable` comes back — the same reason `thread.destroy` is never called on an
abandoned read's thread — so the replacement `run_bounded` spawns leaves the old `Worker` exactly as
its last job left it: its thread (still blocked, or, once whatever it was blocked on lets go,
parked forever on its own `wake` event), the `wake` and `done` kernel event handles
`close_worker_events` would otherwise close, and the `Worker` struct itself, all on
`runtime.heap_allocator()`'s heap for the rest of the process — `close_worker_events` is never
called on an abandoned worker at all. Measured by forcing every `.Unstoppable` path in a row: 25
abandoned workers left the thread count +25, with `spawn_worker` producing a clean replacement each
time and no corruption. The trade is the same one `Unstoppable` already makes for a one-shot read;
it costs two kernel handles and a heap struct more per occurrence, because a `Worker` owns more than
a `Read_Job` does.

## Consequences

**The by-pointer `Handle_List` is a shape that invites a cleanup, and the cleanup is a silent
defect.** That is the accepted cost of the attribute list: the alternative — a by-value return —
compiles, reads better, and works most of the time. The comment at the type and this ADR are the
whole defence, because there is no diagnostic to add.

**A flood costs latency, not correctness.** Under `MAX_DRAIN_BYTES` a run bound is honoured to
within one poll plus one drain, so a child flooding stderr is stopped a fraction of a second later
than a quiet one. That is a trade taken deliberately against the alternative, which is a bound never
reached at all.

**The console-window criterion is carried by review and a hand-run harness**, which is the ceiling
ADR-0009 already names for the shell: the subprocess layer gets integration tests and inspection,
not unit tests. The compile-time assertion narrows what can be lost silently to zero for the flag
and to everything else for the behaviour.

**The suite pays wall clock for its bounds**, and pays it on every sweep. Three seconds for a stop
that succeeds, three for a file to come free, half a second for a stop that must answer false: the
figures are small because each was cut to the smallest value that still fails its measured impostor,
not to the smallest value that passes.

**`src/audio`'s drain was a known live gap, closed by issue #33.** `src/audio/run.odin` no longer
carries a drain of its own — it calls `child.run_bounded`, the same procedure
`src/engine/run.odin` calls, so the ceiling is shared rather than duplicated. What was true of the
gap while it stood is still true of the shared drain today: it is a busy spin and not a wedge —
`child.read_diagnostics` never blocks, `PeekNamedPipe` guards the `ReadFile` and returns on
`waiting == 0` — so the loop burns a core rather than hanging.

Issue #33 carried both halves as acceptance criteria. The lifted drain keeps `MAX_DRAIN_BYTES`, and
`src/audio/run_test.odin` now carries
`a_flood_on_the_diagnostic_stream_does_not_stop_the_bound_from_being_reached`, the case
`src/child/run_test.odin` gained from the same lift under the same name. Neither one, nor
`src/engine/engine_test.odin`'s own copy, discriminates the ceiling itself — see above —
`child.a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood` is the one case that does, and
it is the one that goes red if `MAX_DRAIN_BYTES` is dropped.

**A read that misses its bound is cancelled and joined, reclaiming its thread, stack, thread handle,
file handle and every heap block it held** — measured with `CreateToolhelp32Snapshot` returning to
within `TOLERANCE` of its baseline after a hundred abandoned reads, a margin sized to absorb this
suite's own concurrent sibling noise and nothing more (see above). Only a thread that will not stop
even once `CancelSynchronousIo` asks it to — a case nothing measured here has produced — falls back to the
original trade: `Read_Job`, its cloned path and whatever bytes its thread eventually reads stay
allocated on `job_allocator`'s heap rather than the caller's own, for as long as the process runs,
the same trade `Unstoppable` already makes for a child that will not stop. Issue #27 is the ticket
that added the bound; its callers now cover a hand-typed path (`src/cli/main.odin`'s `--from-json`),
one this program built from a Recording's own stem (`src/artifact/place.odin`'s Engine-output read),
a `--model-file` hash (`src/artifact/model.odin`), and the directory listing, Sidecar and
Transcript-head reads discovery makes (`src/planning/walk.odin`).

## What reopens this

A measured flood that reaches the megabyte ceiling on a real Engine and matters — meaning progress
falls behind by more than a poll on material a user would actually transcribe. A machine on which a
grandchild survives a real `TerminateJobObject`, which would turn this ADR's stated non-claim into a
claim and change what the second wait is for. And the windowed binary of issue #15 existing, which is
the first moment the console-window criterion can be automated at the level it is actually stated.

A resource `CancelSynchronousIo` genuinely cannot unblock — nothing measured here has produced one,
against a reserved console device or a named pipe with no writer — which would turn `await_or_abandon`'s
`.Unstoppable` branch from a documented fallback into the common case rather than the rare one, and
make the leak this section used to describe as unconditional the live risk again.

Issue #33's lift moved before a third caller existed, so the "third consumer" trigger this ADR
originally recorded no longer applies the way it was written: `src/audio/run.odin` and
`src/engine/run.odin` already share one copy in `transcibr:child`, and a future caller — issue #12's
pipeline is the one named — adds a third by calling `child.run_bounded` directly, not by writing a
third copy. What the lift did not resolve is `on_poll`'s `-> bool` signature collapsing three
distinct stops into one `.Stopped` — recorded where it is fully stated, at `watched_poll` in
`src/engine/run.odin`.

## Addendum (2026-08-06, #152)

Anchored to ADR-0035's first accepted risk. Locally, nothing kills a wedged `just test` any more —
`scripts\common.ps1`'s ten-minute process-tree ceiling this record's "Every child the suite starts
is bounded" section names is gone, and a `Ctrl+C` is the only local recourse; CI's job-level
`timeout-minutes: 30` is the sole remaining backstop. Every bound `src/child/child_test.odin`
carries is correspondingly MORE load-bearing than this record states, not less: a hang that used to
be caught locally inside ten minutes now runs until CI's half-hour ceiling, or until someone notices.

The console-window criterion section's scope correction: `#assert(CREATION_FLAGS &
win32.CREATE_NO_WINDOW != 0)` no longer fires "today the sweep and not `scripts\build.ps1`" —
`src/cli` imports `transcibr:child` today (`main.odin:12`, `batch.odin:15`, `doctor.odin:9`,
`transcribe.odin:8`), so the assert now fires wherever this package is compiled, including `just
build` and `just release`, not only `just test`.

The read-bound section's re-run instruction is retired along with the wrapper it named: past
`await_bounded`'s bound, there is no `scripts\common.ps1` sweep timeout to kill a hang and report it
under its own message any more. Proving the negative — that a mutated bound check does hang — now
needs `just test-one` run under an external timeout of the caller's own choosing, not the sweep's
former ten-minute default.
