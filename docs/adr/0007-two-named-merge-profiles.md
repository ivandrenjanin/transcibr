# Paragraph merging uses two named profiles, chosen by measurement

Merging cues into paragraphs breaks on two signals only: the silence gap between consecutive cues,
and whether the previous cue ended a sentence. Two named `Merge_Params` constants ship —
`monologue`, which merges generously, and `conversation`, which breaks aggressively — selectable per
batch.

This is the program's core value-add. Raw cues are a few seconds each and cut mid-sentence; turning
them into prose is the reason to write this rather than run the engine directly.

## The measurement that justifies it

There was a serious objection: the engine emits cues delimited by timestamp tokens in consecutive
pairs, so the end of one cue is by construction the start of the next, and inter-cue gaps might carry
almost no information across most of a recording. If true, both profiles collapse into one rule and
the feature is theatre.

Tested on a controlled pair — two 20-minute excerpts from the same source, same speaker, same room,
same recording rig, differing only in session format. `large-v3-turbo`, beam size 5, no VAD.

| | Continuous single-speaker | Interactive, short exchanges |
|---|---|---|
| cues per 20 min | 154 | 415 |
| gaps ≤ 0 ms (touching) | 45.8% | 5.8% |
| gap p50 | 80 ms | 520 ms |
| gap p75 | 800 ms | 1020 ms |
| gap p90 | 8240 ms | 2340 ms |
| gaps ≥ 800 ms | 25.5% | 35.3% |
| gaps ≥ 2500 ms | 19.0% | 9.2% |
| sentence-final punctuation | 80.5% | 99.8% |
| cue duration p50 | 3840 ms | 1220 ms |

**The objection is false.** The gap signal is present and strong. More importantly the two content
types are measurably different populations rather than a distinction invented in advance: the
continuous recording is bimodal (46% touching cues, with 19% of gaps over 2.5 seconds while the
speaker pauses), the interactive one is a dense continuous distribution of short turns with almost no
touching cues. A single threshold cannot serve both.

## Consequences

**The thresholds are taste, not truth.** They are the one part of the program tuned by reading real
output, which is precisely why they live in a struct passed as an argument — a test can pin
behaviour while the defaults are tuned. Tuning is cheap because the engine JSON is retained
(ADR-0002, ADR-0003): change the profile, re-render, no GPU.

Speaker diarization is out of scope, so `conversation` handles multi-speaker material *temporally* —
it cannot label speakers and will still merge two people who overlap without a gap. That limitation
is inherent, not a defect to be fixed later without reopening the diarization exclusion.

This decision depends on VAD being off. VAD drives gaps to 97.2% zero and sentence-final punctuation
to 0.0% on interactive material, annihilating both signals at once and leaving the merger nothing to
break on — see ADR-0005.
