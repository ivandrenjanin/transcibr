# Discovery and planning are one package, and four decisions inside it that are not obvious

`src/planning/` is the spec's **core** module *Planning* and its **shell** module *discovery*, in one
Odin package. ADR-0017 names `src/planning/` for the first of those outright, so putting the second
in beside it narrows that decision rather than applying it, and it is recorded here for the same
reason ADR-0018 recorded the pairing of probing and extraction.

Also here: how a Markdown file is known to be transcibr's, why `core:os`'s `File_Type` cannot decide
what a reparse point is, why the container duration is copied rather than probed, and what
cancellation costs when there is no window yet.

## Why discovery is not a package of its own

**This argued itself out of ADR-0018 and that was the wrong argument.** ADR-0018 merged two *shell*
modules the spec lists with a comma between them, neither of which has a named seam of its own. None
of that is true here. The spec makes *Planning* a **core** module that "takes a finished inventory",
and seam S2 is "**Inventory and settings in**, plan with reasons out" — so discovery is outside that
seam by the seam's own wording, and the seam this ADR claimed would be split by a package boundary
is one it invented for the occasion. The "third package that turns out to hold half of one of them"
does not apply either: `Found` living in `src/planning` and being filled by `src/discovery` is the
ordinary shell-imports-core direction ADR-0009 prescribes, not a third package. The outcome stands;
the argument it stood on did not, and here is the one it actually stands on.

**A package for one procedure costs more than it separates.** Discovery is `walk.odin`: one exported
procedure, one destroy, and the record it fills. It has exactly one consumer, produces exactly one
value, and — unlike the probe in ADR-0018 — carries no decision a caller can vary. A directory, an
import in every consumer, a row in `test.ps1`'s per-package accounting and a `$OdinPackagesWithoutTests`
question, for a file.

**The cases that prove the criteria span both halves and cannot be split with them.** Criterion two
is not `decide` in isolation: `access_test.odin` builds a real directory nothing may be written to,
walks it, and asks `decide` what that Recording gets. The reparse-point cases do the same. Under a
split those cases live in `src/discovery` — legally, importing `transcibr:planning` — and the sweep
reports the criteria of the *Planning* module under the name of a package that is not it.

**What the merge costs, and it is not nothing.** ADR-0018's own remedy for a package whose name
describes half its contents is *name it for the pair*, and that is not applied here: `planning` is
the core module's name, and it does not cover walking a tree. It is not applied because there is no
pair to name — `CONTEXT.md` has no heading over discovery and planning the way *Turning a recording
into audio* stands over Probe and Scratch cache, and inventing one to justify a directory layout is
vocabulary driven by a build system. So the defect ADR-0017 names is accepted, knowingly, and the
thing that reopens it is `CONTEXT.md` growing a heading that does cover both.

What keeps the halves apart is the file split, exactly as in `src/audio`: `plan.odin`, `batch.odin`
and `report.odin` are pure and carry the suite; `walk.odin` touches the disk. A decision that turns
up in `walk.odin` belongs in one of the three beside it — and nothing enforces that here either.

## A Transcript is transcibr's because of its own bytes, and the Sidecar never says so

ADR-0008 asks that an existing `.md` "parse as transcibr's own output — front matter present and
carrying the generator key" before it counts as a Transcript. This is that, and the reason it is not
the Sidecar is that **a Transcript can outlive its Sidecar**. A user who deletes `talk.sidecar` still
has a Transcript transcibr wrote; a user with a hand-authored `notes.md` does not, whatever else is
in the directory.

So two questions, two sources, and neither can answer the other's:

| question | answered by | when it is wrong |
|---|---|---|
| is this Markdown file transcibr's? | the file's own first bytes | never — the bytes are the claim |
| is what it records still current? | the Sidecar beside it | missing or unparseable means unknown, and ADR-0003 says re-do it |

`written_by_transcibr` matches a **prefix** and never searches: a hand-authored note that quotes a
Transcript somewhere in its body carries the same bytes, and only a file that OPENS with them was
written by this program. The marker stops at the space `version.banner` writes before the number, so
a Transcript an OLDER transcibr wrote is still transcibr's.

