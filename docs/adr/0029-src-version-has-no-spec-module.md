# `src/version` is a package with no spec module behind it, and that is recorded rather than fixed by folding it

ADR-0017 puts one Odin package on each spec module the maintainer confirmed, named for the module.
`src/version` breaks that pattern in the direction ADR-0018 and ADR-0026 do not: those two record a
spec module *narrowed* across a shared package; this package holds *no* spec module at all.
`docs/spec/0001-transcibr-v1.md` names five seams — transcript production, batch planning, the
process contract, pipeline topology, and the end-to-end seam (S1–S5) — and none of them is "the
program's own name and number." Every other package under `src/` answers to one of those; this one
answers to nothing the spec names.

## What it holds, and why it is not folded into `src/cli`

`Version` is a three-field struct, and `banner` is one pure procedure that renders
`<program> <major>.<minor>.<patch>` and asserts the shape of what it hands back: no embedded newline,
the program name as a prefix, exactly one space between the name and the number. `src/cli/main.odin`
is the only importer, in both of the places a version can reach a user — the bare-argument case that
prints it and exits, and `--help`'s usage block.

Folding it into `src/cli` would cost the one thing keeping it separate buys. `src/cli` is named in
`$OdinPackagesWithoutTests` (ADR-0009's ceiling for a shell thin enough to read rather than test), and
`test.ps1` refuses that package outright if it ever collects a test. `banner`'s assertions on its own
output are exactly the kind of small, pure decision ADR-0009 says belongs in the core rather than the
shell: a truncated banner, a missing separator, a banner that runs onto two lines are all real defects
a release could ship, and `version_test.odin` is what would go red first if the code the CLI trusts
started emitting one. Moved into `src/cli`, that coverage does not migrate with it — it disappears,
because nothing in that package is allowed to collect a test at all.

## Consequences

`src/version` is core by ADR-0009's own test — a pure function worth testing, touching nothing outside
itself — and package-per-spec-module (ADR-0017) does not apply to it, because there is no spec module
for it to be one of. Recorded here so the next reader does not go looking for the seam that named it,
and does not read the omission as the kind of drift ADR-0018 and ADR-0026 already flagged and left for
a later ticket to fix — this one was never meant to be fixed the same way.

## What reopens this

A second fact the version banner needs that only `src/cli` has today — a build number, a commit hash —
is the point at which this either grows a spec-shaped seam of its own or is folded into whatever holds
that fact already. Until then: one program name, one number, one file, and no spec module standing
over it.
