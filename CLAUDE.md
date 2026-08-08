# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

What transcibr is, why it is built the way it is, and what is deliberately out of scope: see
[README.md](README.md). The specification lives in `docs/spec/`. Everything below is how to write
the code.

## Agent skills

### Issue tracker

GitHub Issues in `ivandrenjanin/transcibr`, driven by the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context — `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

---

# Odin Style Guide

The engineering standard for Odin code in this repository. Adapted from
[the svsw Odin Style Guide](https://github.com/svswengine/svsw/blob/main/docs/ODIN_STYLE.md), itself
adapted from [TigerStyle](https://tigerbeetle.com/TigerStyle). Design goals, in order: **safety,
performance, developer experience**.

Every rule here earned its place in a working codebase. Review enforces all of them; the compiler's
vet flags enforce S1 and S2 on every build. Examples are retargeted to this repository; where an
example and the linked original differ, the rule is the same and the linked document is canonical.

## 0. Comment policy

The operative contract is self-documenting code with comments driven toward minimal. Comments are banned inside procedure bodies. IF a comment is needed, it must be a comment that explains why the code is doing what it is doing, not a comment that repeats the code's logic.

Enforced mechanically, repository-wide, and it fails `just check`: `collect_comment_violations` in
`tools\policy\check.odin` reads every `.odin` file `discover_odin_files` walks — every directory the
repository holds `.odin` files under, `src` and `tools` included — and names the file, line and
procedure of anything it finds. It reads with
`core:odin/parser`, inside `tools\policy` itself (ADR-0028), so a `//` inside a raw string is text and not
a comment, and a procedure declared inside a `when` block is covered like any other.

## 1. Assertions

Assertions detect programmer errors. Operating errors (a malformed SRT, a missing video, a
truncated model file) are expected and handled. Assertion failures are unexpected, and the correct
response to corrupt internal state is a crash at the point of corruption. Assertions turn a
catastrophic correctness bug, such as a transcript silently missing half its cues, into an
immediate, located crash.

### A1. Two assertions per procedure, on average

Assert procedure arguments, return values, preconditions, postconditions, and invariants. A
procedure must not operate on data it has not checked. Hold the file average at two or more
assertions per procedure; pure leaf math may carry fewer when its callers carry more.

```odin
// GOOD: every parameter checked before use.
merge_paragraphs :: proc(cues: []Cue, p: Merge_Params) -> []Paragraph {
	assert(p.max_gap_ms > 0, "max gap must be positive")
	assert(p.hard_gap_ms >= p.max_gap_ms, "hard gap must not sit below max gap")
	assert(p.max_para_chars > 0, "paragraph cap must be positive")
	// ...
}

// BAD: operates on unchecked data; a zero hard_gap_ms breaks every cue into its own paragraph.
merge_paragraphs :: proc(cues: []Cue, p: Merge_Params) -> []Paragraph {
	// ...
}
```

Assertions stay enabled in every build configuration. Disabling them in a shipping target is a
logged decision, not a flag flip.

### A2. Split compound assertions

Write `assert(a); assert(b)` over `assert(a && b)`. The split form reads as two facts and names
which one failed. Assert an implication with a single-line `if`:

```odin
if len(cues) == 0 { assert(len(paras) == 0) }
```

### A3. Assert the positive and the negative space

Assert what must be true and what must be absent. An add path asserts absence; the matching remove
path asserts presence:

```odin
queue_push :: proc(q: ^Job_Queue, job: Job) {
	assert(q.len < len(q.slots), "push onto a full bounded queue")
	// ...
}

queue_pop :: proc(q: ^Job_Queue) -> Job {
	assert(q.len > 0, "pop from an empty queue")
	// ...
}
```

Test the same way: exercise invalid data and valid data turning invalid (a cue whose end precedes
its start, a job whose output file vanished mid-run), not only the happy path.

### A4. Pair assertions across code paths

Enforce each critical property in at least two places: on the write side and the read side, on
entry and on exit, on add and on remove. A parser that produces monotonically ordered cues asserts
that on the way out; the renderer that consumes them asserts it on the way in.

### A5. Compile-time assertions

Use `#assert` for type sizes and constant relationships the code relies on. A type whose raw byte
image is parsed or written carries a `#assert` on its size next to its definition; the claim lives
in checked code, not prose:

```odin
#assert(size_of(Riff_Chunk_Header) == 8)  // 4-byte id + 4-byte length, read at a walked offset
#assert(size_of(Wav_Fmt_Body) == 16)      // PCM fmt payload; the chunk's own length is still checked
```

Assert the shape of a record, never the layout of a file. A WAV header is *not* a fixed 44 bytes —
ffmpeg's muxer writes a `LIST`/`INFO` chunk before the data chunk, unconditionally, so `data` starts
at a per-file offset. `#assert(size_of(Wav_Header) == 44)` is the kind of claim that looks rigorous,
passes review, and fires on the first real input.