**The predicate belongs to the package that WRITES the bytes**, and `src/planning` asks it rather
than answering. It was spelled out here first, which re-typed five facts owned next door — the fence,
the field key, the generator name, the space, and the order the fields are written in — three of them
because `FENCE` and `GENERATOR` are private in `transcibr:transcript`. `TRANSCRIPT_PREFIX` is now
built from those constants beside the writer that uses them, so the coupling is structural.

What is left rotting is the field ORDER, which no constant can capture: a renderer that put `source`
first would still compile against the same three constants and recognise nothing. That is what
`what_the_renderer_actually_writes_is_what_this_package_recognises` holds — it renders a real
Transcript through `render_markdown` and asks the predicate about it, and it lives beside the
renderer it is about. Red there rather than every Transcript on disk becoming a stranger, which would
silently refuse every Recording in a corpus.

`src/planning` keeps only `TRANSCRIPT_HEAD_BYTES`, which is its own policy — how much of a megabyte
file to read to answer a question about its first line — with a `#assert` across the two packages
that the head is long enough to carry the answer.

## `core:os` cannot answer "is this a reparse point", and the type is the wrong question

Measured against the pinned compiler, in `core/os/stat_windows.odin`:

```odin
is_sym = ReparseTag == win32.IO_REPARSE_TAG_SYMLINK || ReparseTag == win32.IO_REPARSE_TAG_MOUNT_POINT
if is_sym {
    type = .Symlink
} else if file_attributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0 {
    type = .Directory
```

A directory carrying **any other** reparse tag — a cloud-files placeholder, a WCI or DFS link — is
not `.Symlink` and is not `.Undetermined`. It is a plain **`.Directory`**. A walk that refused
`.Symlink` and descended into `.Directory` would follow every one of them, which is the narrowing
ADR-0023 already recorded for the sweep, arriving a second time with the polarity reversed. (An
AppExecLink is *not* an example of this: ADR-0023 measured 39 of them and they are non-directory
reparse points, "neither symlink nor junction nor directory". This ADR listed them under directories
and was wrong about it.)

`File_Type` is equally unable to answer the question in the other direction: a junction reads
`.Symlink` whether it stands for a directory or a file. So the walk asks `GetFileAttributesW` for
`FILE_ATTRIBUTE_DIRECTORY` and `FILE_ATTRIBUTE_REPARSE_POINT` together, in one call, and does not
depend on `File_Type` for either. What `File_Type` *is* trusted for is ruling the question **out**: a
directory is never `.Regular` or `.Undetermined`, because `_file_type_mode_from_file_attributes`
tests `FILE_ATTRIBUTE_DIRECTORY` before it ever opens a handle — so the files that make up most of a
tree cost no Win32 call at all.

**The rule is about TRAVERSAL and about nothing else.** This once said "one rule, applied to
directories and to files alike", and that sentence produced two bugs.

A reparse point is a directory this walk does not go **through**: it is reported, not descended into,
and `follow_reparse_points` is the whole of what turns it on. A **file** has nothing to go through.
Refusing one on the strength of its tag dropped it from the inventory — and because
`Reparse_Point_Not_Followed` is the one note that leaves the inventory whole, the run reported
success over a plan missing a Recording. Every OneDrive Files-On-Demand dehydrated file carries
`FILE_ATTRIBUTE_REPARSE_POINT`, so a corpus in OneDrive planned as **empty** with exit zero: ADR-0009's
silently short file list, reached through this program's own opt-out. `a_candidate` therefore never
asks about the tag, and its table walks every `File_Type` a listing can produce.

The other bug ran the opposite way. `follow_reparse_points = yes` skipped the attribute check
entirely, so a junction — `.Symlink`, not `.Directory` — fell past the descend branch and out of the
walk with **no note at all**. Turning the flag on was strictly less safe than leaving it off, because
the default at least reports the skip. The check now always runs and only the *disposition* varies.

`.Undetermined` goes the other way here than it does in the sweep, and for ADR-0023's own reason. A
non-directory whose handle will not open reads `.Undetermined` — which is what an ordinary file
another process holds open looks like from outside, and a Recording still being written by a camera
is exactly that file. Its size and modification time come from the directory entry and are as good as
a `.Regular` entry's, so it is still a candidate Recording.

