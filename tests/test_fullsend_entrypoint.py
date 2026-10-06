"""Tests for the script-led Fullsend single-RFE flow."""
import fnmatch
import os
import subprocess
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[1]
ENTRYPOINT = REPO / ".fullsend/scripts/strategy-entrypoint.sh"
CI_DIR = REPO / ".fullsend/scripts/ci"


def _run_flow(tmp_path, *, locked=True, fail_stage=""):
    root = tmp_path / "repo"
    ci = root / ".fullsend/scripts/ci"
    (root / "scripts").mkdir(parents=True)
    ci.mkdir(parents=True)
    log = tmp_path / "events.log"

    (ci / "clone-data-repo.sh").write_text(
        "#!/bin/sh\nmkdir -p \"$2/.git/info\"\n"
    )
    (ci / "clone-data-repo.sh").chmod(0o755)
    (ci / "ca-bundle.sh").write_text((CI_DIR / "ca-bundle.sh").read_text())
    (ci / "run-claude.sh").write_text(
        "#!/bin/sh\n"
        "printf 'claude %s\\n' \"$1\" >> \"$EVENT_LOG\"\n"
        "if [ \"$1\" = '/strategy-create RHAIRFE-1234' ]; then\n"
        "  mkdir -p \"$STRAT_CREATOR_ROOT/artifacts/strat-tasks\"\n"
        "  printf '%s\\n' strategy > \"$STRAT_CREATOR_ROOT/artifacts/strat-tasks/RHAISTRAT-55.md\"\n"
        "fi\n"
        "if [ \"${FAIL_STAGE:-}\" = \"$1\" ]; then exit 7; fi\n"
    )
    (ci / "pipeline-post.sh").write_text(
        "#!/bin/sh\n"
        "printf 'post %s\\n' \"$1\" >> \"$EVENT_LOG\"\n"
        "mkdir -p \"$STRAT_CREATOR_ROOT/artifacts/RHAISTRAT/20261005\"\n"
        "printf '%s\\n' published > \"$STRAT_CREATOR_ROOT/artifacts/RHAISTRAT/20261005/result.txt\"\n"
        "ln -sfn 20261005 \"$STRAT_CREATOR_ROOT/artifacts/RHAISTRAT/current\"\n"
    )
    for helper in (ci / "run-claude.sh", ci / "pipeline-post.sh"):
        helper.chmod(0o755)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    python = bin_dir / "python3"
    python.write_text(
        "#!/usr/bin/env bash\n"
        "case \"$1\" in\n"
        "  */otel-collector.py) exec sleep 600 ;;\n"
        "  -c) exit 0 ;;\n"
        "  */lock_issues.py)\n"
        "    if [ \"$2\" = lock ]; then\n"
        "      printf 'lock %s\\n' \"$*\" >> \"$EVENT_LOG\"\n"
        "      for arg in \"$@\"; do case \"$arg\" in RHAIRFE-*) key=$arg ;; esac; done\n"
        "      if [ \"${LOCKED:-1}\" = 1 ]; then\n"
        "        for arg in \"$@\"; do case \"$arg\" in */locked-rfe-ids.txt) printf '%s\\n' \"$key\" > \"$arg\" ;; esac; done\n"
        "        printf '%s\\n' \"$key\"\n"
        "      fi\n"
        "    else printf 'unlock %s\\n' \"$*\" >> \"$EVENT_LOG\"; fi\n"
        "    exit 0 ;;\n"
        "  */push_refined_strategies.py) printf 'push\\n' >> \"$EVENT_LOG\"; exit 0 ;;\n"
        "  */otel-summary.py) exit 0 ;;\n"
        "esac\n"
        "exit 0\n"
    )
    python.chmod(0o755)
    git = bin_dir / "git"
    git.write_text(
        "#!/usr/bin/env bash\n"
        "if [ \"$1\" = clone ]; then dest=\"${@: -1}\"; mkdir -p \"$dest/.git/info\"; fi\n"
        "exit 0\n"
    )
    git.chmod(0o755)

    env = os.environ.copy()
    env.update({
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "STRAT_CREATOR_ROOT": str(root),
        "FULLSEND_OUTPUT_DIR": str(tmp_path / "output"),
        "RESULTS_REPO_URL": "https://gitlab.local/group/results.git",
        "RESULTS_PUSH_TOKEN": "test-token",
        "RESULTS_GIT_USER": "oauth2",
        "CI_JOB_ID": "unit-test",
        "EVENT_LOG": str(log),
        "LOCKED": "1" if locked else "0",
        "FAIL_STAGE": fail_stage,
    })
    result = subprocess.run(
        ["bash", str(ENTRYPOINT), "RHAIRFE-1234"],
        cwd=root,
        env=env,
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    events = log.read_text().splitlines() if log.exists() else []
    return result, events, tmp_path / "output"


def test_single_rfe_order_and_unlock_on_success(tmp_path):
    result, events, output = _run_flow(tmp_path)

    assert result.returncode == 0, result.stderr
    assert [event.split()[0] for event in events] == [
        "lock", "claude", "claude", "push", "claude", "post", "unlock",
    ]
    assert events[1] == "claude /strategy-create RHAIRFE-1234"
    assert events[2] == "claude /strategy-refine RHAISTRAT-55"
    assert events[4] == "claude /strategy-review RHAISTRAT-55"
    assert (output / "strategy-run/result.txt").read_text().strip() == "published"


def test_blocked_rfe_is_no_work_without_skill_or_publish(tmp_path):
    result, events, _ = _run_flow(tmp_path, locked=False)

    assert result.returncode == 0, result.stderr
    assert "No work:" in result.stdout
    assert [event.split()[0] for event in events] == ["lock"]


def test_refine_failure_unlocks_without_review_or_publish(tmp_path):
    result, events, _ = _run_flow(tmp_path, fail_stage="/strategy-refine RHAISTRAT-55")

    assert result.returncode == 7
    assert [event.split()[0] for event in events] == [
        "lock", "claude", "claude", "unlock",
    ]


def test_child_wrapper_uses_fullsend_and_preserves_completion_guard():
    wrapper = (CI_DIR / "run-claude.sh").read_text()

    assert 'fullsend-claude "$prompt"' in wrapper
    assert "this entrypoint owns the strat-creator-processing lock" in wrapper
    assert '"$(<"$ARTIFACTS/locked-rfe-ids.txt")" == "$RFE_KEY"' in wrapper
    assert "\nclaude \"$1\"" not in wrapper
    assert 'stream_rc" -eq 42' in wrapper
    assert 'claude_rc" -eq 143' in wrapper
    assert 'claude_rc" -eq 141' in wrapper


def test_reference_image_and_secure_gateway_configuration():
    harness = (REPO / ".fullsend/harness/strategy.yaml").read_text()
    launcher = (CI_DIR / "with-openshell.sh").read_text()
    claude_wrapper = (CI_DIR / "run-claude.sh").read_text()

    assert "ghcr.io/fullsend-ai/fullsend-sandbox@sha256:259605fea321353552fdefd3a6a55e8b5c260998dfc5a622ed143e41a429995a" in harness
    assert 'SUPERVISOR_TAG="quay.io/opendatahub/odh-openshell-supervisor:v$VERSION"' in launcher
    assert "VERSION=0.0.112-rhaiv.0" in launcher
    assert 'openshell gateway add "https://127.0.0.1:17670" --local' in launcher
    assert "providers_v2_enabled" in launcher
    assert "--server-san host.containers.internal" in launcher
    assert "--enable-mtls-auth true" in launcher
    assert "--tls-client-ca" in launcher
    assert "--from-gcloud-adc" in launcher
    assert '"$STATE/bin/openshell"' in launcher
    assert '"$OPENSHELL_REAL_BIN" "$@" --from-gcloud-adc' in launcher
    assert 'ROOT="${STRAT_CREATOR_ROOT:-${CI_PROJECT_DIR:-$PWD}}"' in launcher
    assert 'grpc_endpoint = "https://host.containers.internal:17670"' in launcher
    assert "guest_tls_cert" in launcher
    assert "application_default_credentials.json" in launcher
    assert (REPO / ".fullsend/profiles/fullsend-vertex-ai.yaml").is_file()
    assert "profiles/fullsend-vertex-ai.yaml" in harness
    assert "src: ${GOOGLE_APPLICATION_CREDENTIALS}" in harness
    assert "dest: /tmp/.gcp-credentials.json" in harness
    assert "GOOGLE_APPLICATION_CREDENTIALS: /tmp/.gcp-credentials.json" in harness
    assert "src: /etc/gitlab-runner/certs/ca.crt" in harness
    assert "dest: /tmp/gitlab-ca.crt" in harness
    ca_helper = (CI_DIR / "ca-bundle.sh").read_text()
    assert 'base_bundle="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"' in ca_helper
    assert 'cat "$base_bundle" "$local_ca" >"$destination"' in ca_helper
    assert 'source "$CI_SCRIPTS/ca-bundle.sh"' in claude_wrapper
    assert 'fullsend_prepare_ca_bundle "$TMP_DIR/ca-bundle.pem"' in claude_wrapper
    assert "disable_tls" not in launcher
    assert "allow_unauthenticated_users" not in launcher
    assert "openshell-community/sandboxes/base:latest" not in launcher
    assert "podman --url \"$PODMAN_URL\" build" not in launcher
    assert not (REPO / ".fullsend/images/ci.Containerfile").exists()
    assert not (REPO / ".fullsend/images/sandbox.Containerfile").exists()


def test_fullsend_build_artifact_is_pinned_and_verified():
    builder = (CI_DIR / "build-fullsend.sh").read_text()
    launcher = (CI_DIR / "with-openshell.sh").read_text()

    assert "FEATURE_SHA=8f628aec6d113181914e2a2307fce17488e2c4b4" in builder
    assert "git -C \"$SOURCE_DIR\" rev-parse HEAD" in builder
    assert "fullsend-source-sha" in builder
    assert "fullsend.sha256" in builder
    assert "fullsend-version.txt" in builder
    assert "fullsend-source-sha" in launcher


def test_shell_helpers_parse():
    for script in [
        ENTRYPOINT,
        CI_DIR / "build-fullsend.sh",
        CI_DIR / "run-claude.sh",
        CI_DIR / "with-openshell.sh",
        CI_DIR / "pipeline-post.sh",
    ]:
        subprocess.run(["bash", "-n", str(script)], check=True)


def test_service_permissions_are_in_applied_policy():
    harness = yaml.safe_load((REPO / ".fullsend/harness/strategy.yaml").read_text())
    policy = yaml.safe_load((REPO / ".fullsend" / harness["policy"]).read_text())
    services = policy["network_policies"]["local_services"]
    endpoints = {entry["host"]: entry for entry in services["endpoints"]}
    assert set(endpoints) == {
        "jira.local", "gitlab.local", "orgpulse.local", "github.com",
        "api.github.com", "raw.githubusercontent.com", "codeload.github.com",
    }
    assert all(entry["port"] == 443 for entry in endpoints.values())
    local_hosts = {"jira.local", "gitlab.local", "orgpulse.local"}
    for host in local_hosts:
        assert endpoints[host]["tls"] == "skip"
        assert "protocol" not in endpoints[host]
    assert all(entry["enforcement"] == "enforce" and "tls" not in entry
               for host, entry in endpoints.items() if host not in local_hosts)
    assert endpoints["api.github.com"]["access"] == "read-only"
    binaries = [entry["path"] for entry in services["binaries"]]
    assert any(fnmatch.fnmatch(
        "/sandbox/.uv/python/cpython-3.14.3-linux-x86_64-gnu/bin/python3.14", pattern,
    ) for pattern in binaries)
    assert "profiles/strat-creator-services.yaml" not in harness["openshell"]["profiles"]
