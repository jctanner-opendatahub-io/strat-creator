# CI helper provenance

Source repository: `git@gitlab.com:redhat/rhel-ai/agentic-ci/strat-pipeline`.
Source branch: `main`. Source commit:
`fd36b15c5095c9f20a270b1d69933c578c04d9da`. Source and destination
repositories use Apache License 2.0; the repository's existing `LICENSE`
continues to cover these helpers.

| Destination | Source path | Treatment |
| --- | --- | --- |
| `stream-claude.py` | `ci-scripts/stream-claude.py` | Copied; preserves stream rendering and exit 42 completion-marker protocol. |
| `otel-collector.py` | `ci-scripts/otel-collector.py` | Copied; retains loopback collection. |
| `otel-summary.py` | `ci-scripts/otel-summary.py` | Copied; summarizes the retained Claude OTEL log. |
| `push-results.py` | `ci-scripts/push-results.py` | Copied/adapted: explicit URL plus inherited Git auth header; no token in remote URL. |
| `push-to-org-pulse.py` | `ci-scripts/push-to-org-pulse.py` | Copied/adapted: TLS certificate and hostname verification remain enabled. |
| `pipeline-post.sh` | `ci-scripts/pipeline-post.sh` | Copied/adapted: checked-out repo/artifacts paths and explicit token variables. |
| `clone-data-repo.sh` | `ci-scripts/clone-data-repo.sh` | Copied/adapted: full URL, process-scoped authentication, and failure on stale destination. |
| `run-claude.sh` | `ci-scripts/run-claude.sh` | Rewritten around `fullsend-claude`; keeps the stream parser and validates early-termination statuses. |
| `strategy-entrypoint.sh` | `.gitlab-ci.yml` `single-rfe` job | New sequential entrypoint; preserves lock/create/refine/push/review/post/unlock order. |
| `with-openshell.sh` | Breadboard M2 smoke at `var/demos/fullsend-entrypoint-poc/openshell-smoke/openshell-smoke.sh` | Adapted as an isolated gateway/command wrapper; pins M2 versions and cleans only job-local Podman storage. |

The source checkout was not modified. `setup-claude-ci.sh` was not copied:
its root-only UBI9 package/user setup and service-account key file are replaced
by the Containerfiles and Fullsend's Vertex provider. Dashboard triggering
remains a CI responsibility for M6.
