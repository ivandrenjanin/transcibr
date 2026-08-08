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
	Unset = 0,
	Fail_The_Recording,
	Quarantine_And_Rerun,
	Shorten_And_Replan,
}
```

`Unset` is not a fourth outcome; it is the same sentinel `Fault_Blames` and `Fault_Scope` already
carried, added here because a `FAULT` row missing its `disposition =` line otherwise read back as a
real value instead of refusing — see the compile-check-adjacent guard this cost, in its own section
below.

`process.Fail_The_Job` became `Fail_The_Recording` rather than the other way around. Every
`Build_Fault` that carries it is raised from `child.start`, called once per Recording to spawn
ffmpeg, ffprobe or the Engine — there is no sense in which building that one command line is a "job"
distinct from the Recording it is for. This PR's own description said the rename "removes a name
collision" with `child.Job_Object`; that does not survive a check. `Job_Object` is declared in package
`child`; `Fail_The_Job` was declared in package `process`. Odin resolves an enum member's name inside
its own package and nowhere else, so a member of `process.Disposition` was never capable of colliding
with a struct in `child` — there was no collision there to remove. The real one went unmentioned:
`process` already had a "job" of its own, `Engine_Job` (`src/process/engine.odin`), whose own comment
reads "ONE Recording's" for the audio path and output prefix it carries — the same package, the same
word, the same concept (one Recording's unit of work) `Fail_The_Job` was also reaching for. Keeping
`Fail_The_Job` beside `Engine_Job` would have left one package answering "whose job is this" two
different ways for two different things; that is the collision the rename actually removes.
`transcript.Fail_The_Recording` kept its name outright; `Quarantine_And_Rerun` and `Shorten_And_Replan`
both survive as distinct values rather than collapsing into one generic "retry", because they name two
different actions a caller has to take — quarantining a stale Engine output file is not shortening a
command line, and a reader deciding what to do next needs to know which.

`process` is where the merged type lives, not `transcript`, not a new package, for one reason: every
package that now needs `Disposition` already imports `process` for something else. `child` already
imported it for `Build_Error`. `transcript` gains the one new import this ADR costs — `process` has
no `transcibr:`-internal imports of its own, so this does not create a cycle. A shared package built
solely to hold `Disposition` was considered and rejected — a single enum with two established
importers and no cycle to avoid does not need a package of its own to answer the question the ticket
actually deferred (the fault-report *shape*, table and reader and renderer together, generalised over
an arbitrary enumeration); a bare type is not that shape, and treating the two as one question was
this ADR's own mistake in an earlier draft, corrected below.

An earlier draft of this ADR cited `process.ascii_only` (`src/process/engine.odin`) as "a small pure
helper unrelated to command-line building" and precedent for `process` holding cross-cutting code.
That is backwards, and ADR-0025 is explicit about why: `ascii_only` sits beside `engine_arguments`
rather than in `ffmpeg.odin` next door *because* the placement is load-bearing — ffmpeg re-reads
`GetCommandLineW()` and does not have the ANSI-argv bug ADR-0002 measured, so the check constrains the
Engine's command line specifically, which is exactly half of what ADR-0017 says this package is for.
`ascii_only` is an on-topic resident of `process`, not an off-topic one, and it cannot be cited as
precedent for placing something that is not.

## Where `batch_setup_message` lives, argued on its own

`Disposition`'s placement rests on the import graph above and needs nothing more. `batch_setup_message`
is a different claim and deserves its own argument, which the PR this ADR describes did not give it —
the code comment beside it said only that its two callers "already import `process`", the same
non-argument `ascii_only` was wrongly recruited for, corrected above.

ADR-0017 names what `process` is for: "builds command lines; interprets Engine output lines into
progress and duration events." `batch_setup_message` does neither. It renders one sentence — a
scratch-cache or Model refusal, plus the fixed suffix `" -- the Batch cannot start"` — for `audio` and
`artifact` to call once each, before any Recording is touched and nowhere near a command line or an
Engine output line. On ADR-0017's own terms this is not a Process-contract resident.

ADR-0029 is the real precedent for code with no spec module of its own — `src/version` holds one
struct and one banner-rendering procedure, accepted into its own package rather than folded into
`src/cli` because `src/transcript` also needs it and `src/transcript` cannot import `src/cli` without
a cycle. That argument does not transfer here by itself: `audio` and `artifact` do not import each
other today, so putting `batch_setup_message` in either one and having the other import it would
create no cycle —
unlike `Disposition`, nothing here is *forced* into `process`. "Its consumers already import `process`"
is also not, on its own, a rule that picks `process` out from any other package both consumers happen
to touch: `process` has no `transcibr:`-internal imports, so it is what every core package eventually
imports for *something*, and a rule satisfied by the one universal leaf is not discriminating between
candidates.

So the honest placement argument is smaller than the one given: `batch_setup_message` is three lines
that call `deliverable` (`src/process/command_line.odin`), the same NUL-free, valid-UTF-8, non-empty
guard `Build_Error`'s own renderer, `error_message`, already calls at every one of its three branches —
reusing that guard directly, rather than writing a fourth copy of it in a fourth package, was worth
more than a near-empty package declared solely to hold one function and its one test. That is a
judgement call about proportion, not a structural necessity ADR-0029 or the import graph forces, and
it is recorded as one rather than as an inevitability.

## Every call site that changed meaning

- `src/process/command_line.odin`: `Disposition` moved out to `disposition.odin`; every
  `.Fail_The_Job` in `FAULT` became `.Fail_The_Recording`. `fault_facts` gained a fourth assertion,
  `facts.disposition != .Unset`, paired with `transcript`'s copy of the same check (below).
- `src/process/disposition.odin`: `Disposition` gained a fourth member, `Unset = 0`, on the same
  pattern `Fault_Blames` and `Fault_Scope` already used — a zero value nothing ever means to produce,
  asserted against by both packages' `fault_facts`. Before this, the zero value was
  `Fail_The_Recording`: a `FAULT` row left without a `disposition =` line read back as a real,
  silently wrong answer — the *destructive* one, for faults where the correct default was
  `Quarantine_And_Rerun` in 15 of `transcript`'s 18 rows — rather than refusing to build or to run.
- `src/child/child.odin`: `disposition_of`'s fallback (`.Fail_The_Job`) became `.Fail_The_Recording`.
  Its return type (`process.Disposition`) is unchanged.
- `src/transcript/engine_json.odin`: the local `Disposition` enum is gone. `Fault_Facts.disposition`
  and `disposition_of`'s return type are now `process.Disposition`. The `FAULT` table's own rows are
  unchanged — `.Quarantine_And_Rerun` and `.Fail_The_Recording` still resolve by implicit selector,
  now against the imported type. `fault_facts` gained the same `!= .Unset` assertion as `process`'s.
- `src/artifact/place.odin`: `disposed_of`'s `switch` on `transcript.disposition_of(...)` gained two
  arms it cannot reach from a real `Parse_Fault` today, `case .Shorten_And_Replan:` and
  `case .Unset:`, each calling `unreachable()` explicitly rather than falling through to the trailing
  one. `transcript`'s own `FAULT` table never assigns either value to any `Parse_Fault` — both arms
  exist because the switch is exhaustive over the *type*, which is now shared with a package
  (`process`) that does produce `Shorten_And_Replan`, and because `Unset` is a possible value of the
  type at all, not because either is possible from this caller. What this costs, and what still
  guards it, is its own section below.
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
| `process.Disposition` | consumed by an exhaustive `switch` in `artifact/place.odin` | `place.odin(137:2) Unhandled switch case: Mutant_Case` |

The fourth row is the one this reconciliation adds risk to and is why it is measured separately: the
`Disposition` values a caller has to switch on are no longer decided by the package that raised the
fault alone. Merging the vocabulary could have merged it into something an existing `switch` no
longer covers exhaustively without anyone noticing — instead, the same class of compiler error that
guards a `[Key]Value` table also guards `artifact.disposed_of`'s `switch`, and adding a value neither
`transcript` nor `process` currently produces still fails the build there.

None of the four is disturbed by this change: each fires at the table or switch literal itself, in
the package that owns it, exactly as before.

## What this widening costs, honestly

The four rows above are not the whole of what changed, and saying "none of the four is disturbed"
does not say nothing was. Before this ADR, `transcript.Disposition` had three members and no member
named `Shorten_And_Replan` at all — writing `.Shorten_And_Replan` into a row of `transcript`'s own
`FAULT` table was a name the compiler had never heard of, in that package, full stop. That was never
one of the four measured properties; it was a free side effect of the two vocabularies being distinct
types, and merging them spends it. After this ADR, `transcript.Parse_Fault`'s `FAULT` table can name
`.Shorten_And_Replan` on any row, the build stays clean, and `artifact.disposed_of` reaches its
`case .Shorten_And_Replan: unreachable()` the first time a real Recording carries that fault —
aborting the whole Batch, which is exactly what a `Parse_Fault` is supposed never to do (ADR-0002
disposes of one Recording at a time). Confirmed by mutation: setting `.Cues_Out_Of_Order`'s row to
`.Shorten_And_Replan` and running `.\scripts\build.ps1` prints `Built 1 target(s)` — clean — where the
same edit failed to compile before this ADR landed.

What still stands between that edit and a live abort is two things, neither of them the enumerated-
array or switch-exhaustiveness class of guard the table above proves: the walking test
`every_fault_says_what_adr_0002_does_with_it`, which would fail on the mismatched disposition and
require a developer to *edit* it to get back to green rather than simply deleting a line; and a second,
narrower test added alongside it, `no_parse_fault_ever_asks_to_shorten_a_command_line`, which states
the constraint directly — no `Parse_Fault` disposition is ever `.Shorten_And_Replan` — rather than as
a side effect of an expected-value table a developer could extend without reading what it means.
Neither is a build-time guarantee. `place.odin`'s two cases, `case .Shorten_And_Replan: unreachable()`
and `case .Unset: unreachable()`, are written explicitly rather than left empty so the impossibility
is stated at the point it holds, but they do not and cannot refuse the assignment upstream — a
`#partial switch` there would be strictly worse, deleting the fourth compile-check row above entirely,
which is why the switch stays exhaustive rather than being narrowed.

