# The operational trail rides the crash writer, and rotation happens once at open

Issue #176, filed from the #76 loop (PR #166, merged 97e6dca), and gating #16: spec story 50
("a log file on disk") is served today only when the failure was a crash. ADR-0036 already
discloses this deliberately, under "What this build deliberately does not do": `%LOCALAPPDATA%\
transcibr\transcibr.log` is opened on every run (`crashlog.install`, `install.odin:20-30`, which
calls `open_log` at `:24` before `register` at `:28`), but no procedure in `transcibr:crashlog`
writes a line outside a crash, so an ordinary healthy run — a version print, a refused `--plan`, a
`--doctor` run — leaves the file at 0 bytes (ADR-0036's own citation: issue #76 review round 3
measured this directly). #16 would otherwise wire a GUI view over a file that is empty in the
common case for every run that does not crash. This record amends ADR-0036's "No rolling
operational trail" and "Nothing here rotates or bounds the file either" clauses, by addendum
reference rather than by rewriting them — the addendum at the end of that document points here.

This is a design record only. No code moves in this PR; 176-B wires the trail at `src/cli`'s
existing report points, 176-C adds rotation, and 176-D (its own ADR, 0040) moves fault reporting
out of `src/pipeline`'s stdio writes and into events. What follows is what those PRs build to.

## D1. One mechanism, four line shapes — the trail rides `crashlog`'s own writer

`record.odin` holds three line shapes today: `record_assert_line` (`record.odin:13-29`, reached from
`assertion_hook`, `hooks.odin`), `record_stack_frame_line` (`record.odin:37-50`, reached from
`resolve_frame`, `hooks.odin:140`), and `record_exception_line` (`record.odin:58-75`, reached from
`exception_filter`, the process-wide `SetUnhandledExceptionFilter` callback) — all three
`"contextless"`, all three built from the same `write_str`/`format_int` primitives. `record.odin`
gains a fourth, `record_note_line`, beside them; `crashlog.note(level, subject, detail)` is the
public entry point, `"contextless"` and allocation-free like the three that exist, built from the
same `raw_write.odin` primitives (`write_str`, `format_int`, `format_hex`) writing into a
caller-owned stack buffer, never the heap. That shared shape is what makes `note` callable from a
wndproc, a worker thread, or the crash path itself with no second contract to reason about — the
same handle (`g_log`, `crashlog.odin:49`), the same non-allocating write primitive, one more caller
of it.

ADR-0036's decisive argument against `core:log.create_file_logger` — the exception filter's
callback has no `context` at all, so `context.logger` cannot be reached from it regardless of what
runs earlier in the process, and building a second, everyday-use mechanism on `context.logger` next
to the crash path's raw writer means keeping two implementations of "put a line in the file" looking
like the same log by hand — applies to a routine-path writer exactly as it applied when ADR-0036
was written. Nothing here reopens that argument; it is restated because a second writer for the
non-crash path was the obvious naive move, and the reason it is not taken has not changed since
`crashlog` was first built. `crashlog.note` is not a new writer with a new argument; it is a fourth
call into the writer ADR-0036 already chose.

Cost accepted, stated so nobody proposes recovering it later: `crashlog.note`'s three arguments
(`level`, `subject`, `detail`) are all plain strings and integers rendered by the same
`format_int`/`format_hex` helpers `record_assert_line` and `record_exception_line` already use —
there is no `fmt.aprintf`-shaped formatting anywhere in this package, because that formatting
allocates and the crash-path callers of the same writer cannot allocate. A caller that wants a
composed message builds it into its own stack buffer before calling `note`, the same discipline
`record_assert_line`'s callers already follow for `message`.

## D2. Rotation is by generation, once, at `open_log` — and the rename is best-effort and loud

