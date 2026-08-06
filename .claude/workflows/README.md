# ticket-loop

The workflow that ran the 2026-08-06 ticket chain: one run takes one GitHub issue from open to
merge-ready through the repository's proven pattern — implementer (Sonnet, medium effort, strict
TDD, opens the PR) → adversarial reviewer (Opus, medium effort, every serious finding proved by
instrumentation in a disposable worktree, never by reading) → fixer (Sonnet, findings only, never
re-implements) — looping until the reviewer verdicts MERGE, capped at five fix rounds, after which
it returns the open findings for orchestrator adjudication instead of churning.

The orchestrator merges (merge commit, never squash), deletes the branch, removes the worktree,
prunes, and routes every deferred minor and out-of-scope discovery to a ticket. The loop never
merges anything itself.

## Invocation

```
Workflow({ name: "ticket-loop", args: {
  issue: 70,                                  // required, the GitHub issue number
  branch: "fix/70-some-slug",                 // required
  implNotes: "- scope guards, context the ticket cannot carry, in-flight collision warnings",
  reviewNotes: "- what to prove by instrumentation, scope lines, known no-gos",
  continueNotes: null,                         // see Continuation below
  repo: null,                                  // repo checkout path; defaults to C:\projects\transcibr
  worktreeBase: null,                          // defaults to <repo>-worktrees
  reportDir: null,                             // defaults to $env:TEMP\transcibr-sdd (agents resolve the env var)
  refutedListPath: null                        // optional path to a review-record REFUTED list; without it,
                                               // reviewers are pointed at docs/adr/ and closed-issue evidence
}})
```

`args` may arrive as a JSON string; the script parses it defensively. `issue` must be a number.
Machine- or user-specific paths belong in the ARGS at invocation time, never committed into this
script — its defaults carry no username and derive everything from the repo path or `$env:TEMP`.

## What the prompts already carry

The repo's binding constraints are baked into every role's prompt: CLAUDE.md's mechanical rules
(comment ban, 70-line cap, `@(require_results)`, vet tags), A8 boundary discipline, the issue #22
assert-hostile-runner rules, the #68-era flake etiquette, validation via `.\scripts\build.ps1` and
`.\scripts\test.ps1`, worktrees OUTSIDE the repo under the `-worktrees` sibling of the checkout
(`issue-<N>` for the implementer/fixer, `review-<N>-r<R>` disposable for each reviewer round), the
prior-refutation check before structural proposals, and report files under
`%TEMP%\transcibr-sdd\issue-<N>-report.md`. Per-ticket `implNotes`/`reviewNotes` are for what the
ticket cannot know: scope guards, sibling-ticket coordination, stale line numbers, in-flight
territory collisions.

## Continuation

If an implementer is interrupted mid-delivery (its work sits uncommitted in the worktree), relaunch
with `continueNotes` describing the verified state and the remaining checklist. The run then skips
worktree creation, verifies the described state, finishes delivery, and enters the same review loop.

## Return value

`{ issue, pr, outcome, rounds, acceptance_criteria, open_findings, deferred_minors,
new_issue_candidates, implementer_tests }` where `outcome` is `MERGE_READY`, `CAP_REACHED` (five fix
rounds spent, findings still open — adjudicate), or a named failure
(`IMPLEMENTER_DIED`/`BLOCKED`/`NEEDS_CONTEXT`/`NO_PR_NUMBER`/`FIXER_BLOCKED`/…). Route
`deferred_minors` and `new_issue_candidates` to tickets or the parking umbrellas — they are the
review's paid-for byproduct, not noise.
