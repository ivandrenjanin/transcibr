# transcibr v1 — specification

Status: ready for implementation. Vocabulary follows `CONTEXT.md`; decisions follow `docs/adr/`.

## Problem Statement

I have a large archive of recorded audio and video — hundreds of hours across many files — and no
practical way to read it. Watching it back in real time is not an option, and I need the words as
text I can search, quote, and hand to something else.

Every existing route fails me in a different way. Cloud transcription means uploading recordings that
I am not willing to send anywhere, paying per hour, and depending on a service that can change or
disappear. Running the command-line tools myself works for one file, but I have hundreds: I would be
hand-writing invocations, remembering which files I had already done, and babysitting an overnight
run that stops the moment one file fails. And what those tools emit is not something anyone can read
— three-second subtitle fragments, cut mid-sentence, each stamped with a timestamp, sometimes with a
phrase repeated forty times where the room went quiet.

What I want is to point at a folder and come back to readable prose.

## Solution

transcibr is a Windows desktop program that turns a folder of recordings into a folder of readable
Markdown transcripts, entirely on my own machine.

I install it, and the first time I run it, it tells me exactly what it needs to download, from where,
how big it is, and under what licence — and waits for me to agree. After that it never touches the
network again unless I ask it to.

I pick a folder. It walks it, tells me what it found and what it will skip and why, and starts. A
list shows every Recording with its progress. It runs for hours without me, and it does not let the
machine fall asleep underneath it. If something goes wrong with one Recording, that Recording is
marked failed with a reason I can read, and the Batch carries on. If I stop it — or the power goes —
what finished stays finished, and starting again picks up where it left off rather than redoing work.

What comes out is prose. Not subtitle fragments: paragraphs, with a timestamp Anchor every few
minutes so I can find my place in the source, and a short header recording how the Transcript was
made. If I decide the paragraphing is wrong for a particular kind of material, I change the Merge
Profile and re-render — which costs seconds, because the Engine's output is kept.

## User Stories

### Installation and first run

1. As a new user, I want the installer to contain everything needed to start, so that I am not
   chasing dependencies before I can see the program work.
2. As a new user, I want to be told what still needs downloading before anything is downloaded, so
   that I am never surprised by a multi-gigabyte transfer.
3. As a privacy-conscious user, I want to see the exact URL, byte size, SHA-256 and licence of each
   download before it starts, so that I know precisely what is arriving on my machine.
4. As a user, I want to cancel a download dialog and still have a working program for everything that
   does not need that component, so that declining is a real option.
5. As a user who already has the Engine or a Model on disk, I want to point transcibr at them, so
   that I do not download gigabytes I already have.
6. As a user on a metered or slow connection, I want a download to resume after interruption rather
   than restart, so that a dropped connection does not cost me the whole transfer.
7. As a user, I want a download that fails verification to be deleted and reported, so that a corrupt
   or tampered file can never be used.
8. As a user, I want a preflight check that tells me whether the Engine, Model and GPU are all
   actually usable, so that I find out before a Batch rather than three Recordings in.
9. As a user, I want to be told if the Engine is running on the CPU instead of the GPU, so that I do
   not discover it after an overnight run produced a fifth of the work.
10. As a licence-conscious user, I want the licences of downloaded components written to disk beside
    them, so that I can read the terms after the fact.

### Selecting work

11. As a user, I want to choose a folder through a normal Windows folder picker, so that I do not
    have to type or paste a path.
12. As a user, I want to drag a folder or files onto the window, so that I can start work the way I
    start work in every other program.
13. As a user with a nested archive, I want subfolders walked automatically, so that I do not run the
    program once per folder.
14. As a user, I want the scan to show progress and be cancellable, so that pointing at a huge or
    slow location does not freeze the program.
15. As a user, I want to see what was found and what will be skipped, with a reason for each, before
    anything starts, so that I can correct a mistake before spending hours of GPU time.
16. As a user, I want Recordings that already have a Transcript to be skipped, so that re-running
    over a folder is cheap and safe.
