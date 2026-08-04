# A Batch that cannot name its Engine cannot report the Engine as changed

ADR-0003 makes resume consult recorded provenance: a Recording is done only when its artifacts exist
*and* the recorded settings match the current ones. This narrows one of those ten fields, in one
direction, and the direction is the whole decision.

`planning.Settings.engine_version` is a `Maybe(string)`. Where a Batch names an Engine, the recorded
one is compared against it as ADR-0003 asks. Where a Batch names **none** — which is the ordinary
command line, because `--engine-version` is optional — the recorded Engine is carried over as the
current one, exactly as `container_ms` already is, and `artifact.changed` can then never answer
`.Engine_Version`. That is asserted rather than trusted, beside the assertion that already says the
same about the duration.

## What it is fixing

`--plan` defaulted the field to `transcript.UNKNOWN`, so the default dry run over an
already-transcribed tree reported this:

```
A: default                              -> transcribe "…\talk.mp4": the settings it was made
                                           with have changed (Engine_Version)
B: --engine-version "whisper.cpp 1.9.1" -> skip       "…\talk.mp4": its Transcript was made
                                           with these settings
```

`.Engine_Version` is ordered ahead of `Merge_Profile`, so it is a full re-transcribe and not a
re-render. The spec's criterion — a Recording with a matching Transcript and matching recorded
settings is skipped — therefore held only for a user who re-typed the version string byte for byte.
A user who never passed the flag compared `"unknown"` to `"unknown"` and the field detected nothing
at all, so the flag was a foot-gun or a no-op with nothing in between.

## Why the direction is not symmetric

A **record** that names no Engine is unknown provenance, and ADR-0003's disposition for unknown is
re-do it. That still happens: a Sidecar carrying `engine: "unknown"` re-transcribes under a Batch
that names one, and there is a case for it.

A **Batch** that names no Engine has said nothing about the Engine at all. It is not a claim that the
Engine is unknown; it is the absence of a claim, and this is why the absence is now in the type
rather than spelled as a magic value that compares unequal to every real one.

The asymmetry is not a general principle about missing data — it rests on what this particular field
is. `Settings` hashes the Model to identity precisely because a path cannot notice a file replaced
under the same name. The Engine is the one setting taken on **faith**: a string a caller types.
A string a user types cannot protect a user who did not type it, so treating its absence as a
mismatch buys no safety and costs the hours of GPU time the resume rules exist to save.

Where there is no record either, the Recording is transcribed anyway and the string is only what the
Batch *would* record: `transcript.UNKNOWN`, which is what a `--transcribe` run given no
`--engine-version` writes. `src/planning` asks `transcibr:transcript` for that word rather than
keeping a copy.

## Consequences

**A user who upgrades their Engine and does not say so is not noticed.** That is the accepted cost,
and it is what `--engine-version` is for. It is a narrower failure than the one it replaces: an
unnoticed upgrade produces Transcripts of the quality the previous Engine gave, where the old
behaviour re-transcribed an entire finished corpus for nobody's benefit.

**The decision lives in `transcibr:planning` and not in `src/cli`.** `src/cli` is named in
`$OdinPackagesWithoutTests`, so a rule that lived there could not be turned red — which is how this
one got in. The CLI now forwards presence or absence and decides nothing;
`a_batch_that_names_no_engine_never_reports_the_engine_as_changed` and
`a_transcript_recorded_without_an_engine_is_done_again_by_a_batch_that_names_one` hold both
directions.

**What reopens this** is the Engine becoming identifiable rather than merely nameable. If transcibr
ever asks the Engine binary for its own version — or hashes it, the way the Model is hashed — then a
Batch always names its Engine, the absent case stops existing, and this decision goes with it.
