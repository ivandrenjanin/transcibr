# `src/artifact` is a pure provenance core and an impure storage shell, kept apart by file split

`src/artifact/` is two layers in one Odin package: a pure provenance/naming core — `sidecar.odin`
(the Sidecar, `Model`, and `changed`) and `naming.odin` (stems, extensions, injectivity) — beside an
impure storage shell — `place.odin` (writing artifacts into place) and `model.odin` (reading and
hashing a Model file, on its own thread). The core imports only `core:*`, `transcibr:process`, and
`transcibr:transcript`; the shell imports `transcibr:child`, `core:os`, and `core:thread`. Nothing
records that split, the way ADR-0026 records planning's pure/shell mix inside one package, and it is
recorded here for the same reason.

## Why this is not a package split

A package split was evaluated and refused. `src/planning` keeps 19 of its 28 references to artifact
either way, so a split buys planning nothing — it would still import both halves through one name or
two. ADR-0017 makes a new package a *reopening* of "one package per spec module", not a free move,
and CONTEXT.md has no heading over the pure and impure halves the way *Turning a recording into
audio* stands over Probe and Scratch cache (ADR-0018's test for when a pair earns a name). What keeps
the halves apart is the file split alone, exactly as ADR-0026 records for `src/planning`: a decision
that turns up in `model.odin` or `place.odin` belongs beside the storage code it is next to, and
nothing enforces that here either — this ADR names the boundary so review checks it instead of
rediscovering it.

## The identifier census

Every artifact identifier `src/planning` imports is declared in `sidecar.odin` or `naming.odin`,
with one exception before this change: `Model`, declared at `model.odin:24`, in a file importing
`transcibr:child` and `core:thread`. Measured directly against the pinned tree:

| identifier | declared in |
|---|---|
| `Change` | `sidecar.odin` |
| `Model` | `sidecar.odin` (moved here by this ADR; was `model.odin`) |
| `Sidecar` | `sidecar.odin` |
| `changed` | `sidecar.odin` |
| `destroy_sidecar` | `sidecar.odin` |
| `read_sidecar` | `sidecar.odin` |
| `recordable` | `sidecar.odin` |
| `sidecar_of` | `sidecar.odin` |
| `destroy_names` | `naming.odin` |
| `extension_of` | `naming.odin` |
| `names_of` | `naming.odin` |
| `stem_of` | `naming.odin` |

## The one move this ADR makes

`Model`'s struct declaration moves from `model.odin` into `sidecar.odin`, next to `Digest` and ahead
of `Sidecar`, the struct that already holds `sidecar_of` — its one consumer inside the pure half.
`identify_model` and `destroy_model`, the impure work of resolving a path and hashing a file on its
own thread, stay in `model.odin` exactly where they were; only the shape of the value moves, not the
work that fills it. This is a declaration move and nothing else: no import changed anywhere in the
repository, and `src/artifact`'s own package boundary is unchanged.

## Consequences

The entire surface `src/planning` imports from `transcibr:artifact` now lives in the two pure files.
A reviewer checking whether planning still touches only the pure half can read `sidecar.odin` and
`naming.odin` and stop — `model.odin` and `place.odin` are shell code a planning change should never
need to open. Nothing here buys a compiler-enforced boundary the way a package split would; `#+vet
explicit-allocators` and every other file tag still apply per file inside one package, and a future
change is free to declare something impure in `sidecar.odin` without the build noticing. That is the
same cost ADR-0026 accepted for `src/planning`, accepted here for the same reason: the alternative is
a package for one moved struct, which costs a directory, an import in every consumer, and a row in
`test.ps1`'s per-package accounting, for nothing a file split does not already buy.

## What reopens this

A second Model-shaped value that genuinely needs its own package — one with more than one consumer
outside `src/artifact` and a name CONTEXT.md gives a heading of its own — reopens whether the pure
half is still small enough to live beside the shell rather than apart from it.

## Addendum (2026-08-06, #152)

The refused-alternative cost above — "a row in `test.ps1`'s per-package accounting" for a package
holding one moved struct — is now a row in the justfile's `test:` recipe plus `tools\policy`'s
package-accounting check. The decision to keep the pure half beside the shell in one package is
unaffected.
