# transcibr

Turning long-form audio and video recordings into readable transcripts, locally and offline.

## Source material

**Recording**:
A single source audio or video file to be transcribed. Any content, any length — no assumption
about subject, setting, or number of speakers.
_Avoid_: video, audio file, media file, input, source

**Batch**:
The set of recordings selected by one invocation, processed together and resumable as a unit.
_Avoid_: run, queue, folder

## Transcription

**Engine**:
The external speech-recognition program transcibr drives as a subprocess. Distinct from the model
it loads.
_Avoid_: whisper, backend, recognizer

**Model**:
The weights file the engine loads to recognise speech. Interchangeable; the engine is not.
_Avoid_: engine, network, checkpoint

**Cue**:
One timestamped fragment of speech as the engine emits it — a start, an end, and its text.
Typically a few seconds long and cut mid-sentence.
_Avoid_: segment, subtitle, line

**Engine output**:
The JSON one engine invocation leaves in the scratch cache, named from the artifact stem. Distinct
from Transcript, which is a whole stage later: nothing here has been collapsed, merged or rendered,
and it is retained so a transcript can be re-rendered without spending GPU time again. Named in full
and never as bare "output" — that word is the one the Transcript entry avoids, and the two are one
word apart in a sentence and a stage apart in the pipeline.
_Avoid_: transcript, result, transcription, json

## Driving the engine

**Process contract**:
Everything pure about driving a child process: the command line one is started with, and the output
lines it writes read back as progress and duration. One core module and one test seam over both
halves (ADR-0017), which is why `src/process` is named for the module rather than for either half.
_Avoid_: spawner, subprocess, command line, runner

**Executable**:
The path of the child transcibr starts — ffmpeg or the Engine — as it is spelled on the command
line. Distinct from the program transcibr itself is: `program` meant both, and one of the two was
always the wrong reading.
_Avoid_: program, binary, command, exe

**Child**:
One running ffmpeg or Engine process, with the handles that hold it and the job object that ends it.
Distinct from Executable, which is only the path — and it is a tree rather than a process, because a
child that starts something of its own leaves a process no handle reaches (ADR-0004).
_Avoid_: spawner, subprocess, runner, process

**Run**:
One bounded execution of a single Child, from start to Finished, Stopped or Unstoppable — what
`transcibr:child.run_bounded` hands back. Not a Batch: Batch's own entry avoids this word for exactly
this reason, because "a run" colloquially means the whole invocation, and this is one child inside
it. Not the Child either, which is the process itself rather than how its execution ended.
_Avoid_: execution, attempt, invocation, session

## Watching the engine run

**Reading**:
One progress percentage the engine has actually reported. Arbitrary values rather than a grid, and
how many a recording produces depends on its length: at most twenty, and eleven in the one real
capture of a four-minute recording (ADR-0012). The gap between two of them is the longest silence a
healthy run produces, which is what every silence bound in transcibr is sized against — from the
capture's largest jump between two readings rather than from a count of them.
_Avoid_: progress line, tick, sample, update, step

**Startup banner**:
The line the engine writes before inference, naming the audio it is about to process and how long it
is. One of the two places a duration may come from; the container probe is the other and the scratch
audio's own header is neither (ADR-0012).
_Avoid_: header, preamble, first line, prologue

**Estimate**:
The percentage transcibr works out from elapsed time and the recording's length when the engine has
not supplied a reading recently. Floored at the last reading and never allowed to reach a hundred —
only the engine or a finished engine output can say a recording is done.
_Avoid_: fallback, guess, projection, extrapolation

**Frozen**:
What a progress display becomes when nothing has arrived on any stream transcibr can see: the number
stops moving and says it is waiting. A display state and never a verdict — a bar that keeps climbing
over a child that has stopped is the failure ADR-0012 exists to prevent, and one that has stopped
climbing is not yet a failed recording.
_Avoid_: stalled, stuck, hung, dead

**Watchdog**:
What decides that silence has gone on long enough to be an operating error rather than a display
state. Keyed on bytes arriving, never on readings — the engine is silent on progress for the whole
of model load — and bounded by the recording's own length rather than by a fixed number of minutes.
_Avoid_: timeout, heartbeat, monitor, keepalive