This is the trade a shared, wider type makes against a narrower one, stated rather than left for a
reader to notice on their own: a compile-time impossibility in the narrow type becomes a runtime
invariant held by test discipline in the wide one. It is accepted here because the alternative — two
`Disposition` vocabularies that cannot answer for each other's faults — is the defect issue #36 opened
on, and because the residual guard, while not a build failure, is a test whose name states the
constraint rather than one a developer can silently widen.

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

## Addendum (issue #63): `refusal_line`'s placement, re-taken at six importers

The "`batch_setup_message` lives here, argued on its own" section above rejected one argument for
`process` as this package's home — "its consumers already import `process`" — as true of every
package `process` has no cycle with, and therefore not discriminating. It kept `process` anyway,
on a narrower, proportion-shaped claim: `batch_setup_message` is three lines that call `deliverable`
(now `refusal_line`), the guard `error_message` already called at every branch of `Build_Error`, and
reusing that guard directly was worth more than a near-empty package built to hold one function and
its one test.

Issue #63 exported `deliverable` as `refusal_line` so `child` (two call sites), `audio` (one call
site), `artifact`, `engine` and `transcript` could call the same non-empty, NUL-free, valid-UTF-8
guard directly, instead of each spelling a weaker, non-empty-only copy of it. That takes the
importer count this ADR argued over from one (`process` itself) to six packages — `process`,
`child`, `audio`, `artifact`, `engine`, `transcript` — which is the point this ADR itself named as
worth re-opening the question rather than inheriting it silently.

