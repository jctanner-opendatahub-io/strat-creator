# Fullsend strategy entrypoint POC

This branch preserves the `single-rfe` path from the strat-pipeline source
checkout at commit `fd36b15c5095c9f20a270b1d69933c578c04d9da`. The target repo
is the checked-out `feat/fullsend-strategy-entrypoint` branch; CI must not
clone public `main` over it. The sequence is issue lock, strategy create,
strategy refine, deterministic refined-strategy push to Jira, strategy review,
report/data publication, and lock release on every exit path. A blocked lock is
a no-work success. A missing or duplicate strategy artifact is a failure.

## Local invocation

The GitLab job uses rfe-autofixer's CI image directly. A separate Go build job
produces the Fullsend feature binary artifact; the strategy job downloads that
artifact, then runs the pinned job-owned gateway wrapper from the repository
root:

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
# The `fullsend-build/` artifact comes from build-fullsend.sh in the Go job.
bash .fullsend/scripts/ci/with-openshell.sh -- fullsend run strategy \
  --fullsend-dir "$PWD/.fullsend" \
  --target-repo "$PWD" \
  --output-dir "$PWD/fullsend-run-output"
```

Build the binary artifact in a separate job using a Go image with Go 1.26.5 or
newer:

```yaml
build-fullsend-feature:
  image: golang:1.26.5-bookworm
  script:
    - bash .fullsend/scripts/ci/build-fullsend.sh
  artifacts:
    paths:
      - fullsend-build/
```

The strategy job uses
`quay.io/aipcc/agentic-ci/openshell:0.3.46` directly. It requires the M1/M2
Podman-capable job environment, the build artifact, and one unique `CI_JOB_ID`.
Each job starts its own Podman API and OpenShell gateway with mTLS, a unique
network, generated certificates, and job-local state. It saves gateway/Podman
logs, removes the job's containers/network, unregisters the gateway, and
deletes job state on exit. It does not use a host engine socket or shared
gateway. The Kubernetes executor must provide isolated, ephemeral job
storage and the permissions validated by M1/M2.

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
| `GOOGLE_APPLICATION_CREDENTIALS` | GitLab file variable containing the GCP credential JSON; Fullsend copies it to `/tmp/.gcp-credentials.json` in the sandbox for Claude Code ADC |
| `ANTHROPIC_VERTEX_PROJECT_ID` | GCP project used by Fullsend's Vertex provider |
| Runner CA bundle | `/etc/gitlab-runner/certs/ca.crt`; copied into the sandbox and appended to OpenShell's trust bundle by the strategy entrypoint and Claude wrapper |
| `ORG_PULSE_URL` | Optional Org Pulse API URL; set blank to skip the non-blocking upload |
| `ORG_PULSE_API_TOKEN` | Optional Org Pulse token; set blank to skip the non-blocking upload |

The local Jira, GitLab, Org Pulse, and Vertex endpoints are runtime inputs. The
committed OpenShell service profile scopes sandbox traffic to the local service
names and the public GitHub hosts used by architecture-context retrieval.
M6 must verify DNS, CA trust, and egress from each nested network layer before
running a credential-bearing job.

## Fullsend versions and hooks

The separate build job compiles Fullsend from
`jctanner/fullsend@8f628aec6d113181914e2a2307fce17488e2c4b4`, the M3 review-fix
commit on `feat/entrypoint-harness`, and records its source SHA and binary
checksum. The strategy harness uses
`ghcr.io/fullsend-ai/fullsend-sandbox@sha256:259605fea321353552fdefd3a6a55e8b5c260998dfc5a622ed143e41a429995a`.
The reference CI image reports OpenShell CLI and gateway `0.0.112-rhaiv.0`;
the gateway uses `quay.io/opendatahub/odh-openshell-supervisor:v0.0.112-rhaiv.0`.
The CI image already has Podman, curl, OpenSSL, Bash, Git, Python 3.12, and
PyYAML 6.0.3. The sandbox has Claude, Node, Git, Bash, Python 3.14, and PyYAML
6.0.3. Neither image has `fullsend-claude` preinstalled; Fullsend installs its
supported helper during a Claude run. The strategy scripts do not require
`jsonschema`, which is absent from the CI image. No custom image extension is
currently needed. Claude uses Fullsend's Vertex provider. Following the
rfe-autofixer harness, Fullsend `host_files` copies the GitLab file variable
at `GOOGLE_APPLICATION_CREDENTIALS` to `/tmp/.gcp-credentials.json` in the
sandbox and sets that path for Claude Code ADC. The M4.1 smoke used the
existing `authorized_user` ADC file, which contains a refresh token with
cloud-platform scope; copying it gives sandbox code the same cloud access as
that user. Do not use this credential for a real strategy run. M6 needs a
dedicated service account restricted to Vertex inference, provisioned as a
protected GitLab file variable and rotated through secret management.

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
  service-account key copy are replaced by the reference CI/sandbox images
  and Fullsend provider setup. Fullsend itself is a separate binary artifact.
  Dashboard triggering and GitLab artifact upload remain CI responsibilities
  for M6.

The M4.1 image and gateway compatibility checks are recorded in the Breadboard
ledger task. Re-run the gateway/data-plane checks in the privileged Kubernetes
job context before relying on this image set for a credential-bearing strategy
run.

Detailed file-by-file copy/adaptation provenance is in
`.fullsend/scripts/ci/SOURCE-PROVENANCE.md`.
