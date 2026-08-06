# The build reads Odin with the compiler's parser, not with a scan of its own

Four of the checks that read Odin source — rule F1's line limit, section 0's comment ban, rule F2's
`@(require_results)` and rule M2's `#+vet` tags — answer from `core:odin/parser` and `core:odin/ast`,
through `tools\policy`, an Odin program the build compiles before it runs the checks. A fifth,
`Assert-OdinNetworkConfinement`, also reads Odin source and does not: it answers a literal substring
(issue #58), which needs no grammar, so it is not part of what this decision is about.

This reverses a recorded position. PR #51 built one shared column-zero text scan in
`scripts\common.ps1` and refused this migration as out of scope, and that refusal was reviewed and
held. The reasoning below is why it is being reopened rather than re-litigated.

## What the scan was

478 lines of `scripts\common.ps1`, out of 1,889: `Get-OdinLineFact` lexed a line into ordinary code
with every comment, string and rune literal blanked to spaces; `Read-OdinProcedureHeader` and
`Get-OdinProcedureRange` walked column 0 for a declaration and its closing brace;
`Get-OdinHiddenProcedure`, `Get-OdinBodyComment`, `Get-OdinResultProcedure` and `Get-OdinFileVetTag`
read the answers off that. It tracked nested block comments, raw backtick strings that span lines,
rune literals including `'\''`, and bracket depth.

None of that was gratuitous. `INLINE_SPECIALS` in `src\transcript\render.odin` is three string
literals joined, one of them a double-quoted backtick; a regex counting backticks reads that file as
having an unterminated raw string and misclassifies every line after it. Odin's raw strings take no
escapes and span lines, so a line beginning `//` inside one is transcribed speech — and this program
transcribes whatever somebody said. The scan was a lexer because the job needs one.

## Why a second model was the problem

It was a second model of Odin, in a second language, maintained by this repository. **It was
silently wrong three times.**

The most recent: one bug in `Get-OdinProcedureRange` made rule F1 measure a phantom eight-line
procedure *and* section 0 report a comment in a top-level table as a comment inside a procedure body.
Both wrong from the day they landed, both invisible until a third reader turned the same bug into a
hard build failure.

Two of the three residual limitations recorded on that branch had the same shape, and the third had a
wrong reason written beside it:

| the shape | under the scan | under the parser |
| --- | --- | --- |
| a procedure declared **indented** — inside `when`, or nested | invisible to every check, so `Assert-OdinVisibleProcedure` **refused the declaration** | read like any other |
| a continuation between a signature and its brace that is not `where` | the header ends early and the procedure vanishes from every check, silently | there is no header reader |
| a body that opens and never closes at column 0 | **dropped**, and a dropped procedure is the same green as a file with no procedure in it (issue #52) | read |

The recorded reason for leaving the third open was that odinfmt "cannot produce" that shape. It does
not have to produce it — it **accepts** it. The file is an odinfmt fixed point and `odin check` exits
0 over it under the full vet set, and the procedure in it breaks section 0 and rule F2 at once while
being invisible to both.

The first row is the one that gives the argument its edge. The honest patch for a check that cannot
see a construct was to **ban the construct** — a rule about where code may be written, standing in
for a rule about what it may say. That is the cost of the model showing up in the language.

## What the parser costs, which is real

**A new Odin package and a new build target.** `tools\policy` is the first Odin outside `src\` that
is a package rather than a spike, so `$OdinPackageRoots` in `scripts\common.ps1` is now a declared
list of two roots rather than `src\` alone. `src\` is one package per spec module (ADR-0017); a build
tool is not a spec module, and putting it there would make `test.ps1`'s per-package accounting track
something the spec does not describe.

**The bootstrap.** The checker has to exist before it can be asked about the tree that contains it —
including about its own source, which `Get-OdinSource` discovers like any other `.odin` file, so the
checker is held to the rules it enforces. `Resolve-OdinPolicyTool` builds it from `tools\policy` under
the same vet set as every other target, or takes an already-built one from `$env:TRANSCIBR_POLICY`.
It **refuses** in every direction it cannot answer: a named tool that is not there, a package that is
not there, a compile that fails or times out. The state being designed against is a build that
reports four policy verdicts it never reached; the scan had no such state, and it also had no
compiler.

`$env:TRANSCIBR_POLICY` exists for `scripts\selftest.ps1`, which plants around thirty throwaway
repositories and runs the real build command inside each. Without it, every one of those cases would
fail on a bootstrap with nothing to build rather than on the thing it is about — and the suite would
compile the same program thirty times to say so. The suite still runs the real bootstrap once, at
startup, against the real package.

**Two toolchain defects, both measured at the pin and both handled in the package.**
`core:odin/parser` is a recursive descent with no depth limit — the same trap `core:encoding/json`
carries (CLAUDE.md, Odin notes) — and it overflows its stack at 62 nested parentheses in a debug
build. So the depth is bounded before the parse with the compiler's own tokenizer, which is iterative.
Unlike the JSON case there is no order of magnitude to be had: 62 is the shallowest *bracket* crash
and the deepest file here reaches 7, so the bound is a guard against the pathological file rather
than a proof. It is not the shallowest crash outright — a chain of `^` in a type carries no bracket
at all and goes at about eighty, counted depth one — so the residual is real, and the tool writes
each file's name **before** it reads that file: a crash fails the build naming one file rather than
saying only that something died somewhere in seventy-odd. And `core:odin/tokenizer` fills its
keyword table behind a double-checked lock that never re-checks, so two threads calling
`tokenizer.init` for the first time race and the second trips an assertion inside `core` — one run in
three of this package's own test sweep died that way, with no summary (issue #22). An `@(init)` fills
the table before any test thread exists.

## Why the partial was not available

Migrating one check would have put a second model of "where a procedure begins and ends" beside the
one being replaced, which is the defect this decision is about, reintroduced one language over. #51
refused that split for that reason. All four moved together.

## Consequences

**The reader is tested in Odin, and that is most of the point.** `tools\policy` carries 52 `@(test)`
procedures and is **not** in `$OdinPackagesWithoutTests`; `.\scripts\test.ps1` sweeps it like any
package under `src\`. Every shape these rules turn on — a procedure type, a `where` clause over two
lines, a raw string holding a `}` at column 0, an attribute quoted inside one, both spellings of
`@(require_results)`, a tag below the package clause — is a string literal in a test file. Five
`scripts\selftest.ps1` cases that probed the PowerShell reader against fixture text moved there.

**What remains in PowerShell is discovery and policy, not parsing.** `Get-OdinSource` still says
which files exist, because the formatting sweep already asks that question and there is one copy of
it. `Get-OdinRequiredVetTag` still says which `#+vet` names a file's scope requires, because that is a
declaration and not a reading. The four `Assert-Odin*Policy` procedures still own the verdicts and the
words they are refused in.

**A record kind the two sides disagree about is refused.** The report is tab-separated lines and
nothing type-checks across the gap, so `Read-OdinPolicyReport` throws on a record it does not know
rather than ignoring it, and throws when the report says nothing at all about a file it asked about.

**Rule F1 moved into the build.** It was checked by `scripts\selftest.ps1` alone, so a procedure over
the limit reached main and was reported by CI rather than by the build a developer had already run.
It sits beside the three policies it shares a reader with.

**What still cannot be seen.** A procedure inside a `when` block is now measured, and it is measured
for the target the parser is reading for — the parser does not evaluate `when`, so a body excluded
from every build is still held to every rule. That is the direction to prefer. A file that does not
parse is refused rather than read, which means the checks say nothing about a file the compiler would
also refuse. And the depth bound above is a bound and not a proof.

## Addendum (2026-08-06, #152): full supersession — see ADR-0035's "What moved, and where"

Issue #152 deleted the PowerShell layer this record's mechanisms sections name. ADR-0035 is the
record of that migration; this addendum re-points what this record itself said, rather than
restating ADR-0035.

**The network-confinement verdict moved beside the parser-backed checks.** `:6`'s "not part of this
decision" boundary — drawn because `Assert-OdinNetworkConfinement` lived in `scripts\common.ps1`
while the other four moved into `tools\policy` — is dissolved: `collect_network_violations` now
lives in `tools\policy\check.odin` next to the other four, computed in the same program even though
it still answers a literal substring and needs no grammar (ADR-0015's own addendum records the
mechanism unchanged).

**The two-roots fact survives, hardwired.** `:59`'s `$OdinPackageRoots` becoming "a declared list of
two roots rather than `src\` alone" is now `packages.odin`'s package-accounting check running over
both `src\` and `tools\` explicitly, in both directions — the same two roots, expressed in Odin
rather than in a PowerShell list.

**The bootstrap is one line.** `:66`'s `Resolve-OdinPolicyTool` and `:73`'s `$env:TRANSCIBR_POLICY`
paragraph — the throwaway-repository harness `scripts\selftest.ps1` used to plant around thirty
fixture repositories against — are superseded with no replacement. `just check`'s bootstrap is a
single `odin run tools/policy` line; nothing plants a throwaway repository and re-runs a build
command inside it any more, because `just` itself has no PowerShell-shaped control flow left to
prove against a fixture.

**The test count was of its writing.** `:102`'s "52 `@(test)` procedures" is stated as of this
record's own writing, not as a fact to re-pin here; `tools\policy` carries 91 as of this addendum
(2026-08-06). Phrased without pinning a new number for the same reason ADR-0035's own addendum gives
for its test-count correction: a count recorded in prose rots the moment a test is added, and no
mechanism here re-checks it.

**`:109`'s "what remains in PowerShell" division is exactly what #152 dissolved.** Zero PowerShell
remains in the repository (ADR-0035's own "Consequences" section, `Get-ChildItem -Recurse -Filter
*.ps1` returns nothing). The recorded paragraph is **not reworded** — it stays as a true statement
of the repository's state on the day it was written, and this addendum is what says it no longer
describes today's tree.

**Decision close-out, `:116`, ruled from the 2026-08-06 post-#152 audit.** The unknown-record
refusal property this record states — "`Read-OdinPolicyReport` throws on a record it does not know
rather than ignoring it" — guarded a two-language report seam that #152 deleted outright:
`Read-OdinPolicyReport` no longer exists, and `tools\policy` computes and prints its own verdicts in
one program (`main.odin`'s `report_violations`), with no report crossing a language boundary for
anything to fail to recognize. The property is retired **VACUOUS**, with no successor owed: a
verdict can no longer be lost across a protocol gap inside a single program whose own compile
failure already fails `just check` before any verdict is computed at all.