**Bound**:
The wall-clock ceiling on one child, or on one blocking call this program does not otherwise
control, so that nothing in a batch blocks forever (issue #27). `child.run_bounded` polls one for a
child; the same poll-then-abandon shape bounds a blocking read too — a Recording's Engine output, a
hand-typed `--from-json` path naming a reserved Windows device that opens fine but never returns
from reading it, a Model file, or a directory listing a stalled share stops answering. Distinct from
the watchdog: a bound is about something still working that has had long enough, a watchdog about
one that has stopped saying anything at all.
_Avoid_: timeout, deadline, limit, budget

## Turning a recording into audio

**Probe**:
What a container is asked about itself before any work is spent on it — how long it is, and whether
it carries audio at all. A claim the container makes and not a measurement of it, which is why a
container that estimates its own length from an average bitrate can be minutes out.
_Avoid_: ffprobe, scan, inspect, metadata

**Scratch cache**:
The one directory transcibr's children are allowed to write into: extracted audio, the Engine's
output, and nothing that is finished. ASCII-only by construction, because the Engine cannot open a
path that is not (ADR-0002), and swept at Batch start so a run that fails every Recording does not
accumulate audio forever.
_Avoid_: temp, working directory, staging, intermediate

## Doctor

**Report**:
What a preflight run hands back: `[]Check`, nothing more — there is no `Report` type in `src/doctor`,
only a slice of `Check` produced by `run_preflight`, read by `report_ok` to decide the `--doctor`
subcommand's own process exit code, rendered one line at a time by `render_check`, and freed together
by `destroy_report`.
_Avoid_: results, summary, output

**Check**:
One line of a doctor Report: what was checked, and how it came out — PASS, FAIL with an actionable
reason, SKIP with the reason it was never judged, or an advisory INFO that never turns the Report's
own verdict false on its own (ADR-0033). `passed`, `failed` and `skipped` are the three constructors
that produce a Check meant to reach a Report. The Model check also builds a bare, unnamed `Check{}` as
an internal screened-clean sentinel (`model_screened_further`, `checks.odin:200`) — never one of the
three, and never handed to a Report itself; `model_check` discriminates it by `len(refusal.name) > 0`
and, once past it, always returns a Check one of the three constructors made.
_Avoid_: result, verdict, test, probe

**Preflight**:
The doctor run a user invokes directly, through the `--doctor` subcommand, so they find out about a
problem before a Batch rather than mid-run (spec story 8): ffmpeg, ffprobe, the Engine, the Model, then
the GPU diagnostic — five Checks in total, run through to the end even after an earlier one fails, so a
user sees every actionable reason at once rather than fixing one problem per run (`run_preflight`,
ADR-0033). Informational, not gating — a `--batch` run never calls it and is not
blocked by it. Distinct from the health watch, the same GPU guard's other half, which runs during a
Batch rather than before one.
_Avoid_: startup check, sanity check, readiness check

**Load probe**:
The Model check's authoritative half: actually spawning the Engine against the Model and a committed,
silent probe clip, because only a real load proves a Model loads — ADR-0011's spawn-and-verify, never
stat-and-trust. Replaces a SHA-256 over the Model's bytes that ADR-0033 tried and removed: compared
against nothing, it cost 6.9 of an 8.5-second doctor run and still passed a 200 MiB head-truncation of
a real Model that the load probe refuses in under a second. Built from `doctor`'s own exported `Probe`
struct (`tool.odin`) — what one bounded spawn of an executable came to, its whole diagnostic stream
captured — a third sense of the word distinct from this glossary's container Probe, which is a
container's own claim about itself and spawns nothing. Skipped, not failed, when the Engine check
ahead of it did not pass; see Skip.
_Avoid_: hash check, checksum, verification pass

**Health watch**:
The runtime half of the same GPU guard the preflight's Engine check is the other half of
(`first_recording_health`, ADR-0011, ADR-0033): two independent checks on the first completed
Recording, not one comparison. The name half fails only when the Engine's own systeminfo is present
and actively names something other than CUDA, whatever the Recording's speed was — a Recording
running three times the Baseline still fails if a present systeminfo says the build was never
CUDA-capable. An absent or unparsed systeminfo is not evidence of anything and never fails this half
on its own; it leaves the speed half to carry the verdict instead. Once the name half is silent, the
speed half compares the Recording's own realtime factor against the Baseline, catching a driver update
or a GPU in a reset state that a passing preflight could not have seen. A third answer, `conclusive =
false`, is not a fault: a Recording too short for the speed half to mean anything is left unjudged
rather than reported healthy, so a Batch's one health check is not spent on a Recording nothing could
actually be concluded from. Never itself a spawn — the Engine invocation it reads from already
happened for the Recording's own sake.
_Avoid_: runtime check, GPU monitor, watchdog

**Skip**:
What a Check reports when it never ran because an earlier one made its own answer meaningless — the
Model check, when the Engine check ahead of it did not pass, because a Model cannot be judged through
an Engine that does not work. Distinct from Fail: a Skipped Check carries `ok = false` so it never
reads as a pass, but it never turns a Report's own verdict false on its own, because whatever stopped
it from running is already a failure of its own further up the Report. "The model was not judged" and
"the model failed" are two different Checks reporting two different things — the confusion a #96
review round already produced, and the reason this entry exists.
_Avoid_: failed silently, inconclusive, untested, errored

**Advisory**:
A Check that renders as PASS when it passes, exactly like any other Check; only a failing advisory
renders as INFO rather than FAIL, and even then it never turns the Report's own verdict false on its
own — informational, not gating, like every other Check in a preflight Report (ADR-0033). The
GPU diagnostic is the only advisory Check `src/doctor` runs today; the shape exists so a future Check
that is worth printing but never worth failing on does not have to invent one.
_Avoid_: warning, note, informational check

**GPU diagnostic**:
The one advisory Check in a preflight Report: what DXGI can enumerate about attached GPUs, purely to
help a user read a failing Engine check — "no GPU could be enumerated at all" reads differently from
"a GPU is here but the Engine could not reach it." Never the verdict on GPU usability; only the Engine
check, which spawns it directly, and the health watch, which reads what that Engine invocation already
measured, decide that (ADR-0011).
_Avoid_: GPU check, hardware check, GPU probe

**Baseline**:
The one realtime factor this repository has actually measured against a working CUDA path — roughly
17x at beam size 5 over the reference corpus (docs/spec/0001-transcibr-v1.md) — and the frame of
reference the health watch's speed half reads against. Not read by the preflight's Engine check at
all: that check decides on two independent evidence sources, neither of them the Baseline. Before
anything is spawned, `backend_library_present` (`engine.odin:70-71, 90-102`) is a bare filesystem
check for the CUDA DLL beside the executable — ADR-0011's own account of the most common broken
install, missing the DLL entirely — and only once that passes does the check go on to its own
diagnostic output, a `--help` capture checked for `"loaded CUDA backend from"`
(`strings.contains(probe.captured, ...)`, `engine.odin:84`) — not the systeminfo JSON field the
Health watch entry above reads, which is a different Engine output entirely. So the Baseline is the
health watch's own number, not one either of the Engine check's two halves reads. Not a promise about any one machine's own
GPU: the health watch's threshold sits a full order of magnitude below it, because a factor that far
under the Baseline is the CPU-fallback signature the guard exists to catch, not ordinary
machine-to-machine variance.
_Avoid_: benchmark, target speed, expected throughput

## Pipeline

**Stage**:
One step a Recording passes through on its way to a Transcript: extraction or transcription. A
Stage is what a topology test replaces with a fake — the pipeline itself never knows whether a real
one drives ffmpeg, drives the Engine, or does nothing at all (ADR-0006).
_Avoid_: step, phase, task

**Worker**:
A thread that runs one Stage, repeatedly, for as many Recordings as the pipeline hands it. One or
two Workers run the extraction Stage; exactly one runs the transcription Stage, because a GPU is a
serial resource and that is asserted, not merely intended (ADR-0006, ADR-0031). Distinct from
`child.Worker`, an unrelated internal type that bounds a single external call — a Model hash, a
directory listing — on a reusable thread, and never runs a Stage.
_Avoid_: thread, pool

**Queue**:
One of two bounded holding points a Job or its extracted audio sits in on the way to a Transcript
(ADR-0031): the admission Queue in front of the extraction Stage, and the hand-off Queue between the
extraction Stage and the transcription Stage. Both are one or two Recordings deep. The hand-off Queue
is the one ADR-0006's disk-filling bound is about — it is what stops extraction running ahead of the
GPU and filling the scratch cache; the admission Queue carries Jobs rather than audio and costs the
disk nothing. Closing either still delivers whatever it already holds rather than dropping it.
Distinct from Batch, which is the whole invocation and is never called a queue for exactly this
reason — see Batch's own entry.
_Avoid_: channel, buffer

## Repetition

**Saying**:
One cue that said something. The engine writes empty and space-only cues over silence, and those are
not sayings — which is what stops eight minutes of silence being counted as a repetition of it.
_Avoid_: utterance, occurrence, instance, repeat

**Repetition Run**:
A stretch of consecutive cues all saying the same thing, silence cues included. Silence carries a
run on rather than starting one, so a run with the engine's own silence written through it is still
one run.
_Avoid_: streak, sequence, block, loop

**Invention**:
A repetition run the engine produced rather than the speaker — the decoder looping over silence. The
run's number of sayings is the only handle there is on it: per-cue confidence does not exist in
engine output (ADR-0001), and elapsed time separates nothing (ADR-0016).
_Avoid_: hallucination, artifact, fabrication, garbage

**Collapse**:
Dropping the surplus sayings of an invention, keeping the first few so the transcript still shows the
engine ran on. Never a whole-run delete: a run dropped entirely would take the recording's timeline
with it.
_Avoid_: strip, filter, dedupe, prune

## Output

**Paragraph**:
A run of consecutive cues merged into one block of prose. The unit a reader actually reads.
_Avoid_: block, chunk, section

**Merge Profile**:
A named set of thresholds deciding where paragraph breaks fall. `monologue` merges generously;
`conversation` breaks aggressively, because rapid speaker turns leave sub-second gaps that would
otherwise merge two people into one paragraph.
_Avoid_: preset, mode, style

**Anchor**:
A coarse timestamp placed periodically in a transcript so a reader can find their place in the
recording. Deliberately not per-cue.
_Avoid_: marker, timestamp, cue reference

**Transcript**:
The finished document produced from one recording. The deliverable — nothing downstream consumes
it but a human.
_Avoid_: output, transcription, result

**Sidecar**:
The record of how a transcript was produced, written last and only on success. What makes a
transcript's staleness knowable when settings change.
_Avoid_: manifest, marker, metadata, index