### A6. A true assertion beats a comment

Where a condition is critical and surprising, assert it even when it looks obvious. The assert is
documentation that cannot rot; keep the comment for the why.

### A7. Assertions in `contextless` and `proc "c"` code

Odin's `assert` needs a `context`. In `proc "contextless"` and `proc "c"` code, use
`runtime.assert_contextless` from `base:runtime`. Never skip an assert because the context is
missing, and never rebuild a context just to assert.

### A8. Boundary rule: assert internal invariants, reject external input

Nothing outside this program may crash it. At every external boundary — CLI arguments, video and
audio files, the SRT and JSON whisper.cpp emits, ffmpeg exit codes and stderr, the model file, the
filesystem — anything supplied from outside is an operating error: reject it through the error
return, report it against the file that caused it, and keep the batch healthy so the remaining jobs
still run. Reserve `assert` for invariants no external input can reach. An input file that trips an
assert is a bug in the boundary, not a correct assert.

## 2. Procedure shape

### F1. Hard limit: 70 lines per procedure

Counted from the line containing `::` through the closing brace, comments and blanks included. A
procedure that fits on one screen reads as a unit; one that scrolls does not. The limit is
checkable by machine and has no exceptions without a maintainer decision recorded at the site.

Checked by machine, and it fails `just check`: `collect_length_violations` in `tools\policy\check.odin`
reads the same procedure spans section 0 and rule F2 read (ADR-0028) and names the file, line, name
and length of anything over.

### F2. `@(require_results)` on every procedure that returns anything

If it hands something back, the attribute goes above the declaration. No judgement per procedure
about whether *this* answer matters: a fault, an `ok`, a count, a rendered line — all of it.

```odin
// GOOD: a call site that drops the answer does not build.
@(require_results)
quarantine :: proc(path: string, allocator: mem.Allocator) -> bool {
	// ...
}

// BAD: the only value that knows whether the rename happened, and nothing obliges anyone to read it.
quarantine :: proc(path: string, allocator: mem.Allocator) -> bool {
	// ...
}
```

A caller that means to throw an answer away spells it `_ = f(...)`, which is a discard review can
see. `defer` is inside that: `defer f()` stops compiling once `f` carries the attribute, and the
form is `defer _ = f()`.

**Total, because a narrower rule cannot be applied without asking somebody.** "Faults only" leaves
whoever writes the next `-> (value, ok)` deciding what counts as a fault, and case-by-case review
already produced its answer here — `disposition_of` was left bare *because a sibling lacked it*.
**Test files are inside it**, because the failure does not stop at them: a case that drops a
helper's verdict checks nothing and still reports green.

Two halves enforce it. The **compiler** refuses a dropped result at the call site, and refuses the
attribute on a procedure with no results — so it cannot be sprayed wider than the rule says, and
deleting a procedure's return values fails the build until the attribute goes too. What it says
nothing about is a procedure declared *without* it, which is the direction every bare one here
arrived from; `collect_result_violations` in `tools\policy\check.odin` fails `just check` on one,
reading the same procedure spans rule F1 and section 0 read (ADR-0028). It asks only where an attribute can be
written: a procedure TYPE and a literal passed as an argument are outside the rule because the
compiler will not let anybody satisfy it there.

`#optional_ok` points the other way: it makes dropping an `ok` easier, which is the failure the rule
exists to stop.

## 3. Types

### T1. Explicit widths where the width is meaning

Anything hashed, snapshotted, serialized, or crossing the C ABI uses explicit widths: `u32`, `u64`,
`i64`, `f32`, `enum u8`, or `c.int`/`c.size_t` at the C boundary. The byte image is the contract —
WAV header fields and anything written to disk for another process to read are the pattern here.

Odin's `int` is idiomatic for lengths and indices into in-process slices: `len()` returns `int`, and
fighting that breeds casts. The line is persistence and wire. Never use `uint`: unsigned arithmetic
wraps without a diagnostic, and the width depends on the target.

### T2. `distinct` types for identifiers

IDs are not integers; make the compiler agree. `Job_ID :: distinct u32` stops a queue slot index
from passing where a job ID belongs. Every ID-like quantity gets the same treatment. Convert with an
explicit cast at the storage edge (`q.slots[int(id)]`), the exact place the reader should slow down.

## 4. Memory

### M1. Iterate stateful values by reference

Odin's range loop copies each element by default. When a called procedure mutates that copy, the
mutation lands in the copy and vanishes; the code compiles, and the state it was supposed to update
drifts without a diagnostic.  Write `for &x in` for anything mutated in the loop, and pass stateful
or large structs as `^T`.

```odin
// GOOD: mutations land in owned state.
for &job in w.jobs { job_advance(&job) }

// BAD: copies each Job; the progress update happens in the copy and is discarded.
for job in w.jobs { job_advance(&job) }
```

