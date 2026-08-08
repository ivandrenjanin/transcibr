# Faults leave `src/pipeline` as events, never as stdio writes

Issue #176, stage 1's fourth and final PR (176-D). The GUI-era planning session's master plan
(`.scratch/sdd/gui-planning/master-plan.md` §5 D5, §11) named this decision once, ahead of the GUI
stage that needs it (#16): `src/pipeline` currently reports every fault by calling `fmt.eprintln`
or `fmt.println` directly (`report_fault`/`report_line`, `src/pipeline/recording.odin`), which is a
console-subsystem assumption a GUI-subsystem binary cannot share — `fmt.eprintln`, like every other
stdio write, silently disappears into a NULL handle in that binary (§2.4 of the same plan). This
record settles the seam once, before #16 has to build against it, and closes residual 3 of the
#176 tracker comment (2026-08-08): an operating-error run used to note that it started and never
why it failed. Fix round 1 (PR #285's review, finding 4, Important) found residual 3 only partly
closed at this record's first pass: three `src/cli` fault sites -- `transcribe.odin`'s no-file-stem
refusal, `main.odin`'s partial-stdout-write refusal, and `plan.odin`'s collision/incomplete refusal --
still wrote to stderr with a bare `fmt.eprintfln`/`fmt.eprintln` and recorded nothing in the trail.
All three now route through `pipeline.report_fault(pipeline.FAULT_OBSERVER, ...)` like every other
fault site in `src/cli`; residual 3 is closed by every fault site as of this fix round, not most of
them.

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
event.message)` for `.Health`. Fix round 1 (PR #285's review, finding 2, Important) corrects a false
claim this section originally made here: `src/pipeline/transcribe_cli_test.odin`'s three real-binary
drills do **not** pin this by construction — they are `strings.contains` substring checks, and the
reviewer mutated the `.Failed`/`.Refused`/`.Note` arm to print `"REVIEW-MUTANT %s"` and measured `just
test` exit 0, all suites green. `src/pipeline/console_observer_test.odin`
(`write_event_to_console_pins_the_exact_stderr_bytes_for_every_wired_kind`) is the byte-identity pin
that was missing: it redirects `os.stderr` to a pipe for one call and asserts the exact bytes, for
every `Event_Kind` this sink renders.

**Trail** (`src/pipeline/trail_observer.odin`, folded into `FAULT_OBSERVER` alongside the console
sink): every fault `src/cli` reports now also reaches `crashlog.note`. `trail_level_and_subject` is
the pure routing table (`.Failed` → `Error`/"fault", `.Refused` → `Warn`/"refused", `.Health` →
`Warn`/"health", `.Note` → `Info`/"note", every other kind → no subject, meaning "skip"), tested
directly in `src/pipeline/event_test.odin` with no file or handle touched. `pipeline` importing
`crashlog` closes no cycle: every import in `src/crashlog/*.odin` is `core:`/`base:`/`win32`, checked
at the pin. `src/cli` itself carries no test of this wiring (ADR-0009) — the same tradeoff `refuse`
already accepted for its own `crashlog.note` call in 176-B, held by review rather than a test,
because the glue is one line and the two things it calls (`write_event_to_console`, `crashlog.note`)
are each tested on their own.

Fix round 1 (PR #285's review, finding 1, Critical) added `trail_mutex` (a package-private
`sync.Mutex` in `src/pipeline/trail_observer.odin`) around the `crashlog.note` call inside
`write_event_to_trail`. `crashlog.note` composes a line as six to nine separate unlocked `WriteFile`
calls with no lock and no composed buffer (`src/crashlog/record.odin`'s `record_note_line`), which was
safe only as long as every caller ran on `src/cli`'s one main thread. This record's own seam broke
that: `write_event_to_trail` is now reached from worker threads inside `extract_recording`,
`transcribe_and_place` and `checked_first_recording_health` (`spawn_extract_workers`, `run.odin`), and
the reviewer measured 7 of 61 real trail lines torn in one `--batch` run over two extract workers, and
581 of 640 torn in a deterministic 8-thread isolation probe against `crashlog.note` directly. The real
fix — composing one line into a caller-owned buffer and issuing one `WriteFile` — belongs to
`src/crashlog`, which this record's own fence excludes; `trail_mutex` closes the race from this side
instead by serializing every call this package makes into `crashlog.note`, the only path a worker
thread reaches it through today (every other `note` call site — `refuse`, `main`'s own process start —
still runs on the CLI's single main thread).
`src/pipeline/trail_observer_test.odin`'s
`write_event_to_trail_serializes_concurrent_calls_through_trail_mutex` proves a second caller blocks
for as long as the first holds `trail_mutex`, without opening a real crashlog file in-process (see
"Testing `write_event_to_trail` itself" in the implementer report for why that stays out of scope).

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

Seventeen call sites now pass an `Observer` and an `Event_Kind` alongside the message they always
built — four inside `src/pipeline/recording.odin`, one inside `src/pipeline/batch.odin`, twelve
inside `src/cli` (`batch.odin` ×2, `engine_identify.odin` ×2, `main.odin` ×4, `plan.odin` ×2,
`transcribe.odin` ×2; the count was fourteen and nine respectively at this record's first pass — see
the opening section above for the three `src/cli` sites fix round 1 added: `main.odin`'s
partial-stdout-write refusal, `plan.odin`'s collision/incomplete refusal, and `transcribe.odin`'s
no-file-stem refusal). Every one of
them in `src/cli` passes `pipeline.FAULT_OBSERVER`, the console-plus-trail fan-out this record
ships; every one of them inside `src/pipeline` reads the `Observer`/`at` off the `Recording_Job` or
`Batch_Options` it already had in scope. The rolling trail gains one new line shape's worth of
bytes per fault a run actually hits — 176-C's own 8 MiB ceiling and its ~120-byte-per-line sizing
already has an order of magnitude of headroom over a 56-Recording Batch's routine trail; a fault
line is one more `note` call of the same shape, not a new format, so that sizing is unchanged in
kind and grows only in the count of lines a Batch with faults now writes versus one with none.
