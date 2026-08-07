export const meta = {
  name: 'ticket-loop',
  description: 'Implementer→adversarial-reviewer→fixer loop for one transcibr ticket, run to merge-ready',
  phases: [
    { title: 'Implement', detail: 'ticket-implementer agent (Sonnet, medium effort): strict TDD, opens the PR', model: 'sonnet' },
    { title: 'Review', detail: 'ticket-reviewer agent (Opus, medium effort): findings proved by instrumentation', model: 'opus' },
    { title: 'Fix', detail: 'ticket-fixer agent (Sonnet, medium effort): findings only, never re-implements', model: 'sonnet' },
  ],
}

const A = typeof args === 'string' ? JSON.parse(args) : args
if (!A || typeof A.issue !== 'number' || !A.branch) {
  throw new Error('ticket-loop needs args {issue: <number>, branch: <string>}; got: ' + JSON.stringify(args).slice(0, 200))
}
const issue = A.issue
const branch = A.branch
const toFwd = (p) => String(p).replace(/\\/g, '/')
const repo = toFwd(A.repo || 'C:/projects/transcibr')
const wtBase = toFwd(A.worktreeBase || (repo + '-worktrees'))
const wt = wtBase + '/issue-' + issue
const reviewWtBase = wtBase + '/review-' + issue
const reportDir = toFwd(A.reportDir || '$env:TEMP/transcibr-sdd')
const reportFile = reportDir + '/issue-' + issue + '-report.md'
const refutedList = A.refutedListPath || null
const implNotes = A.implNotes || '(none)'
const reviewNotes = A.reviewNotes || '(none)'
const continueNotes = A.continueNotes || null

const COMMON = [
  'Repository checkout: ' + repo + ' (GitHub ivandrenjanin/transcibr). Base branch: main. Windows 11, Windows PowerShell 5.1 (no && / || chaining; chain with ; or if ($?) {}).',
  'Where a path in this prompt is written with $env:TEMP, resolve the environment variable to its actual value before using it in any tool call.',
  'Your role contract is your agent definition (.claude/agents/ticket-*); CLAUDE.md and CONTEXT.md bind everything. The validation commands are the ones CLAUDE.md\'s style section names.',
].join('\n')

const IMPL_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['DONE', 'DONE_WITH_CONCERNS', 'NEEDS_CONTEXT', 'BLOCKED'] },
    pr_number: { type: 'integer' },
    head_commit: { type: 'string' },
    tests: { type: 'string', description: 'one-line test summary, e.g. "471/471 pass, build clean"' },
    concerns: { type: 'string' },
    out_of_scope_defects: { type: 'array', items: { type: 'string' } },
    blocked_reason: { type: 'string' },
  },
  required: ['status', 'tests', 'concerns'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['MERGE', 'FIX'] },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['Critical', 'Important', 'Minor'] },
          title: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'integer' },
          evidence: { type: 'string' },
          proved_by: { type: 'string', description: 'the instrument that proved it: probe test, mutation, measurement' },
        },
        required: ['severity', 'title', 'evidence', 'proved_by'],
      },
    },
    acceptance_criteria_verdicts: { type: 'array', items: { type: 'string' }, description: 'one line per AC: PROVEN or FAILED with the proof' },
    notes: { type: 'string' },
    out_of_scope_defects: { type: 'array', items: { type: 'string' } },
  },
  required: ['verdict', 'findings', 'acceptance_criteria_verdicts'],
}

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['DONE', 'BLOCKED'] },
    head_commit: { type: 'string' },
    tests: { type: 'string' },
    notes: { type: 'string' },
    blocked_reason: { type: 'string' },
  },
  required: ['status', 'tests'],
}

