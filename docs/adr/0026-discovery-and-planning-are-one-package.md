# Discovery and planning are one package, and four decisions inside it that are not obvious

`src/planning/` is the spec's **core** module *Planning* and its **shell** module *discovery*, in one
Odin package. ADR-0017 names `src/planning/` for the first of those outright, so putting the second
in beside it narrows that decision rather than applying it, and it is recorded here for the same
reason ADR-0018 recorded the pairing of probing and extraction.

Also here: how a Markdown file is known to be transcibr's, why `core:os`'s `File_Type` cannot decide
what a reparse point is, why the container duration is copied rather than probed, and what
cancellation costs when there is no window yet.

## Why discovery is not a package of its own

Discovery exists **for** planning and for nothing else, exactly as the probe exists for the
extraction. It produces one value — a finished inventory — that one procedure consumes, and it
carries the refusals that stop a Recording being planned at all: a directory that cannot be listed,
a Markdown file transcibr did not write, an output directory nothing can be written into.

Split into `src/discovery/` and `src/planning/`, the `Found` record would have to live in one and be
built by the other, which is the "third package that turns out to hold half of one of them"
ADR-0017 names. Odin also collects tests per package, so the one seam over "point transcibr at a
folder and see what it will do" would become two sweeps that pass and fail independently.

`src/audio` is the precedent and this is the same shape: the file split is what keeps the halves
apart. `plan.odin`, `batch.odin`, `report.odin` and `transcript.odin` are pure and carry the suite;
`walk.odin` touches the disk. A decision that turns up in `walk.odin` belongs in one of the four
beside it — that is ADR-0018's rule, and nothing enforces it here either.

The difference from `src/audio` is which way round the naming went. There, two shell modules were
named for the pair. Here a **core** module's name hosts a shell one, because `Planning` is the name
ADR-0017 already fixed and `discovery` is the thing that feeds it.

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

The marker is a claim about what `transcibr:transcript` writes, and that is the part that could rot.
What holds it is `what_the_renderer_actually_writes_is_what_this_package_recognises`, which renders a
real Transcript through `transcript.render_markdown` and asks the predicate about it. A renderer that
moved the generator field turns that case red rather than turning every Transcript on disk into a
stranger — which would silently refuse every Recording in a corpus.

## `core:os` cannot answer "is this a reparse point", and the type is the wrong question

Measured against the pinned compiler, in `core/os/stat_windows.odin`:

```odin
is_sym = ReparseTag == win32.IO_REPARSE_TAG_SYMLINK || ReparseTag == win32.IO_REPARSE_TAG_MOUNT_POINT
if is_sym {
    type = .Symlink
} else if file_attributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0 {
    type = .Directory
```

A directory carrying **any other** reparse tag — a cloud-files placeholder, an AppExecLink, a WCI or
DFS link — is not `.Symlink` and is not `.Undetermined`. It is a plain **`.Directory`**. A walk that
refused `.Symlink` and descended into `.Directory` would follow every one of them, which is the
narrowing ADR-0023 already recorded for the sweep, arriving a second time with the polarity reversed.

So the walk asks `GetFileAttributesW` for `FILE_ATTRIBUTE_REPARSE_POINT` directly, and the answer
does not depend on `File_Type` at all. One rule, applied to directories and to files alike: a reparse
point is not followed, it is **reported**, and `follow_reparse_points` is the whole of what turns it
on.

`.Undetermined` goes the other way here than it does in the sweep, and for ADR-0023's own reason. A
non-directory whose handle will not open reads `.Undetermined` — which is what an ordinary file
another process holds open looks like from outside, and a Recording still being written by a camera
is exactly that file. Its size and modification time come from the directory entry and are as good as
a `.Regular` entry's, so it is still a candidate Recording. What it is never allowed to do is be
**descended into**: only `.Directory` is, and only after the attribute says it is not a reparse point.

**What no case here reaches** is the exotic tag itself. A junction is `IO_REPARSE_TAG_MOUNT_POINT`,
which `core:os` does classify, so `a_reparse_point_is_not_followed_by_default_and_is_reported` proves
the criterion and not the measurement above it. Creating a cloud-files placeholder from a test is not
possible; the code is written so the distinction cannot matter, and that is the whole of the defence.

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
| `Reparse_Point_Not_Followed` | yes — this is the default the caller chose |
| `Root_Unreadable` | no |
| `Directory_Unreadable` | no |
| `Too_Deep` | no |

`left_unlooked_at` is that table as a procedure, in the pure half, so the CLI asks rather than
decides. The dry run exits non-zero for any of the three, and it was written because the binary
**did not**: a root that could not be walked printed one report line and exited zero, which is the
failure above with a message attached to it.

## The accepted costs

**The walk writes a file into every directory it looks at.** Writability cannot be answered on
Windows without trying, so `directory_writable` creates a pid-qualified probe, closes it and removes
it. Once per DIRECTORY and never per Recording. A Batch pointed at a read-only tree therefore
attempts one create per directory and fails them all, which is the answer it wanted.

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
`MAX_JSON_DEPTH` is; it bounds a pathological tree, and a cycle would need a directory hard link NTFS
does not permit plus a reparse point this walk does not follow.

## What reopens this

A Recording arriving in a container not in `RECORDING_SUFFIXES` is the list being wrong, not the rule
— the alternative, probing every file in the tree, is an ffprobe per README and was never on.

A second consumer of the inventory reopens whether `Found` should carry `audio.Reading` outright: it
holds the size and modification time already, and only `taken_ns` is missing, which is the reading
ADR-0023's settling wants. It is left out today because it would make a core package depend on a
shell one for a field nothing in this ticket reads.

The window landing (#16) is what proves the cancellation seam. If it needs more than a flag and a
callback, this is the decision that was too small.
