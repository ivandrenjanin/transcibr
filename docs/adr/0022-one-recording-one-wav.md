# One Recording becomes one WAV, and the container's own duration is what proves it

transcibr extracts audio with one fixed ffmpeg argument list, times the Recording with one fixed
ffprobe argument list, and then refuses the extraction unless the produced WAV's own length agrees
with the container's claim to within `max(1000 ms, one thousandth of the container)`. Every option in
both lists defends against a specific measured default, and **strip the reasoning and the output half
of the extraction is thirteen strings nobody can safely edit.** This ADR is that reasoning, and the
evidence behind the tolerance.

What the check exists to catch is a source still being written, a truncated container, or one that
fails to decode part way. All three yield audio *shorter* than the Recording, and all three otherwise
produce a Transcript that stops mid-sentence and is marked complete forever. The container's own
duration is the only independent claim about how long the Recording is, so it is what the produced
audio is measured against.

ADR-0018 records where this code lives and why the argument lists sit in `src/process` rather than
beside the extraction; ADR-0009 records why probing in the shell is allowed at all. Neither says what
the arguments are for.

## Every argument defends against a named default

| argument | what it defends against |
|---|---|
| `-vn -sn -dn` | a container's **cover art is a video stream**; without these ffmpeg tries to put it in a WAV |
| `-map 0:a:0` | a Recording with a commentary track has two audio streams, and ffmpeg's default choice between them is **by bitrate** — a silent high-bitrate track wins. This takes the first audio stream and only it |
| `-f wav` | stated rather than inferred: the destination is a `.part` file, and no muxer maps to that extension |
| `-y` | a previous interrupted run's `.part` would otherwise make ffmpeg prompt for permission to overwrite, on a standard input that is the null device (ADR-0004) |
| `-nostdin` | belt over the same braces: ffmpeg reads standard input for interactive keys, and an ffmpeg that decided to prompt wedges a worker (issue #27) |
| `-hide_banner` | ffmpeg opens every run with its build configuration — a dozen lines naming every library it was compiled against, on a stream this program has to drain |
| `-loglevel error` | the default is `info`, which narrates each stream it finds. What is left is the diagnostics of a run that actually failed, which is what a report can carry |
| `-ac 1 -ar 16000 -c:a pcm_s16le` | the audio the Engine reads, and nothing else |

The three numbers are held against their own spellings by the compiler — `#assert(AUDIO_SAMPLE_RATE
== 16000)`, `#assert(AUDIO_CHANNELS == 1)`, `#assert(AUDIO_BITS_PER_SAMPLE == 16)` — because the
command line is the write side of a claim `src/audio` checks on the read side (CLAUDE.md rule A4).
The depth's spelling is a **codec name and not a number**, so no `#assert` can hold `pcm_s16le`
against sixteen; what holds it is a case comparing the spelling, and the bit-depth check on the
produced WAV that was missing until a file declaring one channel at 16 kHz and **eight** bits a
sample was accepted as the audio the Engine reads.

Order is load-bearing in both lists. ffmpeg's option parser binds every option to the file that
follows it, so `-i` goes **last** in the probe's list — an input named before its options is an input
with none of them. The extraction's list is built by copying the thirteen output arguments in at an
offset and writing the destination past them by hand, so it carries a postcondition that every slot
is non-empty: an off-by-one there builds, spells, and makes ffmpeg refuse a Recording for a reason
that appears nowhere.

## ffprobe's own CLI has two silent failure modes, and the probe is shaped round them

`PROBE_ENTRIES` is `"format=duration:stream=codec_type"` — **one** `-show_entries` occurrence,
because a second occurrence *replaces* the first rather than adding to it. Written the natural way,
`-show_entries format=duration -show_entries stream=codec_type` asks only for the codec types and the
duration silently disappears.

`stream=duration` is deliberately **absent**, and the absence is load-bearing: a stream duration
prints under the same `duration=` key as the format duration, so asking for both produces two
indistinguishable lines and the reader cannot say which container it is holding.

The output format is `-of default=noprint_wrappers=1` rather than `-of json`, because nothing in the
answer needs a JSON parser between transcibr and a duration — and CLAUDE.md already records what
`core:encoding/json` costs anyone who reaches for one.

The fixtures pinning this shape are real probe output, captured from **ffprobe N-125907** against a
0.2-second clip and committed byte for byte. An ffprobe upgrade that stops printing `codec_type=` or
renames `duration=` fails there, rather than showing up as Recordings that mysteriously report no
audio stream.

## The fault set is built round two observed outcomes, not around a taxonomy

**Measured.** Pointed at a file that is not media, ffprobe exits 1, writes its diagnostic to standard
error, and leaves a **zero-byte** answer file. That is `.Said_Nothing`, and it means the whole file is
unreadable — not "no audio streams and no duration". A reader that took an empty answer as the latter
would report the wrong fault for every unreadable Recording there is.

**Measured.** Pointed at a raw MPEG-4 video elementary stream, ffprobe prints the codec type and
`duration=N/A`: a well-formed answer about a container it cannot time. That is `.Duration_Unknown`,
and it is a live observation rather than a hypothetical. `.Duration_Unreadable` — a `duration=`
carrying something that is not a number at all — is kept apart from it deliberately: that one means an
ffprobe this package has stopped understanding, where `.Duration_Unknown` means a Recording that needs
remuxing.

**Zero audio streams is not a fault here.** It is a fact about the Recording, and the refusal that
names the file belongs to the caller that knows the file's name (ADR-0002).

## Rounding, and the guard on the rounded value

ffprobe prints six decimals, and 0.2 seconds arrives as a binary fraction a hair under 200
milliseconds, so truncating rather than rounding loses a millisecond on an exact clip.

The positivity guard is then applied to the **rounded** value and not to the float, and that is a
measured requirement rather than a preference: a WAV holding **three samples at 8 kHz** makes ffprobe
print `duration=0.000375` — a positive number of seconds and a zero number of milliseconds. A guard on
the float hands that back as a zero duration with no fault on it, `read_probe`'s own postcondition
then fires on bytes ffprobe wrote, and a Batch dies on one degenerate container instead of failing
that Recording and carrying on (rule A8, ADR-0002).

The suite pins the boundary from both sides:

| `duration=` | milliseconds | verdict |
|---|---|---|
| `0.000021` | 0 | refused, `.Duration_Not_Positive` |
| `0.000375` | 0 | refused — the measured three-sample WAV |
| `0.000499` | 0 | refused |
| `0.000500` | 1 | **accepted, and the shortest container there is** |

`milliseconds_of` is shared by the two sources a duration may come from — ffprobe's `duration=` and
the Engine's startup banner — because a rounding or a ceiling holding in one and not the other would
make the two disagree about the same Recording by an amount nobody could account for. Its upper bound,
`LONGEST_CONTAINER_MS`, is a thousand hours: not a policy on Recording length but the guard that stops
a nonsense duration reaching the arithmetic downstream, and more than thirteen times the 75-hour whole
Batch of the reference corpus.

## The tolerance: five containers of the same 300-second sine

Measured on this machine, with the ffmpeg build this repository bundles (ADR-0013) and the argument
list above:

| container | probe said | extracted audio | difference |
|---|---|---|---|
| AAC in MP4 | 300.000000 | 300000 ms | 0 ms |
| MP3 with its Xing header | 300.000000 | 300000 ms | 0 ms |
| PCM in WAV | 300.000000 | 300000 ms | 0 ms |
| AC3 in Matroska | 300.006000 | 300000 ms | **6 ms** |
| the same MP3, cut in half | 300.000000 | 149918 ms | **150082 ms** |

The last row is the failure the whole check exists for. **The gap between the 6 ms row and the
150,082 ms row is the window any tolerance has to fit inside**, and it is a factor of 25,000 wide.

## Why one second, and why a thousandth

`DEFAULT_TOLERANCE` is `floor_ms = 1000, per_mille = 1`.

**The floor is sized against a reasoned budget, and only one term of that budget is measured.** AAC
encoder priming and padding is at most 2,112 samples, and so 48 ms at 44.1 kHz; one video frame of
container rounding is 42 ms at 23.976 fps; a non-zero audio start time and the whole-sample rounding
of a WAV add smaller amounts. Those figures are arithmetic over documented quantisation effects, not
observations taken here. The single measured figure is the **6 ms** of AC3 in Matroska. So one second
is twenty times the largest *reasoned-about* case and more than 160 times the largest *measured* one,
and the headroom between 6 ms and 1,000 ms is margin nobody has observed a container consume.

**The relative term keeps that margin proportional on a long Recording.** On the reference corpus's
longest, 168 minutes, a thousandth allows 10,080 ms. Thousandths rather than a percentage because
integer arithmetic is what makes the bound pinnable from both sides to the millisecond; a float
threshold is one nobody can hold, and every case in the suite pins its bound one millisecond either
side.

**One claim carried in the source comment is wrong, and is corrected rather than copied here.** The
relative term was described as "three orders of magnitude tighter than the smallest real truncation
measured". It is not, and the two numbers being compared belong to different Recordings: 10,080 ms is
the allowance on a 168-minute Recording, while 150,082 ms was measured on a 300-second one. At the
file where the truncation was actually measured the *floor* governs, so the honest ratio is 150,082 ms
against 1,000 ms — a factor of **150**, two orders of magnitude, and still ample.

**The check is two-sided.** Audio *longer* than the container claims disagrees too — 300,000 against
450,000 is refused — because a check written as `container - audio > allowed` passes every row of the
table above and waves through a probe that read a different file from the one ffmpeg extracted.

The tolerance travels as an argument with a default rather than as a constant read inside, which is
the discipline ADR-0007 applies to the merge profiles and ADR-0018 notes for this package. The bound
on it, `MAX_PER_MILLE = 1000`, is a **policy** bound and not overflow protection: the multiplication
it guards overflows an i64 somewhere past a per-mille of 2.5e9 against a thousand-hour container, six
orders of magnitude above it. A thousand per-mille is the whole of the container's duration, so a
tolerance at that bound already agrees with any audio at all.

## The accepted cost: two measured false failures

Where a container carries no duration and ffprobe estimates one from the average bitrate, the estimate
is nowhere near the truth:

| container | probe said | extracted audio |
|---|---|---|
| MP3 written with `-write_xing 0` | 287,765 ms | 300,042 ms |
| raw ADTS AAC stream | 587,005 ms | 300,025 ms |

**Both files are complete, and both fail this check.** The trade is stated rather than routed around:
a container that cannot say how long it is cannot be used to tell a complete extraction from a
truncated one, so the Recording is reported against by name and the Batch carries on (ADR-0002),
rather than the tolerance being loosened to admit them. What the user gets is a line naming the file
and both durations, which is actionable; what the alternative gives is four hours of half a Recording
marked complete.

This is the exact thing a future maintainer will otherwise "fix" by widening the tolerance, which is
why the two input recipes are written down — `-write_xing 0` and a raw ADTS stream reproduce both rows
in a minute.

**The second cost is quieter and is not measured at all.** A truncation *smaller* than the tolerance
passes: under a second on any Recording, and under a thousandth on one long enough for the relative
term to govern — 10 seconds lost from a 168-minute Recording is inside the bound. Nothing in the
corpus has produced such a truncation, and nothing here would notice one.

## RIFF chunk lengths are checked, never trusted

ffmpeg writes **placeholder lengths** and seeks back to patch them when it closes the file, so a
killed ffmpeg leaves `0xFFFFFFFF` in both the RIFF length and the `data` length while every byte
before them is perfectly well formed. That is `Riff_Fault.Truncated`, it is the truncation detector,
and it is the shape a Stop press or a full disk actually leaves on disk — which is why the case that
pins it writes 0xFF bytes into the length field of the real fixture rather than into an invented one.

`Head_Too_Short` is reported apart from `Truncated` so that a buffer too small is never mistaken for a
malformed file: **the two are fixed in different places**, one by reading more of the file and one by
failing the Recording. Only the head is read — 64 KiB against a chunk table ffmpeg writes in the first
hundred bytes — so the distinction is reachable in ordinary operation rather than theoretical.

`Empty_Data_Chunk` is ADR-0002's own case one layer down: exit code zero means nothing, and a run that
produced a well-formed file holding no audio is a failure that reports success everywhere else.

Why the lengths are walked at all rather than read from a 44-byte header is CLAUDE.md's rule A5, which
uses this file as its worked example; it is not restated here.

## What would reopen this

A container that is well formed, carries a real duration, and still disagrees by more than a second —
that is a quantisation effect nobody budgeted for, and the floor is then a number to re-derive rather
than to nudge. A measured truncation smaller than the tolerance reopens it from the other side.

Neither of the two false failures above reopens it. They are the known price, they are reproducible
from the recipes named, and a maintainer widening the tolerance to admit them is trading a Recording
that fails loudly for one that fails silently.
