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
