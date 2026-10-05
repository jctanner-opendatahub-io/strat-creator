# Fullsend strategy entrypoint POC

This branch preserves the `single-rfe` path from the strat-pipeline source
checkout at commit `fd36b15c5095c9f20a270b1d69933c578c04d9da`. The target repo
is the checked-out `feat/fullsend-strategy-entrypoint` branch; CI must not
clone public `main` over it. The sequence is issue lock, strategy create,
strategy refine, deterministic refined-strategy push to Jira, strategy review,
report/data publication, and lock release on every exit path. A blocked lock is
a no-work success. A missing or duplicate strategy artifact is a failure.

## Local invocation

Build or select the CI image from `.fullsend/images/ci.Containerfile` and run
the pinned job-owned gateway wrapper from the repository root:

```bash
export CI_PROJECT_DIR="$PWD"
export CI_JOB_ID=local-001
export RFE_KEY=RHAIRFE-1234
export JIRA_SERVER=https://jira.local
export JIRA_USER='set-me'
export JIRA_TOKEN='set-me'
export RESULTS_REPO_URL='https://gitlab.local/group/project.git'
export RESULTS_PUSH_TOKEN='set-me'
export RESULTS_GIT_USER=oauth2
export ANTHROPIC_VERTEX_PROJECT_ID='set-me'
export ORG_PULSE_URL=
export ORG_PULSE_API_TOKEN=
bash .fullsend/scripts/ci/with-openshell.sh -- fullsend run strategy \
  --fullsend-dir "$PWD/.fullsend" \
  --target-repo "$PWD" \
  --output-dir "$PWD/fullsend-run-output"
```

`with-openshell.sh` is intended to run in the CI job image built from
`.fullsend/images/ci.Containerfile`; it requires the M2 Podman-capable job
environment and one unique `CI_JOB_ID`. Each job starts its own Podman API,
OpenShell gateway, network, certificates, and state. It saves gateway/Podman
logs, removes the job's containers/network, unregisters the gateway, and
deletes job state on exit. It does not use a host engine socket or shared
gateway. The Kubernetes executor must provide an isolated, ephemeral job
container/storage and the permissions validated by M1/M2.

## Required GitLab variables

Configure these in local GitLab project settings, never in this repository:

| Variable | Purpose |
| --- | --- |
| `RFE_KEY` | One approved `RHAIRFE-NNNN` issue for the manual `single-rfe` job |
| `JIRA_SERVER` | Jira base URL; use the local emulator URL for the POC |
| `JIRA_USER` | Jira bot username |
| `JIRA_TOKEN` | Jira bot PAT with required read/write strategy permissions |
| `RESULTS_REPO_URL` | HTTPS URL of the strat-pipeline-data project |
| `RESULTS_PUSH_TOKEN` | GitLab token allowed to push result artifacts and summaries |
| `RESULTS_GIT_USER` | Username paired with the results token (often `oauth2`) |
| `ANTHROPIC_VERTEX_PROJECT_ID` | GCP project used by Fullsend's Vertex provider |
| `ORG_PULSE_URL` | Optional Org Pulse API URL; set blank to skip the non-blocking upload |
| `ORG_PULSE_API_TOKEN` | Optional Org Pulse token; set blank to skip the non-blocking upload |

The local Jira, GitLab, Org Pulse, and Vertex endpoints are runtime inputs. The
committed OpenShell service profile scopes sandbox traffic to the local service
names and the public GitHub hosts used by architecture-context retrieval.
M6 must verify DNS, CA trust, and egress from each nested network layer before
running a credential-bearing job.

## Fullsend versions and hooks

The CI image builds Fullsend from
`jctanner/fullsend@8f628aec6d113181914e2a2307fce17488e2c4b4`, the M3 review-fix
commit on `feat/entrypoint-harness`. OpenShell CLI, gateway, supervisor, and
stock sandbox versions remain at the M2-tested 0.0.116 set. The strategy
sandbox image extends the M2 stock image and installs Python 3, Git, Bash, and
PyYAML 6.0.3; those replace `setup-claude-ci.sh`'s runtime package install and
`useradd` on UBI9. Claude uses Fullsend's Vertex provider and
`fullsend-claude`; this flow does not copy a GCP key into the sandbox.

Fullsend hooks remain enabled with the M3 default. This branch does not set
`security.sandbox_hooks.enabled: false`; wait for the separate hooks-switch
change before selecting an opt-out. The hook-integrity checks are checkpoint
checks and retain M3's documented bypass/restore limitations.

## Source differences

- `run-claude.sh` delegates child startup to `fullsend-claude`, retains the
  stream renderer and `FULL RUN COMPLETE` sentinel, and accepts success only
  when the parser returned 42 and the child ended from the expected SIGTERM or
  SIGPIPE. Other non-zero statuses fail the entrypoint. Fullsend owns the
  child runtime and cancellation boundary.
- The entrypoint runs one RFE rather than four job types. A blocked issue lock
  exits without invoking skills or publishing an empty run. The script rejects
  zero or multiple created strategies rather than guessing from a glob.
- The workspace is the checked-out feature branch. There is no `/tmp` clone,
  root-only token directory, or `CI_PROJECT_DIR` dependency inside the sandbox.
- Results authentication uses a process-scoped Git HTTP header. Tokens are
  not embedded in `.git/config` remote URLs. Org Pulse keeps normal HTTPS
  certificate and hostname verification enabled; configure its CA trust in
  the job image.
- The UBI9 `setup-claude-ci.sh` user creation, package installation, and
  service-account key copy are replaced by the two pinned Containerfiles and
  Fullsend provider setup. Dashboard triggering and GitLab artifact upload
  remain CI responsibilities for M6.

Detailed file-by-file copy/adaptation provenance is in
`.fullsend/scripts/ci/SOURCE-PROVENANCE.md`.