17. As a user, I want a Recording whose Transcript was produced with different settings to be re-done
    rather than skipped, so that changing the Model or Merge Profile actually takes effect.
18. As a user, I want a Markdown file that transcibr did not write to be left alone and reported, so
    that my own notes beside a Recording are never mistaken for a Transcript and never overwritten.
19. As a user, I want to be warned when two Recordings in a folder would produce the same output
    file, so that one of them cannot silently overwrite or shadow the other.
20. As a user with recordings on read-only or network storage, I want to be told before the Batch
    starts that output cannot be written there, so that I do not spend GPU time producing nothing.

### Running a batch

21. As a user, I want a list showing every Recording with its state and progress, so that I can see
    at a glance what is happening.
22. As a user, I want a real percentage for the Recording being transcribed, so that I can judge how
    long is left.
23. As a user, I want progress to keep moving while the next Recording's audio is being extracted, so
    that the GPU is never idle waiting on disk work.
24. As a user, I want the machine kept awake for the duration of a Batch, so that an unattended
    overnight run is not silently paused by sleep after thirty minutes.
25. As a user, I want a Stop button that actually stops, so that I can reclaim my machine immediately.
26. As a user, I want Stop to leave completed work intact and leave no half-written files behind, so
    that stopping is never destructive.
27. As a user, I want to close the program mid-Batch without leaving processes running, so that my
    GPU memory is not held by something invisible.
28. As a user, I want to restart a Batch after a crash, power loss or reboot and have it continue, so
    that hours of completed work are never lost.
29. As a user, I want the program to remember the folder and settings of my last Batch, so that
    resuming after a reboot does not mean re-entering everything.
30. As a keyboard user, I want to reach every control by keyboard, so that the program is usable
    without a mouse.
31. As a user on a high-DPI display, I want the window to render sharply, so that it does not look
    broken on a scaled monitor.

### Output quality

32. As a reader, I want continuous prose paragraphs rather than subtitle fragments, so that the
    Transcript is something a person can actually read.
33. As a reader, I want a timestamp Anchor every few minutes rather than on every line, so that I can
    find my place in the Recording without the text becoming a table.
34. As a reader of single-speaker material, I want generous paragraph merging, so that a continuous
    explanation reads as continuous.
35. As a reader of interactive material, I want aggressive paragraph breaking, so that a fast
    back-and-forth does not collapse into one wall of text.
36. As a user, I want to choose the Merge Profile per Batch, so that I can match the material rather
    than accept one compromise for everything.
37. As a reader, I want repeated hallucinated phrases collapsed, so that four minutes of silence does
    not appear as the same line sixteen times.
38. As a reader, I want legitimately repeated speech preserved, so that the hallucination filter does
    not quietly delete real words.
39. As a user, I want each Transcript to record how it was made — Model, Merge Profile, Engine
    version, detected language, transcibr's own version — so that a file found on its own months
    later is self-describing.
40. As a user, I want the detected language shown per Recording, so that a misdetection is visible
    rather than producing four hours of confident nonsense.
41. As a user, I want a Recording that produced almost no text to be flagged rather than marked done,
    so that a dead audio track is retried rather than skipped forever.
42. As a user, I want to supply a short list of vocabulary for a Batch, so that names and jargon
    specific to my material are spelled correctly.

### Re-running and tuning

43. As a user, I want to change the Merge Profile and re-render without re-transcribing, so that
    tuning the paragraphing costs seconds instead of hours.
44. As a user, I want re-rendering to produce the same Transcript it would have produced originally,
    so that the two paths do not disagree.
45. As a power user, I want a command-line binary that can plan a Batch without running it, so that I
    can check what would happen from a script.
46. As a power user, I want to re-render from kept Engine output from the command line, so that I can
    iterate on paragraphing in a tight loop.

### Failures

47. As a user, I want one bad Recording to fail on its own, so that it never takes down the rest of
    the Batch.
