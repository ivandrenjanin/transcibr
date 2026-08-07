# The scratch cache is swept behind a floor, and a Recording settles only across a gap the filesystem can express

Two decisions in `src/audio` that both act on a clock and a filesystem this program does not own, and
both of which had to depart from what was originally asked for.

**The sweep works to three numbers where the spec asks for two.** `docs/spec/0001` asks that the
scratch cache be swept at Batch start "with a size and age ceiling"; `Sweep_Limits` carries a size
ceiling, an age ceiling, and a **floor** — `spare_age_ns`, under which nothing is taken whatever
either ceiling says.

**A Recording is settled by two readings taken at least three seconds apart**, the gap chosen against
the coarsest modification timestamp a Recording can carry rather than against taste, and every wait
that gap implies rounded **up** to a whole millisecond because the sleep underneath it truncates.

## The floor is what makes the delete safe rather than merely bounded

Ceilings bound a cache. They do not make deleting from it safe, and the reason is ADR-0002: the
scratch cache is not a spoil heap but the working directory of anything currently running. An
extraction's `.wav.part` and the Engine's output are both written **there, while they are being
written**. A ceiling that took the oldest file until the total fitted would, on a machine with a
second transcibr window open, take the audio another worker was at that moment writing.

The floor is checked before either ceiling and never after. A rule that only applies where nothing
else has already decided is not a floor at all:

```odin
if entry.age_ns < limits.spare_age_ns {
	continue
}
if entry.age_ns > limits.max_age_ns || total > limits.max_bytes {
	append(&chosen, index)
	total -= entry.bytes
}
```

It is not the only thing between a running worker and a delete, but it is the only one that does not
depend on how the other process opened the file. Windows refuses to delete a file another process
holds open without sharing delete permission, so `sweep_cache` is best-effort by construction: it may
choose such a file, `os.remove` may refuse, and it counts what it actually removed. **Nothing in
`src/audio` logs that refusal** — there is no `core:log` import in the package — so the returned count
is the whole of the signal today. Recorded as a gap rather than as a design.

## The shipped values, and which of them is measured

The reference corpus is 56 Recordings totalling 75 hours, longest 168 minutes (`docs/spec/0001`).
Mono 16 kHz signed 16-bit PCM is 32,000 bytes a second, so a whole Batch of that corpus extracts to
**8.64 GB** of audio.

| number | value | where it comes from |
|---|---|---|
| `max_bytes` | 20 GiB | a little over two whole Batches of the reference corpus at 8.64 GB apiece |
| `max_age_ns` | 7 days | a Batch interrupted over a weekend resumes against its own extracted audio rather than extracting it all again |
| `spare_age_ns` | 1 hour | an extraction of the corpus's longest Recording takes minutes, and the Engine writes its output at the end of one transcription, so a file something is still using is minutes old at the very most |

Only the 8.64 GB is arithmetic on a measured corpus. **The three limits themselves are judgements
sized against it and nothing else** — no cache was observed filling, no weekend resume was timed, and
the hour is an order of magnitude of headroom over a "minutes" that was reasoned about rather than
measured. `sweep_test.odin` pins all three outright and pins each threshold one nanosecond either
side, because "roughly a week" and "roughly an hour" are not what the code does: a file is kept or it
is gone, and the whole difference is one nanosecond across a number nobody had written down.

The one relationship between the three is held by the compiler at the definition, before any test
runs: `#assert(DEFAULT_SWEEP_LIMITS.spare_age_ns < DEFAULT_SWEEP_LIMITS.max_age_ns)`. A floor above
the age ceiling would make the age ceiling unreachable.

A file dated in the **future** gets a negative age, is therefore younger than the floor, and is never
taken. That is the safe answer to clock skew or a file copied off a machine running ahead, and it
falls out of doing the arithmetic in one place rather than clamping it in another.

## Why three seconds

FAT and exFAT store a modification time to a **two-second** granularity, and SMB servers commonly
round to the same. A gap shorter than two seconds can therefore fall entirely inside one bucket: a
file being actively appended to shows the *same* timestamp at both readings, and only its size gives
it away. Two seconds is the floor that guarantees the bucket moves. The third second covers the
writer's own flush interval, since what is timestamped is the last write before the reading and not
the reading itself.