const CONTINUE_PROMPT = [
  'You are FINISHING an interrupted implementation for GitHub issue #' + issue + ' in ivandrenjanin/transcibr. A previous implementer completed the code change but was cut off before delivery. Do NOT redesign or rewrite the approach - verify what exists, finish the remaining checklist, and deliver it.',
  '',
  COMMON,
  '',
  'WORKSPACE: the worktree ALREADY EXISTS at ' + wt + ' on branch ' + branch + ', holding UNCOMMITTED working changes. Do not create a worktree. Start by reading the state exactly as it is: git -C ' + wt + ' status, then git -C ' + wt + ' diff. Then read the ticket (gh issue view ' + issue + ' --repo ivandrenjanin/transcibr) and CLAUDE.md at the worktree root, and confirm the described state matches what you see before proceeding.',
  '',
  'HANDOFF FROM THE INTERRUPTED IMPLEMENTER - what was done, and the remaining checklist you must finish:',
  continueNotes || '(none)',
  '',
  'DELIVERY - same contract as any implementer: commits in the repo history style; push with git -C ' + wt + ' push -u origin ' + branch + '; open the PR with gh pr create --repo ivandrenjanin/transcibr --base main --head ' + branch + ' carrying what/why, the real test evidence, the ticket acceptance criteria as a justified checklist, and: Closes #' + issue,
  'Write the full report to ' + reportFile + ' (create the directory if needed). Leave the worktree in place. Do NOT merge the PR.',
  'If any remaining verification FAILS - a repeat sweep flakes, a mutation proof does not discriminate, a configuration breaks - STOP and return BLOCKED with the evidence. Never tune numbers to get green.',
  'Structured output: status, pr_number, head_commit, one-line tests summary, concerns, out_of_scope_defects.',
].join('\n')

const IMPL_PROMPT = [
  'You are the sole implementer for GitHub issue #' + issue + ' in ivandrenjanin/transcibr.',
  '',
  COMMON,
  '',
  'WORKSPACE - an isolated worktree OUTSIDE the repo. Never edit ' + repo + ' itself; never commit to main.',
  '1. Run: New-Item -ItemType Directory -Force ' + wtBase,
  '2. Run: git -C ' + repo + ' worktree add ' + wt + ' -b ' + branch + ' main',
  '3. Everything you edit and every build/test you run happens inside ' + wt + '.',
  '',
  'REQUIREMENTS - read in this order, BEFORE writing any code:',
  '1. Run: gh issue view ' + issue + ' --repo ivandrenjanin/transcibr -c',
  '   The ticket is your complete requirements document, acceptance criteria included. It was written from measured evidence in an adversarial review; trust its file:line cites but re-read every cited line yourself. Implement exactly what it asks - nothing more, nothing less.',
  '2. Read CLAUDE.md at the worktree root, in full.',
  '3. Read every file the ticket cites.',
  '4. Orchestrator notes for this ticket - these bound your scope and carry context the ticket cannot:',
  implNotes,
  '',
  'METHOD - strict test-driven development, non-negotiable:',
  '- Write the failing test FIRST (the ticket names its shape), run it with just test-one <package> <test_name>, watch it fail for the RIGHT reason, then implement until green, then refactor.',
  '- If .claude\\skills\\implement\\SKILL.md exists in the worktree, read it and follow it.',
  '- You are done only when just ci passes clean from the worktree root.',
  '',
  'DELIVERY:',
  '- Commits: imperative single-sentence subjects in the repo history style (see git log --oneline -10). Logical commits, not one blob.',
  '- Push: git -C ' + wt + ' push -u origin ' + branch,
  '- Open the PR: gh pr create --repo ivandrenjanin/transcibr --base main --head ' + branch + ' with a sentence title and a body carrying: what changed and why, the test evidence (real commands and real output), the ticket acceptance criteria as a checklist with each item checked and justified, and the line: Closes #' + issue,
  '- Do NOT merge the PR. Merging is the orchestrator responsibility.',
  '- Write your full report to ' + reportFile + ' (create ' + reportDir + ' first): what changed and why, a file:line map of every edit, decisions taken and alternatives rejected, test commands with their actual output, and any doubts. The reviewer and fixer depend on this file.',
  '- Leave the worktree in place; the fixer reuses it.',
  '',
  'Structured output: status (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED), pr_number, head_commit, one-line tests summary, concerns (empty string if none), out_of_scope_defects (defects you NOTICED but must not fix - list them, do not touch them), blocked_reason if blocked.',
].join('\n')

