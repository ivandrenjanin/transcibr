# `src/version` is a package with no spec module behind it, and that is recorded rather than fixed by folding it

ADR-0017 puts one Odin package on each spec module the maintainer confirmed, named for the module.
`src/version` breaks that pattern in the direction ADR-0018 and ADR-0026 do not: those two record a
spec module *narrowed* across a shared package; this package holds *no* spec module at all.
`docs/spec/0001-transcibr-v1.md` names four core modules, nine shell modules and two interface
modules — Transcript, Planning, the Process contract and Worker planning; discovery, probing,
extraction, Engine invocation, process spawning and termination, downloading, artifact storage,
logging and settings persistence; the Win32 window and the command-line front end — and none of them
is "the program's own name and number." Every other package under `src/` answers to one of those
modules; this one answers to nothing the spec names. ADR-0017's rule is keyed to that module list, not
to the spec's five *test* seams (S1–S5): only Transcript, Planning and the Process contract have a
seam of their own, and a package such as `src/cli` answering to the command-line-front-end module
with no seam behind it is the ordinary case, not a defect.

## What it holds, and why it is not folded into `src/cli`

`Version` is a three-field struct, and `banner` is one pure procedure that renders
`<program> <major>.<minor>.<patch>` and asserts the shape of what it hands back: no embedded newline,
the program name as a prefix, exactly one space between the name and the number. `src/cli/main.odin`
is one importer — the bare-argument case that prints it and exits — and `src/transcript/render.odin`
is a second, calling `version.banner` to write the `generator` field
(`render.odin:262,271`) into a Transcript's front matter — transcibr's own name and version. The
`engine` field is a separate line, fed from `Render_Context.engine_version` (`render.odin:274`), and
never calls into `src/version` at all.

That second importer is why folding `src/version` into `src/cli` is not available at all, never mind
costly. `src/cli/main.odin` already imports `transcibr:transcript` to render a Transcript from a
plan. If `banner` moved into `src/cli`, `src/transcript` would have to import `src/cli` to keep
calling it — a two-package import cycle, which the compiler refuses outright. `src/version` cannot be
folded into `src/cli` while `src/transcript` needs what it holds; the coverage argument below is a
second, independent reason and not the load-bearing one.

`src/cli` is also named in `$OdinPackagesWithoutTests` (ADR-0009's ceiling for a shell thin enough to
read rather than test), and `test.ps1` refuses that package outright if it ever collects a test.
`banner`'s assertions on its own output are exactly the kind of small, pure decision ADR-0009 says
belongs in the core rather than the shell: a truncated banner, a missing separator, a banner that runs
onto two lines are all real defects a release could ship, and `version_test.odin` is what would go red
first if the code both importers trust started emitting one. Moved into `src/cli`, that coverage does
not migrate with it — it disappears, because nothing in that package is allowed to collect a test at
all. And it would not even resolve the cycle above: `src/transcript` is core and cannot import
`src/cli` regardless of whether the moved code is tested.

## Addendum (2026-08-06, #152)

`$OdinPackagesWithoutTests` is now `TEST_LESS_SRC_PACKAGES` in `tools\policy\packages.odin`, and
`test.ps1`'s refusal is now `exempt_packages_holding_tests` failing `just check`. The folding
argument — the import cycle `src/transcript` would need, and the coverage `version_test.odin` would
lose — is unaffected by the rename.

## Consequences

`src/version` is core by ADR-0009's own test — a pure function worth testing, touching nothing outside
itself — and package-per-spec-module (ADR-0017) does not apply to it, because there is no spec module
for it to be one of. Recorded here so the next reader does not go looking for the module that named
it, and does not read the omission as the kind of drift ADR-0018 and ADR-0026 already flagged and left
for a later ticket to fix — this one was never meant to be fixed the same way.

## What reopens this

A second fact the version banner needs that only `src/cli` has today — a build number, a commit hash —
is the point at which this either grows a spec-shaped module of its own or is folded into whatever
holds that fact already. Until then: one program name, one number, one file, and no spec module
standing over it.