The two-second granularity is documented filesystem behaviour rather than something measured here.
The third second is a judgement with no measurement behind it at all.

It is a **gap and not a wait**, and the distinction is what makes it affordable. On a Batch of
several hundred Recordings, a wait taken per Recording would be minutes of pure idling. It is not
paid that way: the first reading is the one taken when the Batch was *planned*, which for every
Recording but the first is already minutes or hours old by the time its extraction starts. Only a
Recording whose extraction begins within the gap of its own planning ever waits, and it waits once —
which is every Batch's **first** Recording and no other, since its first look is always too soon to
tell. `SETTLING_ATTEMPTS` is 2 for that reason, and a `#assert` holds it at two or more: a Recording
looked at once and found too soon to tell can never answer anything else, because there is no second
reading to compare against.

## The sleep that truncates, and the Recording it cost

`time.sleep` on Windows is `win32.Sleep(win32.DWORD(d / Millisecond))` in
`core/time/time_windows.odin` — integer division, so it **truncates**. That defeated the second look
outright, and it was found by a running case rather than reasoned about: the case in `run_test.odin`
that takes this wait against a real file came back red the first time it ran.

The worked example is the one that case exercises, at its own two-second gap:

| gap | spent before the first look | wait asked for | `Sleep` actually sleeps | verdict |
|---|---|---|---|---|
| 2 s | 300 µs | 1,999,700 µs | 1,999 ms | still inside the gap → `Too_Soon_To_Tell` again → `.Still_Unsettled` |
| 2 s | 300 µs | 2,000 ms, rounded up | 2,000 ms | `Settled` |

Three tenths of a millisecond early is the whole of it. The reading taken then is still inside the
gap, `settling` answers `Too_Soon_To_Tell` a second time, and `settle` refuses a Recording nothing was
ever wrong with — **the exact failure the second look exists to prevent**, landing on every Batch's
first Recording and no other. So `remaining_gap_ns` rounds every wait up to a whole millisecond:
waiting a fraction of a millisecond longer than the gap costs nothing, and waiting a fraction less
costs the Recording. The same procedure clamps a negative `waited` to the whole gap, because a clock
that stepped backwards between the two readings would otherwise ask for a longer wait than the gap
ever was, and clamps at zero so a gap already outlasted is not a negative duration handed to a sleep.

That procedure is in `settling.odin` and not inline in `run.odin` for ADR-0018's reason: it is a
decision, and a decision in `run.odin` is one no case can reach. It lived inline once and had no case
at all.

## A Reading carries a wall clock, and the residual is stated rather than worked around

`Reading.taken_ns` is a wall clock and not a monotonic tick, on purpose. A Batch resumes across a
reboot (ADR-0003), and a tick from a previous boot compares against nothing.

The cost is that a **forward** clock step is arithmetically indistinguishable from time passing. A
minute of clock inserted between two readings a millisecond apart looks exactly like two readings a
minute apart, and a `Reading` holds no third fact that could tell them apart. What bounds the damage
is which half of the answer the clock reaches: the gap decides only how much to make of two readings
that **agree**, while the proof that a file is moving is its size and its modification time, and a
step in either direction leaves both of those alone. So the worst a forward step can do is turn
`Too_Soon_To_Tell` into `Settled` on a file nothing was seen to touch. `settling_test.odin` pins
exactly that reach — the step, and then the same stepped reading with four kibibytes added and with
its modification time moved, both of which are still `Still_Being_Written`.

A **backward** step — NTP, or a user setting the time — is external input under A8 and answers the
same way an unmeasurably short gap does. `settling` deliberately does not assert "taken in order":
the readings belong to this package, but the clock they carry belongs to the machine. It held that
assertion once, and a clock step during a Batch would have crashed the program.

## The listing counts entries `core:os` cannot classify

