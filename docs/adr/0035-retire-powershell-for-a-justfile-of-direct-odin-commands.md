# Retire the PowerShell layer for a justfile of direct odin commands

Issue #152, maintainer-ruled to precede every other open ticket. The six `scripts\*.ps1` files —
4,823 lines, of which 2,482 (`selftest.ps1`) existed purely to test the other 2,341 — are deleted.
In their place: a ~100-line `justfile` (casey/just) spelling every `odin`/`odinfmt` invocation
directly, and the small amount of logic that genuinely needs logic — the source-policy verdicts, the
file-tag roster, and a new package-accounting check — moved into `tools\policy`, an Odin program
already built and tested in Odin (ADR-0028).

## What moved, and where

`tools\policy` used to *report facts* — one tab-separated record per procedure, comment, vet tag and
`os.remove_all` call — for `scripts\common.ps1`'s five `Assert-Odin*` procedures to read back and
turn into a pass/fail verdict in a second language. That split only existed because the PowerShell
layer needed something to call. With it gone, the verdicts moved into `tools\policy` itself:

- `check.odin` computes the five verdicts CLAUDE.md's source policies and issue #97/#105 ask for —
  section 0's comment ban, rule F1's line limit, rule F2's `@(require_results)`, rule M2's `#+vet`
  tags (`vet_tag_roster`, moved here from `$OdinFileVetTags`), and the `os.remove_all` ban — plus the
  network-confinement check (issue #58), which answers a literal substring and needs no parser, but
  is now one more thing `tools\policy` decides rather than one more thing a script decided from its
  report.
- `discover.odin` walks the repository for `.odin` files itself (`os.Walker`), replacing
  `Get-OdinSource`'s PowerShell walk. Same exclusions — `.git`, `build`, `.scratch` — same
  repository-wide scope (`docs\reference\` included, exactly as CLAUDE.md's Odin notes record for
  the comment ban).
- `packages.odin` is new: the package-accounting check the ticket asked for, over **both** package
  roots — `src\` and `tools\`, the same two `$OdinPackageRoots` covered — and in **both**
  directions. Every package under either root holding a `*_test.odin` file must be named in the
  `justfile`'s own `test:` recipe body — scoped to that recipe's lines specifically, not a
  whole-file search, because `test-single` also mentions `src/child` and a whole-file match would
  call a package present the moment *any* recipe mentioned it — and every package under either root
  holding `.odin` files and *no* `*_test.odin` file at all is a violation, which is what makes the
  check deny-by-default rather than a list of things it already knows about. `cli` is the one
  declared exemption (`TEST_LESS_SRC_PACKAGES`), carrying forward `$OdinPackagesWithoutTests`'
  single entry and ADR-0009's reasoning for it; that roster is `src\`-only, and `tools\` has no
  roster at all (`NO_TEST_LESS_PACKAGES`), so the `tools\check` runner accepted risk 1 names as a
  re-entry path lands inside the check rather than beside it.
- `main.odin` is the entry point `just check` runs: no request file any more (nothing left to write
  one), it discovers the repository root itself — the one argument, or `just`'s own working
  directory — and prints each file's name to standard error *before* reading it, preserving the
  crash-resilience property `render_file` used to give the PowerShell reader: a pathological file
  that overflows the parser's stack still fails naming one file, not "something died somewhere in
  seventy-odd."

## What did not move

**The PE-subsystem check (`Assert-PeSubsystem`) is dropped, not migrated.** The ticket's own `build`
recipe is spelled as a bare `odin build src/cli` with the vet set; nothing in the ticket asks for the
PE-header read ADR-0004 introduced it for. One target exists (`transcibr-cli`, console subsystem);
the GUI binary ADR-0004 anticipates does not exist yet. Re-entry path: if a second, GUI-subsystem
target lands, add the header read back as a recipe that runs after `build`/`release`, the way
`build.ps1` used to run it inline.

**No PowerShell-era pin *verification* survives.** `Confirm-OdinVersion` and `Confirm-OdinfmtVersion`
used to refuse an unpinned toolchain outright in CI and warn about it locally. The `justfile` does
not check what `$env:ODIN` / `$env:ODINFMT` resolve to; it runs whatever is there. `install-tools`
still downloads the exact pinned release, so CI is pinned *structurally* — the tag in the justfile is
the only tag CI ever installs — but a local machine with a stray unpinned binary on `PATH` or at
`C:\Odin\dist\` gets no warning any more. Re-entry path: a `just`-native version check (`just`
supports `assert` expressions and shell interpolation) if this bites.

## The three accepted risks

Recorded here because the maintainer ruling for this ticket asked for the decision **and** its
residual risks, each with a measured origin and a re-entry path, in the ADR — not merely in
CLAUDE.md's prose.

### 1. No timeout tree-kill

**Origin, measured.** Issue #22: `odin test`'s runner hangs outright when two or more tests assert
concurrently — the Windows signal handler races a `TerminateThread` against a second concurrent
fault, and `TerminateThread` on a thread killed mid-log abandons its locks. `scripts\common.ps1`'s
`Invoke-NativeCommand` wrapped every `odin` invocation in a wall-clock ceiling
(`$OdinCommandTimeoutSeconds`, 600s) and killed the process **tree** — not just the compiler, whose
child (the test binary) is what actually hangs — because nothing in the toolchain has a timeout of
its own.

**What replaces it.** Nothing wraps `odin` any more. The repository-wide discipline this ticket's
own CLAUDE.md sweep leaves untouched — no committed test may deliberately trip an assert (issue #22)
— is the mitigation: a hang requires two tests asserting concurrently, and the discipline exists
precisely so that never happens in committed code. A local hang is a `Ctrl+C` away; in CI, the job's
own `timeout-minutes: 30` in `.github/workflows/ci.yml` is the only backstop, and it is kept for
exactly this reason.

**Re-entry path if it bites.** A small Odin `tools\check` runner, reusing `src\child`'s own
tree-kill machinery (`CreateProcessW` → `TerminateProcess` → `WaitForSingleObject`), wrapping the
`odin test` invocations the `justfile`'s `test`, `test-one` and `test-single` recipes spell.

### 2. No space-free out-dir selection

**Origin, measured.** `odin test` builds its test executable and runs it through an unquoted command
line: a space in the output path is re-parsed as an argument separator and the compiler exits `-1`
with `Unknown argument encountered '<second word>'`. `Get-OdinTestRoot` in `scripts\common.ps1`
chose `build\odin-test\` when that path held no space, falling back to
`%ProgramData%\transcibr\odin-test\` — chosen, not sanitised out of the 8.3 short name, because 8.3
generation is a per-volume policy that can be off and does not apply retroactively to a directory
that already exists.

**What replaces it.** Nothing. Every `justfile` test recipe writes to a plain `build\odin-test\`
with no fallback. A checkout under a path containing a space (`C:\Users\John Smith\...`) now fails
`just test` outright, the same failure the compiler always gave, with no PowerShell layer to route
around it first.

**Re-entry path if it bites.** One line in the README, which this PR adds: check the repository out
under a path with no space in it. The failure is loud — the compiler's own message — never silent,
which is what makes a wrapper optional rather than required.

### 3. No doc-test-name pins

**Origin, measured.** `scripts\selftest.ps1` (before this ticket) discovered every `-TestName`
example cited in CLAUDE.md, README.md and `test.ps1`'s own help text, and ran each one for real —
so a test renamed or deleted without updating its citation failed the suite rather than rotting
silently.

**What replaces it.** Nothing. `just test-one <pkg> <name>` examples throughout CLAUDE.md are now
unpinned prose; a rename can make one stale without any check noticing.

**Re-entry path if it bites.** Extend `tools\policy`'s package-accounting check (or a sibling check
beside it) to discover `just test-one` citations in `.md` files the way the retired selftest case
did, and fail `just check` on one that names a test the tree no longer collects.

## Consequences

**`just ci` is what CI runs, verbatim** (`fmt-check check build release test test-single smoke`) —
CI↔local parity is now structural (the same recipe, not two copies of a check pinned by regex, which
issue #116/#135 needed to guard against) rather than asserted by a 2,482-line selftest suite.

**The selftest suite itself is not replaced.** It existed to test PowerShell control flow that no
longer exists — thirty planted fixture repositories proving a *script* refuses a hang or reports a
wrong verdict. `tools\policy`'s own `@(test)` procedures (77, after this ticket) cover the verdict
logic the same way; nothing plants a throwaway repository and re-runs `just` against it, because
`just` itself has no comparable control flow to prove.

**Zero PowerShell remains in the repository.** `Get-ChildItem -Path . -Recurse -Filter *.ps1` from
the repository root returns nothing.

## Addendum (2026-08-06, post-#152 documentation audit)

`EXCLUDED_DIRECTORY_NAMES` gained a fourth, load-bearing exclusion before this ticket's ADR merged:
`.tools`, alongside `.git`, `build` and `.scratch` — because `just install-tools` extracts 1,330
core-library `.odin` files there, and without excluding it `just check` measured 19,965 violations
against files that are not this repository's own source. "What moved, and where" above records only
the original three exclusions `discover.odin` carries forward from `Get-OdinSource`; `.tools` is a
fourth this decision added rather than moved.

The test count in "The selftest suite itself is not replaced" — "`tools\policy`'s own `@(test)`
procedures (77, after this ticket)" — was of this ADR's own merge. `tools\policy` carries 91
`@(test)` procedures as of this addendum (2026-08-06); phrased without pinning a new number, for the
same reason the original count was already wrong the moment a test was added after it: a count
recorded in prose rots and nothing here re-checks it against the tree.
