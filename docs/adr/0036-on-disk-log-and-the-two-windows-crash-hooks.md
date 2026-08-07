# On-disk log and the two Windows crash hooks

Issue #76, maintainer-ruled 2026-08-06. Spec stories 50 ("a log file on disk") and 51 ("a crash
leaves something in the log") mapped to no open ticket. The ruling: this lands as its own build,
before #16, covering both binaries; the artifacts live in local application data, never over the
network (story 57 stands); the design is the two-hook shape the 2026-08-06 adversarial review
measured at the pin (`dev-2026-07-nightly:819fdc7`); and this build owes the log-layer argument
below. `transcibr:crashlog` is the new package. Today only `src/cli` exists, so that is the one
binary this wires into; the package carries no dependency on `cli` in the other direction, so #16's
GUI binary installs the same two calls with no rework.

## Where the artifacts live

`%LOCALAPPDATA%\transcibr\transcibr.log`, created on first use (`crashlog.default_directory`,
`crashlog.open_log`). `%LOCALAPPDATA%` is local application data by definition and never a path this
program is handed by a user, so reading it is the one place this package touches the environment;
an unset or empty value is an operating error handed back through `ok`, never asserted (CLAUDE.md
A8 — external input, even environment-shaped, is rejected through an error return). One file, append
mode (`FILE_APPEND_DATA`): every crash artifact this build produces, whether the process asserted or
took an unhandled exception, lands in the one place spec story 50 asks a user to "look at a failure
after the program has been closed" — a user does not get to know in advance which of the two it was,
so both hooks write into the same place. This build does not yet write a rolling operational trail
into that file on the non-crash path; see "What this build deliberately does not do" below.

## The log layer: this package's own thin writer, not `core:log.create_file_logger`

The maintainer ruling asked for this argued and recorded. `core:log.create_file_logger` puts a
`Logger` on `context.logger` — a context-carrying, allocator-heavy abstraction built for structured,
leveled application logging. It was rejected for two reasons, one of them decisive on its own:

1. **The exception filter has no context at all.** `SetUnhandledExceptionFilter`'s callback is
   `proc "system"`, and Windows makes no promise the thread it fires on has ever built one, let alone
   an intact one — the maintainer ruling's own "zero allocation in a crashed process" constraint
   exists for exactly this reason. `context.logger` is a field of `context`; a callback with no
   context has no `context.logger` to call through, whatever this build put on it earlier. Only a
   handle-plus-raw-write mechanism reaches that callback at all, so something along those lines was
   going to exist regardless of what governed the operational log.
2. **Building it anyway means two log-writing mechanisms instead of one.** `context.logger` for
   everyday operation, and a separate raw writer for the crash path, is two implementations of "put a
   line in the file" that have to be kept looking like the same log by hand. `assertion_hook` (the
   `context.assertion_failure_proc` replacement) DOES have a context, but the maintainer ruling holds
   it to the same no-allocation bar as the exception filter regardless — so it, too, has to go through
   the raw writer, not `context.logger`. With both hooks routed through one writer already, there is
   nothing left for `core:log` to do that this package's own `open_log`/`write_str`/`format_hex`/
   `format_int` do not already cover, and pulling it in would only add a second code path the crash
   entries never use.

