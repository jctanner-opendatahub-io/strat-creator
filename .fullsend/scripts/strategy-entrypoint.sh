#!/usr/bin/env bash
# Script-led equivalent of strat-pipeline's single-rfe job.
set -Eeuo pipefail

if [[ $# -ne 1 || ! $1 =~ ^RHAIRFE-[0-9]+$ ]]; then
  echo "usage: strategy-entrypoint.sh RHAIRFE-NNNN" >&2
  exit 2
fi

ROOT="${STRAT_CREATOR_ROOT:-$PWD}"
CI_SCRIPTS="$ROOT/.fullsend/scripts/ci"
source "$CI_SCRIPTS/ca-bundle.sh"
CA_BUNDLE="${TMPDIR:-/tmp}/strat-ca-${CI_JOB_ID:-$$}.pem"
fullsend_prepare_ca_bundle "$CA_BUNDLE"
ARTIFACTS="$ROOT/artifacts"
LOCKED_FILE="$ARTIFACTS/locked-rfe-ids.txt"
OUTPUT_DIR="${FULLSEND_OUTPUT_DIR:-/sandbox/workspace/output}"
RFE_KEY="$1"
COLLECTOR_PID=""
LOCKED_KEYS=""
PREVIOUS_RUN=""

mkdir -p "$OUTPUT_DIR"
if [[ -z "${RESULTS_PUSH_TOKEN:-}" ]]; then
  echo "ERROR: RESULTS_PUSH_TOKEN is required for result publication" >&2
  exit 1
fi
auth="$(printf '%s:%s' "${RESULTS_GIT_USER:-oauth2}" "$RESULTS_PUSH_TOKEN" | base64 | tr -d '\n')"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.${RESULTS_REPO_URL:?RESULTS_REPO_URL is required}.extraHeader"
export GIT_CONFIG_VALUE_0="Authorization: Basic $auth"
unset auth

if [[ -d "$ARTIFACTS/.git" ]]; then
  echo "Using existing result repository at $ARTIFACTS"
elif [[ -e "$ARTIFACTS" ]]; then
  echo "ERROR: $ARTIFACTS exists but is not the results repository" >&2
  exit 1
else
  "$CI_SCRIPTS/clone-data-repo.sh" "${RESULTS_REPO_URL:?RESULTS_REPO_URL is required}" "$ARTIFACTS"
fi
mkdir -p "$ARTIFACTS/.git/info"
printf '%s\n' 'locked-rfe-ids.txt' >> "$ARTIFACTS/.git/info/exclude"
git -C "$ARTIFACTS" rm --cached --ignore-unmatch -q locked-rfe-ids.txt 2>/dev/null || true

export OTEL_LOG_FILE="$ARTIFACTS/claude-otel.jsonl"
export OTEL_RATE_FILE="$ARTIFACTS/claude-otel-rate.json"
if [[ -L "$ARTIFACTS/RHAISTRAT/current" ]]; then
  PREVIOUS_RUN="$(readlink "$ARTIFACTS/RHAISTRAT/current")"
fi

cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  set +e

  if [[ -n "$COLLECTOR_PID" ]]; then
    kill -TERM "$COLLECTOR_PID" 2>/dev/null
    wait "$COLLECTOR_PID" 2>/dev/null
  fi

  if [[ -s "$LOCKED_FILE" ]]; then
    LOCKED_KEYS="$(tr '\n' ' ' < "$LOCKED_FILE" | xargs)"
    if [[ -n "$LOCKED_KEYS" ]]; then
      python3 "$ROOT/scripts/lock_issues.py" unlock $LOCKED_KEYS || {
        echo "ERROR: failed to release Jira lock(s): $LOCKED_KEYS" >&2
        rc=1
      }
    fi
  fi

  CURRENT_RUN=""
  if [[ -L "$ARTIFACTS/RHAISTRAT/current" ]]; then
    CURRENT_RUN="$(readlink "$ARTIFACTS/RHAISTRAT/current")"
  fi
  if [[ -n "$CURRENT_RUN" && "$CURRENT_RUN" != "$PREVIOUS_RUN" ]]; then
    mkdir -p "$OUTPUT_DIR/strategy-run"
    cp -aL "$ARTIFACTS/RHAISTRAT/current/." "$OUTPUT_DIR/strategy-run/" 2>/dev/null || rc=1
  fi
  for file in "$ARTIFACTS/pipeline-data.json" "$ARTIFACTS/strat-tickets.md" "$ARTIFACTS/strat-skipped.md"; do
    [[ -f "$file" ]] && cp -f "$file" "$OUTPUT_DIR/" || true
  done
  if [[ -d "$ARTIFACTS/reports" ]]; then
    mkdir -p "$OUTPUT_DIR/reports"
    cp -a "$ARTIFACTS/reports/." "$OUTPUT_DIR/reports/"
  fi

  rm -f "$LOCKED_FILE"
  rm -f "$CA_BUNDLE"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
export OTEL_METRIC_EXPORT_INTERVAL=10000

python3 "$CI_SCRIPTS/otel-collector.py" &
COLLECTOR_PID=$!
for ((attempt = 0; attempt < 30; attempt++)); do
  if python3 -c 'import socket; s=socket.create_connection(("127.0.0.1", 4318), 1); s.close()' >/dev/null 2>&1; then
    break
  fi
  kill -0 "$COLLECTOR_PID" 2>/dev/null || { echo "OTEL collector exited during startup" >&2; exit 1; }
  sleep 1
done
kill -0 "$COLLECTOR_PID" 2>/dev/null || { echo "OTEL collector did not start" >&2; exit 1; }

rm -f "$LOCKED_FILE"
LOCKED_KEYS="$(python3 "$ROOT/scripts/lock_issues.py" lock --locked-keys-file "$LOCKED_FILE" "$RFE_KEY")"
if [[ -z "$LOCKED_KEYS" ]]; then
  echo "No work: $RFE_KEY is already locked or blocked by its Jira labels."
  exit 0
fi
if [[ "$LOCKED_KEYS" != "$RFE_KEY" ]]; then
  echo "ERROR: lock helper returned an unexpected key set: $LOCKED_KEYS" >&2
  exit 1
fi

"$CI_SCRIPTS/run-claude.sh" "/strategy-create $RFE_KEY"

mapfile -t strategy_files < <(find "$ARTIFACTS/strat-tasks" -maxdepth 1 -type f -name 'RHAISTRAT-*.md' -print 2>/dev/null | sort)
if [[ ${#strategy_files[@]} -ne 1 ]]; then
  echo "ERROR: expected one created strategy for $RFE_KEY; found ${#strategy_files[@]}" >&2
  exit 1
fi
STRAT_KEY="$(basename "${strategy_files[0]}" .md)"

"$CI_SCRIPTS/run-claude.sh" "/strategy-refine $STRAT_KEY"
python3 "$ROOT/scripts/push_refined_strategies.py" --artifacts-dir "$ARTIFACTS/strat-tasks"
"$CI_SCRIPTS/run-claude.sh" "/strategy-review $STRAT_KEY"
"$CI_SCRIPTS/pipeline-post.sh" single-rfe
python3 "$CI_SCRIPTS/otel-summary.py" "$OTEL_LOG_FILE"