function reviewPrompt(round, pr, prior, implConcerns) {
  const scopeBlock = round === 1
    ? 'This is the FIRST review. Attack the whole PR.'
    : 'This is re-review round ' + round + '. The fixer just pushed fixes for these prior findings (JSON):\n' + JSON.stringify(prior, null, 1) + '\nVerdict each prior finding ADDRESSED or NOT ADDRESSED, each with proof. Then attack the fix commits as hard as the original diff - in EVERY prior PR on this repo, at least one fix pass introduced a new defect the next review caught.'
  return [
    'You are an adversarial code reviewer for transcibr PR #' + pr + ' (branch ' + branch + ', fixes issue #' + issue + '). You did not write this code. Your job is to break it before a user does.',
    '',
    COMMON,
    '',
    'METHOD - the one rule that has always paid: MUTATE, DO NOT READ. Every Critical or Important finding must be PROVED BY INSTRUMENTATION - a probe test you write, a mutation the suite should catch and does not, a measurement - never by reading alone. Across five prior PRs every real defect was proved by instrumenting and none by reading. Do not trust the PR description or the implementer report; verify their claims yourself.',
    '',
    'SETUP - disposable instrumentation worktree (never instrument the implementer worktree at ' + wt + ', never push anything):',
    '1. Run: git -C ' + repo + ' fetch origin',
    '2. Run: git -C ' + repo + ' worktree add --detach ' + reviewWtBase + '-r' + round + ' ' + branch,
    '3. Instrument there. When finished, remove it: git -C ' + repo + ' worktree remove --force ' + reviewWtBase + '-r' + round,
    '',
    scopeBlock,
    '',
    'WHAT TO VERIFY:',
    '1. Every acceptance criterion in the ticket (gh issue view ' + issue + ' --repo ivandrenjanin/transcibr): prove each holds - e.g. mutate the code it names and watch the covering test go red; a criterion you cannot prove is a finding.',
    '2. The full diff (gh pr diff ' + pr + ' --repo ivandrenjanin/transcibr) against CLAUDE.md: comment policy, 70-line cap, @(require_results), assertion density and A8 boundary discipline, #+vet tags, T1/T2 typing, M1 reference iteration.',
    '3. just ci green in YOUR worktree - run it yourself.',
    '4. Scope: nothing beyond the ticket. Orchestrator scope notes:',
    reviewNotes,
    '5. After the correctness pass: a simplification pass over the diff (duplication, wrong altitude, needless branches, dead parameters) - report those as findings too, honestly severity-labeled.',
    refutedList
      ? '6. Before proposing ANY structural or stdlib change, read the REFUTED list at ' + refutedList + '. Re-proposing an evidence-backed no-go is itself a review defect.'
      : '6. Before proposing ANY structural or stdlib change, check the repository record first - docs/adr/ and the evidence on closed issues. Re-proposing an evidence-backed no-go is itself a review defect.',
    '7. Read the implementer report at ' + reportFile + ' LAST, and check its claims against what you measured.',
    '',
    (implConcerns && implConcerns.length > 0) ? 'The implementer flagged these concerns - weigh them: ' + implConcerns : 'The implementer flagged no concerns.',
    '',
    'VERDICT RULES: verdict MERGE only if zero Critical and zero Important findings remain. Minor findings do not block but must be listed. For every acceptance criterion output one line: PROVEN (and how) or FAILED (and the finding it maps to). Clean up your instrumentation worktree before returning; never leave mutations behind.',
  ].join('\n')
}

