# Artifacts replace the source extension, and `plan_jobs` asserts the mapping is injective

A recording at `<dir>/<stem>.<ext>` produces `<dir>/<stem>.md` and its retained engine JSON and
sidecar under the same stem. `plan_jobs` — pure, and already the test-first surface — asserts that
the set of planned artifact paths is exactly as large as the set of jobs, and fails **the plan**,
naming the offending pair, when it is not.

The natural claim is that writing artifacts beside their source makes name collisions impossible by
construction. That is false. Two recordings in one directory differing only by extension —
`interview.mp4` and `interview.m4a`, a video plus its extracted audio, a camera file plus a recorder
file, an original plus a remux — both map to `interview.md`.

The failure is worse under the pipeline (ADR-0006) than sequentially. Sequentially the second
recording is silently *skipped*, shown complete, and nothing records that it was never transcribed.
Concurrently, the second job sees the first job's JSON, skips transcription, renders the **first**
recording's cues, and stamps the **second** recording's path into the front matter — a transcript
that names the wrong source, marked complete forever. Both writers also open the same `.part` path,
so the atomic rename can publish an interleaved file.

## Considered and rejected

Appending to the full filename (`interview.mp4.md`) is injective by construction and needs no
assertion at all. Rejected because it is worse to read on disk, and because it adds four characters
to every artifact path — which matters against `MAX_PATH` in deep directory trees, where a source
that extracts fine can still fail to write its output after the GPU work is already spent.

## Consequences

An unenforced prose claim becomes a checked invariant with a two-line red-green test, and the failure
is loud and early — at plan time, before any GPU work — rather than silent and permanent.

The same blind spot swallows files transcibr did not write: a hand-authored `notes.md` beside
`notes.mp4` is mainstream practice, and presence-only reasoning would skip that recording forever.
Before skipping, an existing `.md` must parse as transcibr's own output — front matter present and
carrying the generator key. A foreign `.md` is an operating error for that recording, not a skip.
