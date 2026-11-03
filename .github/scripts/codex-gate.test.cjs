'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const gate = require('./codex-gate.cjs');
const SHA = 'a'.repeat(40);
const NEXT_SHA = 'b'.repeat(40);
const BASE_SHA = 'c'.repeat(40);
const MERGE_SHA = 'd'.repeat(40);
// Minimal public comment format observed from Codex, without copying a PR body.
const observedSummary = { id: 1, user: { ...gate.CODEX_BOT }, body:
  `${gate.SUMMARY_MARKER}\n<!-- codex-review-state:v1 {"code_review":{"commit_sha":"${SHA}","has_any_findings":false,"has_unresolved_findings":false,"status":"completed"},"security_review":{"commit_sha":"${SHA}","has_any_findings":null,"has_unresolved_findings":null,"status":"completed"}} -->` };
const state = () => ({ code_review: { commit_sha: SHA, status: 'completed',
  has_any_findings: false, has_unresolved_findings: false }, security_review: {
  commit_sha: SHA, status: 'completed', has_any_findings: null, has_unresolved_findings: null } });
const comment = (reviewState = state(), extra = {}) => ({ id: 1, user: { ...gate.CODEX_BOT },
  updated_at: '2026-11-03T12:00:00Z', body: `${gate.SUMMARY_MARKER}\n<!-- codex-review-state:v1 ${JSON.stringify(reviewState)} -->`, ...extra });
const evaluate = (comments, extra = {}) => gate.evaluateCodexReview({ comments, headSha: SHA, threads: [], ...extra });
const pull = (extra = {}) => ({ number: 7, node_id: 'PR_7', state: 'open', draft: false,
  base: { ref: 'main', sha: BASE_SHA, repo: { full_name: 'owner/repo' } },
  head: { ref: 'feature', sha: SHA, repo: { full_name: 'owner/repo' } }, merge_commit_sha: MERGE_SHA,
  mergeable: true, mergeable_state: 'clean', html_url: 'https://github.com/owner/repo/pull/7', ...extra });
const workflowRun = (extra = {}) => ({ id: 88, name: 'macOS CI', path: '.github/workflows/ci.yml',
  event: 'pull_request', head_sha: MERGE_SHA, head_repository: { full_name: 'owner/repo' },
  pull_requests: [{ number: 7, head: { sha: SHA }, base: { sha: BASE_SHA } }],
  check_suite_id: 99, status: 'completed', conclusion: 'success', ...extra });
const checks = () => gate.REQUIRED_CI_CHECKS.map((name, i) => ({ id: i + 1, name,
  head_sha: MERGE_SHA, check_suite: { id: 99 }, app: { id: 15368 }, status: 'completed', conclusion: 'success' }));

test('observed Codex summary format parses without using a thumbs-up reaction or human table', () => {
  const input = { comments: [observedSummary], headSha: SHA, threads: [] };
  assert.equal(gate.evaluateCodexReview(input).state, 'success');
  assert.equal(gate.evaluateCodexReview({ ...input, requiredReviews: ['code_review', 'security_review'] }).state, 'pending');
});