**What no case here reaches** is the exotic tag itself. A junction is `IO_REPARSE_TAG_MOUNT_POINT`,
which `core:os` does classify; creating a cloud-files placeholder from a test is not possible, and a
FILE symbolic link needs Developer Mode or elevation, so `a_recording_that_is_itself_a_reparse_point_-`
`is_planned_and_never_skipped` stops rather than fails where machine policy refuses one. What holds
the rule on every machine is the pure table over `a_candidate`, which needs no privilege at all —
because the code is written so the tag cannot matter to a file, and that is the whole of the defence.

**A junction as a ROOT proves nothing about a junction in a tree.** `a_walk_told_to_follow_reparse_-`
`points_walks_through_one` passes the link as a root, where `enumerable` asks `os.is_dir`, which
resolves it, and `took` never runs. That case read as proof of the criterion and exercised a
different path from the one users hit; the one beside it now walks a junction found inside a
sub-directory.

## The container's duration is copied out of the record, never probed to plan

`artifact.changed` compares ten fields and `container_ms` is one of them, but a probe costs an
ffprobe per Recording and ADR-0009 puts probing at **job start**. Planning supplies the recorded
duration as the current one, on the ground that a Recording whose size and modification time are both
unchanged is the same file and cannot have changed length.

That is a real claim and it is asserted rather than trusted: `changed` can then never answer
`.Container_Duration` at plan time, and `resumed` says so. If it ever fires, the copy above it is
wrong.

The cost is that this reuses `artifact.changed` **whole** rather than writing a second comparison
that skips a field — which is what the alternative would have been, and which would have been a
second answer to "are these settings the same" living one package away from the first.

## Cancellation and progress, with no window to drive them

Issue #16 has not landed and nothing in this repository starts a thread. The seam is therefore the
smallest thing that #16 can drive and that a case can exercise today: a `^bool` the caller owns, read
with `sync.atomic_load` on the walking thread, and an `on_progress` callback shaped exactly like
`engine.Report`'s.

Nothing in `discover` starts a thread, and that is deliberate — **what runs the walk is the caller's
to decide**, and a package that started its own would have to be unpicked when the window arrives.

The cases drive cancellation **from the progress callback**, which is the same seam from the other
end and needs no thread at all: the callback sets the flag, the next check sees it, and the walk
answers with what it had got to. A cancelled walk is not an empty one — the Recordings it found and
the notes it left are still true — but it is not the whole tree either, which is what
`left_unlooked_at` exists to say.

## What a note means, and why a partial walk is a failure

ADR-0009: "A silently short file list is the one discovery failure a user cannot detect." Four things
can leave the inventory short of the tree, and only one of them is what the caller asked for:

| note | inventory whole? |
|---|---|
| `Reparse_Point_Not_Followed` | yes — this is a DIRECTORY the caller chose not to enter |
| `Root_Unreadable` | no |
| `Directory_Unreadable` | no |
| `Too_Deep` | no |

`left_unlooked_at` is that table as a procedure, in the pure half, so the CLI asks rather than
decides. The dry run exits non-zero for any of the three, and it was written because the binary
**did not**: a root that could not be walked printed one report line and exited zero, which is the
failure above with a message attached to it.

The first row is why a reparse-point **file** must never leave a note (above): the exemption is
correct for a directory nobody entered and wrong for a Recording, and the two were one code path.

**It answers `Maybe(Walk_Note)` and not a bare `Note`.** A walk that was *cancelled* leaves no note
behind — there is nothing to name — and an enumeration with no absent value answered its own zero
member, so a stopped walk reported `Root_Unreadable` against a root it had been reading perfectly
well. Latent only while nothing sets the flag, and reachable the moment issue #16 drives the seam
this package exists to provide.

**`plan_batch` takes the whole `Inventory` and not its `found` alone**, and refuses the plan itself
when the walk did not finish. Handed the slice, it *structurally* could not see `cancelled` or the
notes, so the one rule stopping a Batch running over a short file list lived entirely in caller
discipline — and the only caller that asks is `src/cli`, the package nothing can turn red.

