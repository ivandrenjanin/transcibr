# Non-ASCII paths are refused three times over, and `transcibr-cli`'s own argv defeats the check before it runs

ADR-0002 measured that `whisper-cli` is `int main(int argc, char**argv)` under MSVC, so its argv
arrives in the system ANSI code page: a path carrying a byte outside ASCII fails to open, no output
appears, and the process exits **zero** — that decision's fourth measurement, and the reason none of
this can be left to the child to report. This ADR records how the refusal is actually spelled. Three
checks over one predicate, at three altitudes; why the two that overlap do not subsume each other;
and one measured hole in the console binary that nothing automated in this repository can hold.

The predicate is one procedure, `ascii_only` in `src/process/engine.odin`. It sits beside
`engine_arguments` rather than in `ffmpeg.odin` next door, and that placement is load-bearing: ffmpeg
re-reads `GetCommandLineW()` and does **not** have the bug (ADR-0002), so probing and extraction look
perfectly clean while only transcription fails. A reader who found the rule filed beside all three
argument lists would draw exactly the wrong conclusion about which child it constrains.

| check | asks about | when | answers |
|---|---|---|---|
| `audio.open_cache` | the **resolved** scratch cache | once per Batch | `Cache_Fault.Path_Not_Ascii` |
| `artifact.identify_model` | the **resolved** Model path | once per Batch | `Model_Fault.Path_Not_Ascii` |
| `engine.openable_by_the_engine` | the Model, the audio and the output prefix **as spelled** | once per Recording | `Fault.Path_Not_Ascii` |

## The third refusal is per-Recording, and that asymmetry is not an oversight

