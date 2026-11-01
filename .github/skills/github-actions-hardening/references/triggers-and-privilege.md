# Triggers and Privilege

The single most important question for workflow security is: **can an outside contributor trigger
this workflow, and if so, what token and secrets does it get?** GitHub answers this differently per
trigger.

## Trust Matrix

| Trigger | Who can fire it | `GITHUB_TOKEN` | Secrets available | Risk |
| --- | --- | --- | --- | --- |
| `push` | Repo collaborators | read/write | yes | Low — trusted authors |
| `pull_request` (same-repo branch) | Collaborators | read/write | yes | Low |
| `pull_request` (from a fork) | **Anyone** | Usually read-only* | Usually no* | Conditional — verify settings and runner isolation |
| `pull_request_target` | **Anyone with a fork** | Depends on effective permissions* | May be available* | **High** — base-repo context; assess code execution and runner |
| `workflow_run` | Fires after another workflow | Depends on effective permissions* | May be available* | **High** |
| `issue_comment`, `issues` | **Anyone** | Depends on effective permissions* | May be available* | **High** |

*Effective `GITHUB_TOKEN` permissions are determined by workflow/job permissions and repository
defaults. Repository fork-PR settings separately control whether fork-triggered workflows may receive
write tokens or secrets; verify both rather than assuming defaults. Keep runner isolation distinct
from these controls. Untrusted fork code is exempt from a finding based solely on execution only
when it runs on an isolated runner with no exposed credentials/secrets or persistent resources. A
persistent self-hosted runner may be compromised and affect later jobs regardless of token permissions
or trigger type.

The trap: Maintainers who find that "the secrets don't work on fork PRs" may switch to
`pull_request_target` to get them back — exposing base-repository permissions and potentially secrets
to workflows triggered by arbitrary contributors. Evaluate this exposure separately from runner
compromise.

## Why `pull_request_target` Is Dangerous

`pull_request_target` checks out the **base** repository's workflow definition (so a fork can't
change what runs), but it runs with full privileges. The danger is when the workflow then
explicitly checks out the **fork's** code and executes it:

```yaml
# DANGEROUS — RCE with a write token + secrets
on: pull_request_target
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
        with:
          ref: ${{ github.event.pull_request.head.sha }}   # fork's code
      - run: npm install && npm test                        # runs the fork's code + scripts
```

`npm install` alone runs arbitrary lifecycle scripts from the PR. With `pull_request_target`, the
workflow can access repository secrets through expressions, but those secrets are not automatically
exported into npm lifecycle scripts. A secret reaches a script only if the workflow explicitly
passes it, for example through a step's `env:` or an action input.

Separately, `actions/checkout` persists its GitHub token in local Git configuration by default, so
code that runs Git may use that credential. Whether it can push depends on the token's effective
permissions; persistence alone does not grant write access.

## The Safe Two-Workflow Pattern

Split responsibilities. An **unprivileged** workflow runs the untrusted code; a **privileged**
workflow consumes only the trusted *output*.

```yaml
# 1) Unprivileged: runs untrusted code; verify effective permissions, fork-PR settings, and runner isolation
name: PR Build
on: pull_request
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - run: npm ci && npm run build
      - uses: actions/upload-artifact@<sha>
        with: { name: pr, path: dist/ }
```

```yaml
# 2) Privileged: triggered by the first, never runs fork code
# The downloaded artifact is still untrusted data; validate it and never execute it.
name: PR Comment
on:
  workflow_run:
    workflows: ["PR Build"]
    types: [completed]
permissions:
  actions: read
  pull-requests: write
jobs:
  comment:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@<sha>
        with:
          name: pr
          run-id: ${{ github.event.workflow_run.id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
      # Validate the untrusted files, then use them only as data in the comment.
      # Never source, import, or execute downloaded files.
```

## Rules

* Treat `pull_request_target`, `workflow_run`, `issue_comment`, and `issues` as privileged.
* In a privileged workflow, **never** check out and execute PR/fork code.
* If you only need to label, comment, or triage based on metadata, that is fine — just don't run
  the contributor's code.
* Prefer `pull_request` when possible, but verify effective token permissions, repository fork-PR
  settings, and runner isolation separately. Only exempt fork-code execution on isolated runners
  with no exposed credentials/secrets or persistent resources. Assess persistent self-hosted runner
  compromise independently of token permissions or trigger type.
