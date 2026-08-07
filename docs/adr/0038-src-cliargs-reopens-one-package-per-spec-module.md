# `src/cliargs` gives the command-line grammar a tested package, reopening ADR-0017 the way ADR-0029 already did

ADR-0017 puts one Odin package on each spec module the maintainer confirmed, named for the module,
and its own consequences name the way out: "a third package that turns out to hold half of a spec
module is this decision being reopened, not applied." `src/cli` answers to the spec's
command-line-front-end module (ADR-0029's own accounting of the four core, nine shell and two
interface modules). `src/cliargs` answers to the same module and holds none of a second one — it is
not a second front end, it is the first one's grammar, moved to where it can be tested. This is
that reopening, recorded the way ADR-0029 recorded `src/version` breaking the same rule in the
opposite direction: not a module split in two, but no module at all standing over the new package.

**Maintainer ruling, 2026-08-06 (issue #75): Approved.** This ADR restates that ruling as a decision
record. It is Stage 1 of #75 — the ADR lands before any code moves. Nothing in `src/cli` changes here.

## The case

`src/cli` carries `#+vet explicit-allocators` and nothing else that would let it hold a decision
worth testing: it is `cli`, the one package `tools\policy`'s `TEST_LESS_SRC_PACKAGES` roster (formerly
`$OdinPackagesWithoutTests`) exempts from ever collecting a test at all (ADR-0009). ADR-0009's own
prescription is the exit this ticket takes: "the moment a decision worth testing turns up in
`src/cli`, it belongs in the core instead." Three defects already measured that decision landing in
the wrong place:

- **#70** — the engine_version regression. ADR-0027 named the root cause: "`src/cli` ... could not
  be turned red — which is how this one got in."
- **#94's review** (PR #124, merged 1249948) — `src/cli/batch.odin`'s `read_batch_option` still pairs
  an option name with its destination field by hand
  (`case "--extract-workers": read_batch_worker_option(&o.extract_workers, name, value)`); swapping
  two fields there is undetectable under ADR-0009, and no pipeline test observes it. **The maintainer's
  #94 deposit on this issue names the fix for that specific defect, and this record adopts it: the
  enum-keyed table shape #124 already introduced for the worker ceilings
  (`pipeline.Worker_Option_Ceiling`/`worker_option_ceiling`, `pipeline.odin:57-75`, walked by
  `worker_option_ceilings_pair_each_option_with_its_own_max` in `defaults_test.odin:109-131`) closes
  the hand-pairing defect too once the grammar moves — a mispairing can then only live in one
  table, where a test walks it and catches a swap the same way it already catches a swapped ceiling.**
- **#76's deposit** (PR #166, merged 97e6dca) — the round-5 CRITICAL in that loop
  (`context.assertion_failure_proc` assigned inside an `if`, so the shipping binary carried no
  assertion capture at all) survived five review rounds specifically because nothing automated
  covers `src/cli`.

