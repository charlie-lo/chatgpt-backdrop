# Pull request automation

Pull requests targeting `main` run the `macOS CI` workflow. The required checks
are `Build macOS App`, `CDP Tests`, `Media Tests`, `Theme Tests`, and
`Automation Tests`. macOS tests use Apple Silicon macOS 15 runners; release
validation should separately confirm compatibility with macOS 14.

Codex automatically reviews new pull requests and new commits. Repository
review guidance lives in `AGENTS.md`. The `Codex Auto-merge` workflow checks
the current commit's trusted Codex summary after review comments and CI runs,
and also checks again twice an hour. It publishes the `Codex review gate`
commit status.

Automatic squash merging is limited to open, non-draft pull requests from a
branch in this repository into `main`. Fork pull requests and stacked pull
requests targeting another branch need maintainer handling.

The policy waits until the current commit has a completed Codex code review
with no unresolved findings, a completed security review, no unresolved review
conversations, and all five checks from the matching PR CI workflow succeeded.
Security review completion alone does not establish that no vulnerabilities
exist: unknown security finding fields are not interpreted as a clean scan.
The repository rules also require the branch to be up to date before merging.
Update a branch when it falls behind `main`; the new commit must be tested and
reviewed again.

If a review, check, or API response is missing, malformed, stale, skipped, or
failed, the policy leaves the pull request waiting. A changed commit or base
invalidates the previous evaluation. Review and address findings before marking
conversations resolved; never remove a required check merely to merge a failing
pull request.

The merge workflow loads its code from trusted `main`. It does not execute PR
code or download PR artifacts with its write-capable token. The policy has
regression tests covering spoofed identities, stale commits, failing checks,
unresolved findings, and concurrent branch changes. Changes to this policy or
to the required check names should be reviewed carefully.