`cache_entries` keeps `.Regular` **and** `.Undetermined`, and what that admits is wider than it looks.
`core:os`'s `stat_windows.odin` calls a directory entry a `.Symlink` for `IO_REPARSE_TAG_SYMLINK` and
`IO_REPARSE_TAG_MOUNT_POINT` and for no other tag, so **any** other reparse point on a non-directory
falls through to `.Undetermined` the moment its handle will not open — as does an ordinary file
another process holds open without sharing.

Measured on this machine: `%LOCALAPPDATA%\Microsoft\WindowsApps` lists **39 non-directory reparse
points** — AppExecLinks, size zero, neither symlink nor junction nor directory.
Nothing like that belongs in a scratch cache; the realistic one inside a cache is a cloud-files
placeholder whose hydration fails offline.

Dropping them had a **measured** cost, and `run_test.odin` holds the reproduction. A file held open
with no sharing at all — which is what an extraction's `.part` looks like from outside while ffmpeg
has it — comes back `.Undetermined`, so under the old filter its bytes never entered the size total:

| cache | ceiling | total the sweep measured | swept |
|---|---|---|---|
| held 2048 B (unopenable) + older 1024 B | 2048 B | 1024 B, with the held file dropped | nothing |
| held 2048 B (unopenable) + older 1024 B | 2048 B | 3072 B, counting both | the older file |

A cache dominated by in-flight `.part` files therefore measured well under its ceiling and swept
nothing at all — **which is the leak the ceiling exists to stop**. They are counted because the size
and the modification time of an `.Undetermined` entry come from the directory entry and are exactly as
good as a `.Regular` entry's. What bounds the widening is not the type filter but the floor and the
two ceilings, which an `.Undetermined` entry meets like any other.

## The two intermediates carry the process id; the finished audio does not

`<name>.probe` and `<name>.wav.part` were the same two names in every transcibr on the machine, and
the scratch cache is shared. Two windows over one Recording had one worker's `defer os.remove(answer)`
deleting the other's probe answer, and one worker's rename moving the file the other's ffmpeg was
still writing. Both intermediates now carry `os.get_pid()`. `<name>.wav` stays plain because it is the
artifact stem (ADR-0008), and two workers that both produced it produced the same bytes.

**The stated residual: the process id does not separate two workers inside one transcibr.** What keeps
those apart is the artifact stem, and that rests on no two workers in a Batch ever taking the same
Recording. That is the **Batch's** guarantee, and nothing in this package enforces it — `extract` is
handed a `Job` and believes it. Said out loud because the two intermediates are named for the process,
and it would be easy to read that as the whole answer.

## The accepted costs

**The cache can sit over both ceilings indefinitely, and that is the floor working.** The pinned case
is three eight-gibibyte files plus a 30 GiB in-flight `.part` half an hour old: the three go, the cache
is still far over 20 GiB, and the young one stays. A run that hangs onto a large `.part` forever
therefore defeats the size ceiling entirely. That is the trade — a bounded cache that occasionally
overshoots, against a sweep that destroys the run it is starting.

**A forward clock step can call a file settled that nothing was seen to touch.** Pinned, not fixed,
and unfixable without a monotonic tick this design cannot carry.

**Every Batch's first Recording pays three seconds** before its extraction starts.

**The four assertions in `sweep_choice` are assertions on this program's own values, and that expires.**
Every `Sweep_Limits` reaching it today is `DEFAULT_SWEEP_LIMITS` or a value a case built, so a floor
above the age ceiling is corrupt internal state and A8's `assert` is right. The day a settings file
supplies these numbers they arrive from outside, and all four must become a refusal in `Cache_Fault`'s
own vocabulary, next to the one `open_cache` already answers in (ADR-0018).

**A latent under-free that is harmless today.** A dynamic array made at `cap` and returned as `[:]`
under-frees, because `delete` frees `len` items — so the returned slice is not the whole of its own
allocation. `sweep_choice` and `cache_entries` both `shrink` to what was actually kept for that
reason, and `check_audio`'s head buffer is on the stack for the same class of reason, having
previously been freed at the length **read** rather than the length reserved. Odin's heap allocator
ignores the size on free, so none of this is observable now; it becomes wrong the day ADR-0010's
per-worker allocators become size-classed. The surviving `shrink` calls look like tidiness and are
not.

