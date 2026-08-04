# An artifact set is published by rename inside its own directory, and the whole record is validated before the first one lands

Every artifact this program writes reaches its name twice: written under `<destination>.<pid>.part`,
flushed, and then renamed onto `<destination>`. The three of them — the retained Engine output, the
Transcript, the Sidecar — are published in that fixed order with the Sidecar last, and before any of
them lands, the record the Sidecar will eventually carry is checked whole.

ADR-0002 settles that transcibr owns every artifact and that nothing the Engine writes is treated as
a completed artifact in place. ADR-0003 settles that the Sidecar is written last and only on success,
and that its presence plus its contents are what resume reads. Neither says which Win32 call the
"move" is, what that call does when it is asked to cross a volume, or where the validation has to sit
for the discipline to hold at all. This ADR is those three things, and it exists because the last one
was placed wrong and crashed the program.

## One call, one flag, and everything below rests on which flag is absent

`os.rename` on Windows is `_rename` in the compiler's own `core/os/file_windows.odin`, and it is a
single call:

```odin
if win32.MoveFileExW(from, to, win32.MOVEFILE_REPLACE_EXISTING) {
```

`MOVEFILE_COPY_ALLOWED` is **not** passed. Nothing at the call site `os.rename(part, destination)` in
`publish` says any of that, and two independent properties this design rests on follow from that one
flag list. They are read off the compiler's source rather than measured here; the failure modes below
are the documented behaviour of the API those flags select.

## Cross-volume: the answer is in the name, not at the rename

`MoveFileExW` is atomic **within** a volume and is not across one. Without `MOVEFILE_COPY_ALLOWED` a
cross-volume rename **fails outright** rather than quietly degrading into a copy and a delete — and
copy-and-delete is precisely the shape that publishes a half-written artifact under its final name,
which is ADR-0002's first measurement one layer down.

This program never asks for one. `part_of` builds the temporary name from one format, `"%s.%d.part"`
over the destination and the process id — the destination's own path with a suffix appended — so the
temporary and the destination are always in one directory and therefore always on one volume:

| destination | temporary name | last separator |
|---|---|---|
| `C:\clips\talk.md` | `C:\clips\talk.md.4321.part` | unchanged |
| `talk.json` | `talk.json.4321.part` | there is none in either |
| `C:/clips/talk.sidecar` | `C:/clips/talk.sidecar.4321.part` | unchanged |

A scratch cache on another drive from the Recording therefore costs a **copy of the bytes**, and
never costs atomicity: the bytes cross the volume boundary before the artifact has a name at all.
That is the whole trick, and it is a **naming** decision rather than a filesystem one.

Which is why the property is checked in `naming_test.odin` over those three destinations and not
asserted in `publish`. The claim is about the **format string** and not about any argument: for every
input `part_of` can be handed, an answer that appends to the destination has the destination's own
last separator, so a run-time assertion on it could never fire on any input this program can produce.
What it actually guards is an *edit* to that one format string, and three destinations guard that
exactly as well as infinitely many would, because the answer does not depend on the input.
`the_temporary_name_an_artifact_is_written_under_is_in_its_own_directory` is the case; the middle row
above is in it because a destination with no directory component at all is the one that would expose
a `part_of` that had started building paths rather than appending to one.

The process id in that name is `transcibr:audio`'s reason, recorded in ADR-0023 for the two scratch
intermediates: a Recording's directory is shared, and two transcibr windows over one Recording under
one temporary name had one window's rename publishing the file the other was still writing.
`two_transcibrs_over_one_recording_write_under_different_temporary_names` pins it at two pids.

**The rename is atomic in the file system, which is not the same as the bytes being on the disk.**
`wrote` calls `os.sync` before it closes, and only then does `publish` rename — without it, a power
loss between the write and the rename leaves the artifact under its final name with a hole in it and,
worse, a Sidecar beside it saying the Recording is finished. Three flushes per Recording, against a
Recording that took minutes on a GPU.

## Replace-existing is what keeps a re-runnable Recording re-runnable

`MOVEFILE_REPLACE_EXISTING` is not incidental. Two things depend on it directly:

A re-run under changed settings publishes **over** its own existing artifacts. That is the whole
mechanism ADR-0003 describes — a user who switches Model or Merge Profile and re-runs gets new
artifacts under the same three names — and a rename that refused an existing name would make every
such re-run fail *after* the GPU time had already been spent.
`publishing_over_an_artifact_that_is_already_there_replaces_it` writes an older Transcript first and
checks the new bytes are what is there afterwards.

