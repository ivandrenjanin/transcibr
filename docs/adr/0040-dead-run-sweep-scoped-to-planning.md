# The dead-run sweep is scoped to `src/planning`; the other per-pid scratch families stay unswept

Issue #217. The ticket's third acceptance criterion asked that "whatever lands, the same decision
is stated for the other per-pid scratch families (audio, pipeline, artifact, child) or scoped to
planning with the reason" — a decision that had no home in the tree at merge time, only in the PR
body, which does not survive the merge. This records it.

## The decision

`sweep_dead_runs` (`src/planning/dead_run_sweep_test.odin`) is scoped to `src/planning` only. It
sweeps exactly the `transcibr-planning-<pid>-<name>` prefix, on the same per-pid convention
`src/audio`, `src/pipeline`, `src/artifact` and `src/child` also use for their own scratch trees,
and does not touch any of those other families' prefixes.

## Why planning and not the others, yet

Planning was the one package with a measured dead-run accumulation at the time this ticket was
written: the #179 review found eleven stranded directories under `%TEMP%` from two dead runs, and
nothing else revisited them. That measurement is what this ticket was scoped against.

## The premise this rests on does not hold for the other families, and that is stated here rather than left implicit

The PR that shipped the planning sweep said the other families "have no equivalent measurement
yet." That was true when it was written and is not true now: a single `just ci` run on this
branch, measured during the round-1 fix review, left 30 fresh `transcibr-pipeline-<pid>-*`
directories under `%TEMP%` from five distinct pids, none of them dead runs — ordinary successful
`just ci` invocations. `artifact` and `child` were not re-measured, but the reasoning that "no
measurement exists yet" no longer holds for `pipeline` as stated.

This ADR does not extend the sweep to `pipeline`, `artifact`, `audio` or `child`. Each of those
families has its own scratch-tree naming, its own lifecycle, and its own package boundary; folding
a second family's sweep into `src/planning` would touch package territory this ticket was not
scoped to open, and doing it without that family's own equivalent of the #179 measurement and its
own safety proof (the junction test this ticket's sweep carries) would be the same "fabricate
against an unmeasured problem" mistake this repository's Odin notes warn against elsewhere.

## What reopens this

A dead-run accumulation measured against `pipeline`, `artifact`, `audio` or `child` — the kind of
concrete count the #179 review produced for planning, or the 30-directory count above — is grounds
for a follow-up ticket giving that family the same sweep, built and reviewed against its own
prefix and its own junction/lock safety proof, not by widening `src/planning`'s.
