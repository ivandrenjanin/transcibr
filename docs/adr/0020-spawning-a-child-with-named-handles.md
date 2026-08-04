# A child is spawned with the handles it may inherit named, and every loop over one is bounded except `src/audio`'s, which is recorded here

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

## What this retires in ADR-0006

ADR-0006's last consequence still reads:

> Concurrent spawns leak each other's inheritable pipe handles unless handled (see ADR-0004), and
> the mitigation partially re-serialises the very path this pipeline exists to parallelise. That is
> a further argument for **one** extract worker rather than two.

**The mitigation serialises nothing.** It is a per-spawn attribute list, built and destroyed inside
`create_hidden`, and two spawns may run at once with no relationship to each other. The
cross-reference is wrong as well: ADR-0004 does not mention handle inheritance, the attribute list,
or this measurement anywhere.

That sentence must be corrected where it stands, or the argument for one extract worker keeps
resting on a cost that no longer exists. Nothing else in ADR-0006 is affected — the one-GPU-worker
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

`an_engine_that_floods_its_diagnostic_stream_is_still_stopped_at_its_bound` pins it: a stand-in that
types a **1 MiB** flood file to stderr and then waits, run under `EXPIRING_LIMITS` whose `bound_ms`
is **500**, and required to come back `Fault.Did_Not_Finish`. Both halves are the claim — the flood
is drained *and* the bound is still honoured.

**This reasoning has a live second consumer.** `src/audio/run.odin`'s `drain` is still the unbounded
shape, discarding what ffmpeg says at `-loglevel error` in a `for {}` with no ceiling. It is a
smaller exposure — ffmpeg says almost nothing unless a Recording fails to decode, and then it says a
line per frame — but it is the same loop, and the two files are a near-verbatim copy of one another
pending the lift into `transcibr:child` (issue #33). Whichever change closes that duplication takes
the ceiling with it.

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

**`src/audio`'s drain is a known live gap**, stated here rather than left to be discovered. It is
recorded as a consequence and not as a defect because the exposure is bounded by what ffmpeg emits
at `-loglevel error`, and because closing it properly is the lift into `transcibr:child` (issue #33)
rather than a third copy of the same twenty lines. It is a busy spin and not a wedge:
`child.read_diagnostics` never blocks — `PeekNamedPipe` guards the `ReadFile` and returns on
`waiting == 0` — so the loop burns a core rather than hanging, which is why this is a consequence
and not a stop-everything defect.

Issue #33 carries both halves as acceptance criteria, and the title of this decision names the gap
so that neither can be lost to a title nobody re-reads: the lifted drain keeps `MAX_DRAIN_BYTES`,
and the audio path gains the flood-plus-bound test it does not have. `src/engine/engine_test.odin`
has that test; `src/audio/run_test.odin` has no equivalent, so today nothing would go red if the
ceiling were dropped from the copy that has one.

## What reopens this

A measured flood that reaches the megabyte ceiling on a real Engine and matters — meaning progress
falls behind by more than a poll on material a user would actually transcribe. A machine on which a
grandchild survives a real `TerminateJobObject`, which would turn this ADR's stated non-claim into a
claim and change what the second wait is for. A third consumer of the poll-and-drain shape appearing
before issue #33 lifts it, which is the point at which the duplication stops being a deferral. And
the windowed binary of issue #15 existing, which is the first moment the console-window criterion
can be automated at the level it is actually stated.
