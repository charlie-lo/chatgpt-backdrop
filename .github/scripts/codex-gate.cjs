'use strict';

// This file must execute from the trusted default branch, never a PR checkout.
const CODEX_BOT = Object.freeze({ id: 199175422, login: 'chatgpt-codex-connector[bot]' });
const SUMMARY_MARKER = '<!-- codex-pull-request-review-summary -->';
const STATE_MARKER = 'codex-review-state:v1';
const REQUIRED_CI_CHECKS = Object.freeze(['Build macOS App', 'CDP Tests', 'Media Tests', 'Theme Tests', 'Automation Tests']);
const ACTIONS_APP_ID = 15368;

function isTrustedCodex(user) {
  return user?.id === CODEX_BOT.id && user?.login === CODEX_BOT.login;
}

function evaluateCodexReview({ comments = [], threads = [], headSha, requiredReviews = ['code_review'], requireSecurityComplete = true }) {
  const pending = reason => ({ state: 'pending', reason });
  if (typeof headSha !== 'string' || !/^[0-9a-f]{40}$/.test(headSha)) return pending('Invalid PR head SHA');
  if (!Array.isArray(comments) || !Array.isArray(threads)) return pending('Incomplete review data');
  if (!requiredReviews.length) return pending('No review policy configured');
  const summaries = comments.filter(comment => isTrustedCodex(comment.user) &&
    typeof comment.body === 'string' && comment.body.includes(SUMMARY_MARKER));
  summaries.sort((a, b) => (Date.parse(b.updated_at || b.created_at) || 0) -
    (Date.parse(a.updated_at || a.created_at) || 0) || Number(b.id) - Number(a.id));
  const summary = summaries[0];
  if (!summary) return pending('Waiting for a trusted Codex review summary');
  const matches = [...summary.body.matchAll(/<!--\s*codex-review-state:v1\s+([\s\S]*?)\s*-->/g)];
  if (matches.length !== 1) return pending('Missing or ambiguous Codex review state');
  let state;
  try { state = JSON.parse(matches[0][1]); } catch { return pending('Invalid Codex review state'); }
  if (!state || typeof state !== 'object' || Array.isArray(state)) return pending('Invalid Codex review state');
  for (const reviewName of requiredReviews) {
    const review = state[reviewName];
    if (!review || review.commit_sha !== headSha) return pending(`Waiting for ${reviewName} on this commit`);
    if (review.status !== 'completed') return pending(`Waiting for ${reviewName} to complete`);
    if (review.has_unresolved_findings !== false) return pending(`${reviewName} has unresolved or unknown findings`);
    if (typeof review.has_any_findings !== 'boolean') return pending(`${reviewName} has unknown findings`);
  }
  if (requireSecurityComplete) {
    const security = state.security_review;
    if (!security || security.commit_sha !== headSha || security.status !== 'completed') {
      return pending('Waiting for security review to complete on this commit');
    }
    // The observed API reports null findings for security. This confirms only
    // completion, never "no security findings"; explicit unresolved results block.
    if (security.has_unresolved_findings === true) return pending('Security review has unresolved findings');
  }
  if (threads.some(thread => thread.isResolved !== true)) return pending('Unresolved review conversations remain');
  return { state: 'success', reason: 'Codex reviewed this commit; no unresolved findings or conversations', summaryId: summary.id };
}

function selectCIWorkflowRun({ runs, pull, repositoryFullName, workflowPath = '.github/workflows/ci.yml', workflowName = 'macOS CI' }) {
  const candidates = runs.filter(run => run.event === 'pull_request' && run.name === workflowName &&
    run.path?.split('@')[0] === workflowPath && run.head_repository?.full_name === repositoryFullName &&
    run.pull_requests?.some(pr => pr.number === pull.number));
  candidates.sort((a, b) => Number(b.id) - Number(a.id) || Number(b.run_attempt) - Number(a.run_attempt));
  const run = candidates[0];
  if (!run) return { state: 'pending', reason: 'Waiting for the trusted PR CI workflow' };
  const matchingPR = run.pull_requests.some(pr => pr.number === pull.number &&
    pr.head?.sha === pull.head.sha && pr.base?.sha === pull.base.sha);
  if (!matchingPR || ![pull.head.sha, pull.merge_commit_sha].filter(Boolean).includes(run.head_sha)) {
    return { state: 'pending', reason: 'CI does not match the current PR head and base' };
  }
  if (run.status !== 'completed' || run.conclusion !== 'success' || !Number.isInteger(run.check_suite_id)) {
    return { state: 'pending', reason: 'Waiting for the current CI workflow to succeed' };
  }
  return { state: 'success', run };
}

