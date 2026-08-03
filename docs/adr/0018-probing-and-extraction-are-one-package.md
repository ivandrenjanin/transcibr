# Probing and extraction are one package, and the pure half of driving ffmpeg is not in it

`src/extract/` is the spec's shell module *extraction* and its shell module *probing*, in one Odin
package. The pure half of driving those two children — the command lines, and ffprobe's answer read
back as a duration — is not there at all: it is in `src/process/`, the *Process contract*.

ADR-0017 is one package per spec module, so putting two of them in one package is that decision being
narrowed rather than applied, and it is recorded here for that reason.

## Why the pure half went to the Process contract

`CONTEXT.md` defines the Process contract as "everything pure about driving a child **process**: the
command line one is started with, and the output lines it writes read back as progress and duration."
ffprobe is a child process. Its argument list is a command line one is started with, and its answer
is output lines read back as a duration. The match is with the module's own definition and not with a
convenient reading of it — the spec's sentence names the Engine, and `CONTEXT.md` generalises it to
"a child process", which is the wording this follows.

That leaves `src/process/ffmpeg.odin` holding the write side of a claim `src/extract` checks on the
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

`src/extract` is the first package in this repository where the pure and the impure sit side by side,
and the file split is what keeps them apart: `riff.odin`, `duration.odin`, `settling.odin` and
`sweep.odin` are pure and carry the suite; `run.odin` runs the children and touches the disk and has
no cases at all, which is ADR-0009's ceiling stated rather than an omission. A decision that turns up
in `run.odin` belongs in one of the four beside it, and the fact that `run.odin` has no test to add is
the thing that keeps asking the question — the same pressure ADR-0009 records for `src/cli`.

**It also brings a fourth copy of the fault-report shape**, which `src/child` says out loud is one
too many: "a third copy is the point at which the shape moves into a package of its own and both of
these import it". `src/extract` carries the small version — an enumeration, a table of sentences, one
checked reader and one renderer, and neither the borrowed-culprit record nor the disposition table,
because the culprit here is always the Recording and the disposition is always "this Recording fails
and the Batch carries on". Moving the shape is its own change and is not this one.
