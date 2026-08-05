# Where the pure/impure boundary actually falls

The program is a pure core inside a thin impure shell. The core holds cue parsing, paragraph
merging, hallucination stripping, Markdown rendering, the hardware→settings decision, job planning,
and Windows command-line quoting. The shell holds ffmpeg, the engine, the filesystem, and Win32.

This is not a style preference. The core is where the program's value lives *and* the only part that
can be tested properly — a speech model cannot be unit tested — so the split is what makes the
test-first discipline possible at all.

Three places the boundary is easy to get wrong, and where it actually sits:

**`plan_batch` does not enumerate anything.** It cannot: walking a directory tree is I/O. It receives
a finished list of paths and returns a plan — which recordings to process, which to skip, and the
reason for each. Discovery is the shell's job: recursive, off the UI thread, cancellable, streaming
its results, refusing to follow reparse points by default, and reporting a failed sub-directory
enumeration as an operating error rather than as an empty result. A silently short file list is the
one discovery failure a user cannot detect.

**Probing a recording with `ffprobe` is allowed, because it happens in the shell.** The concern that
probing would make discovery impure is misplaced — `plan_batch` still receives a finished list. Probing
once per recording at job start buys detection of a truncated container, a still-being-written file,
and a mid-file decode failure, any of which otherwise yields a transcript that ends mid-sentence and
is marked complete forever. It also supplies a true duration instead of one derived circularly from
the cues.

**Rendering takes an explicit `Render_Context`.** Front matter contains a clock read, an environment
read, and a machine-specific path. If the renderer reaches into the world for those it stops being a
pure function, and the golden fixture can only be compared with the front matter stripped — which
removes the entire metadata block from test coverage, letting a malformed YAML block ship into every
transcript. Passing `{ now, engine_version, source_display }` in keeps rendering pure and makes the
front matter the most-tested part of the output rather than the least.

## Consequences

Be honest about what this does not buy. The pipeline, the subprocess layer, the Win32 window and the
GPU path will never have unit tests; they get integration tests and a golden fixture, and that is the
ceiling. The core/shell split does not make the whole program testable — it concentrates the parts
that *can* be tested where the value also happens to be, and keeps everything else thin enough to
inspect by reading.

**The command line is on that list, and its bill is the one easiest to forget.** `src/cli` is named
in `$OdinPackagesWithoutTests`, and `test.ps1` *requires* it to collect zero tests. The direct
consequence is that no change to that package can turn a test red: deleting an assertion from it
leaves the whole suite green, and so does putting one back. Measured rather than assumed — the
empty-option-name assertion that A8 had removed from `read_option` was restored as a mutant and every
test in the repository still passed.

What runs the built `transcibr-cli` at all is `build.ps1`'s smoke test, and it runs it with *no
arguments* and reads the banner line. Nothing automated here exercises `--from-json`, `--profile`,
`--help`, or a refusal. So every claim the command line makes about itself — the assertions bracketing
`read_options`, the four shape checks in `print_version`, the byte count after the write — is held up
by review, by reading, and by whatever fuzzing a change brings with it. That is the price of a shell
thin enough to inspect, and it stays a fair price only while the shell stays thin: the moment a
decision worth testing turns up in `src/cli`, it belongs in the core instead, and the sweep's refusal
to let that package collect a single test is the thing that keeps asking the question.

The golden fixture is one real engine JSON plus its expected Markdown. That choice also pins the
JSON schema this design bets on (ADR-0001), so an engine upgrade that changes the schema fails a test
rather than silently producing empty transcripts.
