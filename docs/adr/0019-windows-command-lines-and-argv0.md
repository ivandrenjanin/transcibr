# Windows command lines are built against a measured CommandLineToArgvW, and argv[0] is a second rule

`build_command_line` in `src/process/command_line.odin` is the one place this program writes a
Windows command line. It carries **two writers** — one for the executable path, one for every
argument after it — seven refusals, and a ceiling counted in UTF-16 code units. Its suite hands every
line it builds to the real `CommandLineToArgvW` in shell32 and compares what comes back with what
went in.

ADR-0004 records the decision in a single line: "We own Windows argument quoting, unit-tested in the
pure core against adversarial paths." This ADR is the evidence under that sentence. Every rule below
was **measured against `CommandLineToArgvW` itself**, not read off documentation.

Windows has no argument vector. `CreateProcessW` takes one string and the child splits it again,
almost always with `CommandLineToArgvW` or with the identical rules baked into the C runtime that
fills `argv`. Getting the quoting wrong is therefore silent: an argument disappears, or one argument
becomes two, and the child does something subtly different from what was asked. `-i` followed by a
path that lost its quoting is ffmpeg reading the first word of a folder name.

## argv[0] is parsed by a rule of its own

This is why there are two writers rather than one. For argv[0] the scan is *skip the opening quote,
copy until the next one*, and **no backslash is special**. Measured rows:

| command line | argv[0] | what follows |
|---|---|---|
| `"C:\dir with space\" one` | `C:\dir with space\` | argv[1] `one` |
| `"C:\dir\\" one` | `C:\dir\\` — **both** backslashes kept | argv[1] `one` |
| `"a""b" one` | `a` | argv[1] `b`, argv[2] `one` |
| an empty command line | **the running executable's own path** | — |

Two consequences follow directly. Reusing the general argument rule here doubles a trailing backslash
and hands the child `C:\dir with space\\`, a path the filesystem does not have — and a path that
already ends in a doubled run keeps both backslashes, because nothing in argv[0] was ever an escape,
so there is no collapsing anywhere for a writer to compensate for. And there is no escape for a quote
in argv[0] at all, so an executable path containing one cannot be expressed at all — the fault
`Quote_In_Executable` refuses it rather than emitting something that parses as a different path.
Windows forbids `"` in a filename anyway, so a caller holding one has a bug rather than an exotic
path.

The empty row is the reason `.Empty_Executable` exists rather than passing an empty line on. An empty
command line is not an error to Windows; a child handed one would silently run against itself.

`write_executable` therefore quotes and does not escape, and it is guarded on the write side. The
mutant it stops is a reader's own "correction" of the rule above, and **three assertions have to be
defeated before a wrong argv[0] can be observed rather than crashed on**: the length assertion in
`write_executable`, then "the escaping outgrew the reservation made for it" (the extra byte overruns
a reservation that allowed the path exactly its own length plus two quotes), then the A3
negative-space check on a line with no arguments. Only then do two tests fail —
`a_trailing_backslash_in_the_executable_path_is_not_an_escape` and
`the_executable_path_round_trips_under_its_own_rule`, both naming the doubled path they got back from
`CommandLineToArgvW`.

## The rule for every argument after it

The part people get wrong is the backslash rule, and it is not "escape every backslash". A run of
backslashes is **literal unless it meets a quote**: a run of 2n before a quote is n backslashes plus a
structural quote, and 2n+1 is n plus a literal one. The closing quote counts as a quote — which is why
`C:\path with space\`, quoted naively, ends `\"` and runs on into the next argument.

The separator set is exactly two characters plus the quote itself, measured:

| character | splits an argument? |
|---|---|
| space, tab | **yes** — the whole reason quoting exists |
| newline, carriage return | no |
| vertical tab, form feed | no |
| U+00A0 no-break space, U+3000 ideographic space | no |
| cmd.exe's metacharacters — caret, ampersand, pipe, percent, angle brackets | no — ordinary text |

