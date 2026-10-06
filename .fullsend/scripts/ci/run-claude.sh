#!/usr/bin/env bash
# Adapted from strat-pipeline ci-scripts/run-claude.sh at fd36b15c5095c9f20a270b1d69933c578c04d9da.
# Fullsend owns the Claude process and credentials; this wrapper preserves the
# existing stream rendering and FULL RUN COMPLETE marker behavior.
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: run-claude.sh '<skill prompt>'" >&2
  exit 2
fi
command -v fullsend-claude >/dev/null || { echo "ERROR: Fullsend did not install fullsend-claude" >&2; exit 127; }

ROOT="${STRAT_CREATOR_ROOT:-$PWD}"
CI_SCRIPTS="$ROOT/.fullsend/scripts/ci"
ARTIFACTS="$ROOT/artifacts"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/strat-claude.XXXXXX")"
FIFO="$TMP_DIR/stream.jsonl"
STDERR_LOG="$ARTIFACTS/claude-stderr.log"
CLAUDE_PID=""
STREAM_PID=""
mkdir -p "$ARTIFACTS"
mkfifo "$FIFO"
source "$CI_SCRIPTS/ca-bundle.sh"
fullsend_prepare_ca_bundle "$TMP_DIR/ca-bundle.pem"

cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  set +e
  [[ -n "$CLAUDE_PID" ]] && kill -TERM "$CLAUDE_PID" 2>/dev/null
  [[ -n "$STREAM_PID" ]] && kill -TERM "$STREAM_PID" 2>/dev/null
  [[ -n "$CLAUDE_PID" ]] && wait "$CLAUDE_PID" 2>/dev/null
  [[ -n "$STREAM_PID" ]] && wait "$STREAM_PID" 2>/dev/null
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fullsend-claude "$1" >"$FIFO" 2>>"$STDERR_LOG" &
CLAUDE_PID=$!
python3 -u "$CI_SCRIPTS/stream-claude.py" --claude-pid "$CLAUDE_PID" <"$FIFO" &
STREAM_PID=$!

set +e
wait "$STREAM_PID"
stream_rc=$?
STREAM_PID=""
if kill -0 "$CLAUDE_PID" 2>/dev/null; then
  echo "--- Fullsend Claude child still runs after stream closed; terminating it ---" >&2
  kill -TERM "$CLAUDE_PID" 2>/dev/null
fi
wait "$CLAUDE_PID"
claude_rc=$?
CLAUDE_PID=""
set -e

rc="$claude_rc"
if [[ "$stream_rc" -eq 42 && ( "$claude_rc" -eq 143 || "$claude_rc" -eq 141 ) ]]; then
  echo "--- FULL RUN COMPLETE: Claude terminated by the source pipeline marker ---"
  rc=0
elif [[ "$stream_rc" -ne 0 ]]; then
  echo "ERROR: Claude stream parser exited with status $stream_rc" >&2
  rc="$stream_rc"
elif [[ "$claude_rc" -ne 0 ]]; then
  echo "ERROR: Fullsend Claude child exited with status $claude_rc" >&2
fi

sleep 7
if [[ -s "$STDERR_LOG" ]]; then
  echo "--- Claude stderr ---" >&2
  cat "$STDERR_LOG" >&2
fi
exit "$rc"