48. As a user, I want a one-line reason on the failed Recording in the list, so that I know what
    happened without leaving the program.
49. As a user, I want to open the full captured output for a failed Recording, so that I can diagnose
    it without a console.
50. As a user, I want a log file on disk, so that I can look at a failure after the program has been
    closed.
51. As a user, I want a crash to leave something in the log, so that a report is actionable.
52. As a user, I want a Recording that is still being written, or truncated, to be detected rather
    than silently producing a Transcript that stops mid-sentence.
53. As a user, I want a corrupt intermediate file to be re-done from scratch on the next run rather
    than permanently poisoning that Recording.
54. As a user, I want disk exhaustion to fail clearly, so that I understand why the Batch stopped.

### Trust

55. As a privacy-conscious user, I want transcription to make no network request at all, so that my
    Recordings provably never leave my machine.
56. As a sceptical user, I want the offline claim to be checkable rather than promised, so that I do
    not have to take anyone's word for it.
57. As a user, I want no update checks, telemetry, analytics or crash reporting, so that the program
    has nothing to phone home with.
58. As a user, I want the program to work with the network cable unplugged, so that the guarantee is
    real rather than aspirational.
59. As a redistributor, I want the licences of everything bundled to be present and correct, so that
    passing the program on is not a compliance problem.

## Implementation Decisions

### Shape

The program is a pure core inside a thin impure shell (ADR-0009). Two binaries share it: a
GUI-subsystem application, which is the product, and a console-subsystem command-line binary for
planning, re-rendering and scripting (ADR-0004). Both drive subprocesses through **one** shared
spawner, so the command-line binary exercises the same subprocess path the shipped application uses.

**Core modules** (pure, no I/O, no clock, no environment):

- *Transcript* — parses Engine JSON into Cues, collapses repetition runs, merges Cues into
  Paragraphs under a Merge Profile, renders Markdown with front matter and Anchors.
- *Planning* — takes a finished inventory and settings, returns a plan with a per-Recording decision
  and reason.
- *Process contract* — builds command lines; interprets Engine output lines into progress and
  duration events.
- *Worker planning* — turns detected hardware into a worker configuration.

**Shell modules** (impure, kept thin): discovery, probing, extraction, Engine invocation, process
spawning and termination, downloading, artifact storage, logging, settings persistence.

**Interface modules**: the Win32 window, and the command-line front end.

### Engine and artifacts

- Parse the Engine's **JSON**, not SRT (ADR-0001). Hallucination handling is repetition detection
  only; per-Cue confidence does not exist in that output.
- The Engine writes **only into a scratch cache**, under an ASCII-only path. transcibr validates what
  it produced — parses, Cue count above zero, monotonic offsets — and only then moves it beside the
  Recording (ADR-0002). A file that fails validation is quarantined and the Recording is re-run in
  full, not reported as permanently failed.
- Engine exit code zero is not a success signal; absence of valid output is a failure regardless of
  exit code.
- One input file per Engine invocation.
- Child **stdout goes to the null device, never a pipe** — the Engine writes every Cue to stdout
  during inference and an undrained pipe deadlocks it. Only stderr is piped (ADR-0004).
- Beam search stays at the Engine default; there is no batch-size setting to reduce (ADR-0012 context;
  see README scope table).
- Voice activity detection is not used (ADR-0005).

### Completion and resume

- Every artifact is written to a temporary name and moved into place atomically.
- A **Sidecar** is written last and only on success, recording Engine version, Model identity and
  hash, beam size, Merge Profile, vocabulary prompt, source size and modification time, and container
  duration.
- Planning treats a Recording as done only when its artifacts exist **and** the recorded settings
  match the current ones (ADR-0003). Model identity comes from transcibr's own record, never from the
  Engine's output, which reports every large Model under one name.
- Artifact names replace the source extension, and planning asserts the source-to-artifact mapping is
  injective, failing the plan and naming the offending pair rather than letting two Recordings race
  one output path (ADR-0008).