The metacharacters are ordinary text because `CreateProcessW` starts the child directly and there is
no shell anywhere in this path to interpret them. A builder that quoted them anyway would still be
correct; one that quoted them and got the escaping wrong would not, which is what
`METACHARACTER_CASES` pins.

An **empty argument must be quoted or it disappears**, and being wrong here is worse than a mangled
string: the child does not receive an empty value, it receives one fewer argument, and everything
after shifts down a place. Measured, `x.exe  -flag` reaches `CommandLineToArgvW` as argc 2 while
`x.exe "" -flag` reaches it as argc 3. `--language "" --model big.bin` with the empty one dropped is
a child told its language is `--model`.

## What is refused, and why the refusals live in the pure core

Seven faults, each named against the input that carried it. A8 puts them here: an executable path and
an argument list arrive from outside — a CLI flag, a discovered recording, a configured model path —
so a bad one is an operating error through the return, never an assertion.

A NUL is **two faults and not one** (`Nul_In_Executable`, `Nul_In_Argument`) though the byte and the
damage are identical: a NUL ends the command line where Windows reads it, silently discarding every
argument after it. They are produced by two different scans, and a caller holding a single
`Embedded_Nul` cannot say which input to go and fix. "A NUL somewhere" names no file.

The UTF-8 refusal is the one that could plausibly have been left to the shell, and the number is why
it was not. `build_command_line` returns UTF-8; the spawner converts with `utf8_to_utf16`, which
passes `MB_ERR_INVALID_CHARS` and answers nil rather than substituting. **A fuzz run produced 9,790
command lines the builder accepted that the conversion could not encode** — every one of which would
have failed later, in the layer ADR-0009 says will never have a unit test, with no `Build_Error`
naming the offending argument. That count is the whole justification for the refusal sitting in the
core, and it is the same argument that keeps `MAX_COMMAND_LINE_UNITS` here.

The check itself is `utf8.valid_string` rather than a hand-rolled scan, and that it agrees with
Windows is measured: **across 194,984 random byte strings, `utf8.valid_string` and
`MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS)` returned the same verdict every time — zero
disagreements.** Both reject unpaired surrogates, overlong forms, truncated sequences and stray
continuation bytes. This is reachable from the filesystem rather than exotic: NTFS permits unpaired
surrogates in a name and `wstring_to_utf8` hands one back as WTF-8. The suite keeps the named cases —
unpaired high and low surrogate, `0xFF`, a lone continuation byte, three- and four-byte sequences cut
short, and one buried in otherwise valid text — as `UNENCODABLE_CASES`; the fuzz run is what
established the rule and is not re-run.

Six of the seven refusals are inputs that cannot be spelled on a Windows command line at all, and no
retry changes that. `.Too_Long` is a different kind of refusal — the same job fits if it is built
from shorter paths, and ADR-0002 puts the engine's output under `<cache>\<job_id>` with the cache path
transcibr's own to choose — so `Disposition` answers `Shorten_And_Replan` for it and `Fail_The_Job`
for the rest. A caller treating all seven alike would either retry the unfixable forever or fail a job
one shorter path would have run.

## The ceiling is counted in UTF-16 code units, and the asymmetry is why

`CreateProcessW`'s documented limit on `lpCommandLine` is 32,767 characters *including* the
terminating null. Characters means UTF-16 code units, which is neither bytes nor runes. The two ways
of getting that wrong are not equally bad:

| what the builder counts | what it does | what Windows does | what the child gets |
|---|---|---|---|
| bytes | refuses a line that fits | — | nothing runs; the refusal names a fault |
| runes | accepts a **40,027-unit** line built from a 20,000-emoji argument | **truncates at 32,767** | **argc 2 where 4 went in** — `--output` and the file after it silently gone |
| UTF-16 units | refuses at the real ceiling | — | nothing runs; the refusal names a fault |