The scratch cache is one directory for the whole Batch and the Model is one file, so both questions
have one answer for every Recording and both are answered once, before anything starts — the shape
ADR-0018 records as standing in for the `doctor` ADR-0002 asks for (issue #13).

The third cannot be. The artifact stem comes from the **Recording's own name** (ADR-0008), so the
offending byte arrives with the Recording rather than with the settings: a Batch of ASCII-named
Recordings plus one called `Björn.mp4` fails exactly that one and carries on, which is ADR-0002's
disposition for a per-Recording failure.

It is refused **before the child starts**, and that is the whole value of it. The Engine's own answer
to a path it cannot open is to spend the GPU time, write nothing and exit zero, and there is nothing
in that a caller can act on. `src/engine/engine_test.odin` pins the negative space rather than the
message: `a_recording_whose_scratch_paths_the_engine_cannot_open_never_starts_one` sets `job.name` to
`Björn interview` and asserts that a marker file the stand-in child writes on its first line never
appears.

## It does not cost nothing, and which caller pays decides how much

The refusal is cheap relative to the Engine, not cheap absolutely. The order is `open_cache`, then
`identify_model`, then `stem_of`, then `extract_one` — an ffprobe of the container and a **full ffmpeg
extraction** — and only then `engine.transcribe`, which is where `openable_by_the_engine` runs. Where
the offending byte arrives **intact**, one complete pass over the Recording has been spent by the time
this check fires. That is the caller which hands its paths over in process: the window ADR-0004
promises.

It is **not** what `transcibr-cli` does with a Recording named on its own command line, and the
section below is why. That argv arrives ANSI-mangled, so the bytes are already `?` by the time
anything looks — and `extract_one`'s first act is `audio.read_source`, whose first act is `os.stat`
(`src/audio/run.odin`). A path carrying `?` where the name was does not exist, so the Recording is
refused as `Source_Unreadable` before ffprobe starts, never reaching the ASCII rule and never paying
for a pass. The wrong reason, and cheaply: the same defect the argv section records, seen from the
cost side.

The check that costs nothing is the Model's, which `transcibr:artifact` makes once at Batch start,
before any Recording is touched. Recorded because the source comment claimed the per-Recording check
cost nothing, and a reader who believes that will move it later rather than earlier — and because the
first correction of it over-generalised in the other direction, billing `transcibr-cli` for a pass it
never makes.

## Two checks on the cache coexist, and neither subsumes the other

`open_cache` asks about the **resolved** cache, which is ADR-0002's own wording and the move ADR-0018
records: the scenario that decision names is a path perfectly ASCII as spelled that is not once
resolved — a non-ASCII Windows account name inside `%LOCALAPPDATA%`, which a relative cache path
resolves straight into. The prefix that `openable_by_the_engine` checks is
`fmt.aprintf("%s\\%s", job.cache, job.name)`, so it carries the cache **as the caller spelled it**,
plus a component `open_cache` never sees at all.

They disagree in both directions:

| situation | resolved cache | prefix as handed to the child | `open_cache` | prefix check |
|---|---|---|---|---|
| cache spelled `cache`, account `Björn` | `C:\Users\Björn\…\cache` | `cache\lecture` | refused | accepted |
| cache spelled `C:\scratch`, Recording `Björn.mp4` | `C:\scratch` | `C:\scratch\Björn` | accepted | refused |
| cache spelled `C:\scratch\Zürich\..\cache` | `C:\scratch\cache` | `C:\scratch\Zürich\..\cache\lecture` | accepted | refused |

Row one is ADR-0002's named scenario and is why the Batch-level check resolves first. Row two is the
stem arriving from the Recording. **Row three is reasoned from `get_absolute_path`'s contract and was
not measured** — a resolver that drops a `..` component drops the byte with it — but the refusal it
produces is the correct one either way, because the string the Engine is handed still carries the
byte.

So what the per-Recording check covers is the prefix a child is **really handed**, and the
Batch-level question stays where it is answered. The earlier version of this reasoning claimed the
prefix check was a second route to the same answer; that is exactly the reasoning under which one of
the two would later be deleted as duplication, and deleting either one reopens a silent failure at
exit code zero.

## All three paths, and three `if`s rather than one conjunction

The Model comes from settings; the audio and the output prefix are both named from the Recording's
stem (ADR-0008). **A check on one of them is a check on none** — any one of the three carrying a byte
outside ASCII produces the same silent nothing at exit code zero, so a check that covers two of them
covers the failure not at all.

`every_path_one_invocation_is_handed_is_checked_and_not_just_the_prefix` spoils them one at a time:
the Model as `C:\models\ggml-large-v3-türkce.bin`, the audio as `C:\nowhere\录音.wav`. Each spoiling
must answer `Fault.Path_Not_Ascii` and must leave the marker file absent.

It is three `if`s and not one conjunction, which is rule S2's own remedy: every case is visible, and
the day one of them earns a fault of its own there is a line to put it on. The empty path answers
ASCII, which is honest and never useful — a caller with nothing in hand has a different complaint,
and each of the three callers states that one separately.

## `transcibr-cli`'s own argv arrives mangled, one layer above the Engine

This binary has ADR-0002's third measurement itself. Odin's Windows entry point is
`main :: proc "c" (argc: i32, argv: [^]cstring)` in `base/runtime/entry_windows.odin`, so `os.args`
is the C runtime's ANSI argv — exactly like `whisper-cli`.

| typed on the command line | what the program receives | refusal that fires |
|---|---|---|
| `--model-file <temp>\<two CJK characters>\model.bin` | `<temp>\??\model.bin` | `Model_Fault.Unreadable`, "the Model could not be read" |

The refusal that should have fired is `Model_Fault.Path_Not_Ascii`, "the Model is under a path the
Engine cannot open, because it carries a byte outside ASCII". It cannot: by the time `identify_model`
looks, there is nothing left for the ASCII check to see the byte in.

This does **not** weaken the ASCII refusals themselves. The scenario ADR-0002 names is a non-ASCII
Windows *account* name inside `%LOCALAPPDATA%`, and that byte arrives from an environment read rather
than from argv, so `open_cache` and `identify_model` see it intact and refuse it by name — as does
the window ADR-0004 promises, which hands its paths over in process. What it does mean is that a
Recording, a Model or a cache **named on this command line** with a byte outside ASCII is refused for
the wrong reason.

The fix is what ffmpeg does: re-read `GetCommandLineW()` and `CommandLineToArgvW` in place of
`os.args`. That is a change to how the binary starts rather than to any decision here, so it is its
own ticket. ADR-0019 measures the same API from the write side, and the relationship between them is
one way round only: this program builds command lines whose UTF-16 form re-splits into exactly the
arguments intended, including outside the Basic Multilingual Plane, and that says nothing whatever
about whether the child can then open the file. A correct command line is a precondition for the
fix above, never a substitute for it.

It matters more than it looks, because nothing automated can ever hold it. ADR-0009 records that
`src/cli` is named in `$OdinPackagesWithoutTests` and that `test.ps1` *requires* it to collect zero
tests, and that the only thing which runs the built binary is `build.ps1`'s smoke test, with no
arguments, reading the banner line. This ADR and review are the whole of the enforcement.

## Addendum (2026-08-06, #152)

The three pointers above re-anchor without changing the conclusion. `$OdinPackagesWithoutTests` is
now `TEST_LESS_SRC_PACKAGES` in `tools\policy\packages.odin`; `test.ps1`'s refusal is now `just
check`'s `exempt_packages_holding_tests`; and what runs the built binary is the justfile's `smoke`
recipe — the same no-arguments banner read, now also asserting the banner reached standard output
(the #119 review's finding). This ADR and review remain the whole of the enforcement for the
non-ASCII refusal this record is about.

## What would fix the class, considered and deferred

Decouple the scratch name from the artifact stem. The Engine only ever sees paths inside the cache,
so those could be named from something injective and ASCII **by construction**, while the artifacts
written beside the Recording keep the Recording's own name. That removes the per-Recording check
entirely and leaves two Batch-level questions about settings.

The price is that it changes what ADR-0008 says a stem is — the claim that audio, engine output,
transcript and Sidecar all share one stem — and it moves three packages, so it is not that ticket.
Until it lands, a Recording whose name carries a non-ASCII byte fails loudly and by name, which is
what ADR-0002 asks for and a great deal better than the silent nothing it replaces.

## The accepted cost

**A user with a non-ASCII Recording name cannot transcribe it until they rename the file.** ADR-0002
requires the ASCII property be *chosen* rather than sanitised — 8.3 short-name generation looks like
the escape and is a per-volume policy that can be off, and does not apply retroactively to a
directory that already exists — so there is no automatic way out, and the program says rename rather
than doing it.

Where the name reaches the check intact, that refusal is paid after a probe and a full extraction, per
the correction above; the Recording costs one pass before it is told no. Named on `transcibr-cli`'s
command line it costs nothing and is told the wrong thing, which is worse.

Three checks over one predicate, spread across three packages, with a visible overlap between two of
them. It reads as duplication, and the last reader to act on that reading wrote the misreading into a
comment rather than into a deletion. The next one may not stop there.

A path that is not valid UTF-8 answers `.Unusable` or `.Unreadable` and not `.Path_Not_Ascii` in
either Batch-level check, because `get_absolute_path` refuses it before the ASCII rule sees it, and
NTFS permits an unpaired surrogate in a name. Both answers stop the Batch and name the file, so what
is lost is the reason — and the reason is the one that says what to rename.

And on the command line the reason is wrong outright, with no test that can go red when it changes.

## What reopens this

The scratch/stem decoupling landing, which retires the per-Recording check. `CommandLineToArgvW`
landing in `main`, which retires the wrong-reason refusal and makes the Batch-level checks answer for
command-line paths too. A `doctor` (issue #13) arriving to take the two Batch-level answers in one
place, as ADR-0018 already anticipates. Or a measurement showing a whisper.cpp build that re-reads
the wide command line — which would retire the rule itself rather than relocate it, and until such a
measurement exists the rule stays where all three copies of it are.