A Recording that fails the same way twice quarantines onto an **existing** `.json.bad`. ADR-0002
names that file outright, and `quarantine` is one `os.rename` onto a name that may well already be
occupied by the previous attempt. A refusal there would convert a re-runnable Recording into a
permanent failure — the exact shape ADR-0002 exists to prevent. The quarantine is nevertheless
best-effort: a move Windows refuses because something still holds the file leaves the Recording
exactly as re-runnable as it already was, because the next run's Engine writes over that name
regardless.

**It is no longer reported the same either way, and that half of this paragraph was wrong.**
`quarantine` returns a `bool` saying whether the rename happened, and `disposed_of` dropped it — so a
refused move still answered `Fault.Output_Quarantined`, whose sentence reads *"it has been moved
aside and this Recording will be done again from the start"*. A user was told a file had moved that
was still exactly where the Engine left it, and the one value that knew otherwise had been thrown
away on the line above. Re-runnable is what the *outcome* is; it is not what the sentence said, and a
program that reports the filesystem wrongly is not made right by the outcome being survivable.

`Fault.Output_Not_Quarantined` reports it. Its sentence keeps the promise the outcome does support
and drops the claim it does not: the output *"could not be moved aside, and this Recording will be
done again from the start over the top of it"*.
`engine_output_that_could_not_be_moved_aside_is_not_reported_as_moved_aside` blocks the `.json.bad`
name with a **directory** — the same block
`an_artifact_that_cannot_be_moved_into_place_leaves_no_half_written_file` uses, and a thing a user
can really have — and then asserts the Engine's output is still where it was and no Sidecar vouches
for the Recording.