The proportion argument still holds, checked again rather than assumed: `refusal_line` is nine
lines including its three asserts (`command_line.odin:167-175`, counted by rule F1's own rule — the
line containing `::` through the closing brace), all of them already read as one small guard, and
none of the five importing packages branch on anything about it beyond "call it last." A package
built solely to hold it would still be as near-empty at six importers as it was argued to be
wrong-sized for at one — the lines that would move are the same nine, and nothing about a sixth or
seventh call site changes their shape. The "its consumers already import `process`" non-argument the
original section rejected is exactly as non-discriminating now: every one of the five importing
packages already imports `process` for something else (`child` and `audio` for
`Build_Error`/`Probe_Fault`, `artifact` for `Disposition` and `Model` plumbing, `engine` for the same
command-line contract `error_message` renders, `transcript` for `Disposition` in `disposition_of`),
so that fact alone still picks out nothing. What answers the question is the same thing it answered
before: `process` already holds `refusal_line`'s one other caller (`batch_setup_message`), the guard
is small enough that a dedicated package for it is a worse trade than it was at one importer, and no
package among the five importing it is a more natural home for a guard about how ANY refusal reaches
a UTF-16 Win32 call — it is not about command lines, Recordings, Engine output, child processes or
Engine JSON specifically, so moving it into one of those five would misname it exactly as `process`
holding it never did. `process` stays the home; five more importers changed the count this ADR
watches, not the argument it made.
