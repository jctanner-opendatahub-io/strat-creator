"""Tests for the script-led Fullsend single-RFE flow."""
import os
import subprocess
from pathlib import Path

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

    assert "fullsend-claude \"$1\"" in wrapper
    assert "\nclaude \"$1\"" not in wrapper
    assert 'stream_rc" -eq 42' in wrapper
    assert 'claude_rc" -eq 143' in wrapper
    assert 'claude_rc" -eq 141' in wrapper


def test_shell_helpers_parse():
    for script in [ENTRYPOINT, CI_DIR / "run-claude.sh", CI_DIR / "with-openshell.sh", CI_DIR / "pipeline-post.sh"]:
        subprocess.run(["bash", "-n", str(script)], check=True)