The middle row is measured on a builder counting one unit per rune. There is no error anywhere in it:
the safe mistake fails a job, this one runs the wrong one.
`a_line_that_only_fits_when_runes_are_counted_is_refused` pins it with 17,000 astral runes — 34,000
units, over the ceiling, while the rune count is half that and comfortably under — and asserts that
the rune count *stays* under, because a body long enough to be refused on runes as well would pass
for the wrong reason.

`utf16_units`'s own postcondition is `units <= len(s)` and **not** `len(s) * 2`. That matters and was
measured: the loose bound is the surrogate pair's ratio applied to every byte, so it is satisfied by
any counting mistake within a factor of two — change the BMP branch to add 2 and ASCII reports exactly
`2 * len(s)`, which passes the old bound and fails this one. An assert that cannot fail on the edit it
exists to catch is a comment with a runtime cost.

## cmd.exe is a third parser, and it disagrees with both

`build_command_line` writes for `CommandLineToArgvW`. cmd.exe does not read that rule, and the two
places in `src/child/child_test.odin` that use `cmd /c` say so at the call site rather than working
around it silently.

An argument holding a space is quoted and an embedded quote is escaped `\"` — so a quoted path buried
inside a single `/c` command string reaches cmd with the backslashes still on it, and `type` **failed
every time**. cmd.exe also strips the outer quotes of a `/c` string when its first character is a
quote, and the quote it removes is the *last* one on the line — which would be a path's own closing
quote on a machine whose temp directory holds a space. So any path handed to cmd goes as its own
separate, space-free argument, quoted once, by us.

The same test carries a second measurement worth keeping: with a plain `&` instead of `&&`, the
standard-output case **passed whether the file was ever read or not**. `&&` runs the echo only if
`type` succeeded, so the word arriving is proof the file went to standard output rather than proof
the child reached the end of its command line.

## Nothing but the command line names the executable

`lpApplicationName` is deliberately nil in `create_hidden` (`src/child/child.odin`), so Windows reads
the executable back out of the command line. That is what lets a caller name a bare `ffmpeg.exe` and
have it found the way every other program on the machine finds it.

**It is safe only because `build_command_line` always quotes argv[0].** Unquoted,
`C:\Program Files\ffmpeg\ffmpeg.exe` can be re-read as `C:\Program.exe` with arguments — the classic
unquoted-path hijack. This is a security-relevant coupling between two packages that neither file's
code states, and it is why `build_command_line` asserts `out[0] == '"'` on the finished line rather
than trusting the writer.

## The suite breaks purity on purpose, and it costs the shipped binary nothing

A parser written here would only prove that the builder and the parser share an assumption: both
would agree, and a child linked against the real one would still receive something else. So `argv_of`
converts the line with `utf8_to_utf16` and hands it to shell32's own `CommandLineToArgvW`. The
builder stays pure under ADR-0009; the harness that checks it does not, and that asymmetry is the
only reason the criterion can be met at all.

The fear this invites is a shell32 dependency reaching ADR-0004's GUI binary. Measured A/B on the
image: **Odin does type-check `_test.odin` files in an ordinary build**, including for an imported
package — plant a broken one and `odin build` of a main package importing this one fails — but the
link-time conclusion does not follow. A main package importing this one carries **no SHELL32 import
and no `CommandLineToArgvW` anywhere in the image**, while a binary that really calls the API carries
both.

## What is measured and what is not

Measured, and **re-measured through the real parser on every run**: every value in the whitespace,
metacharacter, quote-and-backslash, non-ASCII and executable-path tables, each alone, all together
and flanked by neighbours; the two exact argv[0] lines `"C:\dir with space\" -after` and
`"C:\dir\\" one`; an emitted empty argument arriving as argc 5 with the flag after it intact; the
seven unencodable shapes; and both edges of the ceiling.

