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
  #94 deposit on this issue names the fix for that specific defect, and this record adopts it, in the
  form the grammar package can actually take.** #124 built the precedent, and that precedent is a
  table keyed by STRINGS, not by an enum: the pairing is declared ONCE, as data, in
  `WORKER_OPTION_CEILINGS` — a `[?]Worker_Option_Ceiling` array of `{name: string, ceiling: int}`
  rows, searched linearly by `worker_option_ceiling` (`pipeline.odin:57-75`) — one row per option
  name, adjacent and reviewable, walked by one test
  (`worker_option_ceilings_pair_each_option_with_its_own_max`, `defaults_test.odin:109-132`).
  **`src/cliargs` UPGRADES that precedent to a genuinely enum-keyed `[Worker_Option]int` table**,
  the natural shape once the grammar package owns the option vocabulary as an enum rather than as
  bare strings — no enum for worker options exists anywhere in `src/pipeline` or `src/cli` today,
  which is why #124 could not have written one. The upgrade is what buys compiler-enforced
  exhaustiveness: an enumerated array that leaves a key unfilled does not build (`Unhandled
  enumerated array case`, the CLAUDE.md enumerated-array note), where #124's string-keyed array with
  a row deleted builds clean under the full vet set and runs. That is what closes the hand-pairing
  defect structurally once the grammar moves — the pairing is explicit adjacent data and every
  option must appear. It does not make a WRONG ceiling in a correctly named row compiler-detected;
  review sees that one.
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
  `plan.odin:242-250`, `transcribe.odin:170-179`, each a `for missing in ([?][2]string{...})` loop
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
  `context` at entry, so S3 requires it to rebuild one from stored state before touching anything
  allocator- or logger-dependent; that stored state is the batch-run wiring `src/cli` already holds,
  which is the reason it stays there, not the file's vet tag (`src/cliargs` carries
  `#+vet explicit-allocators` too, like every file in the tree — see the allocation-tag paragraph
  below);
- **model and engine identification I/O** (`model_identified`, `engine_identified`,
  `main.odin:345-381`) — both open a file and hash it;
- **pipeline wiring** — `planned_and_run`, `run_the_batch`, `run_one`, `report_plan`, the calls into
  `transcibr:pipeline`, `transcibr:planning`, `transcibr:artifact`, `transcibr:doctor`.

The grammar returns its verdict — an `Options` struct and an `ok`, or a refusal — as a VALUE.
`src/cliargs` never writes to `os.stderr` itself; `src/cli` still does, via the same non-allocating
path it uses today.

