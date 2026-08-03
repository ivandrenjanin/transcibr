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

## 5. Style

### S1. Formatting: odinfmt, tabs, the full vet set

Indent with tabs: odinfmt emits them and `-vet-tabs` enforces them. Every test and type-check
invocation passes the full vet set. A style rule that fights the toolchain becomes a rule nobody
runs; the formatter plus the vet flags are the rule.

The set is `-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do`. Do not spell
it out at a call site: `scripts\common.ps1` holds the only executable copy (`$OdinVetFlags`), and
both commands pass all of it.

```powershell
.\scripts\build.ps1     # every target in $OdinTargets, vet set, subsystem and smoke checked
.\scripts\test.ps1      # every package under src\, vet set, memory failures fatal
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

**Testing is built in; there is no framework to choose.** Mark procedures `@(test)`, import
`core:testing`, and assert with `testing.expect` and `testing.expect_value`. `.\scripts\test.ps1`
sweeps every package; `.\scripts\test.ps1 -TestName version.banner_names_the_program_and_its_version`
runs one. A name written here is checked against the real suite by `scripts\selftest.ps1`, so it
cannot go stale unnoticed.
Do not hand-roll the compiler invocation — the sweep also enforces that every package either
collects tests or is declared test-less in `$OdinPackagesWithoutTests`.

**`odin test` cannot write its test executable to a path containing a space.** It runs the binary
it builds through a command line it does not quote, so a space is re-parsed as an argument
separator and the compiler exits `-1` with `Unknown argument encountered '<second word>'`. The
default output path comes from the working directory, so a checkout under `C:\Users\John Smith\`
fails before a single test runs, and CI never catches it because a runner's path has no spaces.
`scripts\common.ps1` falls back to the 8.3 short name. `odin build` is unaffected.

**Win32 subprocess handling needs hand-rolled `CreateProcessW`.** `core:os` spawns children with
`CREATE_UNICODE_ENVIRONMENT` and `NORMAL_PRIORITY_CLASS` only, and `Process_Desc` has no field for
creation flags — so `CREATE_NO_WINDOW` cannot be passed through it. A console-subsystem build is
unaffected; any GUI-subsystem build pops a console window per child (one per ffmpeg, one per
whisper) until `CreateProcessW` is called directly with `STARTF_USESHOWWINDOW` and `SW_HIDE`, plus
`CreatePipe`/`PeekNamedPipe` to read output.
