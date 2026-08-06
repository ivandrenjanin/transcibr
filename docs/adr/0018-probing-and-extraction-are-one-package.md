# Probing and extraction are one package, named `audio` for the pair, and the pure half of driving ffmpeg is not in it

`src/audio/` is the spec's shell module *extraction* and its shell module *probing*, in one Odin
package. The pure half of driving those two children — the command lines, and ffprobe's answer read
back as a duration — is not there at all: it is in `src/process/`, the *Process contract*.

ADR-0017 is one package per spec module, so putting two of them in one package is that decision being
narrowed rather than applied, and it is recorded here for that reason.

## Why it is not called `extract`

It was, for the length of one review. ADR-0017 refuses "a package whose name describes half its
contents", and a package holding *probing* and *extraction* called `extract` is precisely that — the
same defect that decision renamed `command_line` to `process` to avoid, with the same remedy: name it
for the pair. `CONTEXT.md` files **Probe** and **Scratch cache** under one heading, *Turning a
recording into audio*, and that heading is the name.

The rename happened here for ADR-0017's own reason: it was free and it stops being free. Nothing
imported `transcibr:extract` yet, packages are **discovered** rather than listed so
`$OdinPackagesWithoutTests` needed no edit, and the whole cost was one directory. After the first
consumer it is a directory, an import in every consumer, and a merge conflict with whatever is in
flight.

## Why the pure half went to the Process contract

`CONTEXT.md` defines the Process contract as "everything pure about driving a child **process**: the
command line one is started with, and the output lines it writes read back as progress and duration."
ffprobe is a child process. Its argument list is a command line one is started with, and its answer
is output lines read back as a duration. The match is with the module's own definition and not with a
convenient reading of it — the spec's sentence names the Engine, and `CONTEXT.md` generalises it to
"a child process", which is the wording this follows.

That leaves `src/process/ffmpeg.odin` holding the write side of a claim `src/audio` checks on the
read side: `AUDIO_SAMPLE_RATE` and `AUDIO_CHANNELS` are spelled once, ffmpeg is asked for them there
and the produced audio is required to carry them here (CLAUDE.md rule A4).

## Why probing and extraction are not two packages

They are one job. The probe exists **for** the extraction and for nothing else in this ticket: it
supplies the duration the produced audio is measured against, and it carries the two refusals that
stop an extraction from starting — a Recording with no audio stream, and one that cannot be timed.

Split into `src/probing/` and `src/extraction/`, the duration tolerance would have to live in one and
be used by the other, which is the "third package that turns out to hold half of one of them" ADR-0017
names. Odin also collects tests per package, so the one seam over "a Recording becomes audio and its
true duration is known" would become two sweeps that can pass and fail independently, and
`test.ps1`'s per-package accounting would be tracking two things the ticket describes as one. That is
the same argument ADR-0017 makes for keeping the Process contract's two halves together, applied to
two modules the spec happens to list with a comma between them.

## Why the pure decisions are in a shell package

ADR-0009 puts probing and extraction in the shell, and the decisions they rest on — the chunk walk
over a buffer, the duration tolerance, the two readings of a source, the sweep's choice of what may
be deleted — are pure and are where every test in this package is. They are not moved to a core
package of their own, because the core packages are named for **core spec modules** and there is no
core module for them; inventing one would be reopening ADR-0017 rather than narrowing it.

What makes them testable instead is the shape `remaining_ms` in `src/child` already uses: the clock
reading, the file length and the age are **handed in** rather than read inside, so a gap exactly
reached, a file dated in the future and a `data` chunk claiming more bytes than exist are all values
a case can produce and a clock and a filesystem cannot.

## Consequences

`src/audio` is the first package in this repository where the pure and the impure sit side by side,
and the file split is what keeps them apart: `riff.odin`, `duration.odin`, `settling.odin` and
`sweep.odin` are pure and carry the suite; `run.odin` runs the children and touches the disk. A
decision that turns up in `run.odin` belongs in one of the four beside it — the clock-step clamp on
how long to wait for a Recording to settle turned up there once and is `remaining_gap_ns` in
`settling.odin` now, with cases of its own.

`run.odin` is not *untested*, which ADR-0009 is sometimes read as licensing. It has no **unit** tests
because it holds no decisions to unit-test, and `run_test.odin` covers what `src/child` already
showed can be covered: children started under a bound and stopped when it runs out, and a real
scratch cache swept — which is the code that deletes files. What stays hand-verified is what needs
ffmpeg and ffprobe themselves, because a stand-in answering ffprobe's argument list would be a test
of the stand-in.

