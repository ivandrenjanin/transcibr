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
The wall-clock ceiling on one child, so that nothing in a batch blocks forever (issue #27). Distinct
from the watchdog: a bound is about a child still working that has had long enough, a watchdog about
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