`transcibr.log` growing past `LOG_CEILING_BYTES :: 8 << 20` is renamed to `transcibr.log.1`
(`MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`, replacing whatever `.1` already existed) before the
new run's handle is opened — inside `open_log`, ahead of its `CreateFileW` call
(`handle.odin:55-63`), and therefore ahead of `install`'s call into `register`
(`install.odin:32, 36`). `GetFileAttributesExW`, `MoveFileExW` and `DeleteFileW` are all bound at
the pin (`grep -rlw` over `C:\odin\dist\core\sys\windows\` returns `kernel32.odin` for each), so
nothing here is hand-declared. The size check is handleless — `GetFileAttributesExW`, not
`GetFileSizeEx` —
specifically so the size check itself never becomes the handle that blocks the rename: `handle.odin`'s
own open flags (`FILE_APPEND_DATA`, `FILE_SHARE_READ | FILE_SHARE_WRITE`, no `FILE_SHARE_DELETE`)
apply to any handle this package opens on the file, including a sizing one, and Windows enforces the
missing `FILE_SHARE_DELETE` against the opening process itself, not only against a second one. A
`GetFileSizeEx` call would need its own `CreateFileW` first and would have to close that handle again
before `MoveFileExW` could succeed — measured directly: a `FILE_APPEND_DATA` handle opened under
exactly `handle.odin`'s flags makes `MoveFileExW` on the same file fail `ERROR_SHARING_VIOLATION` in
the same process, and closing that handle before the rename call is what clears it.
`GetFileAttributesExW` never opens a handle at all, so this hazard does not arise.

Rotation never runs mid-run. ADR-0036 records the crash hooks' handle as pre-opened once at process
start and never re-opened inside a hook — "the maintainer ruling's 'pre-opened handles' constraint,
applied to the log the same way it would apply to a minidump." A rotation that could fire after
`register` has already pointed the exception filter and the assertion hook at `g_log` would leave
those hooks holding a handle to a file that has since been renamed out from under them; a crash
between that rename and process exit would either write into the renamed `.1` generation or fail
outright, either way breaking the constraint ADR-0036 states as load-bearing. Running rotation only
at `open_log`, before any handle exists, keeps it true by construction: whichever file `register`
gets a handle to is the one every hook writes for the rest of the process's life.

**The honest part.** `handle.odin:55-63`'s `open_log` shares `FILE_SHARE_READ | FILE_SHARE_WRITE`
and deliberately not `FILE_SHARE_DELETE` — issue #76 review round 2 measured a `FILE_SHARE_READ`-
only open refuse a second concurrent transcibr outright, which is why both flags are already there,
and Windows refuses to rename a file a second process holds open without `FILE_SHARE_DELETE`. So
while a second live transcibr already holds `transcibr.log` open, `rotate_if_over` refuses the
rename, and the new process opens the existing file anyway (append mode still finds its own end).
`note` writes through `g_log`, and `g_log` is not set until `register` runs (`crashlog.odin:44-49`,
"Set once, by `register`") — after `open_log` has already returned — so `open_log` cannot call
`note` itself; the refusal fact has to leave `open_log` some other way. `open_log` gains a second
result alongside its handle, `rotation_refusal: Rotation_Refusal`, and `install` is the one that
calls `crashlog.note` with it, immediately after `register` (`install.odin:32, 36`), by which point
`g_log` is live. That is a signature change to `open_log` — a small one, one added result — and D1's
"every existing caller gets it for free" claim below is scoped to rotation's *enforcement*, not to
this one WARN line.

**Amended, fix round 2 of issue #270's PR #270.** The round-1 review measured the rename failing for
a reason other than a second live transcibr — a live probe holding only the *destination* generation
file open (no source handle at all) still failed the rename, with `ERROR_ACCESS_DENIED`, not
`ERROR_SHARING_VIOLATION`. A bare `rotation_refused: bool` could not tell that case apart from the
one this section describes, so it reported "a second process holds transcibr.log open" for a cause
that was not that. `open_log`'s second result is therefore not a `bool` but
`Rotation_Refusal :: enum u8 { None, Second_Opener, Unknown }` (`rotate.odin`): `.Second_Opener`
only when `MoveFileExW`'s `GetLastError()` is exactly `ERROR_SHARING_VIOLATION`, the one cause this
section's reasoning actually confirms; every other rename failure is `.Unknown`, logged with a
cause-neutral detail rather than the second-process claim. `install` switches on the enum
exhaustively and warns for both non-`.None` cases, each with its own wording. **The sharing flags do
not change for this.** Adding `FILE_SHARE_DELETE` would let one process rename the very file a
second process is still appending to out from under it — precisely the failure rotate-at-open exists
to avoid, just moved from "crash hooks hold a stale handle" to "a live append lands in a file nobody
can find by its old name anymore." The refusal is the guard doing its job, not a defect masked by a
`WARN` line.

Residual, stated rather than fixed: the 8 MiB ceiling is not enforced while a second transcibr
process is alive; the file grows past it until the next launch that has the file to itself. Bounded
in practice, not by policy — a 56-Recording Batch's operational trail (§D4 below) runs on the order
of 600 lines at roughly 120 bytes each, near 72 KB, well under the 8 MiB ceiling even before
rotation is considered; concurrent transcibr processes are also the exception rather than the norm
(the CLI's own concurrent-use case, stories 45/46, is unguarded by design — R-25 in the GUI-era
planning session's risk register).

Date-named files under a `logs\` directory were considered and rejected. They require amending
ADR-0036's location clause against this very ticket's own wording rather than leaving it standing;
they add a second bound of their own — an age sweep, with its own best-effort-delete story no
simpler than the rename residual above; they make "which file is the log" ambiguous in a support
request, where today there is exactly one answer; and their one argument with real teeth — "two
processes sharing one log file is the whole defect" — does not hold: each transcibr process opens
its own handle to the one shared file (`handle.odin:55-63`), it does not share a handle with another
process's memory. The GUI design handoff's `logs\transcibr-2026-08-05.log` is a mock string in a
visual reference, not a location this codebase has ever used; the UI copy that names a path is what
gets corrected, in a later GUI-era stage, not this ADR.

## D3. Timestamps: `GetSystemTimeAsFileTime`, rendered UTC ISO-8601 by a pure contextless formatter

`GetLocalTime` is not bound at the pin (absent from the `grep -rlw` sweep over
`C:\odin\dist\core\sys\windows\`), and would need a timezone conversion this package cannot safely
run inside `exception_filter` regardless — the filter runs with no promise the process's heap or
locale state is intact. `GetSystemTimeAsFileTime` is bound (`kernel32.odin`) and is a lock-free read
of a page the kernel keeps updated, which is what makes it safe to call from `exception_filter` on a
possibly-corrupted process the same way `record_exception_line`'s two `runtime.assert_contextless`
calls already assume the `EXCEPTION_POINTERS` block itself is trustworthy enough to read
(`record.odin:59-66`).

Both the routine trail's lines and the three existing crash line shapes — `record_assert_line`,
`record_stack_frame_line`, and `record_exception_line` — carry the same timestamp shape, produced by
the same formatter. That is new: today none of the three carry a timestamp at all, only
`loc`/exception/frame fields. Giving every line — routine and crash alike — the same UTC ISO-8601
stamp is what makes a crash correlatable with the Batch that produced it, which nothing in the tree
does today. That includes `record_stack_frame_line`: a symbolized stack walk is a run of those lines,
the majority of what an assertion crash emits, and each one gets the same stamp as the `assert:` line
that triggered it. The FILETIME → `YYYY-MM-DDTHH:MM:SSZ`
conversion is integer civil-calendar arithmetic — `proc "contextless"`, allocation-free, callable
from the same three call sites `write_str`/`format_int`/`format_hex` already are, and fully testable
against fixed FILETIME values (a leap day, a year boundary) with no real clock involved. It is the
one place in this design a calendar bug can hide, which is why it is specified as pure and tested
against fixed inputs rather than against `GetSystemTimeAsFileTime`'s live return.

## D4. What is written, and what is never written

Written, through `crashlog.note`, at the points `src/cli` already reports through `refuse`/`ok`
today: process start (program name, version, subsystem, resolved DPI awareness once a GUI binary
exists, resolved UI font face once a GUI binary exists); every CLI refusal; Batch start with its
settings (root, entry counts by disposition, Model digest, Engine digest, Merge Profile, and
vocabulary's *length* — never its text); each Recording's terminal outcome with elapsed
milliseconds; every fault message verbatim, exactly as the owning package's own `error_message`
built it, never re-paraphrased; Stop; wake-lock acquire/release and any failure of either; Doctor
verdicts; download begin/verify/failure (URL, expected size, expected hash); settings writes; the
Batch summary.

**Never written:** transcript text, cue text, vocabulary text, or any bytes taken from a Recording's
audio or its Engine output. Spec stories 55 and 57 make the operational log itself a privacy
surface — a log that quotes a transcript puts a Recording's content on disk in a second place the
user never chose to put it, outside the artifact placement `transcibr:artifact` already governs. The
trail's vocabulary is exactly the boundary's own reporting vocabulary — nothing is invented to log
that the pipeline was not already reporting through `refuse`/`ok`/`error_message` — which is what
keeps the log from becoming a second source of truth that can disagree with what the screen (today,
the console; #16, the GUI) shows.

## The location clause is unchanged, and stays that way for a reason

ADR-0036's "Where the artifacts live" section fixes `%LOCALAPPDATA%\transcibr\transcibr.log`,
created by `crashlog.default_directory`/`crashlog.open_log`. This record does not touch that clause.
The rejected date-named alternative in D2 above is the only design considered here that would have
required reopening it; it lost on its own merits, not by default, and the location clause is called
out explicitly so a future reader who notices the GUI design handoff's mock filename does not read
that as evidence the location was meant to change. `Open log folder`, whenever #16 builds it, opens
`%LOCALAPPDATA%\transcibr\` with `ShellExecuteW` (bound at the pin) — a location this record leaves
exactly where ADR-0036 put it.

## What this record does not do

It does not move `src/pipeline`'s fault reporting out of stdio writes and into events — that is
176-D's own design, recorded in its own ADR (0040), because pulling the routine trail's write points
and the pipeline's event vocabulary into one record would tie two decisions the maintainer ruling
(R-10 in the GUI-era planning session) explicitly keeps apart until the seam is decided once. It
does not rename `transcibr:crashlog` to a name that no longer reads as crash-specific now that it
carries a routine trail too — that rename is its own ticket with its own maintainer ruling (the
GUI-era planning session's ruling R-5), filed and scheduled between #176 and the Win32 shell stage
if the maintainer wants it, not folded into this record. It does not wire `transcibr:pipeline`'s two
worker entry points into the crash hooks — ADR-0036 already names that as a re-entry path outside
this ticket's scope, and this record leaves it there.

## Consequences

`crashlog.note` becomes the one place a routine line is built, callable from every context the two
crash hooks already reach plus every ordinary boundary report `src/cli` already makes. Rotation's
enforcement lives entirely inside `open_log`, so every existing caller of `install`/`open_log` gets
rotation itself for free; reporting a refused rotation is the one exception, costing `open_log` one
added `Rotation_Refusal` result (D2) so `install` can log it once `register` has made `note`
callable. The trail
and the three crash line shapes now share one timestamp formatter, one writer, and one handle — the
same "one mechanism" property ADR-0036 built the package around, extended rather than replaced.

**Residual, stated and not fixed:** a trail line written from a worker thread and one written from
the UI thread (once #16's wndproc exists) can interleave. `FILE_APPEND_DATA` makes each `WriteFile`
call atomic against the file's current end, so a line can never tear mid-write, but the *order* two
threads' lines land in is not guaranteed by anything here. A mutex around `note` would close that,
and is deliberately not added: the crash path calls the same writer, and if a thread the crash
interrupted already held that mutex when `assertion_hook` or `exception_filter` fired, the crash path
would block on it forever instead of writing its line — the same hazard ADR-0036 names for
`MiniDumpWriteDump`/`DbgHelp`, whose "single-threaded, pre-opened handles, zero allocation in a
possibly-corrupted process" constraints (`0036-...md:96-97`) are exactly why that record keeps the
crash path free of anything that can wait on another thread.