test('authentic exact-head completed code review succeeds despite security nulls in code-only policy', () => {
  assert.equal(evaluate([comment()]).state, 'success');
  assert.equal(evaluate([comment()], { requiredReviews: ['code_review', 'security_review'] }).state, 'pending');
});
test('no summary, a spoofed login, or a spoofed numeric identity cannot pass', () => {
  for (const comments of [[], [comment(state(), { user: { id: 123, login: gate.CODEX_BOT.login } })],
    [comment(state(), { user: { id: gate.CODEX_BOT.id, login: 'attacker' } })]]) {
    assert.equal(evaluate(comments).state, 'pending');
  }
});
test('stale head, running, failed, unknown, and unresolved findings remain pending', () => {
  for (const patch of [{ commit_sha: NEXT_SHA }, { status: 'in_progress' }, { status: 'failed' },
    { has_unresolved_findings: null }, { has_unresolved_findings: true }, { has_any_findings: null }]) {
    const value = state(); Object.assign(value.code_review, patch);
    assert.equal(evaluate([comment(value)]).state, 'pending');
  }
});
test('resolved historical findings can pass, but unresolved conversations cannot', () => {
  const value = state(); value.code_review.has_any_findings = true;
  assert.equal(evaluate([comment(value)]).state, 'success');
  assert.equal(evaluate([comment(value)], { threads: [{ isResolved: false }] }).state, 'pending');
  assert.equal(evaluate([comment(value)], { threads: [{ isResolved: true }] }).state, 'success');
});
test('newest authentic invalid summary blocks an older success; untrusted summaries are ignored', () => {
  const broken = comment(state(), { id: 2, updated_at: '2026-11-03T13:00:00Z',
    body: `${gate.SUMMARY_MARKER}\n<!-- codex-review-state:v1 {invalid} -->` });
  assert.equal(evaluate([comment(), broken]).state, 'pending');
  broken.user = { id: 123, login: gate.CODEX_BOT.login };
  assert.equal(evaluate([comment(), broken]).state, 'success');
});
test('ambiguous state markers and invalid inputs fail closed', () => {
  const value = comment(); value.body += `\n<!-- codex-review-state:v1 ${JSON.stringify(state())} -->`;
  assert.equal(evaluate([value]).state, 'pending');
  assert.equal(evaluate([comment()], { headSha: undefined }).state, 'pending');
  assert.equal(evaluate([comment()], { requiredReviews: [] }).state, 'pending');
  assert.equal(evaluate([comment()], { threads: null }).state, 'pending');
});
test('closed, draft, fork and stacked PRs are excluded', () => {
  assert.equal(gate.eligiblePullRequest(pull(), 'owner/repo'), true);
  for (const value of [pull({ state: 'closed' }), pull({ draft: true }),
    pull({ base: { ref: 'feature', repo: { full_name: 'owner/repo' } } }),
    pull({ head: { sha: SHA, repo: { full_name: 'attacker/repo' } } })]) {
    assert.equal(gate.eligiblePullRequest(value, 'owner/repo'), false);
  }
});
test('all thread pages are inspected, including an unresolved thread on page two', async () => {
  const cursors = [];
  const github = { graphql: async (_, variables) => {
    cursors.push(variables.cursor);
    return { repository: { pullRequest: { reviewThreads: { nodes: [{ isResolved: !variables.cursor }],
      pageInfo: { hasNextPage: !variables.cursor, endCursor: variables.cursor ? null : 'page2' } } } } };
  } };
  const threads = await gate.fetchReviewThreads(github, { owner: 'owner', repo: 'repo', number: 7 });
  assert.deepEqual(cursors, [null, 'page2']);
  assert.equal(evaluate([comment()], { threads }).state, 'pending');
});