The sentence a caller prints is `incomplete_line`, in `report.odin` with the others and for the
reason that file gives. The CLI printed the note with `%v`, so a cancelled walk read
"this walk did not see the whole tree (Root_Unreadable)" — an enumeration member, in front of a user,
naming a fault that had not happened.

## The accepted costs

**The walk writes a file into every directory that holds a Recording.** Writability cannot be
answered on Windows without trying, so `directory_writable` creates a pid-qualified probe, closes it
and removes it. Once per DIRECTORY and never per Recording — and only where the listing in hand holds
a Recording at all, which in an archive is a minority of the directories walked. The scan that
answers that is the same pure extension test `took` will apply, so the probe is paid for exactly
where the answer is read.

**The answer is consulted against the DECISION and not ahead of it.** Checked first, a Recording with
a matching Transcript and matching recorded settings in a read-only directory came back
`Refuse (Directory_Not_Writable)` — so a read-only archive of finished work reported every Recording
in it as refused. Criteria two and eight are in tension and this is the resolution: nothing is
written for a Skip, so nothing needs to be writable for one. Criterion eight is about not spending
GPU time producing output that cannot be published, and a Skip spends none.

**Injectivity is folded ASCII-and-Unicode-lowercase, not the filesystem's own comparison.** NTFS
compares case-insensitively against an internal uppercase table that moves with the Windows version;
`strings.to_lower` is not that table. Two paths differing only by a case fold this misses would be
planned as two artifacts and be one file. The realistic case — `INTERVIEW.mp4` beside
`interview.m4a` — is caught, and non-ASCII stems are refused a stage later by ADR-0025 anyway.

**Every path in the report is `%q`, so a backslash is doubled in the one output a user reads most.**
That is ugly and it is the repository's rule for a reason: the line reaches a user through a UTF-16
Win32 call, where a raw NUL cuts it off and a byte that is not UTF-8 converts the whole of it to nil.
A second path-rendering rule for the dry run would be a second answer to a question that already has
one.

**The Model is hashed to plan.** `identify_model` reads upwards of a gigabyte before a dry run prints
its first line, because ADR-0003's comparison is on the digest and not the path. It is once per
Batch, not once per Recording, and it is the price of noticing a Model file replaced under the same
name.

**`MAX_WALK_DEPTH` is 64 and is a judgement.** Nothing was measured. The walk keeps its own frontier
rather than recursing, so this is not standing between a tree and a stack overflow the way
`MAX_JSON_DEPTH` is. By default it bounds a pathological tree and nothing else — a cycle would need a
directory hard link NTFS does not permit plus a reparse point this walk does not follow. With
`follow_reparse_points` turned **on** it is the only thing bounding a cycle at all: a junction may
point back up its own tree, and the walk will go round it until the depth runs out. That is the cost
of the flag and it is why the ceiling is not a candidate for removal.

## What reopens this

A Recording arriving in a container not in `RECORDING_SUFFIXES` is the list being wrong, not the rule
— the alternative, probing every file in the tree, is an ffprobe per README and was never on.

**`.ts` was in that list and is not any more, and that is the rule bending once.** It is MPEG
transport stream and it is also TypeScript, and an extension is all this test has: a dry run pointed
at a source checkout planned a Transcript for every file in it. `.m2ts` and `.mts` are the same
container under names nothing else uses, so a transport stream is still found under either. A user
whose Recordings really are `.ts` is the case this costs, and it reopens the list.

A second consumer of the inventory reopens whether `Found` should carry `audio.Reading` outright: it
holds the size and modification time already, and only `taken_ns` is missing, which is the reading
ADR-0023's settling wants. It is left out today because it would make a core package depend on a
shell one for a field nothing in this ticket reads.

The window landing (#16) is what proves the cancellation seam. If it needs more than a flag and a
callback, this is the decision that was too small.

## Addendum (2026-08-06, #152)

The refused-alternative cost this record's "A package for one procedure costs more than it
separates" section names — "a row in `test.ps1`'s per-package accounting and a
`$OdinPackagesWithoutTests` question" — is now a justfile `test:` recipe line plus a
`TEST_LESS_SRC_PACKAGES` question in `tools\policy\packages.odin`. The cost is the same shape,
paid in the current mechanism; the decision to keep discovery and planning in one package is
unaffected.
