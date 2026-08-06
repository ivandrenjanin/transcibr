# `src/doctor` is a new package for preflight verification, spanning what the spec assigns to no single existing module

ADR-0017 puts one Odin package on each spec module the maintainer confirmed. Preflight verification
(story 8) and runtime GPU verification (story 9) are not one of the four core modules or the shell
modules docs/spec/0001-transcibr-v1.md names — they are a cross-cutting check over three of them:
whether ffmpeg and ffprobe (extraction) actually run, whether the Engine (Engine invocation) is a
complete install that actually reaches the GPU, and whether the Model (artifact storage) actually
loads in that Engine. ADR-0011 is the decision this package implements — spawn-and-verify, never
stat-and-trust — and it names no package of its own to hold that logic in.

## Why not fold it into an existing package

`transcibr:engine` already owns spawning the Engine for a real transcription and asserts
`job.container_ms > 0` on every call — a Recording precondition a preflight probe never has, because
it runs before any Recording is chosen. Reusing `engine.transcribe` for a health check would mean
either weakening that assertion for a caller that has no Recording, or growing a second entry point
inside a package ADR-0009 already keeps thin. `transcibr:artifact` owns hashing and publishing
artifacts, neither of which is "spawn a child and read its stderr." `transcibr:child`
owns the spawn primitive itself (`run_bounded`) and stays generic over what a caller does with the
bytes it drains — the doctor's own reading of those bytes ("does this line say `loaded CUDA backend
from`") is policy `transcibr:child` has no business carrying, the same separation `transcibr:engine`
and `transcibr:process` already draw between spawning and interpreting.

The result is a package that imports `transcibr:child` — and nothing of `transcibr:artifact`, because
a digest with nothing to compare it against verifies nothing (see "What it holds") — and is imported
by `transcibr:cli`, for the preflight report, and by
`transcibr:pipeline`, for the runtime check against the first completed Recording of a Batch — the one
place that Recording's measured realtime factor and its Engine output are already both in hand. No
cycle: `transcibr:cli` already imports `transcibr:pipeline` itself, and `transcibr:pipeline` already
sits below `transcibr:cli` and above `transcibr:artifact`/`transcibr:child` in the layering
CLAUDE.md's Odin notes record (L2 `artifact`/`child` → L4 `pipeline` → L5 `cli`); `transcibr:doctor`
takes the same L2 position `transcibr:artifact` and `transcibr:child` already hold, so both importers
reach it downward.

## What it holds

Four checks the ticket names — extraction tooling, the Engine directory, the Model, and a GPU
diagnostic — each rendered as one `Check` a `Report` can print, never itself. The Engine check is the
one ADR-0011 is actually about: it refuses a path that is not a file, refuses before spawning
anything if `ggml-cuda.dll` is not beside it, and then spawns `<executable> --help` — cheap because
the Engine loads every backend candidate before it even reads its own arguments — and reads the
captured stderr for the line the Engine itself writes when the CUDA backend actually loaded.
`vendor:directx/dxgi` backs the GPU diagnostic line alone, and is never the verdict: ADR-0011 says
checking a GPU exists proves nothing about whether the Engine reached it, and the Engine check above
is what actually decides that. (`core:sys/info.iterate_gpus` enumerates nothing at all on the
reference machine, whose GPU the Engine reaches perfectly well, which is why the diagnostic goes
through DXGI directly.)

The Model check is spawn-and-verify for the same reason, and nothing about the Model's bytes is
hashed. A size floor and the ggml magic bytes are a cheap pre-filter that refuses an obviously broken
download without paying for a spawn; the verdict is a real `<engine> -m <model> -f <a committed
probe wav>` run, which passes only when the run finishes AND the Engine exits zero AND it reported
something. The exit status is the load verdict, not the failure marker whisper.cpp prints: a Model
corrupt enough to trip a `GGML_ASSERT` aborts the process before that line can be written, and a
probe reading the marker alone calls that a pass. A SHA-256 over the Model's bytes was tried and
removed: it cost 6.9 seconds of an 8.5-second doctor run and was compared against nothing, and a
load probe is both cheaper and strictly stronger. Hash-against-a-reference becomes real when issue
#14's downloader ships a manifest to compare against; the doctor gains it then.

The Model check depends on the Engine check, and it is the one dependency in the report. Where the
Engine check did not pass, the load probe is skipped rather than run, and the Model line reads SKIP
with the reason — an Engine missing `ggml-cuda.dll` still loads a perfectly healthy Model on the CPU,
and a doctor that failed the Model on that evidence would send a user to re-download it for nothing.
The nonzero exit is already the Engine's; a skip never turns the report's verdict false on its own.

`transcibr:doctor` also holds the runtime half of the same guard (`health.odin`): a pure
`first_recording_health` comparing the Engine's own `systeminfo` report against a realtime factor,
against the baseline docs/spec/0001-transcibr-v1.md measures (roughly 17x realtime at beam size 5) and
the order-of-magnitude threshold ADR-0011 names. This is core in ADR-0009's sense — no I/O, no clock,
pure comparison — living beside the shell checks that share its vocabulary rather than off in
`transcibr:pipeline`, which is where a caller reaches to actually apply the verdict.

## Consequences

A package with no seam of its own among S1–S5 (the same shape `src/version`'s ADR-0029 already
recorded): `transcibr:doctor` is exercised by its own tests, not by the five spec seams, the same way
`src/version`'s banner is. Both importers keep ADR-0009's pure-core/thin-shell boundary intact — every
doctor decision (what counts as a pass, what a message says, what realtime factor is too slow) lives
in this tested package; `src/cli/doctor.odin` only parses arguments, calls it, and prints what comes
back, and `pipeline/recording.odin` only calls `doctor.first_recording_health` once, against the
first Recording a Batch finishes, and turns a failing verdict into the same cancellation signal a
Ctrl+C press already sets rather than inventing a second way to stop a Batch early.

## What reopens this

If a third package needs what `transcibr:doctor` holds, or if `transcibr:pipeline`'s own use of it
grows past the one call site this ticket ships, the shape is worth re-examining then, the same way
`src/version`'s own ADR names its own reopening condition.