function harness({ fresh = pull(), comments = [comment()], threads = [], commentError = false,
  runs = [workflowRun()], checkRuns = checks(), finalPull, mergeError } = {}) {
  const statuses = [], mutations = []; let gets = 0;
  const github = { rest: { pulls: { get: async () => ({ data: ++gets === 1 ? pull() : gets === 2 ? fresh : (finalPull || fresh) }),
    merge: async variables => { mutations.push({ variables }); if (mergeError) throw mergeError;
      return { data: { merged: true } }; } },
    issues: { listComments: 'listComments' }, actions: { listWorkflowRuns: 'listWorkflowRuns' },
    checks: { listForRef: 'listForRef' }, repos: { createCommitStatus: async value => statuses.push(value) } },
    paginate: async endpoint => { if (commentError) throw new Error('API unavailable');
      return endpoint === 'listWorkflowRuns' ? runs : endpoint === 'listForRef' ? checkRuns : comments; },
    graphql: async (query, variables) => {
      if (query.startsWith('query')) return { repository: { pullRequest: { reviewThreads: {
        nodes: threads, pageInfo: { hasNextPage: false, endCursor: null } } } } };
      mutations.push({ query, variables }); return {};
    } };
  return { github, statuses, mutations, core: { info() {} } };
}
const process = h => gate.processPullRequest({ github: h.github, core: h.core, owner: 'owner', repo: 'repo', number: 7, mergeMode: 'direct' });
test('controller checks CI, marks head pending then success, and pins direct merge to that SHA', async () => {
  const h = harness(); const result = await process(h);
  assert.equal(result.merged, true);
  assert.deepEqual(h.statuses.map(s => s.state), ['pending', 'success']);
  assert.equal(h.mutations[0].variables.sha, SHA);
  assert.equal(h.mutations[0].variables.merge_method, 'squash');
});
test('a new head during evaluation never gets success or enables auto-merge', async () => {
  const h = harness({ fresh: pull({ head: { sha: NEXT_SHA, repo: { full_name: 'owner/repo' } } }) });
  assert.equal((await process(h)).state, 'pending');
  assert.deepEqual(h.statuses.map(s => s.state), ['pending']);
  assert.equal(h.mutations.length, 0);
});
test('API failure leaves the prior success invalidated and never merges', async () => {
  const h = harness({ commentError: true });
  await assert.rejects(process(h), /API unavailable/);
  assert.deepEqual(h.statuses.map(s => s.state), ['pending']);
  assert.equal(h.mutations.length, 0);
});
test('wrong workflow, stale head/base, latest failed CI, and missing checks never merge', async () => {
  const invalidRuns = [[], [workflowRun({ path: '.github/workflows/forged.yml' })],
    [workflowRun({ head_sha: NEXT_SHA })], [workflowRun({ conclusion: 'failure' })],
    [workflowRun({ pull_requests: [{ number: 7, head: { sha: SHA }, base: { sha: NEXT_SHA } }] })],
    [workflowRun(), workflowRun({ id: 89, conclusion: 'failure' })]];
  for (const runs of invalidRuns) {
    const h = harness({ runs }); assert.equal((await process(h)).state, 'pending');
    assert.equal(h.mutations.length, 0);
  }
  const h = harness({ checkRuns: checks().slice(1) });
  assert.equal((await process(h)).state, 'pending'); assert.equal(h.mutations.length, 0);
});
test('each exact check must be successful and from the Actions app, selected suite and commit', async () => {
  for (const patch of [{ app: { id: 666 } }, { check_suite: { id: 999 } }, { head_sha: NEXT_SHA },
    { conclusion: 'skipped' }, { name: 'Build macOS App (fake)' }]) {
    const checkRuns = checks(); Object.assign(checkRuns[0], patch);
    const h = harness({ checkRuns }); assert.equal((await process(h)).state, 'pending');
    assert.equal(h.mutations.length, 0);
  }
});
test('security completion is required, unknown security findings never mean clean', () => {
  for (const patch of [{ status: 'in_progress' }, { commit_sha: NEXT_SHA }, { has_unresolved_findings: true }]) {
    const value = state(); Object.assign(value.security_review, patch);
    assert.equal(evaluate([comment(value)]).state, 'pending');
  }
});
test('merging is disabled unless explicitly configured and blocked when PR is not clean', async () => {
  const h = harness();
  await gate.processPullRequest({ github: h.github, core: h.core, owner: 'owner', repo: 'repo', number: 7 });
  assert.equal(h.mutations.length, 0);
  const blocked = harness({ fresh: pull({ mergeable: false, mergeable_state: 'dirty' }) });
  assert.equal((await process(blocked)).state, 'pending'); assert.equal(blocked.mutations.length, 0);
});
test('a base SHA change during review or immediately before merge blocks merging', async () => {
  const changedBase = pull({ base: { ...pull().base, sha: NEXT_SHA } });
  for (const options of [{ fresh: changedBase }, { finalPull: changedBase }]) {
    const h = harness(options);
    assert.equal((await process(h)).state, 'pending');
    assert.equal(h.mutations.length, 0);
    assert.equal(h.statuses.at(-1).state, 'pending');
  }
});
test('a failed or skipped fifth Automation Tests job blocks direct merging', async () => {
  assert.equal(gate.REQUIRED_CI_CHECKS[4], 'Automation Tests');
  for (const conclusion of ['failure', 'skipped']) {
    const checkRuns = checks(); checkRuns[4].conclusion = conclusion;
    const h = harness({ checkRuns });
    assert.equal((await process(h)).state, 'pending');
    assert.equal(h.mutations.length, 0);
  }
});
test('a failed PR evaluation does not prevent checking the remaining PRs', async () => {
  const h = harness();
  const originalGet = h.github.rest.pulls.get;
  const evaluated = [], failures = [];
  h.github.rest.pulls.get = async options => {
    evaluated.push(options.pull_number);
    if (options.pull_number === 6) throw new Error('PR 6 API failure');
    return originalGet(options);
  };
  h.github.rest.pulls.list = 'listPulls';
  const originalPaginate = h.github.paginate;
  h.github.paginate = async (endpoint, options) => endpoint === 'listPulls' ? [{ number: 6 }, { number: 7 }] : originalPaginate(endpoint, options);
  h.core.error = () => {};
  h.core.setFailed = message => failures.push(message);
  const results = await gate.run({ github: h.github, core: h.core,
    context: { repo: { owner: 'owner', repo: 'repo' }, payload: {}, eventName: 'schedule' }, mergeMode: 'direct' });
  assert.equal(results[0].state, 'pending');
  assert.equal(results[1].merged, true);
  assert.ok(evaluated.includes(7));
  assert.equal(failures.length, 1);
});
test('cached blocked mergeable_state does not reset a verified gate or prevent API-enforced merge', async () => {
  const h = harness({ finalPull: pull({ mergeable: true, mergeable_state: 'blocked' }) });
  assert.equal((await process(h)).merged, true);
  assert.deepEqual(h.statuses.map(s => s.state), ['pending', 'success']);
});
test('merge API 405 preserves gate success so cached rules can settle before the next run', async () => {
  const h = harness({ mergeError: Object.assign(new Error('Required status check is expected'), { status: 405 }) });
  const result = await process(h);
  assert.equal(result.waitingForMergeRules, true);
  assert.equal(result.merged, undefined);
  assert.deepEqual(h.statuses.map(s => s.state), ['pending', 'success']);
});
test('unknown mergeability preserves verified success and waits without attempting merge', async () => {
  const h = harness({ finalPull: pull({ mergeable: null, mergeable_state: 'unknown' }) });
  assert.equal((await process(h)).waitingForMergeability, true);
  assert.equal(h.mutations.length, 0);
  assert.deepEqual(h.statuses.map(s => s.state), ['pending', 'success']);
});