**The refusal is data, not a built string, and it keeps `refuse`'s own arity — 19 of `src/cli`'s 22
`refuse` call sites interpolate a runtime value, arity 0-3, three being the widest
(`read_batch_worker_option`, `batch.odin:345`), and every interpolated value measured on the tree is a
`string` or an `int` (the `%s`/`%q` and `%d` verbs `refuse`'s callers use).** The other three
interpolate nothing at all (`main.odin:301`, `crash_drill.odin:61`, `crash_drill.odin:78`), which is
the arity-0 end of that same range. A `Refusal` cannot carry
those arguments as `[3]any`: converting a value to `any` stores a POINTER to it
(`Any :: struct {data: rawptr, id: typeid}`), and the values a grammar procedure converts are its own
parameters and locals, so a `Refusal` returned BY VALUE would carry pointers into a stack frame that
no longer exists once the call returns — before `src/cli` ever reads them. That is not fixed by moving
the `any` conversion later, either: a helper that type-switches over typed args and writes each `case`
branch's loop-local variable into an `any` has the identical defect one function-call boundary later,
because that loop-local dies at the end of its own scope and the returned `any` is left pointing at
it. (Measured directly: a probe shaped exactly that way — a `build_args` helper returning `[3]any`
built from a `switch v in a { case string: out[i] = v }` loop — printed
`takes a whole number from 1 to 140696839124424, not ""` for the same inputs that print correctly
below; probe discarded.) Instead, `Refusal` carries a fixed `args: [3]Refusal_Arg` backing array,
addressed by `arg_count: int`, where `Refusal_Arg :: union {string, int}` holds the value ITSELF
inside the union's own storage, not a pointer to somewhere else — copying a `Refusal` copies the
union's bytes with it, so the value stays valid on whichever frame currently holds the `Refusal`.
**This closes the `any`-pointer defect but does not, by itself, make every `string` arm safe:** a
`string` is itself a header — `{data: ^byte, len: int}` — copied by value into the union, but the
bytes that header POINTS AT are not copied with it. An `args[i] = local_buf_slice` built from a
frame-local backing array (a `[N]byte` formatted in place, then sliced to a `string`) dangles exactly
the way the `[3]any` shape did, one field narrower: the union's own bytes survive the copy, the text
they point at does not. Each of the 19 sites that interpolates anything interpolates at least one
`string`, and every one of those strings is either an argv slice (`name`, `value`, `mode`), a
`[2]string` table element (`missing[1]`), or a compile-time constant (`FOLLOW_CHOICE`,
`plan.odin:23`) — all of which outlive the `Refusal` they are
stored in by construction, so nothing on the current tree hits this — but the requirement is on the
call site, not on the union: a `Refusal_Arg`'s `string` arm is safe exactly when its backing bytes
outlive the `Refusal` value carrying it, which argv slices and string literals satisfy and a
frame-local formatting buffer does not. `src/cliargs`'s readers, once written, must build every
interpolated string from argv or a constant, never from a local buffer, for this shape to hold. And
`src/cli`'s `refuse(complaint: string, args: []Refusal_Arg) -> bool` takes the union slice directly
rather than a pre-built `[]any` at all. Inside `refuse`, and only there, two small fixed backing
arrays sized to the same arity — `strs: [3]string`, `ints: [3]int`, both local to `refuse`'s own
frame — receive each argument's concrete value by a `switch v in a`, and the `any` handed to
`fmt.eprintf` is built from THOSE locals (`built[i] = strs[i]` / `built[i] = ints[i]`), which live for
the whole of `refuse`'s call and are never returned past it. This is the shape that actually holds:
verified by probe — `refuse("--extract-workers", 2, "99")`'s `Refusal`, built one frame up, returned
by value, and read through a second local copy after 64 ints of intervening stack traffic, printed the
exact pinned string, `--extract-workers takes a whole number from 1 to 2, not "99".`, byte for byte;
probe discarded. A one-argument refusal slices the arrays down to one element, so `fmt.eprintf` never
receives an unused `any` it would print as trailing `%!(EXTRA ...)` bytes. Nothing here allocates: the
fixed `[3]Refusal_Arg` embedded in the returned value and the fixed `strs`/`ints`/`built` arrays
`refuse` fills on its own stack all call no allocator, where `make`ing a `[]any` would. `src/cliargs`
never calls `fmt.eprintf`, `fmt.aprintf`, or anything else that allocates — but that does not exempt it
from the `#+vet explicit-allocators` file tag (M2/ADR-0010): the tag's scope in
`tools/policy/check.odin`'s `vet_tag_roster` is `.Every`, every `.odin` file `discover_odin_files`
walks (the repository root minus `.git`, `build`, `.scratch`, `.tools`), unconditional on whether the
file itself allocates, and `src/cliargs` carries the tag above its `package` clause like every other
file in the tree — `just check` refuses a file without it regardless of what the file does. `src/cli`'s
`refuse` still makes the one `fmt.eprintf` call it makes today, now fed by a returned `Refusal`'s
union slice instead of a literal format string and inline `any` arguments; the non-allocating property
this section already claims for `refuse`/`write_usage` (lines 100-102) holds on both sides of the move,
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
- **The worker-count ceiling as a parameter, not an import — but the BOUND CHECK is a second,
  narrower breach the ceiling-as-parameter shape does not close by itself.** `read_worker_count`
  takes `ceiling: int` rather than reaching into `pipeline.MAX_QUEUE_DEPTH` or
  `pipeline.MAX_EXTRACT_WORKERS` directly, which closes issue #94's finding (an over-ceiling value on
  one option no longer sails past a refusal keyed to the other option's ceiling) — but its body still
  calls `pipeline.worker_count_within_ceiling(int(parsed), ceiling)` to apply that ceiling
  (`batch.odin:248`), and that call is itself a `pipeline` import, which pulls in `transcibr:child`
  behind it (`pipeline`'s own `recording.odin:17` and `run.odin:14`). Taking `ceiling` as a parameter
  closes the LOOKUP breach (which option's ceiling) without touching this one (comparing a count
  against whichever ceiling it was handed), because the comparison itself is still made by calling
  into `pipeline`. **The shape that closes it: `worker_count_within_ceiling` relocates to
  `src/process`, not `src/pipeline` — and its pinned test SPLITS rather than moving whole, because the
  test as written cannot compile in `src/process` at all.** It names
  `MAX_EXTRACT_WORKERS`/`MAX_QUEUE_DEPTH` six times, twice on each of three lines
  (`defaults_test.odin:64`, `:91`, `:96`);
  `pipeline` already imports `transcibr:process`; and Odin compiles `_test.odin` files into the
  package under test, so a relocated copy that still names those two constants would make
  `src/process` import `pipeline` while `pipeline` imports `process` — a cyclic importation, a hard
  build failure the compiler reports at the relocated file, not a test-only wrinkle. Its own comment
  already says why the PREDICATE can move — it takes `ceiling` as a parameter rather than reading
  `MAX_EXTRACT_WORKERS`/`MAX_QUEUE_DEPTH` by name, so nothing in its body is pipeline-specific — and
  that same fact is what makes the pinned test's coverage independent of the constants too: walking
  `MAX_EXTRACT_WORKERS`, `MAX_QUEUE_DEPTH`, `1` and `5` proves the predicate is keyed to whichever
  ceiling it is handed and not to the other option's, a property that holds for any two distinct
  ceilings, not only today's pipeline-specific pair. The relocated test walks literal representative
  ceilings (for example `1`, `2`, `5`, `9`) instead of naming `MAX_EXTRACT_WORKERS`/`MAX_QUEUE_DEPTH`,
  keeping every assertion the original test makes — including the "itself was refused against its own
  ceiling" boundary check at each walked value — while never importing `pipeline`.
  `WORKER_OPTION_CEILINGS` and the two `MAX_*` constants stay in `pipeline`, which still owns the
  LOOKUP (`pipeline.worker_option_ceiling`) and still walks the table in
  `worker_option_ceilings_pair_each_option_with_its_own_max` (`defaults_test.odin:109-132`),
  unaffected by this split since it never calls `worker_count_within_ceiling` at all — **but that
  test's by-value assertions cannot fire against a mispairing on the tree as it stands.** On the
  current tree `MAX_EXTRACT_WORKERS` and `MAX_QUEUE_DEPTH` are both `2` (`pipeline.odin:37-38`), and
  `worker_option_ceilings_pair_each_option_with_its_own_max` checks the pairing by value
  (`extract_ceiling == MAX_EXTRACT_WORKERS`, `queue_ceiling == MAX_QUEUE_DEPTH`); with the two
  constants equal, swapping the two `WORKER_OPTION_CEILINGS` entries changes nothing either
  `testing.expectf` call reads, so the test passes whether the table is paired correctly or swapped —
  an assertion no mispairing can violate. **Neither constant is this record's to move, and the
  grammar does not wait on that gap being closed.** `MAX_EXTRACT_WORKERS` and `MAX_QUEUE_DEPTH` are
  ADR-0006's bounds — "one or two CPU workers ... connected by a bounded channel of depth one or two"
  — so making them distinct sentinel values would widen a bound another decision record owns, and
  would do it silently: nothing in `src/pipeline` refuses a third worker or a third queue slot today.
  `src/cliargs` changes neither. What closes the option-name-to-ceiling swap for the grammar is the
  shape this record adopts at its #94 bullet above: the pairing declared as DATA in one table, one
  row per option, adjacent and reviewable — #124's own string-keyed `WORKER_OPTION_CEILINGS`
  precedent, upgraded in `src/cliargs` to a genuinely enum-keyed `[Worker_Option]int` table once the
  grammar owns the option vocabulary as an enum. The exhaustiveness belongs to the upgrade and not to
  #124: an enumerated array that leaves a key unfilled does not build (`Unhandled enumerated array
  case`), where #124's string-keyed array with a row deleted builds clean and runs. That is a
  different and stronger guarantee than making a runtime comparison firable — it closes the swap
  DEFECT CLASS by construction, leaving a mispairing one place to live, in a row a reader sees beside
  its neighbour, where a value comparison catches only those swaps whose two values happen to differ.
  It still does not make a wrong ceiling in a correctly named row compiler-detected; review sees that
  one. The
  pipeline-side pairing test's unfirability on today's equal constants is a defect in the live tree,
  outside this record's scope, ticketed separately. Together the two tests cover what issue #94 was
  about across the import fence: the pairing test still walks the table and still proves each worker
  option has a ceiling registered and an unregistered name finds none, and the relocated predicate
  test proves the check honors whichever ceiling it is given and not the other's — held by two tests
  on either side of the fence instead of one test that cannot exist, unmodified, on either side
  alone. This is
  `read_natural`'s own `max_digits` precedent (`process/engine.odin:199`,
  `artifact/sidecar.odin`'s `MAX_SIDECAR_DIGITS`) applied a second time, this time literally rather
  than by analogy: a bound check that takes its ceiling as a parameter belongs beside the reader that
  takes its digit cap as a parameter, in the one package both `src/cli` and `src/cliargs` may import.
  With the predicate relocated, `src/cliargs` keeps a worker-option reader shaped like
  `read_worker_count` itself: it takes `ceiling: int`, parses with `process.read_natural`, and checks
  the result with `process.worker_count_within_ceiling` — never imports `pipeline`. On refusal it
  builds a `Refusal` (the shape above: its own owned complaint format string plus `name`, `ceiling`,
  `value` wrapped as `Refusal_Arg` values in `args[:3]`) itself, because it is the only side of the
  fence that has read the offending value; nothing is pre-formatted by `src/cli` before dispatch, and
  no complaint string crosses the fence built. The LOOKUP (`pipeline.worker_option_ceiling`) stays in
  `src/cli`, called immediately before the grammar's per-option dispatch to resolve `ceiling` for the
  two worker-option names, the same way `src/cli` already resolves `--ffmpeg`/`--ffprobe` into an
  `audio.Tools` after the read loop rather than inside it.
  **Defaults are a separate, already-closed case, not a third breach.** `defaulted_batch`
  (`batch.odin:355-370`) reads `pipeline.DEFAULT_EXTRACT_WORKERS` and `pipeline.DEFAULT_QUEUE_DEPTH`,
  but it runs after the read loop returns, on the `Options` struct the grammar handed back — the same
  place it calls `audio.defaulted_tools` today. It never moves to `src/cliargs`; it is exactly the
  "pipeline wiring" this ADR already lists as staying in `src/cli` (lines 112-113), and its import of
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

## Addendum, 2026-08-07 (issue #75, Stage 4 — `--batch`'s migration): the ceiling-lookup placement, resolved

The routing comment on #75 recorded a wrinkle in this ADR's own sketch (lines 262-266 above): it
placed the ceiling LOOKUP in `src/cli`, "called immediately before the grammar's per-option
dispatch" — but once the grammar's read loop moved into `src/cliargs`, the per-option dispatch moved
with it, so `src/cli` can no longer sit immediately before it. The candidate the routing comment
named — `src/cli` resolves both ceilings up front and hands them across the fence — risks
reintroducing a name-to-ceiling pairing on the `src/cli` side, the exact defect class the enum-keyed
table exists to close. This is what actually shipped, and why it does not reopen that risk.

**`src/cliargs` owns the enum and the table's SHAPE, never the ceiling values.**
`worker_options.odin` declares:

```odin
Worker_Option :: enum { Extract_Workers, Queue_Depth }
Worker_Ceilings :: [Worker_Option]int
```

`Worker_Ceilings` is a TYPE, not a filled table — `src/cliargs` never states a ceiling value itself,
holding to this record's own earlier ruling that neither `MAX_EXTRACT_WORKERS` nor
`MAX_QUEUE_DEPTH` is this record's to move or restate. `Batch_Options`'s read entry point takes a
`Worker_Ceilings` value as a parameter (`read_batch_options(arguments: []string, ceilings:
Worker_Ceilings)`), and its own dispatch (`read_batch_option`) indexes into it by enum member —
`pu.ceilings[.Extract_Workers]`, `pu.ceilings[.Queue_Depth]` — never by a second string search.

**`src/cli/batch.odin` fills a `Worker_Ceilings` value once, as a package-level `::` CONSTANT, built
directly from `pipeline.MAX_EXTRACT_WORKERS` and `pipeline.MAX_QUEUE_DEPTH`:**

```odin
BATCH_WORKER_CEILINGS :: cliargs.Worker_Ceilings {
	.Extract_Workers = pipeline.MAX_EXTRACT_WORKERS,
	.Queue_Depth     = pipeline.MAX_QUEUE_DEPTH,
}
```

This needs no runtime `pipeline.worker_option_ceiling` lookup at all — both `MAX_EXTRACT_WORKERS`
and `MAX_QUEUE_DEPTH` were already `::` constants (`pipeline.odin:37-38`), so the composite literal
above is itself a compile-time value, closing the #192 deposit's own ask ("make the replacement
immutable, an enumerated-array constant") for the table that actually governs the grammar's own
dispatch. The literal's exhaustiveness closes exactly one thing: an OMISSION. A third
`Worker_Option` member added and left out of it fails the build (`Unhandled enumerated array case`)
rather than reaching `src/cliargs` with a silently absent ceiling. What review still has to see —
this record said as much the first time (lines 244-245 above) — is a WRONG constant named at a
correctly-labelled `.Extract_Workers =`/`.Queue_Depth =` line, and that class INCLUDES a swap of the
two rows' values: in an enum-keyed literal the key is the label, so
`.Extract_Workers = pipeline.MAX_QUEUE_DEPTH, .Queue_Depth = pipeline.MAX_EXTRACT_WORKERS` is a
mis-copied value at two correctly-labelled keys, not a shape the exhaustiveness check reaches. That
swap builds clean and passes the full suite (measured against issue #212's own review, fix round 1);
with ADR-0006's two bounds diverged it reproduces issue #94's defect end to end in the shipped
binary. The enum buys completeness, not correctness of the values written into each row — that stays
review's job, unchanged from what this record said the first time.

**`pipeline.WORKER_OPTION_CEILINGS` and `pipeline.worker_option_ceiling` are not deleted.** They stay
exactly where they were — `src/pipeline` still owns the string-keyed lookup and its own pairing
test — but `src/cli` no longer calls `worker_option_ceiling` after this migration; nothing else in
the tree calls it either. They remain as `pipeline`'s own tested record of the pairing, in case a
future caller inside `pipeline` itself wants a name-keyed lookup, not as a live link in `--batch`'s
own dispatch path any more.

**`worker_count_within_ceiling` relocated to `transcibr:process`** exactly as this record's own
worker-ceiling section (lines 191-266 above) specified, with its pinned test split rather than moved
whole (`src/process/worker_ceiling_test.odin`, walking literal ceilings `1, 2, 5, 9` in place of
`MAX_EXTRACT_WORKERS`/`MAX_QUEUE_DEPTH`, keeping every assertion the original made). `src/cliargs`'s
own `read_worker_count` (`batch_options.odin`) calls `process.read_natural` and
`process.worker_count_within_ceiling` directly, never `pipeline`.

**Routing item 3 (the bare literal 3):** `read_worker_count`'s digit ceiling is now
`MAX_WORKER_COUNT_DIGITS :: 3` in `src/cliargs/batch_options.odin`, beside a `#assert
(MAX_WORKER_COUNT_DIGITS < process.MAX_NATURAL_DIGITS)` recording the relationship to
`process.read_natural`'s own precedent (`MAX_NATURAL_DIGITS`, `artifact.MAX_SIDECAR_DIGITS`) rather
than repeating a bare `3` at the call site.

**Routing item 4 (the #94 hand-pairing defect) is closed for `--batch`'s own dispatch**:
`read_batch_option`'s `case "--extract-workers":`/`case "--queue-depth":` arms each name their own
`Worker_Option` member explicitly and read their ceiling out of the enum-keyed table by that member,
never by a second name search. A swap of the two `case` arms — whether the whole arm body or just
its `pu.ceilings[...]` index — is caught by
`read_batch_options_refuses_each_worker_option_against_its_own_ceiling_and_not_the_others`
(`src/cliargs/batch_options_test.odin`): both mutations red that test under the full vet set. What
stays review-only is the VALUE swap inside `BATCH_WORKER_CEILINGS`'s own composite literal, described
just above — a MISSING or DUPLICATED ceiling for a `Worker_Option` member cannot reach `--batch` at
all, since that fails the build at the literal itself.

## Addendum, 2026-08-07 (issue #75, Stage 6 — the contraction): what actually shipped

The stage-5b deposit handed the contraction seven items. This addendum records the shape each one
took, and closes the two open questions this record's own body left standing (the refuse shape's
sibling, and the #50 deposit's two problems).

**`--from-json`'s grammar moved last**, exactly as the ADR's own body always meant it to (this
record's "what it holds" section never carved out an exception for it) — `cliargs.Render_Options`/
`read_render_options` (`src/cliargs/render_options.odin`), the fifth and last of the five migration
sites this ticket ever named (four in the ADR's own count, `--doctor` ruled in by the 2026-08-07
comment on #75). `src/cli/main.odin`'s `read_options`/`read_option` are deleted; `re_render` calls
the grammar and reshapes its already-settled verdict into a `transcript.Render_Context` through
`render_context_of`, a field-for-field copy that decides nothing. Unlike `Batch_Options`/
`Transcribe_Options`/`Doctor_Options`, `Render_Options` embeds no `Common_Options` — it shares no
option spelling with any other command (`--model`/`--engine` are free text here, not
`--model-file`/`--engine-exe`, and there is no `--cache`, no tools struct, no `--prompt`) — and its
required-field refusal keeps `--from-json`'s own pre-migration wording, `"nothing to render."`,
never adopting `required_fields_present`'s shared `"%s names nothing."` (that sweep names a field;
`--from-json`'s complaint never did, and byte-identity binds the wording, not the shape). The
source-falls-back-to-json-path and model/engine-falls-back-to-"unknown" settling this record's own
body never assigned a home also moved into the grammar rather than staying `src/cli` plumbing: unlike
the tool/worker-ceiling defaulting this record keeps in `src/cli` because it needs
`transcibr:audio`/`transcibr:pipeline` behind it, this settling needs nothing beyond
`transcibr:transcript`, already inside the closure, and folding it in leaves `re_render` with
strictly nothing left to decide.

**The refuse shape's sibling is resolved by adopting the letter, not by amendment.** The stage-3
deposit found `refuse_cliargs` (`src/cli/transcribe.odin`) standing as a live sibling of `refuse`
(`src/cli/main.odin`) and asked the contraction to pick one of two ends: either `refuse` itself takes
this record's own union-slice signature and every caller migrates, or `refuse_cliargs` becomes the
one entry and this record gets an addendum recording that instead. This stage takes the first branch,
because it is what lines 153-175 above already specified rather than a new decision: `refuse` now
reads `proc(complaint: string, args: []cliargs.Refusal_Arg) -> (ok: bool)`, taking the slice directly
exactly as this record's own body says, and does what `refuse_cliargs` used to do — two fixed
backing arrays sized to `cliargs.MAX_REFUSAL_ARGS`, filled by a `switch v in arg`, fed to the same
`fmt.eprintf` call `write_usage` already used non-allocating. `refuse_cliargs` is deleted.
`crash_drill.odin`'s three surviving `..any`-shaped call sites (the ones this record's own arity
paragraph names as the arity-0/1 end of the range) now build a `[]cliargs.Refusal_Arg` literal or
pass `nil` for zero arguments, and every one of the five grammar packages' own refusal call sites —
`--transcribe`, `--batch`, `--plan`, `--doctor`, `--from-json` — reaches this one procedure through
`refuse(refusal.complaint, refusal.args[:refusal.arg_count])`.

**The #50 deposit's two problems, resolved**: `--from-json`'s `--engine <version>` stays free text.
It is not the decision-leak the deposit's own wording ("two different kinds of value reaching one
key") suggested on first read — `--transcribe`/`--plan`/`--batch` digest an `--engine-exe` FILE they
hold at run time; `--from-json` renders retained output from an earlier run and is never handed an
engine binary to hash at all, so free text is the only kind of value it COULD carry for that field.
Unifying the two would mean deleting `--from-json --engine`'s ability to record what a prior,
possibly since-deleted engine build reported, for a command whose whole purpose is rendering output
that engine already produced. Left as designed; no code change. The USAGE trailer's own sentence —
"anything not given, or given empty, is recorded as unknown" — turns out to need no rewording either:
re-read against the grammar rather than against the deposit's paraphrase, `--source`, `--model` and
`--engine` are the exact three flag spellings `--from-json` alone accepts (`--transcribe` reads
`--model-file`/`--engine-exe`, `--plan` and `--batch` the same, none of them a bare `--model` or
`--engine`), so the sentence already names only the command it describes. Both halves of this
deposit close as verified-correct-as-shipped rather than as a byte change.

**The BATCH token pin** applies the same fix the stage-5 review already landed for `PLAN`:
`src/cli/batch.odin`'s own `BATCH :: "--batch"` constant, the one the stage-5 deposit measured could
drift to `"--batches"` with the whole `cliargs` suite still green, is deleted. `main.odin`'s dispatch
and `batch.odin`'s own dispatch assert both read `cliargs.BATCH` now, the single declaration
`src/cliargs/batch_options.odin` already carried — the same shape `--doctor` and `--plan` already had
before this stage touched them.

**Two-tools convergence**: `Batch_Options`, `Transcribe_Options` and `Doctor_Options` (`src/cli`)
still each embed their `cliargs.*_Options` sibling via `using`, which still promotes `parsed.tools`
(the ungrammar's own two-string, undefaulted struct) into the same field-access namespace as
`audio_tools` (the defaulted `audio.Tools` this package builds from it). Splitting the struct apart
would touch every one of the dozen-plus call sites each file already threads `o.model`/`o.cache`/
`o.prompt`/… through via that same `using`, for a much larger diff than the defect warrants. Instead,
each of the three command entry points zeroes the promoted `tools` field immediately after building
`audio_tools` from it (`o.tools = {}`) — a stray read of the promoted field now returns two empty
strings rather than a plausible-looking, silently-stale pair, so a misread is loud (an empty
`--ffmpeg`/`--ffprobe` path fails fast at the tool spawn) rather than invisible to the whole
toolchain, closing the s5b review's own framing of the risk. The third uncollapsed copy of the
`audio.Tools{ffmpeg = ..., ffprobe = ...}` construction (`--batch`, `--doctor`, `--transcribe` each
built one by hand) is now one shared procedure, `audio_tools_of` (`src/cli/main.odin`), called from
all three.

**`MIN_PACKAGE_FILE_COUNT` is now a pin, not a floor**: `==` in place of `>=`, at `22`, the exact file
count `src/cliargs` holds once `render_options.odin`/`render_options_test.odin` land. A floor forgives
a file's deletion as readily as a `>=` comparison always did; a pin catches both directions, and this
package is done growing — every migration site ADR-0038 ever named is landed and every reader it
replaced is deleted.

**`pipeline.WORKER_OPTION_CEILINGS`/`worker_option_ceiling` are left exactly where the stage-4
addendum put them, dead-with-a-passing-test.** The stage-4 review deposit offered the contraction two
outs — retire them, or record their tenancy here instead — and this record takes the second: they sit
inside `src/pipeline`, one of this stage's own in-flight fences (issue #211 holds `src/pipeline`
source), so retiring them is not this PR's to do. They remain `pipeline`'s own tested record of the
string-keyed pairing #124 first built, walked by `worker_option_ceilings_pair_each_option_with_its_own_max`
(`src/pipeline/defaults_test.odin`), reachable by a future caller inside `pipeline` itself, but no
longer a live link in any command's own dispatch path — `--batch`'s own dispatch has read the
enum-keyed `Worker_Ceilings` table by member since the stage-4 addendum above, and nothing else in
the tree calls either name.

**The #74-rubric audit, over what remains**: every procedure across `src/cli/main.odin`,
`batch.odin`, `doctor.odin`, `transcribe.odin`, `plan.odin`, `crash_drill.odin` and
`engine_identify.odin` was walked against the same rule #74's own audit used — "the moment a decision
worth testing turns up in `src/cli`, it belongs in the core instead." Nothing new turned up: every
remaining procedure is argv-to-field plumbing, an I/O wrapper this record's own "what stays" list
already names (model/engine identification, the Ctrl+C handler, the job-object prologue, the
non-allocating write), a bool-to-exit-code map (`plan_verdict`'s own shape, per #74's own
resolution), or a presentation-only format call. `crash_drill.odin`'s undocumented mode switch is the
one boundary check outside those categories — it refuses an unrecognized mode string (A8, external
input) rather than asserting on it, the same shape every other migrated grammar's `case:` arm uses,
and it is not one of this ticket's own migration sites (no acceptance criterion or deposit ever named
it). `src/cli` holds no decision under #74's rubric once this stage lands.
