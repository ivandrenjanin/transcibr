# Faults leave `src/pipeline` as events, never as stdio writes

Issue #176, stage 1's fourth and final PR (176-D). The GUI-era planning session's master plan
(`.scratch/sdd/gui-planning/master-plan.md` §5 D5, §11) named this decision once, ahead of the GUI
stage that needs it (#16): `src/pipeline` currently reports every fault by calling `fmt.eprintln`
or `fmt.println` directly (`report_fault`/`report_line`, `src/pipeline/recording.odin`), which is a
console-subsystem assumption a GUI-subsystem binary cannot share — `fmt.eprintln`, like every other
stdio write, silently disappears into a NULL handle in that binary (§2.4 of the same plan). This
record settles the seam once, before #16 has to build against it, and closes residual 3 of the
#176 tracker comment (2026-08-08): an operating-error run used to note that it started and never
why it failed.

## The decision

`src/pipeline` gains an `Event`/`Event_Kind`/`Observer` vocabulary (`src/pipeline/event.odin`).
Every fault a Recording's own Stages hit — an unreadable source, a failed extraction, an Engine
that refused, a placement that could not write, a GPU health verdict, a refused plan entry — is
built into an `Event` and handed to an `Observer` through `fire`, rather than printed directly.
`report_fault` (`src/pipeline/recording.odin`) is the one place every one of those faults still
funnels through; its signature changed to take the `Observer` and the `Event_Kind`/`at` it reports,
but its build/delete/report shape — and every caller's obligation to hand it an already-built
message it now owns — is unchanged from before this record.

```odin
Event_Kind :: enum u8 {
	Batch_Started = 0, Admitted, Extracting, Transcribing, Progress, Engine_Line,
	Language, Placed, Flagged, Failed, Skipped, Refused, Stopped, Health, Note,
	Batch_Finished,
}

Event :: struct {
	kind:     Event_Kind,
	at:       int,
	percent:  int,
	said:     int,
	factor:   f64,
	from:     process.Progress_Source,
	health:   doctor.Health_Fault,
	source:   string,
	message:  string,
	path:     string,
	language: string,
}

Observer :: struct {
	on_event: proc(event: Event, user: rawptr),
	user:     rawptr,
}
```

Sixteen members are named because the plan named them — the GUI stage (#16) needs the whole
vocabulary to drive rows, and inventing a second name for the same concept later would be the
divergence D5's own reasoning warns against. This PR wires four: `.Failed` (a Recording's own Stage
faulted), `.Refused` (a plan entry `planning.plan_batch` already decided not to run),
`.Health` (the GPU health watch's verdict), and `.Note` (a discovery-time note, `--plan`'s own
`inventory.notes`). The remaining twelve — `.Batch_Started` through `.Batch_Finished` minus those
four — are declared and exhaustively switched over (never left as a silent default case an added
member could fall through), but nothing in this tree produces them yet. That is `#16`'s work, not
this record's.

## Why an `int` index and not a pointer

`at` is an index into the caller's own `plan.entries`, never a pointer to the `Recording_Job` or
`planning.Entry` itself. A pointer to worker-owned memory escaping onto another thread — an
Observer running on the UI thread, once #16 exists — is exactly ADR-0010's hazard, stated there as
"getting this wrong writes one Recording's Transcript from another's audio." An `int` cannot
dangle, and `plan.entries` is owned by the caller for the whole Batch — both `src/cli/batch.odin`
and any future GUI caller hold `defer planning.destroy_plan`. `-1` names "no one Recording, this is
Batch-level" — a swept cache, an identified Engine, a CLI-level operating error before any Plan
exists. `Recording_Job` and `Batch_Options` each carry their own `at`/`observer` fields now,
threaded from `new_recording_job`'s two new trailing parameters (defaulted to `Observer{}` and
`-1`, so every existing caller in this package that builds a `Recording_Job` literal directly, or
calls `new_recording_job` without naming them, is unchanged) through to every fault a Job's own
Stages can hit.

## The borrowed-for-the-call string contract

