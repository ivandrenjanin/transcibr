# Voice activity detection is not used

The engine supports VAD (`--vad -vm <silero model>`) and it is tempting: on a single-speaker excerpt
it nearly doubled throughput, 16.7× realtime to 31.2×, and it eliminated hallucinations outright —
the 17-cue and 16-cue repetition runs present without it dropped to a longest run of 1.

We do not use it, because it destroys the deliverable. Measured on the same recordings, same model,
same beam size, the same passage came back two different ways:

- **without VAD** — sentence case, terminal punctuation, and cue boundaries falling at sentence ends
- **with VAD** — one unbroken lower-case run carrying no punctuation of any kind, the whole passage
  landing in a single 22-second cue

**VAD output has no punctuation and no capitalisation**, and cues run up to 53 seconds. On a
multi-speaker recording it drove inter-cue gaps to 97.2% zero and sentence-final punctuation to
0.0% — annihilating *both* signals paragraph merging depends on, so the merger would emit one wall
of text bounded only by the character cap. Readable prose is the entire reason this program exists
rather than a raw subtitle dump.

## Consequences

Repetition stripping carries hallucination handling alone; measurement showed the real-world cases
are repetition runs, so this is adequate (see ADR-0001). Dropping VAD also removes a model download,
a `doctor` check, a failure mode where a missing VAD model abandons an entire invocation, and ~92 KB
of extra stderr per recording for the progress parser to resync through.

Not revisited without new measurement. If a future engine version emits punctuated text under VAD,
the trade changes and this ADR should be reconsidered — the speed gain is real.
