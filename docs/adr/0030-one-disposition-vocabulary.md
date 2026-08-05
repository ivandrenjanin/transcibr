# One `Disposition` vocabulary, living in `process`, and one spelling of "the Batch cannot start"

Issue #36 found two enumerations answering one question — does resolving this fault mean the
Recording it is about can be tried again, or is it done? `process.Disposition` answered
`Fail_The_Job` or `Shorten_And_Replan`, for the seven ways a command line refuses to be built
(ADR-0019). `transcript.Disposition` answered `Quarantine_And_Rerun` or `Fail_The_Recording`, for
the eighteen ways the Engine's JSON refuses to parse (ADR-0002). `src/child/child.odin` already
imported the first, to answer the same question about a Child that never started at all. A reader
who knew one vocabulary could not answer for a fault raised in the other, and the ticket that found
this named it as the part most likely to produce a real defect — not a copy count, a divergent
answer to the same question asked of two different fault trees.

The orchestrator narrowed issue #36 to two things, deferring the harder question of whether the
whole fault-report shape (a table, a checked reader, a renderer) can be extracted generically over
an arbitrary fault enumeration while keeping the enumerated-array missing-row compile check. That
question is still open. This ADR answers the narrower one: reconcile the two `Disposition`
enumerations, and spell the sentence `" -- the Batch cannot start"` once.

## What survived, and why `process` holds it

One `Disposition`, in `src/process/disposition.odin`:

```odin
Disposition :: enum u8 {
	Fail_The_Recording = 0,
	Quarantine_And_Rerun,
	Shorten_And_Replan,
}
```

`process.Fail_The_Job` became `Fail_The_Recording` rather than the other way around. Every
`Build_Fault` that carries it is raised from `child.start`, called once per Recording to spawn
ffmpeg, ffprobe or the Engine — there is no sense in which building that one command line is a "job"
distinct from the Recording it is for, and "job" was already spoken for in this package for
something else entirely (`child.Job_Object`, a Windows kernel object). `transcript.Fail_The_Recording`
kept its name outright; `Quarantine_And_Rerun` and `Shorten_And_Replan` both survive as distinct
values rather than collapsing into one generic "retry", because they name two different actions a
caller has to take — quarantining a stale Engine output file is not shortening a command line, and a
reader deciding what to do next needs to know which.

`process` is where the merged type lives, not `transcript`, not a new package, for one reason: every
package that now needs `Disposition` already imports `process` for something else. `child` already
imported it for `Build_Error`. `transcript` gains the one new import this ADR costs — `process` has
no `transcibr:`-internal imports of its own, so this does not create a cycle. There is also a direct
precedent for `process` carrying a small pure helper unrelated to command-line building:
`process.ascii_only`, defined beside the Engine output-line reader (`src/process/engine.odin`) and
already imported by `artifact`, `audio` and `engine` for a check that has nothing to do with either
half of the Process contract. A shared package built solely to hold `Disposition` was considered and
rejected — it would be the generic-extraction question's own shape (a package for one cross-cutting
fault concept) without answering the question the ticket actually deferred, for a single enum that
already has a natural, well-imported home.

## Every call site that changed meaning

- `src/process/command_line.odin`: `Disposition` moved out to `disposition.odin`; every
  `.Fail_The_Job` in `FAULT` became `.Fail_The_Recording`.
- `src/child/child.odin`: `disposition_of`'s fallback (`.Fail_The_Job`) became `.Fail_The_Recording`.
  Its return type (`process.Disposition`) is unchanged.
- `src/transcript/engine_json.odin`: the local `Disposition` enum is gone. `Fault_Facts.disposition`
  and `disposition_of`'s return type are now `process.Disposition`. The `FAULT` table's own rows are
  unchanged — `.Quarantine_And_Rerun` and `.Fail_The_Recording` still resolve by implicit selector,
  now against the imported type.
- `src/artifact/place.odin`: `disposed_of`'s `switch` on `transcript.disposition_of(...)` gained a
  third arm, `case .Shorten_And_Replan:`, empty, falling through to the existing `unreachable()`.
  `transcript`'s own `FAULT` table never assigns that value to any `Parse_Fault` — the arm exists
  because the switch is exhaustive over the *type*, which is now shared with a package that does
  produce it, and not over what this one caller happens to receive.
- `src/audio/fault.odin` and `src/artifact/model.odin`: `cache_error_message` and
  `model_error_message` now call the one shared `process.batch_setup_message` instead of each
  spelling `fmt.aprintf("%q: %s -- the Batch cannot start", ...)` itself. Their signatures and
  rendered output are unchanged.

## The compile check, proved per package

The property in question: a fault enumeration that gains a member without a matching row fails the
**build**, not a test. Measured against `dev-2026-07-nightly:819fdc7` at `C:\Odin\dist`, by adding one
`Mutant_Case` member to each affected enumeration in turn, leaving its table untouched, running
`.\scripts\build.ps1`, and reverting:

| enumeration | shape | build output |
|---|---|---|
| `process.Build_Fault` | enumerated-array `[Build_Fault]Fault_Facts` | `command_line.odin(57:10) Unhandled enumerated array case: Mutant_Case` |
| `transcript.Parse_Fault` | enumerated-array `[Parse_Fault]Fault_Facts` | `engine_json.odin(60:10) Unhandled enumerated array case: Mutant_Case` |
| `child.Fault` | enumerated-array `[Fault]string` | `child.odin(35:10) Unhandled enumerated array case: Mutant_Case` |
| `process.Disposition` | consumed by an exhaustive `switch` in `artifact/place.odin` | `place.odin(134:2) Unhandled switch case: Mutant_Case` |

The fourth row is the one this reconciliation adds risk to and is why it is measured separately: the
`Disposition` values a caller has to switch on are no longer decided by the package that raised the
fault alone. Merging the vocabulary could have merged it into something an existing `switch` no
longer covers exhaustively without anyone noticing — instead, the same class of compiler error that
guards a `[Key]Value` table also guards `artifact.disposed_of`'s `switch`, and adding a value neither
`transcript` nor `process` currently produces still fails the build there.

None of the four is disturbed by this change: each fires at the table or switch literal itself, in
the package that owns it, exactly as before.

## What did not need the apparatus

Unchanged by this ADR, and deliberately: `Riff_Fault` (`src/audio/riff.odin`) and
`process.Probe_Fault` (`src/process/ffmpeg.odin`) are bare enumerations their one consumer renders
with `%v` — no sentence table, no `Disposition`, because nothing downstream branches on what they
say beyond naming them. `audio.Cache_Fault` and `artifact.Model_Fault` keep their `switch`-shaped
sentence readers (`cache_fault_says`, `model_fault_says`) and take no `Disposition` at all: both are
raised once, before any Recording is touched, and both only ever mean the Batch cannot start — there
is no second outcome for a reader to distinguish, so the field would carry one constant value across
every row it has. The counter-example the ticket named stands: not every fault needs a `Disposition`,
and not every fault needs a table.

## What reopens this

The generic-extraction question issue #36 deferred: whether the fault-report shape itself (a table, a
checked reader, a renderer) can be written once, parametrically, over an arbitrary fault enumeration,
without losing the enumerated-array missing-row compile check the table above proves each copy still
has. That question is unrelated to which package spells `Disposition`, and this ADR does not answer
it. It is reopened by whoever picks that half back up.