**The four tunables sit at four different altitudes, and that is a known shape rather than a
decision.** `Tolerance` is a defaulted parameter, `Sweep_Limits` a required one, and the settling gap
and both child bounds are constants hardwired at their call sites. The cost is visible in
`run_test.odin`, which has to declare a `SHORT_BOUND_MS` of its own and reach for the private
`run_bounded` to exercise a bound at all — where the two it can hand in, the tolerance and the sweep
limits, are checked through the public procedure like anything else. Levelling them is a settings
question and belongs to whatever ticket introduces a settings file; recorded here so that ticket
meets a shape somebody noticed rather than one nobody did.

**Nothing enforces that, and the ADR is the whole of the enforcement.** This once claimed "the same
pressure ADR-0009 records for `src/cli`", and the two are not alike. `src/cli` is named in
`$OdinPackagesWithoutTests`, and `scripts/test.ps1` fails a package named there that collects
anything — so a decision landing in `src/cli` turns the sweep red. `src/audio` collects its own cases
and is not listed, so a decision landing in `run.odin` fails nothing at all. What holds the line here
is review, and review is what it costs.

## The scratch cache is refused in its own vocabulary, and `doctor` is what is missing

`Fault` reports one Recording's failure, and deliberately carries neither the borrowed-culprit record
nor the disposition table: the culprit is always the Recording, and the disposition is always the
same. Two of its members made both claims false: `Cache_Path_Not_Ascii`
and `Cache_Unusable` are facts about the scratch cache, they are the same answer for every Recording
in the Batch, and they mean the Batch has nowhere to put any audio at all. Rendering one through
`error_message` — whose one documented job is *naming the Recording* — meant handing the cache
directory in the Recording's slot, at Batch start, before any Recording exists.

They are now `Cache_Fault`, with a switch, a checked reader and a renderer that names the **directory**
and says the Batch cannot start. `open_cache` and `sweep_cache` answer in it; `extract` does not call
`open_cache` at all.

**ADR-0002 asks for this loudly and once, in `doctor`, and there is no `doctor` in `src/` yet
(issue #13).** What this ticket does instead is check it once at Batch start rather than once per
Recording, in the vocabulary `doctor` will use when it arrives. That is a substitution, and it is
recorded here rather than left as N identical per-Recording failures standing in for one Batch-level
one. ADR-0002 also asks that the check be on the **resolved** path, and it now is: the scenario that
decision names is a non-ASCII Windows account name inside `%LOCALAPPDATA%`, which a perfectly ASCII
relative cache path resolves straight into.

**Built the same way, `Cache_Fault` would have been a fifth copy of the fault-report shape**, one too
many by the rule this ADR states here and nowhere else: "a third copy is the point at which the shape
moves into a package of its own and both of these import it." That sentence is not a `src/child`
comment the tree once carried and the comment ban later removed — `git log -S` for it, and for "THE
SECOND COPY IS THE LAST ONE", turns up only this document's own revisions. An earlier draft of this
paragraph attributed both quotes to `src/child`; that attribution does not survive checking against
`git log` and is corrected here rather than restated. `src/transcript/engine_json.odin` got its
`FAULT` table on 2026-08-03, and `src/audio`'s own `Fault`/`FAULT` — declared in this same file,
alongside `Cache_Fault` — is the fourth copy of the shape.

`src/audio` carries the small version — an enumeration, a table of sentences, one checked reader and
one renderer, and not the borrowed-culprit record — because the culprit here is always the Recording,
which the renderer is handed. Moving the shape is its own change and is not this one.

**`Cache_Fault` is a second vocabulary in this package and deliberately not a fifth copy of the
shape.** The type split above is load-bearing and stays: a Batch-level refusal must not be renderable
through a procedure whose one documented job is naming a Recording. What does not follow from it is
the rest of the apparatus. Two members do not earn a table of sentences and a checked reader of their
own — an exhaustive `switch` gives the identical compiler guard, and it does not bring the one
failure mode a table has, a row that is *present and empty*, which compiles and is found by the
reader's own assertion in front of a user. `Riff_Fault` and `process.Probe_Fault` are the shape
correctly declined: bare enumerations their consumer renders with `%v`. `Cache_Fault` needs a
sentence and nothing beyond it.

## Addendum (2026-08-06, #152)

Same family as ADR-0017's own addendum: the "packages are discovered rather than listed" reasoning
this record's "Why it is not called `extract`" section leans on no longer transfers forward. Packages
are named explicitly, one line per package, in the justfile's `test:` recipe, and `tools\policy`'s
package-accounting check (`packages.odin`) fails `just check` if a tested package under `src\` or
`tools\` loses its line, or a package holding no tests at all goes unnamed by its root's roster. The
`cli` guarantee ADR-0009 records survives under the new names: `TEST_LESS_SRC_PACKAGES` in
`tools\policy\packages.odin` is `$OdinPackagesWithoutTests`' successor, and
`exempt_packages_holding_tests` is what would fail `just check` if `cli` ever collected a test. The
decision to keep probing and extraction in one package, `src/audio`, is unaffected.