`raw_write.odin`'s helpers are the result: `"contextless"`, allocation-free, writing into a
caller-owned stack buffer and out through `win32.WriteFile` on a handle `open_log` opened once at
process start and never re-opened inside a hook (the maintainer ruling's "pre-opened handles"
constraint, applied to the log the same way it would apply to a minidump). `assertion_hook` and
`exception_filter` share these helpers, `record.odin`'s two line-shapes, and the same open handle
(`crashlog`'s package-level `g_log`) — one mechanism, one file, for both the everyday case and the
crash case.

## The two hooks, and why installing one is not installing the other

`assertion_hook` replaces `context.assertion_failure_proc`. `assert`, `ensure`, `panic`,
`unimplemented` and a context-carrying failed type assert reach it. `assert_contextless`,
`panic_contextless`, and — the one that matters most in practice — every bounds and slice check do
not: `base:runtime`'s own `bounds_check_error` and `slice_handle_error` print to stderr contextlessly
and then call `RaiseException(EXCEPTION_ARRAY_BOUNDS_EXCEEDED, ...)` directly, never touching
`context.assertion_failure_proc` at all. `exception_filter`, installed once via
`SetUnhandledExceptionFilter`, is the only hook that ever sees that path. Confirmed by
`crashlog_crash_test.odin`'s bounds-check test asserting the NEGATIVE space too: the log holds
`CRASH exception=0xc000008c` and never `runtime assertion`, because `assertion_hook` genuinely never
ran for it.

`context.assertion_failure_proc` is per-context, not process-wide, and Odin's implicit `context` does
not propagate back out of a call that has already returned — only forward, into whatever a scope
calls next. This means `context.assertion_failure_proc = crashlog.assertion_hook` cannot live inside
`crashlog.install` or any other helper that returns; a helper would set it on its own, now-discarded
copy of the context and the caller's own context would be unchanged the moment that helper returned.
`crashlog.install` therefore only opens the log and calls `SetUnhandledExceptionFilter` — real,
process-wide OS state a helper CAN set on the caller's behalf — and every site that wants assertion
coverage writes the one-line assignment itself: `src/cli/main.odin`'s `main`, and
`src/cli/crash_drill.odin`'s worker-thread entry point, standing in for the "every S3 context
rebuild" the maintainer ruling names (worker threads, and eventually wndprocs). This was found by
running the assert drill before writing the ADR: the first implementation hid the assignment
inside an `install_hooks` helper, and the log held only the exception-filter's line, never the
assertion line, because the context mutation never reached `main`.

## Measuring, not assuming

Both the assertion path and the bounds-check path are exercised by spawning a real, separate,
crashing process (`transcibr:child`, `crashlog_crash_test.odin`) and reading back what it left —
never by asserting inside `odin test`'s own process, which is the #22 failure class this repository's
whole no-concurrent-assert discipline exists to avoid. `src/cli`'s hidden `--crash-drill` mode is the
process: `assert`, `assert-thread` (a `core:thread` worker installing its own hook before asserting),
and `bounds` (an out-of-bounds index derived from `argc`, never a literal, so the compiler cannot fold
it to a refused compile-time-known access). All three are undocumented in `USAGE` and unreachable by
accident.

## What this build deliberately does not do

**No `MiniDumpWriteDump`.** The maintainer ruling marks it optional, and `DbgHelp`'s own
constraints — single-threaded, pre-opened handles, zero allocation in a possibly-corrupted
process — make it a focused piece of work worth its own test coverage rather than a few lines added
to an already-delicate crash path. The exception filter's log line (exception code and faulting
address) already satisfies spec story 51's literal wording — "something in the log" — and the
acceptance criteria's "an artifact... measured, not assumed." Re-entry path: a second pre-opened
handle for the dump file, opened alongside the log handle in `open_log`, and a call to
`MiniDumpWriteDump` from `exception_filter` guarded the same way this package already guards
everything else in the crash path.

**No wiring into `src/pipeline`'s real extraction/transcription worker threads.** The maintainer
ruling's scope note for this ticket was "today only `src/cli` exists — wire it there now"; `pipeline`
is generic ($Job, $Extracted) and carries no Windows dependency today, and adding one for crash
capture alone would couple a portable core package to this platform-specific concern for a ticket
that was scoped to the binary, not the pipeline. `crashlog_crash_test.odin`'s `assert-thread` mode
demonstrates the exact mechanism a real worker thread would use — `context.assertion_failure_proc =
crashlog.assertion_hook` at the top of the thread's own entry point — so wiring `pipeline`'s two
worker entry points (`run_extract_worker`, `run_transcribe_worker` in `src/pipeline/run.odin`) is a
mechanical two-line follow-up, not a design question. Re-entry path: exactly that.

Everything OUTSIDE `src/pipeline` is now wired, which was not true when this ADR was first written:
issue #76 review round 6 measured every real production worker crashing mute — a probe assert in
`transcibr:child`'s `read_worker`, reached through an ordinary `transcibr-cli --from-json`, left the
log holding a bare `CRASH exception=` line with no message, no location and no stack — because only
`main` and the drill's own synthetic thread installed the hook. The one-line install now sits at the
top of all seven: `read_worker`, `worker_loop` and the two directory workers in `transcibr:child`,
`digest_worker` in `transcibr:artifact`, `landed_worker` in `transcibr:engine`, and `head_worker` in
`transcibr:audio`. `src/pipeline`'s two remain the only deliberate omission, for the reason above.
One consequence is structural and worth naming: `transcibr:child` now imports `transcibr:crashlog`,
and Odin refuses a cyclic package import outright, so `crashlog_crash_test.odin` spawns its drills
through `core:os`'s own `process_start`/`process_wait` rather than through `transcibr:child` — which
costs those drills the Job Object they used to run inside.

**No rolling operational trail — only crash artifacts land in the file.** Spec story 50's "look at a
failure after the program has been closed" is served today only when that failure was a crash: no
procedure in this package ever writes a non-crash line, so a normal run, and an ordinary operating
error such as a refused CLI argument, leave the file untouched (issue #76 review round 3 measured
this directly — the file exists at 0 bytes after a version print, a refused `--plan`, and a
`--doctor` run). Nothing here rotates or bounds the file either, since nothing here grows it outside
a crash. Re-entry path: a `context.logger` (or this package's own writer, reused) wired into
`src/cli/main.odin`'s normal control flow, writing at the same everyday points the boundary already
reports through `refuse`/`ok`.
