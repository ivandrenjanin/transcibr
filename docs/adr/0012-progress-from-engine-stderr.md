# Progress is parsed from the engine's stderr, with a time-based fallback

A batch runs for hours, so the UI needs a real percentage per recording. It comes from parsing the
engine's progress output on stderr, degrading to an estimate derived from audio duration and a
measured realtime factor when no progress lines appear.

The format, verified against the binary: lines of the exact shape

```
whisper_print_progress_callback: progress =   6%
```

on **stderr**. The engine's "no prints" flag does not suppress them.

## The 5% steps are not steps, and there are not twenty of them

This ADR first said the lines came "in hardcoded 5% steps, so any recording produces exactly twenty
of them", and issue #9 committed a real capture as a fixture rather than restating it. The fixture
disagrees, reproducibly:

```
10%  21%  27%  33%  42%  52%  64%  75%  85%  94%  100%
```

Eleven lines, none of them a multiple of five. The step is a *threshold* rather than a grid, and the
counter it is measured from advances by the **step** rather than to the reading: the callback fires
once decoded progress passes that counter plus the step, reports where the crossing actually landed,
and moves the counter on by exactly one step — so after printing `10%` the counter sits at 5, not 10.
A recording whose segments are long passes several steps inside one segment and still reports once.

This paragraph first said "past the previous *reading* plus the step", which describes a counter that
advances to what it printed. Both readings of the mechanism reproduce the capture above and both give
the same bound, so nothing downstream changes — but this is a document whose whole purpose is being an
accurate measurement, so it says the one that is true. The count is **at most** twenty either way, and
the values are arbitrary.

Nothing downstream may assume otherwise. A reader that expected multiples of five would reject every
line in that capture; one that expected twenty would treat a healthy run as a stalled one. The two
properties that do hold are the ones the code relies on: the readings are non-decreasing, and the
last is 100 — and even those are read as external input rather than asserted, because a release is
free to change both.

The measurement: whisper.cpp v1.9.1 cuBLAS, `ggml-large-v3-turbo`, one 253.9-second recording,
`-pp -oj`. Captured to `src/process/fixtures/engine-stderr.txt`.

This is a deliberate coupling to another program's human-readable output, which is not a contract and
can change between releases without warning. That is why the fallback exists: a format change
degrades the progress bar instead of breaking the run.

## Consequences

**The fallback triggers on elapsed time since the last progress line, never on the absence of
lines.** The engine is silent during model load, so "no progress yet" is normal for the first minute
and is not a stall.

**Never animate the fallback over a process that has stopped producing bytes.** A confidently
advancing estimate over a dead child is worse than a frozen bar, because it hides the failure — see
the stdout deadlock in ADR-0004, where exactly this combination turns a hang into an apparently
healthy run. A per-job watchdog treats no bytes on either stream for N minutes as an operating error.

"Either stream" is one stream in practice: ADR-0004 sends stdout to the null device, so the progress
line is the whole of what a watchdog can see, and that is what forces N to scale with the recording
below. Issue #32 records what would let it stop scaling — the engine calls `fflush(stdout)` after
every segment, so a drained stdout is a *denser* liveness signal than the progress line rather than a
sparser one. Taking it is a decision against ADR-0004 and wants a measurement first.

**N is the recording's own length, floored at what a cold model load costs, and never a fixed number
of minutes.** This follows from the amendment above and from ADR-0004 together, and issue #9 shipped
the fixed version first and had to correct it. Every cue goes to stdout, which goes to the null
device — so between two progress lines transcibr sees *nothing*, and the longest legitimate silence
in a run is whatever the largest jump between two consecutive readings is worth. In the capture that
jump is **12 points**, 52 → 64, so a run of wall time W carries a legitimate silence of **0.12·W**.

A fixed five minutes therefore fails any healthy run past about **42 minutes** of wall time, which is
the corpus's longest recording, 168 minutes, on anything slower than four times realtime. It also
contradicts the run bound in the same file: that one is four times realtime plus a floor, explicitly
sized against a CPU-only fallback at a quarter of realtime — and at that speed the same recording's
largest gap is 80.6 minutes against a five-minute bound.

The recording's own length clears it everywhere on that grid. At realtime or faster the whole run
fits inside one bound, so no gap inside it can reach one: a margin of 8.3. At the quarter of realtime
the run bound is sized for, the largest gap is 0.48 of the recording's length against a bound of 1.0,
a margin of **2.08**. A *quarter* of the length does not clear it — 0.48 is past 0.25, so at 168
minutes the gap is 80.6 against a 42-minute bound and the healthy run is discarded again. Size the
watchdog against the capture, not against the ceiling.

**Eleven is not the reading count, and it is not a denominator.** The count is a function of the
recording's length: the callback can fire at most once per decoder window, and a window is at most
thirty seconds of audio. A four-minute capture therefore has about ten windows to report from and
each one it reports is worth about a tenth of the whole — the fixture's own timings line says as
much, `encode time = 461.54 ms / 11 runs`, eleven windows against eleven readings. A 168-minute
recording has three hundred and more, each worth about 0.3%, so the 5% threshold is crossed close to
where it sits and the readings come out near 5, 10, … 100: about twenty of them, finely spaced.

Reasoning from the four-minute capture is nonetheless the **safe** choice, and that is why the bound
above is derived from a jump rather than from a count. Fewer readings means larger gaps, and a bound
has to be sized against the sparsest plausible pattern. So the case that walks the capture's eleven
percentages across a 168-minute recording is **conservative, not approximate** — pessimistic in the
direction a bound needs to be wrong in.

**Audio duration comes from the engine's own startup banner**, which reports sample count and
seconds for the file it is about to process, or from the container probe (ADR-0009) — not from the
scratch WAV's size. The WAV header is not a fixed 44 bytes: ffmpeg's muxer writes a `LIST`/`INFO`
chunk before the data chunk, unconditionally and even when the source carries no metadata, so both a
fixed-offset parse and a `(size − 44) / byte_rate` duration are wrong by a per-file amount. Walk the
RIFF chunks or do not read the header at all.