- An existing Markdown file must parse as transcibr's own output before it counts as a Transcript.
- Stale temporary files from an interrupted run are a recognised state and are swept, not ignored.

### Concurrency

- One or two extraction workers feed **exactly one** transcription worker through a bounded channel
  of depth one or two (ADR-0006). This is asserted, not merely intended.
- Shutdown order is close, then join every worker, then destroy — asserted in that order. Channel send
  and receive results are checked and mapped to a Recording state; an ignored failure is how a
  Recording disappears from a Batch without a row in the list.
- **Everything crossing a thread boundary is allocated from an explicitly passed allocator**, never
  the thread-local temporary allocator; each Recording owns an arena destroyed by whichever stage
  finishes it (ADR-0010). Getting this wrong writes one Recording's Transcript from another's audio.
- Child processes are assigned to a job object configured to kill on close, so no Engine survives a
  crash holding video memory (ADR-0004).
- Stopping a child is terminate, wait, close — never the cooperative request, which reports success
  without stopping anything in a console binary.

### Progress, duration and failure

- Progress is parsed from the Engine's stderr, falling back to a time-based estimate keyed on
  **elapsed time since the last progress line**, never on their absence — the Engine is silent during
  model load (ADR-0012).
- The fallback must not animate over a process that has stopped producing bytes; a watchdog treats
  prolonged silence on both streams as an operating error.
- Duration comes from the Engine's startup banner or from a container probe, never from the scratch
  audio file's header, which is not a fixed size.
- Anything arriving from outside the program is an operating error, reported against the Recording
  that caused it, never an assertion. The Batch continues.
- Recording state includes a third outcome beyond done and failed, for output that is suspiciously
  empty for the source duration.
- The GUI keeps a bounded slice of each child's output for its detail view, and writes a rolling log
  to local application data.
- The assertion failure handler and logger are installed at start-up and re-established in every
  foreign-calling-convention entry point; otherwise a GUI-subsystem binary discards every assertion
  message and dies silently.

### Distribution and network

- FFmpeg is bundled, unmodified, from a **pinned dated build**, with corresponding source attached to
  every release (ADR-0013).
- The Engine and Models are fetched only on explicit user action, verified fail-closed against
  compiled-in size and hash constants (ADR-0014).
- All network code lives in one module using hand-declared system HTTP calls; the calling sites are
  exactly two, both behind confirmation (ADR-0015).
- Downloads resume by re-requesting the **canonical** URL, never a stored redirect — redirected
  content URLs expire within about an hour.

From the download prototype, the verification order is decision-bearing and is fixed:

```
expected byte size      (cheapest rejection)
magic bytes             (catches an HTML error page saved as a model)
streaming SHA-256       (never load the file into memory)
then, and only then, move into place
```

A resumed request must be confirmed to have actually resumed — a server that ignores the range and
returns the whole body will otherwise have it appended to the partial file.

- Settings, logs and the scratch cache live under local application data. The scratch cache is swept
  at Batch start with a size and age ceiling; a run that fails every Recording must not accumulate
  audio indefinitely.
- Download descriptors are overridable from disk, so an upstream URL change is repairable without a
  new build.

## Testing Decisions

A good test here states an externally observable fact and would survive the module being rewritten.
It asserts on the Markdown a Recording produces, the plan a folder yields, or the command line a job
generates — never on how those were computed. Tests that assert intermediate structure will be
rejected in review, because the paragraphing internals are expected to change while their output
stays pinned.

There is no prior art: this is a greenfield repository. These tests establish it, and the fixture
below is the pattern later work copies.

Five seams, confirmed with the maintainer:

**S1 — Transcript production.** Engine JSON plus a merge profile and a render context in, Markdown
out. The golden fixture is one real Engine output and its expected Markdown, which additionally pins
the JSON schema the design depends on, so an Engine upgrade that changes the shape fails here rather
than silently emitting empty Transcripts. The render context supplies clock, Engine version and
source identity as arguments, so front matter is covered by the fixture instead of being stripped
before comparison. Table tests cover: cue parsing edge cases, repetition collapse including the case
where repetition is legitimate and must survive, both Merge Profiles against real gap distributions,
and Anchor placement.