Do not alias state into convenience locals that outlive a mutation; a slice taken before an `append`
is stale after it.

### M2. Every file declares the repository's `#+vet` names above its `package` clause

ADR-0010 is the rule: every procedure that allocates takes `allocator: mem.Allocator`, and nothing
crossing a thread boundary comes from `context.temp_allocator`. The tag is that rule spelled so the
compiler holds it. A call that lets Odin fill an `allocator` parameter from the context stops
building:

```
progress_test.odin(40:2) Error: Parameter 'allocator' of type 'Allocator' must be explicitly provided in procedure call
	lines_of(&r, "whisper_print_progress_callback: prog", &collected)
	^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^
```

There is no command-line flag for it — `odin build -vet-explicit-allocators` answers `Unknown flag`
at the pin, so unlike S1's set this one cannot be passed once. It is a **file tag**, it goes above
the `package` clause, and `tools\policy\check.odin` holds the names in `vet_tag_roster`. Adding a
name there is what puts it on the files it is scoped for; do not spell one at a call site.

**Above the clause is the whole of the placement rule — not the first line.** What makes a tag do
anything is that the compiler reads it, and it reads every `#+` line above `package`: stacked with
another tag, or under a twenty-line doc comment, all the same. Nothing checks position among them,
deliberately, because issue #48 puts `#+private` on these files too and one of the two would then
have to be second. Each entry in `vet_tag_roster` also says **which files** it is for (its `scope`),
and `required_vet_tags` refuses the two ways that can be silent: a name that turns a check *off*
declared for every file, and a scope nothing resolves. A name is not repository-wide because the
list is called a list.

**The tag is read per file, and that is why `just check` fails over a missing one.** Measured: a
package holding one tagged file and one untagged sibling compiles clean, with the
sibling's implicit allocators never looked at. The two ways a tag can be wrong are already loud — a
misspelled name is `Syntax Error: Invalid vet flag name` and a tag below the `package` clause is
`Lines starting with #+ (file tags) are only allowed before the package line` — so absence is the
only silent one, and absence is what the check reads.

A parameter written `allocator := context.allocator` is a default no caller in a tagged file can
ever take, so it does not appear in this tree; write `allocator: mem.Allocator` and let the call
site say which allocator it meant.

## 5. Style

### S1. Formatting: odinfmt, tabs, the full vet set

Indent with tabs: odinfmt emits them and `-vet-tabs` enforces them. Every test and type-check
invocation passes the full vet set. A style rule that fights the toolchain becomes a rule nobody
runs; the formatter plus the vet flags are the rule.

The set is `-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do`. Do not spell
it out at a call site: the `justfile` at the repository root holds the only executable copy (the
`vet` variable), and every recipe that builds or tests passes all of it.

