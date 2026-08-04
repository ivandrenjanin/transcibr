# One Odin package per spec module, named for the module

`src/process/` is the *Process contract*. It holds `command_line.odin` today and will hold the
Engine output-line reader when issue #9 lands. It is not called `src/command_line/`, and the
directory name is the module's name rather than the file's.

The spec names the module once and gives it two halves — "builds command lines; interprets Engine
output lines into progress and duration events" — and names **one** test seam over both (S3). The
package boundary follows that line, and the file split happens inside it.

## Why this is a decision and not a preference

The two obvious alternatives both cost something a directory rename does not.

**A package called `command_line`** ends up holding progress parsing, because issue #9 has nowhere
else to put it that keeps one seam. A package whose name describes half its contents is a name that
misleads for the rest of the program's life, and renaming it later is the same work under worse
conditions.

**Two directories, `command_line` and `engine_output`,** splits one spec module and one named test
seam across two packages. Odin collects tests per package, so S3's seam would become two sweeps that
can pass and fail independently, and `test.ps1`'s per-package accounting would be tracking two
things the spec describes as one.

`src/transcript` is the precedent, and it is exactly this shape: 1:1 with its own spec module,
divided internally into `cue`, `paragraph`, `render`, `repetition` and `engine_json`. Nothing about
that package's name says which of the five a reader wants; the file names do.

## Why the rename happened before the second half, not after

It was free, and it stops being free.

Odin packages are **discovered rather than listed**: `test.ps1` sweeps every directory under `src/`,
so the renamed package was picked up with no configuration edit at all —
`$OdinPackagesWithoutTests` was not touched, and `process` collected its tests on the first run. And
nothing imported it yet, so no import path had to move.

Both of those stop being true the moment the spawner imports this package. The cost of the rename
was one directory; after #9 and a consumer it is a directory, an import in every consumer, and a
merge conflict with whatever is in flight.

`program` went with it, for a reason the directory name does not cover: inside the core it meant
three different things — transcibr's own name in `version.banner`, "this program" in CLAUDE.md's A8,
and the path of the child being started. The parameter, the faults and the writer all say
`executable` now, and `build` is `build_command_line`.

## Consequences

**A package doc comment may not describe one file.** `src/process/command_line.odin` opened with a
"THIS FILE builds..." paragraph in a comment attached to `package process`, which is the package's
documentation and not the file's. That paragraph goes wrong the day #9 adds `engine_output.odin`
next to it, and it goes wrong silently — nothing checks a comment. The package comment says what the
package is; each file says what it holds, below its own imports.

**The rule generalises to the two core modules that do not exist yet.** *Planning* and *Worker
planning* are named in the spec with seams of their own (S2, S4), so they get `src/planning/` and
`src/worker_planning/`, whatever the files inside end up being called. A third package that turns
out to hold half of one of them is this decision being reopened, not applied.

**The test-package accounting is what enforces it.** `test.ps1` fails any package under `src/` that
collects zero tests unless it is named in `$OdinPackagesWithoutTests`, so a new directory is a new
declaration a reviewer has to see. Splitting a spec module in two cannot be done quietly.