Every `string` field on `Event` is borrowed for the length of the one `on_event` call that carries
it. The reporting call site builds the message, `fire` hands it to the Observer synchronously, and
the reporting call site frees it (`report_fault`'s own `defer delete`) the instant `fire` returns —
for a `Recording_Job`, the arena backing that string is very often destroyed in the same statement
that follows. This is ADR-0038's own `Refusal_Arg` discipline, restated for a second vocabulary
that carries the identical hazard: **a `string` is a header, and copying the header does not copy
the bytes it points at.** An Observer that needs a string past its own call clones it under an
allocator of its own — `src/pipeline/event_test.odin`'s `capture_event` is the one example of that
shape this record ships, and its own doc comment says so at the point it matters.

## Why `context.logger` is still the wrong answer one layer up

ADR-0036 already ruled `core:log` out for the crash path — `context.logger` is unreachable from
`exception_filter`, which has no `context` at all — and ADR-0039 restated that argument for the
routine trail. The same argument applies here for a different reason: `context.logger` has no
notion of "which Recording," "what percent," or "which `doctor.Health_Fault`" — the exact structured
fields #16 needs to drive a row. Wrapping those into a formatted string and parsing them back out
of a log line on the far side is the "second, parallel vocabulary" D5 already rejects. An `Event`
carries the fields themselves; nothing downstream re-derives them from text.

## The two sinks this PR wires, and the third this PR does not

**Console** (`src/pipeline/console_observer.odin`, `CONSOLE_OBSERVER`): renders the *exact* bytes
`report_fault`/`checked_first_recording_health`'s own fault line always wrote —
`fmt.eprintln(event.message)` for `.Failed`/`.Refused`/`.Note`, `fmt.eprintfln("%s: %s", event.source,
event.message)` for `.Health`. This is the byte-identity obligation the plan calls the review's own
centerpiece: `src/pipeline/transcribe_cli_test.odin`'s three existing drills — each spawning the
real `transcibr-cli` binary and reading its stderr back — pin this by construction, unchanged by
this PR, because they read the process's real stderr rather than any internal call.

**Trail** (`src/pipeline/trail_observer.odin`, folded into `FAULT_OBSERVER` alongside the console
sink): every fault `src/cli` reports now also reaches `crashlog.note` — closing residual 3.
`trail_level_and_subject` is the pure routing table (`.Failed` → `Error`/"fault", `.Refused` →
`Warn`/"refused", `.Health` → `Warn`/"health", `.Note` → `Info`/"note", every other kind → no
subject, meaning "skip"), tested directly in `src/pipeline/event_test.odin` with no file or handle
touched. `pipeline` importing `crashlog` closes no cycle: every import in `src/crashlog/*.odin` is
`core:`/`base:`/`win32`, checked at the pin. `src/cli` itself carries no test of this wiring
(ADR-0009) — the same tradeoff `refuse` already accepted for its own `crashlog.note` call in
176-B, held by review rather than a test, because the glue is one line and the two things it calls
(`write_event_to_console`, `crashlog.note`) are each tested on their own.

**GUI** (#16) is the third sink, deliberately not built here. `Batch_Options.observer` and
`Recording_Job.observer` are the seam; #16 wires a third `Observer` into the same field, nothing
about this record's shape has to change for it to.

## `Health_Watch`'s shape is untouched

The GUI-era plan's own §4 line: "the Observer carries the verdict." `Health_Watch` still carries
exactly the three atomic-bool pointers it carried before this PR (`checked`, `abort`, `unhealthy`)
— `checked_first_recording_health`'s control flow, its atomic stores, and every existing test in
`src/pipeline/recording_test.odin` that exercises it are unchanged. What changed is only how the
health *message* leaves the package: `fmt.eprintfln` became `fire(job.observer, Event{kind =
.Health, ...})`, read by `--batch`'s Batch of many and `--transcribe`'s Batch of one alike, since
both build their `Recording_Job` through the same `new_recording_job`/`checked_first_recording_health`
path (R12 in the plan's own risk register).

## What this record does not do

It does not wire a fourth sink for `.Progress`, `.Engine_Line`, `.Admitted`, `.Extracting`,
`.Transcribing`, `.Language`, `.Placed`, `.Flagged`, `.Skipped`, `.Stopped`, `.Batch_Started` or
`.Batch_Finished` — those are declared, switched over exhaustively, and produced by nothing yet.
It does not touch `report_line` (`src/pipeline/recording.odin`) or the `fmt.println`/blank-`fmt.eprintln`
calls that render a successful placement's path or a progress carriage return — neither is a fault,
and #176's own scope (faults leaving the pipeline as events) does not reach either. It does not
touch `src/crashlog`'s hooks or rotation machinery — 176-C's own territory, left exactly as it
landed. It does not rename `transcibr:crashlog` — the plan's own §11 rider ticket, filed and not
this PR's to pick up.

## Consequences

Fourteen call sites that used to call `report_fault(message, allocator)` directly — four inside
`src/pipeline/recording.odin`, one inside `src/pipeline/batch.odin`, nine inside `src/cli`
(`batch.odin` ×2, `engine_identify.odin` ×2, `main.odin` ×3, `plan.odin` ×1, `transcribe.odin` ×1)
— now pass an `Observer` and an `Event_Kind` alongside the message they always built. Every one of
them in `src/cli` passes `pipeline.FAULT_OBSERVER`, the console-plus-trail fan-out this record
ships; every one of them inside `src/pipeline` reads the `Observer`/`at` off the `Recording_Job` or
`Batch_Options` it already had in scope. The rolling trail gains one new line shape's worth of
bytes per fault a run actually hits — 176-C's own 8 MiB ceiling and its ~120-byte-per-line sizing
already has an order of magnitude of headroom over a 56-Recording Batch's routine trail; a fault
line is one more `note` call of the same shape, not a new format, so that sizing is unchanged in
kind and grows only in the count of lines a Batch with faults now writes versus one with none.
