# Parse the engine's JSON output, not SRT

The engine can emit both SRT and JSON. We parse JSON (`-oj`), because it gives integer millisecond
offsets instead of `hh:mm:ss,mmm` strings that must be re-parsed, carries the detected language and
model parameters we want in the transcript's front matter, and has one unambiguous escaping rule
instead of SRT's blank-line-and-CRLF framing edge cases.

**Record the rationale that did not survive.** JSON was originally chosen to filter *one-off*
hallucinations on per-segment confidence — the class a repetition filter cannot catch. That data
does not exist: `output_json()` emits per cue exactly `timestamps`, `offsets` and `text`, and
`-ojf` adds only per-token `p`. There is no `avg_logprob`, no `no_speech_prob`, no
`compression_ratio`. `whisper_full_get_segment_no_speech_prob()` exists in `whisper.h` but the CLI
never serialises it, so it is reachable only through FFI, which ADR-scope excludes.

Do not re-derive this: the only available number, per-token `p`, is the wrong instrument. A
fabrication over silence is emitted with *high* token probability — that is why the decoder emits it
— so a mean-`p` threshold tuned to catch it strips quiet correct speech instead.

## Consequences

Hallucination stripping is repetition detection only. Measurement on a real 20-minute excerpt found
two hallucination runs — 17 identical cues of one short phrase, and 16 identical cues of the single
word *"you"* spanning 4.5 minutes of silence — so the narrower filter covers the observed cases. If
confidence filtering is ever genuinely required, it is an FFI feature and the FFI exclusion must be
re-opened honestly rather than worked around.
