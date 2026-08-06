# The bounded-call job shape stays six-plus copies; the `.Unstoppable`-do-not-release switch does not

Issue #66 named six copies of "spawn a job, await it with a bound, release it only if it finished or
was cancelled -- never if it was abandoned," and the review comments on it counted two more by the time
this landed (audio's `Head_Job`, engine's `Landed_Job`), plus a seventh and eighth spelling of the
`.Unstoppable`-do-not-release switch itself in `transcibr:pipeline`. The ticket's own technical question
was whether `thread.create_and_start_with_poly_data`'s `where` clause lets the job type become a
parameter, collapsing every copy into one generic primitive in `transcibr:child`. This ADR records why
that extraction was not done, and what was extracted instead.

## The measured shape of the six-plus copies

Two genuinely different mechanisms, not one:

- **One-shot**, at `child.read_bounded`, `child.make_directory_bounded`, `child.list_directory_bounded`,
  `artifact.digest_of_bounded`, `audio.read_head_bounded`, `engine.landed_bounded`: a fresh thread per
  call, `thread.create_and_start_with_data`, joined or abandoned once and never reused.
- **Worker-based**, at `planning.directory_listing_bounded`, and two further call sites in
  `walk.odin`: one persistent OS thread per `Walking`, reused across many jobs through
  `child.Worker`'s own `wake`/`done` events and `run_on_worker`. `child/worker.odin`'s own comment
  gives the reason this exists at all -- PR #64's third review measured a 150-Recording `--plan` at
  7.5 seconds with a thread spawned per bounded call, and back under 200 ms once one thread served the
  whole walk. Collapsing this into the one-shot shape would give that regression back; keeping it as a
  second generic defeats "one definition" as surely as keeping it as a copy does.

Within the one-shot shape, every site's own `*_finished` step touches different fields with different
copy semantics: `Read_Job` copies a `[]u8`; `Directory_Listing_Job` clones a `[]os.File_Info` through a
fallible allocator (`child.clone_directory_listing`); `Digest_Job` clones a `Digest` string only when
`fault == .None`; `Head_Job` copies a `[]u8` already sized to a fixed head length; `Landed_Job` returns a
bare `Fault` with no allocation at all. A generic `bounded_call($Job: typeid, ...)` can express this --
Odin's polymorphism is not the obstacle -- but only by taking a caller-supplied "finished" procedure
value per site, at which point the body a generic primitive could share is exactly the handful of lines
this ADR's own extraction below already unifies, and the shell around it (allocate the job, spawn the
thread, call the caller's finished procedure, release) is not shorter or safer than what each site
already writes.

A standalone probe at the pinned compiler (`dev-2026-07-nightly:819fdc7`) shows a caller-supplied
release does not have to fall back to `proc(rawptr)` to compile: `bounded_call :: proc(job: ^$J,
worker: proc(data: rawptr), release: proc(t: ^thread.Thread, job: ^J), bound_ms: i64) -> bool` builds
and runs, and handing it a `release` typed for a different job struct is refused at compile time
(`Error: Cannot assign value release_b of type proc(^Thread, ^Job_B) to proc(^Thread, ^Job_A) in a
procedure argument`). So a typed release survives a generic `$J` shell; the compile guard AC7 asks not
to lose is not the reason the full job-struct lifecycle stays copies.

The reason is the one above it: each site's own `*_finished` step already differs in what it copies and
how (`[]u8` here, a fallible-allocator clone there, a conditional clone, nothing at all), so a generic
shell still needs a caller-supplied `worker`/`finished` pair per site, and the body left for a shared
primitive to unify is the handful of lines already pulled out below as `reclaim_for`/`await_and_reclaim`.
A polymorphic `bounded_call($J)` was not attempted beyond the probe above -- it would still need a
per-site `finished` procedure value, and nothing measured here says the resulting shell reads better
than what each site already writes.

## What this ADR answers, and does not

**The full job-struct lifecycle stays copies.** `Read_Job`, `Make_Directory_Job`,
`Directory_Listing_Job`, `Digest_Job`, `Head_Job`, and `Landed_Job` remain six separate structs with six
separate `*_worker`, `release_*_job`, and `*_finished` procedures, and `planning`'s worker-based sites
keep their own `Directory_Job`, `Sidecar_Read_Job`, and `Transcript_Head_Job` beside them. This is the
recorded finding AC1 asks for in place of an extraction: generalizing the shell either gives back the
reusable-worker optimization (folding `planning`'s worker-based sites into the one-shot shape) or keeps
two generics side by side, and buys no code once each site's own `finished` step is accounted for -- not
because a typed release cannot be expressed generically (it can; see the probe above).

**What did generalize, because it costs nothing to:** the `.Unstoppable`-do-not-release switch itself, at
every site named in the ticket and its review comments, one-shot and worker-based alike, plus
`transcibr:pipeline`'s two worker-tier joins (`close_and_join`, and `topology_test.odin`'s `join_batch`).
Every one of these used to spell `switch <a Wait> { case .Finished, .Stopped: <release>; case
.Unstoppable: <leave alone> }` by hand. `child.reclaim_for(wait: child.Wait) -> (finished, reclaim: bool)`
(`src/child/reclaim.odin`) names that mapping once, exhaustively over `child.Wait` -- the same class of
guard `transcript_state_of` (`planning/walk.odin`) already gives its own per-caller vocabulary, so a
member added to `Wait` fails the build here rather than falling through silently.

Two call shapes read it. The one-shot sites and the pipeline's worker-tier joins already hold a
`^thread.Thread` and a bound, so they call `child.await_and_reclaim(t, bound_ms)`, which composes
`reclaim_for` with `await_or_abandon` directly. `planning/walk.odin`'s three worker-based sites
(`directory_listing_bounded`, `sidecar_at`, `transcript_state_bounded`) call `run_bounded` first, which
already waited on `state.w` and handed back a `child.Wait` rather than a thread and a bound, so these
three read `finished, reclaim := child.reclaim_for(wait)` directly, then branch on the same two named
answers. Every site above -- one-shot, worker-based, and the pipeline's joins -- now reads through
`reclaim_for` one way or the other rather than re-deriving the three-case switch, closing findings 7 and
8 from the ticket's review comments without touching the shape those findings did not flag.

Also collapsed, because both were genuine byte-identical duplication and cost nothing to remove:
`child.job_allocator` is now the one, exported spelling of the outlives-the-caller heap policy --
`runtime.heap_allocator()` no longer appears inline at any one-shot job site in `child`, `artifact`,
`audio`, `engine`, or `planning`. `child.clone_directory_listing` is the one copy of the listing-clone
logic and its double-free regression test; `planning`'s own copy, and its own `Failing_Allocator`, are
gone. `child.DID_NOT_FINISH_SAYS` is the one spelling of the sentence `read_fault_says` and
`model_fault_says` both carried verbatim. `audio.read_head_bounded` and `engine.landed_bounded` each lost
the one-line forwarding wrapper a `stall_ms` default parameter made unnecessary.

## What reopens this

A typed, polymorphic `release` parameter is confirmed to compile (the probe above); what remains open is
whether the per-site `finished` step -- the part that actually differs, field by field and copy semantics
by copy semantics -- can be pulled behind a single generic `bounded_call($J)` for less code than six
copies plus `reclaim_for`. That is the question this ADR leaves open, the same way ADR-0030 left the
fault-report shape's own generic extraction open.