The formatter half is `odinfmt.json` at the repository root — the one copy, and the name odinfmt
looks for on its own, so an editor formatting on save and the build agree by construction. Do not
reformat a file by hand or with a different config; `just fmt` is the way. A misformatted file fails
`just ci` (`just fmt-check`), which walks `src` and `tools` — each spelled once in
`fmt` and once in `fmt-check` — comparing odinfmt's own reformatted output for each file against the
file on disk, byte for byte, never `git diff`. That two-directory scope is NARROWER than `check`'s:
`check_repository` calls `discover_odin_files` with the repository root itself, excluding only
`.git`, `build`, `.scratch` and `.tools` (ADR-0035's "same repository-wide scope"), so a `.odin` file
added anywhere outside `src` and `tools` — under `examples\`, say — is read against
every source policy by `just check` but never read by `just fmt-check` at all. `fmt`/`fmt-check` do
not yet have a way to name a scope by exclusion the way `discover_odin_files` does; keeping the two
in sync is a manual discipline until they do.

```text
just build       # debug build of src/cli, vet set, subsystem console
just release     # -o:speed build of src/cli, vet set
just check       # tools/policy: CLAUDE.md's source policies and the package-accounting check
just test        # every package under src\ and tools\policy, vet set, memory failures fatal
just fmt         # every .odin file under src and tools against odinfmt.json, rewritten in place
just fmt-check   # per file, odinfmt's own output byte-compared against the file on disk (no git diff)
just ci          # fmt-check, check, build, release, test, test-single, smoke, in that order
```

### S2. Braces on every block

`-disallow-do`, already in the vet set, bans the brace-less `if cond do stmt` form, closing the
"goto fail" class by machine. What remains is judgment: split compound conditions into nested
`if`/`else` trees so every case is visible, and give an `if` its `else` when the negative space
needs handling or asserting (A3).

### S3. Callbacks with a foreign calling convention rebuild the context

A Win32 window procedure is `proc "stdcall"` and carries no Odin context. Every entry point called
from outside Odin assigns `context` from stored state before touching anything allocator- or
logger-dependent, and never leaves a `defer` live across a point that can longjmp. Review checks
this file by file like any other style rule.

---

# Odin notes for this repository

**`core:os/os2` no longer exists.** It was folded into `core:os` in Odin `dev-2026-03`. Essentially
every Odin sample and tutorial online predates this. Treat any snippet you find as suspect and
verify identifiers against the installed compiler's `core` sources before trusting them — this
applies to the whole standard library, not just process handling.

**`process_terminate` is not `process_close` renamed — it is a *cooperative* request the child may
ignore.** On Windows it posts `WM_CLOSE` to the pid's top-level windows, and where there are none it
falls back to `GenerateConsoleCtrlEvent(CTRL_C_EVENT, pid)`, which Microsoft documents as
*succeeding while delivering nothing* for a nonzero group id; `core:os` only falls through to a hard
kill when that call returns FALSE. In a console-subsystem binary it therefore returns success with
the child still running and the model still resident in VRAM. To actually stop a child, spawn it
yourself and stop it yourself: `TerminateProcess` → `WaitForSingleObject` → `CloseHandle` on both
the process and thread handles, and do not touch any file the child had open until the wait
completes. Note also that `Process.pid` is stale once the process exits and Windows recycles pids,
so a late terminate can signal an unrelated application.

**`core:sys/info.iterate_gpus` skips a real adapter over a case-sensitive `MatchingDeviceId` check,
and stops the whole iteration when it does.** `_iterate_gpus` reads each subkey's
`MatchingDeviceId` and requires `strings.has_prefix(matching, "PCI\\VEN")` — but the value Windows
actually stores there is lowercase (`pci\ven_10de&dev_2705`), so the prefix check fails and the proc
takes its bare `return`, which yields `ok = false`. That is not "no adapter at this index and keep
going" — `ok = false` terminates a `for gpu in iterate_gpus(&it)` loop outright, so a real adapter
at a later index (e.g. `0001`) is never reached once an earlier one (`0000`) fails the prefix check.
Measured on this repository's own dev machine (round 3 of the #96 review, confirmed again at the
#122 review): subkey `0000` under `SYSTEM\ControlSet001\Control\Class\{4d36e968-...}` is the real,
working NVIDIA GeForce RTX 4070 Ti SUPER, and `ControlSet001` is in fact the active control set here
(`HKLM\SYSTEM\Select\Current = 1`) — the registry key opens and enumerates fine. The NVIDIA card is
the one that fails the lowercase prefix check, so it is unreachable through `iterate_gpus` at any
starting index; on this machine the only other adapter subkey (`0001`, AMD integrated) is not
affected by the defect and reports fine on its own. There is no index-skipping workaround that
recovers the NVIDIA card — the defect is the case-sensitive prefix match and its
early-return-terminates-iteration behavior, not the hardcoded control-set path. This is why
`src\doctor\gpu.odin` (ADR-0033) talks to `vendor:directx/dxgi` directly — `CreateDXGIFactory1` and
`IFactory1.EnumAdapters1` — rather than through this stdlib wrapper.

**No `os.remove_all(...)` call anywhere in the tree (issue #97/#105).** `core:testing` runs tests on
their own thread, and issue #97 measured `os.remove_all` faulting on that thread over a non-empty
directory — a crash with no summary and no JSON report, the same failure mode issue #22 already
names for concurrent assertions. Nothing needs a whole-subtree delete: `src\testkit\testkit.odin`'s
`remove_cache` is the sanctioned teardown, a per-entry hand loop that never recurses through
`core:os`. `collect_remove_all_violations` in `tools\policy\check.odin` fails `just check` on any
`os.remove_all(...)` call expression, wherever it appears and however the `core:os` import is
aliased, riding the same `tools\policy` AST read as the four CLAUDE.md source policies above — the
one difference being that this is the #97 review's own finding rather than a rule this document
states as one of those four.

**Testing is built in; there is no framework to choose.** Mark procedures `@(test)`, import
`core:testing`, and assert with `testing.expect` and `testing.expect_value`. `just test` sweeps
every package with one explicit `odin test` line each (the `justfile`'s own `test` recipe is the one
place that list is spelled); `just test-one version banner_names_the_program_and_its_version` runs
one. Issue #152 retired the PowerShell layer's own suite that used to check a name written here
against the real one; no mechanism pins these names against the tree any more, so treat every `just
test-one` example as a claim worth re-running, not a pinned fact (ADR-0035's third accepted risk).
Do not hand-roll the compiler invocation — `tools\policy`'s package-accounting check covers both
package roots, `src\` and `tools\`, in both directions: every package under either root holding a
`*_test.odin` file must be named in the `justfile`'s `test` recipe, and every package under either
root holding none at all is a violation (issue #152). `cli` is the one declared exemption
(ADR-0009), and it is a `src\` name — `tools\` has no exemption roster at all, so a tool added
there is denied by default until it holds tests and the `test` recipe names it.

`core:testing`'s runner caps the thread pool at the test count: `thread_count = min(thread_count,
total_test_count)` in `runner.odin`, right after thread count is chosen from
`ODIN_TEST_THREADS`/core count. A package used to check a thread-count define — for example, that
concurrent asserts really do run concurrently — needs at least two `@(test)` procedures in that
package, or the cap silently pins it to one thread regardless of what the define asked for and the
check asserts nothing. `just test-single` runs `src\child` under `ODIN_TEST_THREADS=1` (the recipe
is fixed to that one package rather than parameterised: `src\child` is the only package where
`ODIN_TEST_THREADS=1` surfaces anything, so a parameter would advertise a setting with no second
consumer) alongside `just test-one`. `child` is real production source — process/pipe/directory
lifecycle, not a fixture — kept there because the default 12-thread sweep cannot see the #97 defect
class on it (issue #104).

The notes below name identifiers in the compiler's `core` sources and never line numbers in them. A
name is greppable, survives an upstream edit, and says which thing is meant; a line number in another
repository is a claim with no guard on it at all. The one this file used to carry — a single range
cited for two separate branches of `get_token` — was already wrong about one of them at the pinned
compiler.

**The test runner hangs when two or more tests assert concurrently.** One asserting test fails
cleanly every time. Two or more either crash the process with no summary and no JSON report, or hang
forever — and `-define:ODIN_TEST_THREADS=1` makes the hang *deterministic* rather than mitigating it.
The Windows signal handler records into a single global slot and returns `EXCEPTION_CONTINUE_SEARCH`,
so the faulting thread races a main loop that has to `TerminateThread` it before the OS kills the
process; a second concurrent assertion overwrites that slot, and `TerminateThread` on a thread killed
mid-log abandons its locks. Nothing in the toolchain has a timeout: `testing.set_fail_timeout` is
opt-in per test. Issue #152 retired the PowerShell layer's process-tree-kill wrapper along with
everything else it held — no `odin` invocation the `justfile` runs carries a wall-clock ceiling
of its own; ADR-0035 records this as an accepted risk, mitigated instead by the repository-wide
no-test-trips-an-assert discipline these Odin notes exist to uphold. A local hang is a `Ctrl+C`
away; `.github/workflows/ci.yml`'s job-level `timeout-minutes` is what bounds one in CI. Do not
remove that job timeout; a sweep with no ceiling anywhere is a CI job that burns six hours to say
nothing.

**`core:encoding/json` does not parse integers, silently wraps the ones it does, leaks when it
refuses a file, and crashes on deep nesting.** Four traps, all measured, all with a worked example in
`src\transcript\engine_json.odin`.

`parse_integers` defaults to *false* on every entry point, so `12345` arrives as a `json.Float` and
the natural `value.(json.Integer)` matches nothing at all — every number silently reads as its zero
value, and a monotonicity check downstream still passes, because zero is monotonic. Read the
`json.Float`; do **not** reach for the flag. `get_token` classifies a number on the decimal point and
on an `e`/`E` exponent, so `12345.0` and `1.2e4` stay Floats however the flag is set — a reader has
to handle Floats regardless, and handling Integers as well buys nothing but the trap below.
`DEFAULT_SPECIFICATION` is `JSON5` as well, which accepts trailing commas and comments — pass `.JSON`
where the input is supposed to be strict.

Passing the flag trades a number that is silently zero for one that is silently wrong. The `.Integer`
case of `parse_value` reads its token with `i, _ := strconv.parse_i64(token.text)`, and the discarded
error is not the problem: `parse_i64` **wraps on overflow and returns `ok = true`**, so there is no
failure to read even if you read it. `99999999999999999999999` arrives as `200376420520689663` and
`2^127` arrives as `0` — magnitudes a range check can still refuse — but `18446744073709556616`,
which is 2^64 + 5000, arrives as `5000`, and nothing downstream can tell that from a real value. An
f64 has no wrap to exploit: rounding is monotonic, so a literal outside the range arrives outside the
range. Read the Float and range-check it strictly below 2^53, which is where f64 stops representing
every integer and starts rounding one literal onto another.

The same family's `strconv.parse_int` is worse in three further ways, and it is what a reader reaches
for when the number arrives in a line rather than in a tree. At base 0 it is
`parse_i64_maybe_prefixed`, which accepts `_` as a digit separator, so `1_0` reads as ten; accepts a
leading sign, so `+7` reads as seven and a negative percentage arrives as a number rather than as a
refusal; and runs `value *= base` with no check of any kind, so a forty-digit number answers
something arbitrary and reports `ok`. Every one of those is a byte the Engine can write into its
diagnostics and a corrupt Sidecar can carry. `read_natural` in `src\process\engine.odin` is what this
repository reads a whole number with: digits only, no sign, no separator. Two guards close the
overflow, doing two different jobs. What actually stands between a long literal and a wrap is the
per-digit range check inside the loop — `value > (max(i64) - i64(digit - '0')) / 10`, run before every
multiplication — because it holds at any digit count: a 19-digit run can still exceed `max(i64)`, and
that check is what refuses it rather than letting it wrap. Beside it sits a separate, POLICY ceiling on
the DIGIT COUNT, tested before the first digit is even read: `MAX_NATURAL_DIGITS :: 12`, with
`#assert(MAX_NATURAL_DIGITS < 19)` recording that twelve digits can never reach anywhere near i64's
range, so the per-digit check can never actually fire for that consumer — the ceiling alone already
keeps its numbers well inside i64. Rejecting an implausibly long run on sight is the ceiling's job;
refusing a wrap is the loop's, and the loop's job does not change with the ceiling's value.

The ceiling belongs to the CONSUMER and not to the reader, and it already reads that way:
`read_natural(text: string, max_digits := MAX_NATURAL_DIGITS)` takes it as a parameter — for the day a
second consumer wants a different one, a nanosecond moment needing the full nineteen digits where a
percentage needs two. That day has come: both call sites in `src\process\engine.odin` still take the
default, but `src\artifact\sidecar.odin` declares `MAX_SIDECAR_DIGITS :: 19`, with
`#assert(MAX_SIDECAR_DIGITS == len("9223372036854775807"))`, and passes it at five call sites
(`sidecar.odin:396-405`) — including `s.source_modified_ns`, the nanosecond moment itself. At nineteen
digits the digit-count ceiling no longer bounds the value below i64's range by itself; the per-digit
check in the loop is what still does, unchanged from what it was doing at twelve.

The parser leaks on several of its error paths: an object key parsed just before the value after it
fails is never inserted into the object, so the cleanup that walks that object never frees it, and a
truncated file takes exactly that path. Decode into an arena you destroy unconditionally rather than
trying to free the tree.

It is a recursive descent with **no depth limit**, so nesting deep enough runs the thread off its
stack and takes the process down — 0xC00000FD from 1694 bytes, 751 levels fine and 801 fatal. There
is no error return to catch, so the depth has to be bounded *before* the decode; A8 has no exception
for input that is merely unusual.

`MAX_JSON_DEPTH :: 64` is fixed by two bounds and not by taste. whisper.cpp writes five levels at its
deepest — the root object, the `transcription` array, a Cue, its `tokens` array, a token — so 64
leaves an order of magnitude over anything an Engine release could plausibly add. And the limit has
to sit an order of magnitude BELOW the crash, because the depth the stack survives is not a constant:
it moves with the build configuration and with the stack the calling thread happens to have. A limit
set just under a measured 751 is a limit measured on one build.

Count the depth with `core:encoding/json`'s OWN tokenizer, given the same specification and integer
setting the decode is given. `json.make_tokenizer` is iterative and allocates nothing, so running it
ahead of the decoder runs none of what makes the decoder unsafe, and `parse_value`'s recursion takes
one level per open bracket in exactly that token stream. It costs about half again what a hand-rolled
byte scan costs — 20.6 us against 13.8 us for a whole `parse_cues` over the committed 2335-byte
fixture, across 200,000 of them — and that is paid because the tokenizer is the only thing that
already knows where a JSON string ends. A hand-rolled scan would refuse a Recording for containing
`[[[` in transcribed speech.

`get_token` reports an illegal character WITH a token and walks on past it, so its error return is not
a stop condition; only `.EOF` means there is nothing further to read. A loop that broke at the first
error would measure none of the brackets after it — which the decoder still descends into before it
reaches the error and gives up — so the bound would under-count exactly the region that can crash the
process. Switch on `token.kind`, discard the error, and stop on `.EOF`.

`just test-one transcript parses_real_engine_output_into_cues` is the test that catches the integer
default against real Engine output.

**`core:odin/parser` carries the same unbounded recursion, and it runs out of stack an order of
magnitude sooner.** The build reads Odin with it (ADR-0028), so this is not a hypothetical: measured
at the pin, a debug build overflows on **62 nested parentheses** — `x := (((…1…)))` — where nested
blocks survive 200 and nested calls 100. The deepest file in this repository reaches 7, so
`MAX_SOURCE_DEPTH :: 32` in `tools\policy\policy.odin` sits above everything real and below the
crash — and that is all it is. Where the JSON limit above has a factor of ten between the bound and
the crash, this one has a factor of two either side, so it is a guard against a pathological file
rather than a proof. Bound the depth with the tokenizer, as the JSON reader does, and never with a
byte scan: a scan counting brackets by hand reads the ones in transcribed speech.

**A bracket count bounds bracket shapes and nothing else, so the residual has to name its file.**
62 parentheses is the shallowest *bracket* overflow, not the shallowest one. A chain of `^` in a type
carries no bracket at all and overflows at about **eighty** carets with a counted depth of **one**;
`+` chains and `if`/`else if` chains go at about 1600. A counter over `(`, `[` and `{` cannot be made
to see any of them without becoming a second model of the grammar, which is the defect ADR-0028 is
about. Nor does odinfmt cover the gap — it formats the eighty-caret file without complaint and
survives 400 nested parentheses. So `check_one_file` in `tools\policy\main.odin` writes each file's
**name before it reads it** (`checking: <name>`, to standard error), which is what says which file a
crash was reading when `just check` dies naming nothing else. The residual is a crash that fails
`just check` naming one file, rather than one that says only that something died somewhere in
seventy-odd.

**`core:odin/tokenizer` fills its keyword table behind a double-checked lock that never re-checks.**
Two threads calling `tokenizer.init` for the first time both find `_global_keyword_lut_initialized`
unset, both take the spin lock, and the second runs `keyword_lut_init` over an already-filled table —
where its own `assert(entry.kind == .Invalid, name)` fires, inside `core`, on a thread the runner then
has to kill. One run in three of `tools\policy`'s test sweep died that way, with no summary and no
report, which is the failure mode issue #22 is about. A single-threaded program never meets it and
`odin test` runs twelve threads by default, so the table is filled by an `@(init)` before any test
thread exists. `@(init)` procedures must be `proc "contextless"`, so they build a context of their own
(rule S3) and cannot call anything that allocates.

**`odin build` does not require the package to be called `main`.** Measured at the pin: a package
named anything at all builds to an executable as long as it declares `main :: proc()`. That is what
lets `tools\policy` be `package policy` rather than `package main`, so the test runner reports its
tests under the name the directory has and
`just test-one policy a_body_that_never_closes_at_column_zero_is_read` selects one. The runner
matches `ODIN_TEST_NAMES` on the ODIN package name, and `just test-one`'s `pkg` argument resolves to
a package DIRECTORY (`tools/policy` for `policy`, `src/<pkg>` for everything else), so a `package
main` in a directory called `policy` can be swept but never focused.

**`core:fmt` pads an integer's width with ZEROS, not spaces.** `fmt_write_padding` picks `'0'` unless
the verb carried the space flag, and `_pad` calls it on whichever side `-` selects, so `%3d` of 0
prints `000` and `%-3d` of 7 prints `700`. A padded percentage does not read as a padded percentage;
it reads as a different number. `src\cli\transcribe.odin` printed `transcribing 000%` at the start of
a real run before the width verb came out of it. What a width would have bought is bought instead by
the trailing run of spaces in the format string: the reading only ever grows, so the number cannot
leave a digit behind, but the annotation beside it goes from eleven characters (`(estimated)`) to
none, and without that padding the carriage return leaves the old annotation sitting after the new
line. No test can catch a regression here — ADR-0009 names `cli` in `tools\policy\packages.odin`'s
`TEST_LESS_SRC_PACKAGES`, the one `src\` package the package-accounting check does not require of
the `justfile`'s `test` recipe — so this one line is held by review alone.

**An enumerated array and an exhaustive `switch` give the same compiler guard.** Measured against the
pinned compiler: add a member to an enum, leave its `[Key]Value{...}` table alone, and the build fails
outright with `Unhandled enumerated array case`. It does *not* quietly grow a row made of the zero
value — which is what this repository believed until somebody checked, and what run-time assertions on
every read had been placed to catch. A `switch` left alone the same way fails the same way. So a
missing entry is a build failure under either shape, and the choice between them is not a safety
argument. Issue #33 is the ticket that stops it being re-litigated per package; six packages carry a
fault vocabulary (`src\audio`, `src\child`, `src\engine`, `src\process`, `src\transcript`,
`src\artifact`) and they do not have to agree on shape.

What neither shape refuses is an entry written present and EMPTY. The table makes that the shape of a
hurried edit — `.New_Fault = {}` compiles — while a `switch` arm has to be spelled out before it will
build at all, so an empty one there is deliberate. That is the whole of the difference, and it is why
`src\engine`'s `fault_says` is a switch while `src\audio`, `src\process` and `src\child` keep tables
for theirs. `transcibr:audio`'s table writes one deliberately empty row, for the success value its
renderer refuses by name — and carries a second, smaller vocabulary of its own, `Cache_Fault`, whose
two members earn the switch shape instead of a fifth table (ADR-0018).

Catch the empty entry by WALKING the enumeration in a test (`src\audio\fault_test.odin`), guarded AS
WELL AS by the reader's own assert (rule A4: pair assertions across code paths) — neither is sufficient
alone, and the walking test is not a guarantee. Write the walking test to read the row or case itself
— `len(FAULT[fault].says) > 0`, `len(model_fault_says(fault)) > 0` — and `continue` before calling the
renderer, exactly as `src\audio\fault_test.odin` does; that removes the walking test's OWN call to the
renderer as a source of the hazard below, which is what issue #62's re-enumeration found three of this
family's tests skipping. It buys less than it looks like it does: `core:testing` runs every `@(test)` in
a package concurrently by default (see "The test runner hangs" below), so if ANY OTHER test in the same
package also exercises the renderer on the mutated row — and several legitimately do, to check a specific
fault's rendered wording — that sibling can still trip the reader's assert before the walking test's own
`expectf` ever runs. Measured on this branch mutating one row at a time in `src\artifact` and
`src\transcript`, each with a direct-read walking test already in place: at three of four sites tried
(`model.odin`'s `.Unreadable`, `sidecar.odin`'s `.Prompt`, `engine_json.odin`'s `.Empty_Input`) the
package's full `odin test` sweep died at the assert (`Illegal instruction`, no summary, no test named),
because a sibling test in the same package independently exercises the mutated row's renderer and races
the walking test for it. At the fourth (`place.odin`'s `.Sidecar`, which no sibling test independently
exercises), the full sweep instead reported the walking test's own failure cleanly — `1 test failed`,
exit 1, the row named — on 4 of 4 runs. Running the walking test alone
(`-define:ODIN_TEST_NAMES=<pkg>.<test>`) named the row every time, at all four sites. So the
walking test is what catches the defect in an isolated run of itself, always; whether it also wins the
race in a full package sweep depends on what else that package's tests exercise, and is not something a
test's own shape can promise. Where the reader's assert is the chosen answer, it stays: it is the shipped
binary's last line of defense against the same defect reaching a Recording already failing in front of
somebody (rule A8 — an internal invariant, not external input), and it is the A4 pair the walking test is
checked against, not a redundant copy of it.

The A4 pair is not the only sanctioned answer, and the walking test is not optional at either one. Two
families in this tree deliberately carry no reader assert at all, each for a recorded reason, and each
still requires the walking test:

- `src\doctor\report.odin`'s `sentence_or_fallback` — the shared fallback both `combined_message`
  (`report.odin`) and `health_error_message` (`src\doctor\health.odin`) route an empty row through —
  substitutes `NO_SENTENCE_FALLBACK` for the empty string instead of asserting. Per #137/#139: an assert
  in `src\doctor\engine.odin`'s `engine_fault_says` or `src\doctor\health.odin`'s `health_fault_says`
  would fire on the FIRST report of a check that is already failing in front of a user, turning a
  reportable failure into a crash. `engine_fault_test.odin`/`health_fault_test.odin` still walk the
  enumeration; `report_test.odin` pins `NO_SENTENCE_FALLBACK` so the fallback itself cannot go empty.
- `tools\policy\policy.odin`'s `fault_says` — the trailing `assert(false, "a fault with no words for
  it")` after the switch is unreachable for a case that compiles with an empty return, so this site has
  no reader assert either. A source file is external input (rule A8), and an assertion tripped by one
  would take the whole `odin test` runner down with it, not just the file being checked (issue #22).
  `fault_test.odin` walking `Fault` is the only guard on `fault_says`'s switch, by the comment's own
  words.

Choose the no-assert shape only when its reason applies — the row's absence must reach a caller safely
(A8) rather than crash a build or a check already failing loudly, or an in-renderer assert would take a
concurrent test run down with it (issue #22) — and keep the walking test either way.

**`odin test` cannot write its test executable to a path containing a space.** It runs the binary
it builds through a command line it does not quote, so a space is re-parsed as an argument
separator and the compiler exits `-1` with `Unknown argument encountered '<second word>'`. The
default output path comes from the working directory, so a checkout under `C:\Users\John Smith\`
fails before a single test runs, and CI never catches it because a runner's path has no spaces.
Issue #152 retired the PowerShell layer's space-free out-dir selection (a `build\odin-test\`
preference with a `%ProgramData%` fallback, chosen rather than sanitised out of the 8.3 short name)
along with everything else it held; every `justfile` recipe writes its test executables
under a plain `build\odin-test\` and nothing falls back. ADR-0035 records this as an accepted risk:
the failure is loud, never silent, so the fix is a checkout path with no space in it, not a wrapper.
`odin build` is unaffected.

**Win32 subprocess handling needs hand-rolled `CreateProcessW`.** `core:os` spawns children with
`CREATE_UNICODE_ENVIRONMENT` and `NORMAL_PRIORITY_CLASS` only, and `Process_Desc` has no field for
creation flags — so `CREATE_NO_WINDOW` cannot be passed through it. A console-subsystem build is
unaffected; any GUI-subsystem build pops a console window per child (one per ffmpeg, one per
whisper) until `CreateProcessW` is called directly with `STARTF_USESHOWWINDOW` and `SW_HIDE`, plus
`CreatePipe`/`PeekNamedPipe` to read output.