The duplication is measured on the current tree, re-verified against the numbers the ticket opened
with (which predate #35 and #50, both of which touched `src/cli` since):

- **The pair-off loop is byte-identical, 8 of 9 lines, at four sites** —
  `src/cli/main.odin:290-298` (`read_options`), `src/cli/batch.odin:278-286` (`read_batch_options`),
  `src/cli/plan.odin:232-240` (`read_plan_options`), `src/cli/transcribe.odin:158-166`
  (`read_transcribe_options`). The one line that differs at each site is which single-command reader
  it calls (`read_option`, `read_batch_option`, `read_plan_option`, `read_transcribe_option`).
  **A fifth, uncounted site carries the identical shape**: `src/cli/doctor.odin:74-82`
  (`read_doctor_options`) is the same loop calling `read_doctor_option`. The ticket's acceptance
  criteria name four; this ADR records the fifth as evidence the case is, if anything,
  under-measured — resolving whether `--doctor` migrates too is a call for the migration PRs, not
  this one.
- **The required-option sweep is byte-identical in shape at three sites**: `batch.odin:289-298`,
  `plan.odin:242-251`, `transcribe.odin:170-179`, each a `for missing in ([?][2]string{...})` loop
  refusing the first empty required field. `doctor.odin:85-89` carries a smaller version of the same
  shape. `main.odin`'s `read_options` does not use it — it checks `--from-json`'s one required field
  by hand (`main.odin:300-302`).
- **`--profile` parsing recurs at three sites**: `main.odin:325-330`, `plan.odin:274-279`, and
  `read_common_option`'s own case (`transcribe.odin:253-258`), shared by `--batch` and
  `--transcribe`.
- **`read_common_option` takes six out-pointers plus name and value, eight arguments total**
  (`transcribe.odin:225-236`: `model`, `engine_exe`, `cache`, `tools`, `prompt`, `profile`, `name`,
  `value`) — down from the seven the ticket counted, because #50 retired the `--engine-version`
  out-pointer this same procedure used to thread. The shape of the problem — a signature that grows
  by one pointer per new shared option, at every call site that supplies it — is unchanged; only the
  count has drifted, which is exactly why this record cites line numbers rather than repeating the
  ticket's totals as fact.
- **The #50 deposit, for the grammar's design**: `--from-json` still accepts `--engine <version>` as
  free text feeding the same `Render_Context.engine_version` field that `--transcribe` now fills
  with a SHA-256 digest — two different kinds of value reaching one key, visible from the grammar
  alone (`main.odin:323-324` versus `transcribe.odin`'s digest path). The USAGE trailer's "anything
  not given, or given empty, is recorded as unknown" sentence is now true for `--from-json` only.
  This ADR names both as problems for the grammar package to resolve when it is born — resolving
  them is out of scope for Stage 1.

Honest size: the ticket's own estimate (~5 new files, ~300-450 non-test lines moved or rewritten,
200-400 test lines) predates #35 and #50; `src/cli` today totals 1606 lines across its six files
(`main.odin` 425, `batch.odin` 370, `plan.odin` 284, `transcribe.odin` 263, `crash_drill.odin` 153,
`doctor.odin` 111). The migration PRs re-measure at each step rather than this record pinning a
total that will drift again before the first one lands.

## What it holds, and why it is not folded into `src/cli`

The grammar — every `Options` struct, every `read_*_option(s)` procedure, the required-field sweeps,
`--profile` parsing, and the refusal MESSAGES as pure values — moves to `src/cliargs`. What stays in
`src/cli`, per the maintainer's ruling, is everything that is not a decision:

- the **non-allocating stderr write** (`refuse`/`write_usage`, `main.odin:405-425`) — a refusal that
  allocated to explain itself is one more thing that can fail at the moment least worth failing at,
  and that constraint is deliberate, not an oversight to lift when the grammar moves;
- the **job-object prologue** (`job_object_opened`, `main.odin:389-403`);
- the **Ctrl+C handler** (`console_ctrl_handler`, `batch.odin:71-82`) — `proc "system"`, no Odin
  `context`, nothing a package with no vet tag of its own should hold;
- **model and engine identification I/O** (`model_identified`, `engine_identified`,
  `main.odin:344-381`) — both open a file and hash it;
- **pipeline wiring** — `planned_and_run`, `run_the_batch`, `run_one`, `report_plan`, the calls into
  `transcibr:pipeline`, `transcibr:planning`, `transcibr:artifact`, `transcibr:doctor`.

The grammar returns its verdict — an `Options` struct and an `ok`, or a refusal — as a VALUE.
`src/cliargs` never writes to `os.stderr` itself; `src/cli` still does, via the same non-allocating
path it uses today.

**The refusal is data, not a built string — 19 of `src/cli`'s 22 `refuse` call sites interpolate a
runtime value, and this record picks the shape that keeps that data unallocated.** A refusal carries
the same complaint FORMAT STRING `refuse` already owns as a constant (`"%s takes a whole number from
1 to %d, not %q."` and the rest), plus the concrete arguments that format string needs — measured on
the tree, at most three per site (an option name, an offending value, and a ceiling; `%s takes a
whole number from 1 to %d, not %q.` is the widest one, and no site needs more). Those arguments ride
in typed fields on the refusal value itself, not behind a `..any` slice — a fixed struct needs no
backing allocation to populate, where a slice does. `src/cliargs` never calls `fmt.eprintf`,
`fmt.aprintf`, or anything else that allocates, so it never needs the `#+vet explicit-allocators`
file tag (M2/ADR-0010) or an `allocator: mem.Allocator` threaded through a single grammar entry
point — there is nothing in the package for that tag to police. `src/cli`'s `refuse` interpolates the
returned format string against the returned arguments with the same `fmt.eprintf(complaint, ..args)`
call it makes today, now fed by a value instead of building one itself; the non-allocating property
this section already claims for `refuse`/`write_usage` (lines 83-85) holds on both sides of the move,
not only in `src/cli`.

**Import closure: `transcibr:transcript` and `transcibr:process` only.** Neither imports
`transcibr:child`, `transcibr:audio`, or `transcibr:pipeline` (verified on the current tree: `process`
imports only `core:*` packages; `transcript` imports `core:*`, `transcibr:process` and
`transcibr:version`). `audio` and `pipeline` both import `transcibr:child` — pulling either into
`src/cliargs`'s closure would pull `child` in behind it, which the ruling rules out. Two
consequences follow directly, both already precedented on the current tree rather than invented for
this package:

- **A two-string tools struct of its own**, not `audio.Tools`. `src/cliargs` reads `--ffmpeg` and
  `--ffprobe` into a plain `{ffmpeg, ffprobe: string}` it owns; `src/cli` copies those two fields
  into an `audio.Tools` and calls `audio.defaulted_tools` on it after the grammar returns, the same
  place `defaulted_batch`/`read_transcribe_options`/`read_doctor_options` already call it today —
  after the read loop, never before, so `--ffmpeg ""` still overwrites the default rather than being
  overwritten by it.
- **The worker-count ceiling as a parameter, not an import — and the lookup has to move with it.**
  `read_worker_count` already takes `ceiling: int` rather than reaching into
  `pipeline.MAX_QUEUE_DEPTH` or `pipeline.MAX_EXTRACT_WORKERS` directly (`batch.odin:246-252`,
  closing issue #94's finding: an over-ceiling value on one option no longer sails past a refusal
  keyed to the other option's ceiling). But `read_worker_count` is not where `pipeline` is reached
  for today: `read_batch_worker_option` (`batch.odin:335-348`) — one of the `read_*_option`
  procedures this ADR schedules to move — is the one that calls `pipeline.worker_option_ceiling(name)`
  to find the ceiling and formats the pinned refusal `"%s takes a whole number from 1 to %d, not
  %q."` with it. Moving that procedure verbatim would pull `pipeline`, and behind it `transcibr:child`,
  into `src/cliargs`'s closure, which the ruling rules out. The shape that keeps the fence closed:
  `src/cliargs` keeps a worker-option reader shaped like `read_worker_count` itself — it takes
  `ceiling: int` and the already-formatted refusal text as parameters, never looks up a ceiling by
  option name, and never imports `pipeline`. The lookup (`pipeline.worker_option_ceiling`) and the
  refusal-message formatting stay in `src/cli`, called immediately before the grammar's per-option
  dispatch, the same way `src/cli` already resolves `--ffmpeg`/`--ffprobe` into an `audio.Tools`
  after the read loop rather than inside it. This is `read_natural`'s own `max_digits` precedent
  (`process/engine.odin:199`, `artifact/sidecar.odin`'s `MAX_SIDECAR_DIGITS`) applied a second time:
  the CONSUMER supplies the ceiling, the reader only checks it — except here the consumer is
  `src/cli`, not the grammar package, because only `src/cli` may know `pipeline` at all.
  **Defaults are a separate, already-closed case, not a second breach.** `defaulted_batch`
  (`batch.odin:355-370`) reads `pipeline.DEFAULT_EXTRACT_WORKERS` and `pipeline.DEFAULT_QUEUE_DEPTH`,
  but it runs after the read loop returns, on the `Options` struct the grammar handed back — the same
  place it calls `audio.defaulted_tools` today. It never moves to `src/cliargs`; it is exactly the
  "pipeline wiring" this ADR already lists as staying in `src/cli` (line 91-92), and its import of
  `pipeline` was never part of the grammar's closure to begin with.

**`Common_Options` embeds via `using` in `Batch_Options` and `Transcribe_Options` only.**
`Batch_Options` and `Transcribe_Options` share all six fields `read_common_option` threads today
(`model`, `engine`, `cache`, `tools`, `prompt`, `profile`); a `Common_Options` struct holding exactly
those six, embedded with `using`, replaces both structs' hand-copied field lists and the six-pointer
threading `read_common_option` does today with one call taking `^Common_Options`.

`Plan_Options` does **not** embed it. On the current tree `Plan_Options` reads `--model-file` and
`--engine-exe` (`plan.odin:266-269`) — it does not refuse those two — but it has no `cache` field and
no `tools` field, and `read_plan_option`'s `case:` refuses `--cache`, `--ffmpeg` and `--ffprobe` as
unknown options, same as any other name it does not list (A8: an option outside the grammar a command
accepts is refused, not silently accepted into a field that happens to exist because a shared struct
carries it). `Plan_Options` keeps its own four-field subset — `model`, `engine`, `prompt`, `profile` —
copied by hand rather than embedded, because embedding `Common_Options` would give `Plan_Options` a
live `cache` field and a live `tools` field there is no reader for, and the day some future edit adds
one by accident is the day `--plan --cache X` stops being refused without anyone deciding it should.
One struct forced over all three commands trades that deliberate refusal for a shared shape; the
ruling keeps the refusal.

## Consequences

`src/cliargs` is core by ADR-0009's own test — decisions worth testing, touching nothing outside
themselves once the tools struct and the ceiling parameter close its import closure — and
package-per-spec-module (ADR-0017) does not gate it cleanly, because a second package under one
module is the case ADR-0017's own consequences section names as a reopening rather than a violation.
Recorded here, as ADR-0029 recorded the opposite drift, so the next reader does not read this as the
kind of quiet split ADR-0017 warned against and leave it for a later ticket to justify.

**Expand–contract, one command migrated per PR, readers deleted last.** `src/cliargs` stands up
beside the four (now: five, `doctor.odin` included) readers still in `src/cli`. Each migration PR
moves one command's grammar, rewires that command's `src/cli` entry point to call the new package,
and leaves the old reader in place until every caller of it is gone — never a big-bang cutover that
makes one PR's diff the only chance to catch a byte-changed refusal string. Every refusal string and
its ordering (the complaint, the blank line, the usage block — `refuse`'s own three-part shape) must
be byte-identical before and after each migration, pinned in `src/cliargs`'s own tests: a caller
scripting against this binary's stderr today reads the identical bytes after the grammar moves.

**`src/cli`'s remaining files hold no decision under #74's audit rubric** once migration completes —
the four commands' pipeline wiring, I/O and non-allocating write, and nothing a `red` test could ever
have caught staying in the one package that can never turn red.

## What reopens this

A command whose grammar cannot fit `Common_Options` or the two-string tools struct — one that needs
`transcibr:child` or `transcibr:pipeline` in its own read loop rather than in what `src/cli` does
with the parsed result — is the point at which either this package's import closure grows past what
this record justifies, or that command's grammar stays a `src/cli` reader by name instead. Until
then: two imports, `transcript` and `process`, and nothing named here stands over a spec module of
its own.