The dropped `bool` is the finding behind CLAUDE.md rule F2 (issue #43). Every procedure in this
repository that returns anything now carries `@(require_results)`, so the discard that hid this is a
build failure and a discard that is meant has to be spelled `_ =`.

Every failing path removes its own `.part`. `holds_a_part` in `place_test.odin` is asked after the
success case, after a blocked publish, and after a refusal, because a temporary left behind is a file
in a user's own directory that nobody can explain, and one the next cache sweep would only take on
age (ADR-0023). `an_artifact_that_cannot_be_moved_into_place_leaves_no_half_written_file` blocks the
rename with a **directory** sitting under the artifact's own name, which is a thing a user can really
have.

## The whole record is validated before the first artifact is published

This is the ordering rule, and it is the part that was learned rather than designed.

`os.stat`'s modification time really is negative for real files. Three named classes produce one: a
recorder whose clock never started and defaulted to `1970-01-01 00:00` **local** time, which is
negative anywhere east of Greenwich; a file restored from an archive that kept its original time; and
a virtual filesystem answering FILETIME 0, which is 1601. That value reaches transcibr through
`read_source` in `src/audio` — `os.stat`, then `time_to_unix_nano` — and is handed to `sidecar_of` as
`source_modified_ns`.

The Sidecar's format writes a run of decimal digits with **no sign**. A negative
`source_modified_ns` can therefore be neither written nor read back, and a Recording carrying one is
an operating error: `Fault.Not_Recordable`, refused by name against the file that caused it.

**What made this a decision rather than a bug fix is where the refusal had to go.** The comment on
`write_number` used to claim that every number reaching it was this program's own arithmetic and
nothing external. That was false, and the falsehood was the bug: the `assert(value >= 0)` there
killed the process, and it killed it **late**, because the Sidecar is written last. By the time the
assertion fired, the retained Engine output and the Transcript were already published — a Recording
that looks two-thirds finished with nothing vouching for it, and under a Batch the whole run dead
with it, which is ADR-0002's per-Recording-failure discipline defeated by an assertion.

CLAUDE.md's rule A8 states the general boundary rule. This is the concrete case where the boundary
was drawn in the wrong place, and the rule the next artifact writer needs is the ordering one:
**validate everything before the first publish, because the record that vouches for the set is
written last.**

The fix is `recordable`, called from `complete` before the Engine's output is even read, and it asks
about the **whole record** rather than about the one field that has an outside — `model_bytes`,
`source_bytes`, `source_modified_ns` and `container_ms`. Asking about all four is what makes a number
added to a Sidecar later covered without anybody remembering to come back to it. (`beam` is not
there and cannot be: it is a `u32`, so the type already says what the other four have to be checked
for.) That is also what turns `write_number`'s assertion from a hope into an invariant, which is rule
A4's pairing with the write side actually built.

`a_recording_the_filesystem_dates_before_1970_is_refused_with_nothing_published` is the case, at
`-10_800_000_000_000` — 1969-12-31 21:00 UTC. It asserts `Fault.Not_Recordable` and then asserts the
negative space four times over: no Transcript, no retained output, no Sidecar, no `.part` anywhere.
It also checks the Engine's own output is still where it was, because this is not the shape of
failure a quarantine answers and moving it aside would set up a re-run that spends the GPU time again
to reach the same refusal.

## The order of the three, and why the name and the artifact travel together

| order | artifact | what its presence means with no Sidecar beside it |
|---|---|---|
| 1 | retained Engine output, `.json` | a Recording nobody has finished; the next run overwrites it |
| 2 | Transcript, `.md` | the same — ADR-0003 reads the Recording as unknown and re-does it |
| 3 | Sidecar, `.sidecar` | **last**; ADR-0003's "this Recording is genuinely complete" |

Everything before the Sidecar is re-doable by construction, which is what makes a partial set safe.
A Sidecar written before the artifacts it vouches for would report a Recording complete whose
Transcript never landed, and the next run would skip it for ever — ADR-0003's own failure mode
arriving from the write side.

`publish` takes the whole `Names` record and an `Artifact`, so the path and **which artifact that
path is** arrive together. It used to take a path and, separately, the word for what that path was,
with nothing but care keeping the two in step; a refusal now names the artifact it is really about
because it cannot name any other. `Names` is `distinct [Artifact]string` for that reason rather than
a struct of three fields — a fourth artifact makes `names_of`'s literal a compile error until it says
what the new one is called.

**One Sidecar-specific consequence of the enumerated-array measurement CLAUDE.md now records.** The
`[Key]string` table naming the Sidecar's ten fields was believed to grow a row made of an empty
string when a member was added and the table left alone, and `key_named` carried an assertion per
candidate to catch it — **around a hundred run-time assertions per Sidecar read**, none of which
could ever fire. They are gone. What remains is the two in `write_text` and `write_number`, and they
are about the only hazard that is actually left: a row written empty **on purpose**, which does
compile. This table has no such member and wants none.

## The accepted costs

**A hand-edited artifact is overwritten without warning.** `MOVEFILE_REPLACE_EXISTING` does not ask,
and ADR-0002's "transcibr owns every artifact" is what it implements. The alternative — refusing an
occupied name — turns every re-run and every second quarantine into a permanent failure, which is a
strictly worse trade for a file the program has always claimed to own.

**A Recording the filesystem dates before 1970 is refused after the whole GPU pass has been spent,
and refused again on every re-run.** `complete` runs on Engine output, so by the time `recordable`
answers, the extraction and the transcription are already paid for. Nothing here fixes the file:
clamping the moment to zero is the tempting repair and it would write a moment that is not the
file's, which is wrong provenance rather than absent provenance — and worse, it would leave the mtime
term of `changed` dead for that Recording for ever, which is exactly the silent-skip failure ADR-0003
exists to prevent. The user changes the file's timestamp, or the Recording is not transcribed.

**Publication is atomic per artifact and is not atomic across the set of three.** There is no
transaction; the ordering above is what makes an interrupted set safe, not the rename. A crash
between the Transcript and the Sidecar leaves a Recording that reads as unfinished and is re-done,
which is correct — but two transcibr processes racing over one Recording can still interleave their
three publishes, since the pid separates their *temporary* names and not their destinations.

**The pid does not separate two workers inside one transcibr.** What keeps those apart is the
artifact stem, and that rests on no two workers in a Batch ever taking the same Recording — the
Batch's guarantee under ADR-0008, which nothing in `src/artifact` enforces. ADR-0023 states the same
residual for the scratch cache; it is stated again here because the temporary name is spelled with
the process id and it would be easy to read that as the whole answer.

**The retained Engine output is a copy and not a move.** `complete` reads the Engine's JSON out of
the scratch cache and `publish` writes those bytes beside the Recording, rather than renaming the
file across from the cache. It costs a write and not a read — the bytes have to be read to be
validated and rendered anyway — and it is what buys the cross-volume answer above. Renaming from the
cache instead would put the temporary name on the cache's volume and hand the whole design to
whichever drive the user pointed the cache at.

## What would reopen this

An artifact that does not live beside its Recording. A setting that puts Transcripts in an output
directory would make `part_of` the thing to re-derive rather than to adjust, because the appended
suffix is the only reason the volume question never arises; the temporary name would have to be built
in the *destination's* directory explicitly, and the copy that today happens before naming would move
to somewhere it can be interrupted.

A `core:os` that starts passing `MOVEFILE_COPY_ALLOWED`, or a `_rename` written against a different
API. The loud cross-volume failure is a guard this program relies on without asking for it, and it
would become a silent copy-and-delete.

A Sidecar field that is legitimately signed. `recordable` is a range check over the whole record
because every number in it today is a count or a moment; one quantity that may honestly be negative
makes a whole-record check the wrong shape, and the field-by-field alternative brings back exactly
the "somebody remembers to come here" failure this replaced.

A measurement showing a within-volume `MoveFileExW` that is not atomic — a network redirector, or a
filesystem filter — reopens the atomicity claim itself rather than any of the arrangements built on
it.
