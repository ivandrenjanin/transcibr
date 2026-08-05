# Two bounded channels, not one: admission and hand-off are separate queues

ADR-0006 describes the pipeline's shape in the singular — "connected by a bounded channel of depth
one or two" — and `src/pipeline` has never matched that sentence. `run_batch` (`src/pipeline/run.odin`)
creates two: `extract_queue`, which every Job is admitted onto and every extraction Worker reads from,
and `transcribe_queue`, which extraction hands its output onto and the one transcription Worker reads
from. Both are gated by the same `Config.queue_depth`. This was never flagged by review before PR #67's
(finding 6), and `CONTEXT.md`'s **Queue** entry inherited the singular framing wholesale — "the bounded
holding point *between the extraction Stage and the transcription Stage*" describes only the second
channel. This ADR records the shape that has been running the whole time and corrects the vocabulary
to match it.

## Why one channel cannot do this job

A `chan.Chan(T)` carries one message type. Admission puts a `Job` in front of extraction; extraction's
own output is an `Extracted` — a different type, produced by running the Job through
`Stages.extract`. Nothing in `core:sync/chan` lets one channel narrow from `Job` to `Extracted`
partway down its own buffer, and nothing in the topology needs it to: an extraction Worker is a
consumer of the first and a producer of the second, and those are two distinct roles a single queue
cannot hold at once. Two Stages, each with its own input type, are two channels — one **admission**
queue in front of extraction, one **hand-off** queue between extraction and transcription — and that
was true of the very first `run_batch` this repository committed, whether ADR-0006's own text said so
or not.

## Why the disk-filling bound ADR-0006 exists for still holds

ADR-0006's whole justification for a bounded channel is disk: "extraction is far faster than
transcription... unbounded, the extractors run away and fill the disk at roughly 115 MB per hour of
audio." That risk is carried entirely by `transcribe_queue`. `extract_queue` carries `Recording_Job`
values — a source path, a cache directory, identifiers — never audio bytes, so admitting Jobs ahead of
extraction costs the disk nothing at all. The bound that stops the disk-filling failure is
`transcribe_queue`'s own depth, exactly as ADR-0006 describes, and it is `transcribe_queue` alone that
sits between the Stage that produces scratch audio and the Stage that consumes it. `extract_queue`
being bounded too is a second, unrelated benefit — it caps how many Jobs are admitted ahead of any
extraction happening at all — and costs the same `config.queue_depth` field to express, but it is not
what ADR-0006's disk-filling argument is about.

## Shutdown order, doubled

ADR-0006 fixes the order for one channel: close, then join every worker, then destroy. With two
channels feeding two Worker tiers, `run_batch`'s own shutdown (`shut_down_and_settle`) runs that order
once per tier and in a specific sequence between them: `extract_queue` is closed and its Workers joined
first, then `transcribe_queue` is closed and its one Worker joined. `transcribe_queue` is written by
*both* tiers — extraction sends into it, transcription receives from it — so it is destroyed only once
**both** tiers have actually joined, never merely once the transcription tier has; an extraction Worker
`close_and_join` gave up on (PR #67's finding 1) can still be blocked trying to send into it, and
`chan.destroy` does not check for a blocked sender before freeing the channel's backing allocation. This
is the same hazard, and the same guard, `settle_results` applies to the `working` results buffer:
nothing owned jointly by an abandoned Worker and the caller is freed until every Worker that could still
be touching it has genuinely stopped.

## Consequences

- `CONTEXT.md`'s **Queue** entry is corrected to name both channels rather than describing the
  hand-off queue alone. **Worker**'s claim that the one-transcription-worker invariant "is asserted, not
  merely intended" is made true by `run_batch`'s own explicit assertion (PR #67's finding 5) rather than
  left as a claim the code did not back.
- ADR-0006 itself is left as written. It is not wrong about the invariant that matters — one GPU Worker,
  a bounded hand-off — only silent about the second, disk-cheap channel sitting in front of it. This ADR
  is the correction, not a rewrite of that one.
- A future reader asking "why two `chan.create` calls" now has an answer that does not require reading
  `run_batch` end to end: two Stages, two input types, one of the two channels bounded for the reason
  ADR-0006 gives and the other bounded for a cheaper, unrelated reason.
