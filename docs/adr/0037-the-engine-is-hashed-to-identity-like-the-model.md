# The Engine is hashed to identity, like the Model, and ADR-0027 is superseded

ADR-0027 accepted a trade: `planning.Settings.engine_version` is a `Maybe(string)`, so a Batch that
names no Engine carries the record's own version forward rather than reporting `.Engine_Version` as
changed. Its own reopening clause named exactly what would close it — "if transcibr ever asks the
Engine binary for its own version -- or hashes it, the way the Model is hashed -- then a Batch always
names its Engine, the absent case stops existing, and this decision goes with it." Issue #50 is that
exit, taken.

## What changed

`--plan` gains `--engine-exe <path>`, the one piece ADR-0027 named as missing: `--transcribe` and
`--batch` already required it, to spawn the Engine, but `--plan` spends no GPU time and never opened
the file at all. All three commands now identify the Engine the way `artifact.identify_model`
already identifies the Model -- a streaming SHA-256 of the binary's own bytes, read once per run --
through `artifact.identify_engine` (`src/artifact/engine.odin`), which calls the same private
`digest_of_bounded` `identify_model` already calls rather than growing a second hasher. An Engine
binary that cannot be opened, cannot be hashed within its bound, or cannot even get a thread started
to hash it on is an operating error reported against that file (rule A8) — refused before the run
starts, never asserted, and never silently recorded as `unknown`. `artifact.identify_engine` carries
no ASCII check, unlike `identify_model`: that check exists because a Model's path is later handed to
the Engine's own ANSI-mangled argv (ADR-0025), and the Engine binary's own path is never handed to
itself that way — `CreateProcessW` takes it as UTF-16 directly.

`planning.Settings.engine_version` stops being a `Maybe(string)` and becomes a plain `artifact.Digest`
— sixty-four lower-case hexadecimal characters, exactly what `Model.digest` already is. A Batch
always names its Engine now, because every caller identifies it before `planning.Settings` is ever
built; there is no absent case left for the type to carry. `engine_of` — the procedure that read
`settings.engine_version.?` and fell back to the record's own value, or to `transcript.UNKNOWN`, when
the Batch named none — is deleted outright, and `current_of` reads `settings.engine_version` directly.
The paired assertion in `resumed` that read `"an Engine this package copied out of the record differs
from itself"` for an unnamed Batch is deleted with it: it asserted a fact that only held when the
Batch's own Engine was a copy of the record's, which is no longer ever true.

`--engine-version`, the hand-typed flag ADR-0027 built its trade around, is retired from every
command that named it — `--transcribe`, `--batch` and `--plan` alike. A command line that still
passes it is refused as an unknown option, the same as any other retired flag. `src/cli`'s shared
`read_common_option` (`transcribe.odin`) drops the parameter entirely rather than keeping a dead
case that nothing ever sets.

## Why the direction is no longer asymmetric

ADR-0027's whole argument rested on one fact: the Engine was "the one setting this program does not
measure at all: a string a caller types," where the Model is "hashed to identity precisely because a
path cannot notice a file replaced under the same name." Once the Engine is hashed too, that
asymmetry has nothing left to rest on. A Batch that names its Engine and a Batch that names its Model
are now the identical kind of claim, and `artifact.changed` already treats `.Model` and
`.Engine_Version` as ordinary members of the same comparison — nothing in `planning` needs to know
which field is hashed and which is typed any more, because none of them are typed.

This is also what makes `--engine-exe` mandatory rather than optional on `--plan`: an optional field
that decided nothing when absent was ADR-0027's whole mechanism, and the mechanism is gone. `--plan`,
`--transcribe` and `--batch` now share one requirement, the same way they already share
`--model-file`.

## What an Engine binary replaced under the same name now does

This is the failure ADR-0027 accepted and named as its cost: "a user who upgrades their Engine and
does not say so is not noticed." It is now noticed, because the digest — not the path, not a version
string nobody re-typed — is what `artifact.changed` compares. `src/artifact/engine_test.odin` pins
this directly: hashing the same path before and after its content changes produces two different
digests. `src/pipeline/batch_test.odin`'s
`a_batch_whose_engine_digest_changed_since_re_transcribes_rather_than_skips` pins it at the level a
real Batch runs at — a first pass transcribes and records a digest, a second pass against the
unchanged digest skips, and a third pass against a digest standing in for a replaced binary
re-transcribes.