Measured once and **not** re-run — the suite keeps a named case in place of each, or nothing at all:
the `"a""b" one` split, the empty command line answering with the running executable's own path, the
`x.exe  -flag` argc 2 against `x.exe "" -flag` argc 3, the 194,984-string equivalence between
`utf8.valid_string` and `MB_ERR_INVALID_CHARS`, the 9,790 accepted-but-unconvertible lines, the
rune-counting truncation (which the shipped builder now refuses instead of reproducing), the cmd.exe
rows, and the link-time A/B on the image. The sample size of the run that produced the 9,790 is not
recorded, so that figure is a count and not a rate: it is load-bearing as a demonstration that the
class is large, not as a proportion.

Documented rather than measured: the 32,767 ceiling itself is Microsoft's figure. What was measured
is the *behaviour past it* — truncation without an error — which is the part the decision rests on.

Argued rather than fuzzed: the reservation. It allows twice each argument's bytes plus
`MAX_ESCAPED_OVERHEAD` of 3 — the separating space and the two quotes that may go around it — and the
claim underneath is that no byte can cost more than two. A quote becomes two bytes, a backslash
becomes at most two, everything else is copied through, and the
worst case is reached rather than merely bounded — an argument of nothing but quotes writes `\"` for
every one, and `\\\\"` writes nine backslashes and a quote for five bytes. The runtime check is the
assertion after the build, `len(out) <= reserve`, which is the read side of the reservation rather
than a proof of it.

## The accepted costs

**A recording whose name Windows itself cannot encode is refused rather than transcribed.** NTFS
permits an unpaired surrogate in a filename; transcibr will not build a command line for it. That is
a real file a user can own, reported against the file that caused it and skipped for the life of the
program.

**`.Too_Long` is decided on the finished line, so the builder is fully allocated and filled and then
destroyed before returning.** Nothing leaks, but the memory is taken and given back, proportional to
the *inputs* and not bounded by the ceiling: a one-megabyte argument reserves about two megabytes and
is only then refused. A caller passing a nearly-exhausted arena (ADR-0010) will feel it.

**The package's tests are Windows-only and impure by construction.** They cannot run anywhere else,
and the harness is checked by nothing but review — this is the ceiling ADR-0009 already describes for
the shell, accepted deliberately here in exchange for the only ground truth there is.

**There are two Windows argument quoters in this repository and they do not share a corpus.**
`build_command_line`, and `ConvertTo-NativeArgument` in `scripts/common.ps1`. The PowerShell side pins
seven values in `scripts/selftest.ps1` under `every argument survives the trip through a native
command line`, against a dumper that prints the argv it received: the empty string, `plain`,
`two words`, `C:\path with space\`, `a"quoted"b`, `trailing\\` and `-define:NAME=a b"c`. All seven are
currently covered on the Odin side — three by shape (`''` by
`empty_arguments_round_trip_in_every_position`, `plain` by `plain_arguments_round_trip`, `two words`
by `WHITESPACE_CASES`) and four verbatim in `QUOTE_AND_BACKSLASH_CASES`. **That is a snapshot, not a
mechanism.** A case added on one side does nothing for the other, and nothing in the build notices
when they drift.

## Consequences

The refusals and the ceiling stay in `src/process`, which is where the argument's ordinal is still in
hand and where a test can reach them (ADR-0017, ADR-0009). The shell converts and spawns and adds no
rules of its own — the moment a second writer of `lpCommandLine` appears, the argv[0] quoting
guarantee that makes `lpApplicationName = nil` safe stops being a property of the program and becomes
a property of one call site.

Not revisited without a new measurement against the real parser. What reopens it: a measured
disagreement between the suite and a shipped child's own splitting — `whisper-cli` is
`int main(int argc, char**argv)` under MSVC and already differs downstream of this layer (ADR-0002);
a second place that builds a command line without going through `build_command_line`; a move off
`CreateProcessW`; or a case added to either quoter's corpus that the other cannot pass, which is the
day the two corpora need a mechanism rather than a paragraph.