## What reopens this

A settings file that supplies `Sweep_Limits` from outside reopens the assertions immediately — that
one is scheduled rather than hypothetical.

A cache observed over either ceiling for longer than the floor with nothing running against it means
the floor is placed wrong, not that the ceilings are. A Recording refused as `.Still_Unsettled` that
nothing was writing means the gap or the wait arithmetic is wrong, and it is the first Recording of a
Batch that will show it. A filesystem whose modification-time granularity is coarser than two seconds
reopens the three, and it would be the first evidence that number has ever had beyond documented
behaviour.

`core:os` classifying reparse points more finely than the two tags above would narrow
`.Undetermined` back towards "a file nothing could open", at which point the entry filter is worth
re-reading — but not the decision to count them, which rests on the directory entry and not on the
type.

## Addendum: a refused Recording sweeps its own Engine output, immediately (issue #211)

The sweep above is age- and size-bounded, and runs once at Batch start. It is not the only thing
that removes a file from the scratch cache. Issue #211 measured a second, narrower gap: a
`.Refused` Engine run (issue #186 — the Engine finished and exited nonzero) or an `.Output_Empty`
one (the Engine exited cleanly and left an empty file) both leave their output file sitting in the
cache with nothing to remove it until this Batch-start sweep next runs — one partial file per
failed Recording, unbounded across a batch run against a persistently failing Engine.

**Ruling (maintainer, delegated, 2026-08-07): remove it immediately, at the point the Recording's
own run settles as a refusal, rather than waiting for the next Batch-start sweep.** The fault
record and Sidecar already carry the diagnostic story for a refused Recording; an unbounded cache
of partials across a failing batch is the worse trade, and `.Output_Empty` converges to the same
shape its `.Refused` sibling gets — its file is removed too, which is a behavior change from the
"leaves its file behind" precedent this document's own body describes for `.Output_Empty`'s audio
counterpart.

The shape is `src/audio/run.odin`'s own `discard_part`, restated for the Engine's output rather
than ffmpeg's: every fault removes the file **except** `.Not_Stopped`, whose reason is the same one
`engine.transcribe`'s own doc comment already gives — the Engine may still be running and may still
hold the file open, so nothing here touches it, and it is left for this ADR's age-based sweep
instead. Every other fault either leaves a real half-written or empty file
(`.Did_Not_Finish`, `.Went_Silent`, `.Refused`, `.Output_Empty`) or leaves nothing to remove at all
(`.Path_Not_Ascii`, `.Not_Started`, `.No_Output`) — an `os.remove` of a path that was never written
is the same tolerated failure `discard_part` already accepts.

Implemented in `src/pipeline/recording.odin`'s `discard_engine_output`, called from
`transcribe_and_place` on any Engine fault, rather than in `src/engine` itself: the Engine package
already hands the refusal's fault back with the exit code (issue #186), and `src/pipeline` already
holds `job.cache` and `job.name` — the same two values `engine.transcribe` builds its own output
prefix from — so no new field crosses the package boundary. An exact-path delete of the one file
this Recording's own run could have written; no enumeration of the cache directory, no wildcard, no
`os.remove_all` (CLAUDE.md's Odin notes, issue #97/#105).

**What this addendum does not do.** It does not touch `src/audio`: `discard_part` already applies
this exact discipline to extraction's own `.part` file on every one of its faults but
`.Extraction_Not_Stopped` (`run.odin:672-685`), so measurement here found nothing to fix on that
side of the pipeline. It does not add an operational log line naming what was kept or removed —
the operational log 176-B describes does not exist yet, and this ticket does not invent one; the
line lands with 176-D's event seam instead.

## Addendum: a refused Recording's extracted wav sweeps too, immediately (issue #251)

Issue #211's sweep above, and the addendum that implements it, cover the Engine's own output file.
They do not cover the much larger file sitting beside it in the same cache entry: the extracted
`<cache>\<name>.wav` `transcibr:audio` wrote before the Engine ever ran. Issue #251 measured what
this document's body claims for that file and found it fiction. The stated rationale for keeping a
Recording's wav around — "a Batch interrupted over a weekend resumes against its own extracted
audio rather than extracting it all again" — is implemented **nowhere**: `audio.extract`
(`src/audio/run.odin:567`) does no existence check on a cached wav before writing one, and
`produce` unconditionally extracts to a fresh `.part` and renames over whatever is already there.
Every wav this codebase has ever written is write-once-read-once; nothing reuses it, ever. At the
pinned extraction format (16 kHz mono `pcm_s16le` = 32,000 B/s) that is ~115 MB per hour of source
per failed Recording, roughly 1000× the partial `.json` the addendum above sweeps, held for up to
seven days until the next Batch-start age sweep finds it.

**Ruling (maintainer, delegated, 2026-08-07): sweep it immediately too, at the same point
`transcribe_and_place` already settles the Engine's own output.** With no reuse path implemented
anywhere, keeping 115 MB/hr of source per failed Recording buys nothing the fault record and
Sidecar do not already carry as the diagnostic story.

The fault set this sweep answers to is narrower than the Engine-output sweep's. Both keep
`.Not_Stopped` — the Engine may still be running and may still hold the file open, same reason as
above. The wav sweep also keeps `.Did_Not_Finish`: its own `fault_says` sentence is "the Engine was
stopped before it finished", and every one of its three `child.Stop_Reason` origins
(`.None`, `.Bound_Expired`, `.Drain_Failed`, `src/engine/run.odin`'s `refused`) is this run simply
not landing inside its bound — nothing judged this Recording's audio and rejected it, the way
`.Refused` or `.Output_Empty` do. That is exactly the "Batch interrupted, resumed later" shape this
document's own rationale describes, even though nothing reuses the file yet, so it is the one fault
worth keeping the wav for regardless. Every other fault — `.Refused`, `.Output_Empty`,
`.Went_Silent`, `.Path_Not_Ascii`, `.Not_Started`, `.No_Output` — either judged this Recording's
audio and rejected it or never touched the wav at all, so sweeping it on those loses nothing a
retry could use.

Implemented in `src/pipeline/recording.odin`'s `discard_recording_wav`, called from
`transcribe_and_place` alongside `discard_engine_output` on any Engine fault. It takes the exact
path `extracted.extracted.audio` already carries — the same path `audio.extract` handed back —
rather than rebuilding a prefix the way `discard_engine_output` does, because `transcribe_and_place`
already holds it. `os.remove` on that one path; no enumeration of the cache directory, no wildcard,
no `os.remove_all` (CLAUDE.md's Odin notes, issue #97/#105), tolerant of a locked file the same way
`discard_part` and `discard_engine_output` already are.

**What this addendum does not do.** It does not implement the reuse this document's body still
describes as the reason a successful Recording's wav is kept. That is a real feature — an
existence-and-freshness check in `audio.produce` before it extracts — or, if that feature is never
built, an amendment to this document's body to stop claiming it exists. Issue #251 files that
question to the maintainer in its own PR rather than resolving it here, and does not silently
rewrite the rationale above: the body's words stand as originally written, now qualified by this
addendum's measurement that nothing implements them. It does not touch a successful Recording's
wav at all — that file stays exactly where the age/size sweep already governs it, unchanged.

**A new residual, alongside "The two intermediates carry the process id; the finished audio does
not" above.** That section's safety argument for leaving `<name>.wav` plain — "two workers that
both produced it produced the same bytes" — covers concurrent WRITES only. This sweep adds an
unconditional `os.remove` of that same plain name on a fault, and the write-side argument says
nothing about a delete: if two transcibr processes are pointed at the same `--cache` over the same
Recording (the ADR's own stated scenario for why the two intermediates needed a pid at all), one
process's `.Refused` can remove `<cache>\<name>.wav` in the window after the other has extracted it
but before its own Engine run has opened it, producing a spurious fault on a Recording that would
otherwise have transcribed. `discard_recording_wav` carries no pid, freshness, or handle check
against this. Issue #251 measured that this sweep has no ownership guard and records the gap here
rather than inventing one: an ownership check is a real feature, not a fix, and is left to the
maintainer alongside the reuse question above.
