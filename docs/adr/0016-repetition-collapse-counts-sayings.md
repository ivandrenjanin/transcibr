# Repetition collapse counts sayings, not elapsed time

A repetition run is an invention when it holds **14 or more sayings** of one phrase. Three survive;
the rest of the run is dropped. Nothing else is read — not the elapsed time of the run, not the rate
the sayings arrive at, not the per-token `p` ADR-0001 already ruled out.

The first implementation of this filter used a conjunction: more than three sayings **and** spanning
at least 20 seconds of the recording. That rule is wrong in both directions, and this ADR replaces
it.

## The evidence that exists

ADR-0001 measured two inventions on a real 20-minute excerpt: **17 identical cues of one
short phrase**, and **16 identical cues of the single word *"you"*** spanning 4.5 minutes of silence.
ADR-0005 re-measured the same recordings with VAD enabled and both runs collapsed to a longest run
of **1**, which confirms the engine produced them rather than the speaker.

So the measurement gives us, for both runs, a **count**. It gives us a **span** for only one of them
— the 4.5 minutes attaches to the *"you"* run, and nothing was ever recorded about how long the
17-cue run took. The 20-second threshold that shipped first therefore had no evidence behind it for
the first of the two runs it claimed to cover, and the source comment that justified it ("one saying
every seventeen seconds") applied the *"you"* run's rate to both.

## Why elapsed time cannot be the discriminator

It is not a weaker signal than the count. It points the wrong way at each end.

**At the fast end it lets the engine through, however long the loop runs.** Once a run passes the
count gate, a span threshold is the only thing left deciding, so a loop that repeats quickly never
clears it no matter how many sayings it holds:

| run | sayings | span | verdict under a 20 s threshold |
|---|---|---|---|
| `" Thank you for watching!"` at 1 s apiece | 19 | 19.0 s | kept — 19 paragraphs of it |
| `" Please subscribe."` at 400 ms apiece | 40 | 16.0 s | kept |
| `" you"` at 150 ms apiece | 100 | 15.0 s | kept |

Nineteen seconds is less recording than four cues of ordinary continuous speech cover — ADR-0007
puts cue duration p50 at 3840 ms for continuous material and 1220 ms for interactive, straddling any
threshold placed in this band.

**At the slow end it deletes real speech.** Ordinary human repetition is not always fast. A guided
meditation, a language drill, a call-hold announcement and a parent calling a child all repeat one
phrase slowly and deliberately, and a 20-second threshold condemns every one of them. The sharpest
case is the source comment's own worked example: `" Breathe."` said five times across 28.5 seconds
was deleted down to three by the rule the comment was defending.

The decisive row is the hold announcement. It repeats **every 30 seconds** — *slower* than the
engine's measured invention of `" you"`, which arrived every 16.9 seconds. No threshold on elapsed
time, and no threshold on rate, can put those two on opposite sides of a line, because on the axis
they measure the real speech is further out than the invention.

The count separates them cleanly and with margin: 16 and 17 for the measured inventions, and eleven
for the longest real repetition collected.

## Why 14

The evidence supports a **band**, not a number: above eleven, the longest real repetition in the
collected material, and at or below sixteen, the shorter of the two measured inventions. Fourteen is
the middle of that band, which is the value furthest from both ways of being wrong. `src/transcript`
pins the band rather than the value — a ceiling of 11 fails, 12 and 16 pass, 17 fails — because
pinning a single value inside a band would be pinning taste and calling it truth.

The count that *survives* a collapse stays at three. A run is dropped where it is invented, and a
transcript reading "you. you. you." tells a reader the engine ran on over silence where a single
"you." reads as something the speaker said. Three is not a second discriminator and must never be
used as one: the ceiling sits above it, and a ceiling at `max_run + 1` is a cap on length alone,
which deletes ten of the eleven real repetitions collected.

## The accepted false positive

**A run of more than thirteen genuine sayings of one phrase is truncated to three, and the rest of
that run — including its tail, and therefore the recording time it covered — does not reach the
reader.** A protest chant, a 40-repetition guided meditation, a drill: these are real speech, and
this filter deletes them.

This is stated plainly because the previous version of it was not. The source comment claimed "the
false positive this can still make is cheap"; it was not cheap, and under the old thresholds the
class it applied to was very much larger — a 40-cue meditation spanning 591 seconds came back as
three cues ending at 45 seconds, nine and a quarter minutes of real speech gone. The count ceiling
does not eliminate the class, it narrows it to material that repeats one phrase verbatim more than
thirteen times over, and every pattern in the collected table now survives whole.

The reason it is paid rather than tuned away: the alternative is a missed invention, and ADR-0001
records that as the failure this feature exists to prevent. The two harms are not symmetric in
visibility — a missed invention is four minutes of *"you"* that anybody spots on sight, while
deleted speech is silent — which is precisely why the threshold sits at the top half of its
supported band rather than the bottom, and why the case that holds it *down* (real speech surviving)
is the one the test file says matters more.

## Consequences

**The thresholds are not recorded in the sidecar, and that is deliberate.** ADR-0003 records the
merge profile because it is *user-selectable per batch* — its worked failure is a user switching
model or profile and getting every recording skipped in under a second. These thresholds are not
selectable. There is one set, because repetition is a property of the engine rather than of the
material, which is also why there is one set rather than one per merge profile. Changing them is
changing the program, not changing a setting, and the sidecar has never claimed to make program
changes knowable — it records no transcibr version.

The cost of that is real and bounded: tuning these later leaves existing transcripts counting as
done under ADR-0003 while no longer matching what the current code would produce. It is cheap to
pay, because re-render is free — the engine JSON is retained (ADR-0002, ADR-0003), so a threshold
change is followed by a re-render of the batch and no GPU pass. **If these ever become selectable
per batch, they join the sidecar the same day**, and this paragraph is the reason.

`Collapse_Params` still travels as an argument rather than being read from the constant, so a test
pins its own behaviour while the shipped constant is tuned — the same discipline ADR-0007 applies to
the merge profiles. The shipped constant is named `COLLAPSE_THRESHOLDS` and not `COLLAPSE_DEFAULT`:
there is no second set for a default to be chosen over.

Not revisited without new measurement. The band is set by exactly two observed inventions and one
table of collected real repetition; a third measured invention below fourteen sayings, or a real
repetition above thirteen appearing in actual output, reopens this.
