# Pipelined execution, with exactly one GPU worker

One or two CPU workers extract audio ahead of a single GPU worker, connected by a bounded channel of
depth one or two. While one recording transcribes, the next is being extracted.

**Exactly one GPU worker** is the invariant the whole shape exists to protect. A GPU is a serial
resource: concurrent transcriptions contend for the same SMs and VRAM, so N processes do not give N×
throughput — they give the same work, later, with a higher chance of running out of memory. This is
asserted, not merely intended, so nobody "optimises" it back later.

**The queue is bounded** because extraction is far faster than transcription. Unbounded, the
extractors run away and fill the disk at roughly 115 MB per hour of audio; a 75-hour batch would
write about 8 GB of scratch audio ahead of a GPU that cannot consume it.

## Why pipelined rather than sequential

Sequential execution was seriously considered and is genuinely simpler: per-recording error
isolation, progress and resume all become trivial, one scratch file exists at a time, and the
one-GPU-worker invariant holds by construction. Measured, transcription runs at about **17× realtime**
while extraction is I/O-bound demuxing of tens of seconds, so overlapping them recovers only
**10–15% of wall clock** — on a 75-hour corpus, roughly half an hour out of four and a half.

We took the pipeline anyway, accepting that it buys the hardest code in the program to test: threads,
backpressure, cancellation that must not orphan a child. Recording this explicitly because the payoff
is modest enough that a future reader will reasonably ask whether the complexity was justified, and
because the alternative was rejected with open eyes rather than overlooked.

## Consequences

Use `core:sync/chan` rather than a hand-rolled queue. Verified against its source, it has the two
properties this design needs: `close` broadcasts to both the reader and writer condition variables,
so it wakes blocked senders and is a correct Stop primitive; and `recv` drains a closed non-empty
channel rather than returning immediately, so closing mid-batch cannot silently drop the tail of the
queue while the run reports success.

Three constraints come with it:

- `chan` requires `size_of(T) <= max(u16)`, so a Job carries paths and identifiers — never a cue
  array by value.
- `chan.destroy` frees its backing allocation without checking for blocked waiters, so shutdown
  order is **close → join every worker → destroy**, asserted in that order.
- `send` and `recv` both return a `bool` that must be checked and mapped to a job status. An ignored
  `false` from `send` during Stop is exactly how a recording vanishes from the batch with no row in
  the UI and no entry in the log.

The channel procedures are `proc "contextless"`, so per style rule A7 any assertion in a wrapper uses
`runtime.assert_contextless`.

Concurrent spawns leak each other's inheritable pipe handles unless handled (see ADR-0004), and the
mitigation partially re-serialises the very path this pipeline exists to parallelise. That is a
further argument for **one** extract worker rather than two.

The one-GPU-worker assertion cannot see across process boundaries — an orphaned engine from a
previous crash is invisible to it. The job object in ADR-0004 is what makes the invariant actually
hold.