function fixPrompt(round, pr, openFindings) {
  return [
    'You are the fixer for transcibr PR #' + pr + ' (branch ' + branch + ', fixes issue #' + issue + '), fix round ' + round + '. An adversarial reviewer proved the following findings by instrumentation. Fix EXACTLY these findings - never re-implement the feature, never expand scope, never argue with a finding in code comments.',
    '',
    'FINDINGS (verbatim JSON):',
    JSON.stringify(openFindings, null, 1),
    '',
    COMMON,
    '',
    'WORKSPACE: the implementer worktree at ' + wt + ' on branch ' + branch + ' already exists - work there. Run git -C ' + wt + ' status first; the tree should be clean.',
    '',
    'METHOD:',
    '1. Read the implementation history at ' + reportFile + ' first - it carries what was tried and why.',
    '2. TDD applies to fixes: a finding without a covering test gets one that goes RED before your fix and green after. A finding whose covering test exists gets the fix, then the test re-run.',
    '3. Re-run just ci clean from the worktree root before you finish.',
    '4. Commit in the repo style, push to ' + branch + ' (git -C ' + wt + ' push).',
    '5. APPEND a fix-round report to ' + reportFile + ': per finding, what you changed, the covering test, the command and its output.',
    '',
    'If a finding cannot be fixed without contradicting the ticket or CLAUDE.md, do not force it: return status BLOCKED with the reason. Structured output: status, head_commit, one-line tests summary, notes.',
  ].join('\n')
}

phase('Implement')
log('Dispatching implementer for #' + issue)
const impl = await agent(continueNotes ? CONTINUE_PROMPT : IMPL_PROMPT, { label: 'implement-' + issue, phase: 'Implement', agentType: 'ticket-implementer', model: 'sonnet', effort: 'medium', schema: IMPL_SCHEMA })
if (!impl) { return { issue: issue, outcome: 'IMPLEMENTER_DIED' } }
if (impl.status === 'NEEDS_CONTEXT' || impl.status === 'BLOCKED') { return { issue: issue, outcome: impl.status, detail: impl } }
if (typeof impl.pr_number !== 'number') { return { issue: issue, outcome: 'NO_PR_NUMBER', detail: impl } }

const pr = impl.pr_number
log('#' + issue + ' implemented, PR #' + pr + ' open. Entering review loop.')
const roundLog = []
const newIssues = (impl.out_of_scope_defects || []).slice()
let outcome = 'CAP_REACHED'
let deferredMinors = []
let prior = null
let lastReview = null

for (let r = 1; r <= 6; r += 1) {
  const rev = await agent(reviewPrompt(r, pr, prior, impl.concerns), { label: 'review-' + issue + '-r' + r, phase: 'Review', agentType: 'ticket-reviewer', model: 'opus', effort: 'medium', schema: REVIEW_SCHEMA })
  if (!rev) { outcome = 'REVIEWER_DIED'; break }
  lastReview = rev
  for (const d of rev.out_of_scope_defects || []) { newIssues.push(d) }
  const open = (rev.findings || []).filter(f => f.severity === 'Critical' || f.severity === 'Important')
  deferredMinors = (rev.findings || []).filter(f => f.severity === 'Minor').map(f => f.title)
  roundLog.push({ round: r, verdict: rev.verdict, open: open.map(f => f.severity + ': ' + f.title) })
  log('#' + issue + ' review round ' + r + ': ' + rev.verdict + ', ' + open.length + ' blocking findings')
  if (rev.verdict === 'MERGE' && open.length === 0) { outcome = 'MERGE_READY'; break }
  if (open.length === 0) { outcome = 'MERGE_READY'; break }
  if (r === 6) { outcome = 'CAP_REACHED'; prior = open; break }
  const fix = await agent(fixPrompt(r, pr, open), { label: 'fix-' + issue + '-r' + r, phase: 'Fix', agentType: 'ticket-fixer', model: 'sonnet', effort: 'medium', schema: FIX_SCHEMA })
  if (!fix) { outcome = 'FIXER_DIED'; prior = open; break }
  if (fix.status === 'BLOCKED') { outcome = 'FIXER_BLOCKED'; prior = open; roundLog.push({ round: r, fixer_blocked: fix.blocked_reason || fix.notes }); break }
  prior = open
}

return {
  issue: issue,
  pr: pr,
  outcome: outcome,
  rounds: roundLog,
  acceptance_criteria: lastReview ? lastReview.acceptance_criteria_verdicts : [],
  open_findings: outcome === 'MERGE_READY' ? [] : (prior || []),
  deferred_minors: deferredMinors,
  new_issue_candidates: newIssues,
  implementer_tests: impl.tests,
}
