# Progress is parsed from the engine's stderr, with a time-based fallback

A batch runs for hours, so the UI needs a real percentage per recording. It comes from parsing the
engine's progress output on stderr, degrading to an estimate derived from audio duration and a
measured realtime factor when no progress lines appear.

The format, verified against the binary: lines of the exact shape

```
whisper_print_progress_callback: progress =   6%
```

on **stderr**. The engine's "no prints" flag does not suppress them.

## Both flags this decision rests on default to off

Measured against whisper.cpp v1.9.1's own help, neither flag is a default:

| flag | help says | what its absence costs |
|---|---|---|
| `-oj, --output-json` | `[false]` | the whole GPU pass runs and no output file is written at all |
| `-pp, --print-progress` | `[false]` | the engine transcribes in silence and the bar never moves |

So both are passed explicitly, in the one place an engine command line is built — `engine_arguments`
in `src/process/engine.odin` — and `the_engine_is_asked_for_json_and_for_progress` fails if either is
dropped. This ADR previously recorded only that the capture was taken with `-pp -oj`, which reads as
a description of one measurement rather than as a requirement on every invocation.

Two further flags are recorded as **absences**, because a reader who does not find them assumes they
were overlooked rather than declined:

- `-bs` is the **beam** size, not a batch size — there is no batch-size setting here to turn down at
  all, which is worth writing down because the name reads like one. Beam search stays at the engine
  default (spec).
- `-np` ("no prints") does not suppress the progress lines — the sentence above, verified against the
  binary — but it *does* suppress the startup banner, which is one of the two places a duration may
  come from. It would also save nothing, because stdout is already the null device (ADR-0004). The
  banner half of this is read off what the flag is for and has no capture behind it; only the
  progress half was measured.

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

## The banner says one length twice, and the two spellings are checked against each other

The other reading taken off this stream is the startup banner, which names the audio and gives its
length in both a sample count and printed seconds:

```
main: processing 'C:\tmp\transcibr\recording.wav' (4063182 samples, 253.9 sec), 4 threads, ...
```

| spelling | as milliseconds |
|---|---|
| 4,063,182 samples at 16 kHz — 253.948875 s | 253,949 |
| `253.9 sec`, as printed | 253,900 |
| difference | **49 ms** |

The seconds are printed to **one decimal**, so the two spellings of one length differ by up to
**50 ms by construction** on any recording at all. `BANNER_AGREEMENT_MS :: 1000` is twenty times
that, and the factor is the decision rather than an accident: sized near 50 ms the check would be a
check on printing precision and would refuse healthy banners on rounding alone, while at a second it
can fail only on a banner that has stopped meaning what this reader takes it to mean — a field that
moved, or a unit that changed. A duration read out of a line whose meaning changed is worse than no
duration at all, because the fallback estimate keys on it.

**The sample count is what is kept**, and the precision runs that way round: on the fixture's own
recording the printed seconds are 49 ms short of the truth, while the sample count is exact at the
16 kHz that `transcibr:audio` is required to produce. Where either half is unreadable the banner is
refused and the container probe's answer stands (ADR-0009) — the redundancy this decision asks for is
banner *or* probe, never one half of one line standing in for the other half.

Measured and assumed, kept apart: the 50 ms is arithmetic, the 49 ms is the fixture, and the factor of
twenty is a judgement. No banner with a moved field or a changed unit has ever been observed here, so
nothing measures the thing the check is actually sized against.

## The estimate is sized to lag, against two measurements

`DEFAULT_REALTIME_FACTOR :: 4`. The estimate assumes the engine runs at four times realtime, which is
slower than anything ever measured for it:

| machine and model | throughput |
|---|---|
| RTX 4070 Ti SUPER, `ggml-large-v3-turbo`, this repository's fixture | **58× realtime** |
| the machine this ADR was first written against (ADR-0006, ADR-0011, spec) | ~17× realtime |
| CPU-only fallback | assumed far below both; ADR-0011 puts it more than an order of magnitude down |