## The wrong-provenance note ADR-0027 carried for `current_of`

ADR-0027 warned that a worker reusing a *recorded* Sidecar to write a fresh one would stamp the
previous Engine's version onto cues the currently installed one actually decoded. That warning does
not change shape here: `current_of` (`src/planning/plan.odin`) still builds a comparison operand from
`settings.engine_version` — the Batch's OWN identified digest — and never from `recorded`, so a
worker that writes a real Sidecar after a transcribe still has to build it from what that run actually
used, exactly as ADR-0027 said. What ADR-0027's warning no longer needs is the fallback branch that
copied the record's version forward when the Batch named none: there is no such branch left to misuse.

## Consequences

**Corpora whose recorded Engine version was a typed string re-transcribe once.** A Sidecar written
before this ticket carries a human-typed version (or the literal word `unknown`) in its
`engine_version` field; a Batch run after this ticket always compares that string against a sixty-
four-character digest, which never matches. This is the one-time migration cost issue #50's own notes
call out, and it is the point: the corpus is re-transcribed with a verified Engine identity rather
than staying silently unverified forever. A second run against the same Engine binary then skips
normally, because both sides are digests from that point on.

**A second, independent migration trigger: the Sidecar format itself changed.** This ticket's fix
round gave the Sidecar its own recorded Engine path (`Sidecar.engine`, alongside the digest that was
already `engine_version`), so `SIDECAR_VERSION_LINE` (`src/artifact/sidecar.odin`) moved from
`"transcibr-sidecar 1"` to `"transcibr-sidecar 2"`. `read_sidecar` refuses any Sidecar whose first
line does not match the version it reads for, so every Sidecar written before this ticket fails to
read at all and is treated as unknown provenance — the same ADR-0003 disposition as the string/digest
mismatch above, reached by a different mechanism (a version-line refusal, not a value comparison) and
triggered by a separate edit landed after this ADR was first written. The `engine` path this new field
records is never itself compared for staleness — `artifact.changed` still answers off the digest
alone — so a relocated or differently spelled `--engine-exe` argument with the same bytes is not a
changed Engine; see the closing paragraph below.

**The decision still lives in `transcibr:planning`, not `src/cli`.** `src/cli` remains named in
`tools/policy`'s package-accounting check as test-less by declaration (ADR-0009); every rule this
ticket touches — `current_of`, the deleted `engine_of`, `resumed`'s deleted assertion — is proven by
`src/planning/plan_test.odin`, not by anything in `src/cli`.

**What reopens ADR-0027 is now closed for the named binary, and only for the named binary.** Both the
Model and the Engine are identified from their own bytes for the purpose of deciding staleness — a
Model genuinely is one file, where a real whisper.cpp Windows distribution is not: `whisper-cli.exe`
is a thin driver beside `whisper.dll`,
`ggml.dll`, `ggml-cpu.dll` and `ggml-cuda.dll`, and the compute backend lives in the DLLs.
`identify_engine` hashes exactly the one path handed to `--engine-exe` and nothing beside it.
Measured: hashing an unchanged `whisper-cli.exe` before and after a sibling `ggml-cuda.dll` is
replaced with different content produces the identical digest, so a backend-only swap is exactly the
failure this record's own "What an Engine binary replaced under the same name now does" section
above says is fixed — it is not, for that one shape of replacement. The residual is narrow (a tagged
whisper.cpp release bumps the exe too, so an upgrade a user actually installs is still caught) and is
recorded here rather than closed over: a future ticket that wants to hash the whole distribution
directory, not just the named exe, reopens this ADR to do it.

**Correction: `planning.Settings` does carry a merely-nameable field, and that is deliberate.** An
earlier version of this paragraph claimed the opposite — that no such field was left. This ticket's
own fix round added one: `Settings.engine_path` (and `Sidecar.engine`, its on-disk counterpart), the
Engine binary's own path, recorded for a human reader alongside the digest but never compared by
`artifact.changed` (see the Sidecar-format-break note above). That is by design, not an oversight: a
path is exactly the kind of claim ADR-0027 argued this program should stop trusting for identity, and
recording it anyway serves the same purpose `Model.path` already serves — telling a person which file
produced a Transcript — without letting a differently spelled or relocated path decide staleness on
its own. `engine_path`/`Sidecar.engine` is nameable-but-not-measured by design; `engine_version`/
`Sidecar.engine_version`, the digest, is what carries identity, and that is the field this ADR is
about.