**S2 — Batch planning.** Inventory and settings in, plan with reasons out. Covers every resume rule:
artifacts absent, Engine output present but no Transcript, both present and settings matching, both
present and settings differing, a foreign Markdown file present, and two Recordings colliding on one
artifact name. The collision case asserts the plan fails and names the pair.

**S3 — The process contract.** Job and settings in, exact command line out; and captured output lines
in, events out. Argument quoting is tested against adversarial paths — spaces, quotes, trailing
backslashes, tabs, non-ASCII — because being wrong here is silent. Progress and duration parsing are
tested against real captured Engine output, including the case where the format is unrecognised and
the fallback must engage.

**S4 — Pipeline topology.** Job count, worker configuration and fake stages in, observed concurrency
out. Asserts at most one concurrent transcription, extraction within its configured bound, queue
depth never exceeding the bound, that a closed non-empty channel drains rather than dropping the
tail, and that every job reaches a terminal state. No GPU, no subprocesses, runs in CI.

**S5 — End-to-end, local only.** One short committed Recording through real FFmpeg and the real
Engine, asserting the produced audio is mono at the expected rate and that a Transcript and Sidecar
appear. Cannot run in CI — it needs a multi-gigabyte Model and a CUDA GPU — and is marked so.

Every test invocation runs the project vet set, and memory-failure reporting is enabled so a core
procedure that leaks its returned slice fails rather than passes. Because the code spans several
packages, the test command must iterate packages rather than naming one, or it will report success
having run nothing.

**Not covered by any seam, deliberately**: the Win32 window, the downloader against live upstreams,
and GPU behaviour. These get manual verification. The pipeline, subprocess and window layers will
never have unit tests, and the architecture concentrates value away from them for exactly that reason.

## Out of Scope

- Speaker diarization and forced alignment. Multi-speaker material is handled temporally through
  Merge Profiles; speaker labels are not part of the deliverable.
- Translation. A Transcript is verbatim in the source language.
- Voice activity detection (ADR-0005).
- Engine FFI bindings. The subprocess boundary is what makes the Engine replaceable.
- Any network request beyond the two user-initiated downloads: no update check, no telemetry, no
  analytics, no crash reporting, no licence check.
- Quantized Models, and reducing beam search.
- A database or central manifest. Per-Recording Sidecars plus atomic rename give the same guarantee.
- Real-time or streaming transcription. transcibr is a Batch tool over files that already exist.
- Editing Transcripts in the application.
- Platforms other than Windows, and GPUs other than NVIDIA. A CPU fallback is not a supported mode —
  it must be detected and reported, not silently used.

## Further Notes

**Measured on the target machine, not estimated.** The Engine runs at roughly 17× realtime at beam
size 5 on the reference corpus of 56 Recordings totalling 75 hours — a full Batch is about four and a
half hours. Median Recording length is 48 minutes and the longest is 168; the commonly cited
75-minute reference is not representative, and estimates in the interface should not assume it.

**The Merge Profiles are grounded in measurement** (ADR-0007), and their thresholds are the one part
of the program expected to be tuned by reading real output. That tuning loop is why Engine output is
retained, and it is worth protecting: if re-rendering ever becomes expensive, the profiles will stop
being tuned.

**Code signing is unresolved and is a spend, not a design decision.** Unsigned releases show a
SmartScreen warning that resets with every release and never clears, and on Windows machines with
Smart App Control enabled an unsigned binary will not run at all. Extended-validation certificates no
longer help. The free foundation route for open-source projects is the likely answer but names the
foundation as publisher. Worth starting early, as approval takes time.

**Sequencing.** The core seam has no external dependencies and can be built and tested before any
subprocess, window or download work exists. The pipeline topology seam likewise needs no GPU. The
window and the downloader are the last things to become testable and should not gate the parts that
are.