function evaluateCIChecks({ checkRuns, run, requiredChecks = REQUIRED_CI_CHECKS }) {
  if (!requiredChecks.length) return { state: 'pending', reason: 'No required CI checks configured' };
  for (const name of requiredChecks) {
    const matching = checkRuns.filter(check => check.name === name && check.app?.id === ACTIONS_APP_ID &&
      check.head_sha === run.head_sha && check.check_suite?.id === run.check_suite_id)
      .sort((a, b) => Number(b.id) - Number(a.id));
    if (!matching.length || matching[0].status !== 'completed' || matching[0].conclusion !== 'success') {
      return { state: 'pending', reason: `Waiting for CI check: ${name}` };
    }
  }
  return { state: 'success', reason: 'All required CI checks passed for this PR commit' };
}

function eligiblePullRequest(pull, repositoryFullName, baseBranch = 'main') {
  return Boolean(pull && pull.state === 'open' && !pull.draft && pull.base?.ref === baseBranch &&
    pull.base?.repo?.full_name === repositoryFullName && pull.head?.repo?.full_name === repositoryFullName &&
    /^[0-9a-f]{40}$/.test(pull.head?.sha || ''));
}

async function fetchReviewThreads(github, { owner, repo, number }) {
  const threads = [];
  let cursor = null;
  do {
    const result = await github.graphql(`query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
      repository(owner: $owner, name: $repo) { pullRequest(number: $number) {
        reviewThreads(first: 100, after: $cursor) { nodes { id isResolved }
          pageInfo { hasNextPage endCursor }
        }
      } }
    }`, { owner, repo, number, cursor });
    const page = result.repository?.pullRequest?.reviewThreads;
    if (!page || !Array.isArray(page.nodes) || !page.pageInfo) throw new Error('Incomplete review-thread response');
    threads.push(...page.nodes);
    if (page.pageInfo.hasNextPage && (!page.pageInfo.endCursor || page.pageInfo.endCursor === cursor)) {
      throw new Error('Invalid review-thread pagination');
    }
    cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (cursor);
  return threads;
}

async function processPullRequest({ github, core, owner, repo, number, baseBranch = 'main',
  statusContext = 'Codex review gate', requiredReviews = ['code_review'], requireSecurityComplete = true,
  requiredChecks = REQUIRED_CI_CHECKS, workflowFile = 'ci.yml', workflowName = 'macOS CI', mergeMode = 'disabled' }) {
  const repositoryFullName = `${owner}/${repo}`;
  const { data: pull } = await github.rest.pulls.get({ owner, repo, pull_number: number });
  if (!eligiblePullRequest(pull, repositoryFullName, baseBranch)) return { skipped: true };
  const headSha = pull.head.sha;
  const status = (state, description) => github.rest.repos.createCommitStatus({ owner, repo, sha: headSha,
    context: statusContext, state, description: description.slice(0, 140), target_url: pull.html_url });
  // Invalidate an earlier success before fetching review state; API errors stay closed.
  await status('pending', 'Checking Codex review for the current PR commit');
  const [comments, threads] = await Promise.all([
    github.paginate(github.rest.issues.listComments, { owner, repo, issue_number: number, per_page: 100 }),
    fetchReviewThreads(github, { owner, repo, number }),
  ]);
  let result = evaluateCodexReview({ comments, threads, headSha, requiredReviews, requireSecurityComplete });
  let validatedRun;
  if (result.state === 'success') {
    const runs = await github.paginate(github.rest.actions.listWorkflowRuns, { owner, repo,
      workflow_id: workflowFile, event: 'pull_request', branch: pull.head.ref, per_page: 100 });
    const selected = selectCIWorkflowRun({ runs, pull, repositoryFullName, workflowName,
      workflowPath: `.github/workflows/${workflowFile}` });
    if (selected.state !== 'success') result = selected;
    else {
      validatedRun = selected.run;
      const checkRuns = await github.paginate(github.rest.checks.listForRef, { owner, repo,
        ref: validatedRun.head_sha, filter: 'latest', per_page: 100 });
      const ci = evaluateCIChecks({ checkRuns, run: validatedRun, requiredChecks });
      if (ci.state !== 'success') result = ci;
    }
  }
  const { data: fresh } = await github.rest.pulls.get({ owner, repo, pull_number: number });
  if (!eligiblePullRequest(fresh, repositoryFullName, baseBranch) || fresh.head.sha !== headSha ||
      fresh.base.sha !== pull.base.sha || (validatedRun &&
      ![fresh.head.sha, fresh.merge_commit_sha].filter(Boolean).includes(validatedRun.head_sha))) {
    core.info(`PR #${number} changed while checking; leaving the old head pending`);
    return { state: 'pending', reason: 'PR changed while checking' };
  }
  await status(result.state, result.reason);
  core.info(`PR #${number}: ${result.reason}`);
  if (result.state !== 'success' || mergeMode !== 'direct') return result;
  // Re-fetch after publishing success. The direct merge endpoint atomically
  // guards the expected head SHA and still enforces repository merge rules.
  const { data: finalPull } = await github.rest.pulls.get({ owner, repo, pull_number: number });
  if (!eligiblePullRequest(finalPull, repositoryFullName, baseBranch) || finalPull.head.sha !== headSha ||
      finalPull.base.sha !== fresh.base.sha || finalPull.mergeable === false) {
    await status('pending', 'PR changed or has merge conflicts; waiting for another check');
    return { state: 'pending', reason: 'PR changed or has merge conflicts' };
  }
  // mergeable_state includes asynchronously cached required-check results. A
  // cached "blocked" immediately after our success must not reset our own gate.
  if (finalPull.mergeable !== true) return { ...result, waitingForMergeability: true };
  let merged;
  try {
    ({ data: merged } = await github.rest.pulls.merge({ owner, repo, pull_number: number,
      sha: headSha, merge_method: 'squash' }));
  } catch (error) {
    if (error.status !== 405) throw error;
    core.info(`PR #${number}: merge rules are not ready; preserving the verified gate success`);
    return { ...result, waitingForMergeRules: true };
  }
  if (!merged.merged) throw new Error(`GitHub declined merging PR #${number}: ${merged.message || 'unknown reason'}`);
  return { ...result, merged: true };
}

async function run({ github, context, core, ...options }) {
  const { owner, repo } = context.repo;
  const payload = context.payload || {};
  let numbers;
  if (payload.pull_request?.number) numbers = [payload.pull_request.number];
  else if (payload.issue?.pull_request && payload.issue.number) numbers = [payload.issue.number];
  else if (context.eventName === 'issue_comment') return;
  else {
    // workflow_run PR lists can be empty. A scheduled/default-branch rescan also
    // catches comment updates and CI completions that did not emit another event.
    const pulls = await github.paginate(github.rest.pulls.list, { owner, repo, state: 'open',
      base: options.baseBranch || 'main', per_page: 100 });
    numbers = pulls.map(pull => pull.number);
  }
  const results = [];
  let errors = 0;
  for (const number of [...new Set(numbers)]) {
    try {
      results.push(await processPullRequest({ github, core, owner, repo, number, ...options }));
    } catch (error) {
      errors += 1;
      core.error?.(`PR #${number}: ${error.message}`);
      results.push({ number, state: 'pending', error: error.message });
    }
  }
  if (errors) core.setFailed?.(`${errors} PR gate check(s) failed; other PRs were still evaluated`);
  return results;
}

module.exports = { CODEX_BOT, SUMMARY_MARKER, STATE_MARKER, REQUIRED_CI_CHECKS, ACTIONS_APP_ID,
  selectCIWorkflowRun, evaluateCIChecks, isTrustedCodex, evaluateCodexReview,
  eligiblePullRequest, fetchReviewThreads, processPullRequest, run };