The 58× row and the hardware and model it was taken on are recorded here because `docs/` carries them
nowhere else; every other realtime figure in the repository is the ~17× one.

Four is chosen to **lag and never to lead**. An estimate that ran ahead would reach the estimate
ceiling — 99, because a hundred is a fact that only the engine's own reading or a finished output file
may state — and then sit there for most of the run, saying nothing while looking certain. One that
lags shows motion and is overtaken by the engine's own next reading, which is the floor it can never
fall below.

The accepted cost is a bar that reads far under the truth on a fast machine: at 58× the estimate is
about a fourteenth of the way along at the moment the recording finishes. That is paid because the
estimate only ever stands in *between* readings, never moves backwards, and is floored at what the
engine last said — so an understated estimate is corrected by the next line, while an overstated one
cannot be corrected at all.

The same two measurements are the headroom `ENGINE_BOUND_MULTIPLE` is read against: the run bound is
four times realtime plus a floor, and that four is sized against the CPU-only fallback rather than
against either GPU figure. Both fours are chosen for headroom, and neither is a measurement.

## The argument for not draining stdout is refuted, and that belongs here

Draining stdout would give the watchdog a second stream and let the silence bound stop scaling with
the recording's length. It was declined once, on this reasoning:

| the reasoning, step by step | status |
|---|---|
| C stdio is fully buffered when stdout is not a terminal | true in general |
| so ADR-0004's measured 14,468 bytes for twenty minutes reach a pipe in 4 KB blocks | follows |
| so stdout flushes about once per six minutes of audio, sparser than a progress line | **false here** |

Three and a half blocks across twenty minutes is where "about one flush per six minutes" comes from,
and that arithmetic is right. What is wrong is that the general property never gets to apply.
**whisper.cpp v1.9.1 calls `fflush(stdout)` as the last statement of the per-segment loop in
`whisper_print_segment_callback`**, and installs that callback for every invocation whose `-of` is not
`-`. Every invocation `engine_arguments` builds passes a scratch prefix to `-of` (ADR-0002), so the
callback is installed on all of them. The engine flushes stdout once per *segment* — a few seconds of
audio — which is **denser** than a progress line rather than sparser.

This is written down as a refutation and not merely as a conclusion, because the conclusion on its own
does not survive re-derivation. "stdio is block-buffered when it is not a terminal" is true, is the
right thing to reach for, and gives the wrong answer about this binary; a reader holding only the
conclusion will derive the objection a second time and decline issue #32 on a reason that is false
here.

What is measured and what is not: the flush call and the `-of` condition are read out of
whisper.cpp v1.9.1's source, and nothing in this repository has measured the arrival pattern at a real
drained pipe. That measurement is what issue #32 waits on. Taking the trade is a decision against
ADR-0004, whose 14,468 bytes against a few-kilobyte pipe buffer is a wedge that was actually observed,
and an argument does not overturn a measurement.

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
sparser one. Taking it is a decision against ADR-0004 and wants a measurement first. Where that flush
is in the engine's source, and which argument against draining it is wrong, is *The argument for not
draining stdout is refuted* above.

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

## What would reopen this

An engine release that moves the progress line to another stream, changes its text, or changes the
banner's fields or units. The coupling is to human-readable output and is not a contract, and the
fixture is what would catch it.

A measurement of stdout's arrival pattern at a real drained pipe — issue #32 — which is the one thing
that would let the silence bound stop scaling with the recording's length.

A real per-machine realtime factor, measured rather than assumed, which is what
`DEFAULT_REALTIME_FACTOR` being a handed-in parameter rather than a constant at the call site exists
to leave room for. That would not touch `ENGINE_BOUND_MULTIPLE`, which is deliberately sized against
the CPU-only fallback and not against the machine in front of it.
