#!/usr/bin/env bash
# Start an isolated job-owned Podman/OpenShell gateway, run one command, clean up.
set -Eeuo pipefail

if [[ $# -lt 2 || $1 != -- ]]; then
  echo "usage: with-openshell.sh -- <command> [args...]" >&2
  exit 2
fi
shift

ROOT="${CI_PROJECT_DIR:-$PWD}"
JOB_ID="${CI_JOB_ID:-}"
if [[ -z "$JOB_ID" || ! "$JOB_ID" =~ ^[[:alnum:]_-]+$ ]]; then
  echo "ERROR: CI_JOB_ID must uniquely identify this job" >&2
  exit 2
fi

VERSION=0.0.116
SOCKET=/run/podman/podman.sock
NAME="strat-$JOB_ID"
NETWORK="openshell-strat-$JOB_ID"
STATE="$ROOT/.fullsend-ci/$JOB_ID"
ARTIFACTS="${FULLSEND_CI_ARTIFACTS_DIR:-$ROOT/fullsend-ci-artifacts}"
SUPERVISOR_TAG="ghcr.io/nvidia/openshell/supervisor:$VERSION"
SANDBOX_TAG="localhost/strat-creator-sandbox:m4"
PODMAN_URL="unix://$SOCKET"
PODMAN_PID=""
GATEWAY_PID=""
mkdir -p "$STATE" "$ARTIFACTS" /run/podman /var/lib/containers/storage /run/containers/storage

cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  set +e
  if command -v openshell >/dev/null 2>&1; then
    openshell gateway remove "$NAME" >>"$ARTIFACTS/cleanup.log" 2>&1
  fi
  cp "$STATE/gateway.log" "$ARTIFACTS/gateway.log" 2>/dev/null
  cp "$STATE/podman.log" "$ARTIFACTS/podman.log" 2>/dev/null
  if [[ -n "$GATEWAY_PID" ]]; then
    kill -TERM "$GATEWAY_PID" 2>/dev/null
    wait "$GATEWAY_PID" 2>/dev/null
  fi
  if podman --url "$PODMAN_URL" info >/dev/null 2>&1; then
    podman --url "$PODMAN_URL" rm -af >>"$ARTIFACTS/cleanup.log" 2>&1
    podman --url "$PODMAN_URL" network rm "$NETWORK" >>"$ARTIFACTS/cleanup.log" 2>&1
    podman --url "$PODMAN_URL" ps -aq --no-trunc >"$ARTIFACTS/podman-after-cleanup.txt" 2>&1
    podman --url "$PODMAN_URL" network ls >"$ARTIFACTS/networks-after-cleanup.txt" 2>&1
    if [[ -s "$ARTIFACTS/podman-after-cleanup.txt" ]]; then
      echo "job-local Podman containers remain after cleanup" >>"$ARTIFACTS/cleanup.log"
      rc=1
    fi
    if grep -Fq "$NETWORK" "$ARTIFACTS/networks-after-cleanup.txt"; then
      echo "job-local Podman network remains after cleanup" >>"$ARTIFACTS/cleanup.log"
      rc=1
    fi
  fi
  if [[ -n "$PODMAN_PID" ]]; then
    kill -TERM "$PODMAN_PID" 2>/dev/null
    wait "$PODMAN_PID" 2>/dev/null
  fi
  cp "$STATE/gateway.log" "$ARTIFACTS/gateway.log" 2>/dev/null
  cp "$STATE/podman.log" "$ARTIFACTS/podman.log" 2>/dev/null
  rm -rf -- "$STATE"
  printf 'cleanup_exit=%s\n' "$rc" >>"$ARTIFACTS/cleanup.log"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in podman openshell openshell-gateway curl openssl; do
  command -v "$tool" >/dev/null || { echo "ERROR: required CI image tool missing: $tool" >&2; exit 127; }
done
if [[ -S "$SOCKET" ]]; then
  echo "ERROR: refusing to reuse an existing Podman socket: $SOCKET" >&2
  exit 1
fi
openshell --version | tee "$ARTIFACTS/openshell-version.txt"
if ! openshell --version | grep -Fq "$VERSION"; then
  echo "ERROR: expected OpenShell $VERSION" >&2
  exit 1
fi

cat >"$STATE/storage.conf" <<EOF
[storage]
driver = "vfs"
graphroot = "/var/lib/containers/storage"
runroot = "/run/containers/storage"
EOF
export CONTAINERS_STORAGE_CONF="$STATE/storage.conf"
: > /etc/subuid
: > /etc/subgid
chmod 0777 /run/podman
podman system service --time=0 "$PODMAN_URL" >"$STATE/podman.log" 2>&1 &
PODMAN_PID=$!
for ((attempt = 0; attempt < 30; attempt++)); do
  podman --url "$PODMAN_URL" info >/dev/null 2>&1 && break
  kill -0 "$PODMAN_PID" 2>/dev/null || { cat "$STATE/podman.log" >&2; exit 1; }
  sleep 1
done
podman --url "$PODMAN_URL" info >/dev/null || { echo "Podman API did not become ready" >&2; exit 1; }

podman --url "$PODMAN_URL" pull "$SUPERVISOR_TAG"
podman --url "$PODMAN_URL" pull ghcr.io/nvidia/openshell-community/sandboxes/base:latest
SUPERVISOR_IMAGE="$(podman --url "$PODMAN_URL" image inspect --format '{{index .RepoDigests 0}}' "$SUPERVISOR_TAG")"
BASE_IMAGE="$(podman --url "$PODMAN_URL" image inspect --format '{{index .RepoDigests 0}}' ghcr.io/nvidia/openshell-community/sandboxes/base:latest)"
podman --url "$PODMAN_URL" build --tag "$SANDBOX_TAG" --file "$ROOT/.fullsend/images/sandbox.Containerfile" "$ROOT/.fullsend/images"

mkdir -p "$STATE/jwt"
umask 077
openssl genpkey -algorithm Ed25519 -out "$STATE/jwt/signing.pem" >/dev/null 2>&1
openssl pkey -in "$STATE/jwt/signing.pem" -pubout -out "$STATE/jwt/public.pem" >/dev/null 2>&1
openssl rand -hex 16 >"$STATE/jwt/kid"
openshell-gateway generate-certs --output-dir "$STATE/pki" --server-san host.containers.internal >"$ARTIFACTS/certgen.log" 2>&1

cat >"$STATE/gateway.toml" <<EOF
[openshell]
version = 1
[openshell.gateway]
name = "$NAME"
bind_address = "0.0.0.0:17670"
health_bind_address = "0.0.0.0:17671"
compute_drivers = ["podman"]
disable_tls = true
[openshell.gateway.auth]
allow_unauthenticated_users = true
[openshell.gateway.gateway_jwt]
signing_key_path = "$STATE/jwt/signing.pem"
public_key_path = "$STATE/jwt/public.pem"
kid_path = "$STATE/jwt/kid"
gateway_id = "$NAME"
ttl_secs = 0
[openshell.drivers.podman]
socket_path = "$SOCKET"
default_image = "$BASE_IMAGE"
image_pull_policy = "missing"
network_name = "$NETWORK"
grpc_endpoint = "http://host.containers.internal:17670"
supervisor_image = "$SUPERVISOR_IMAGE"
guest_tls_ca = "$STATE/pki/ca.crt"
guest_tls_cert = "$STATE/pki/client/tls.crt"
guest_tls_key = "$STATE/pki/client/tls.key"
EOF

export XDG_CONFIG_HOME="$STATE/config" XDG_STATE_HOME="$STATE/state" XDG_DATA_HOME="$STATE/data"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME"
env -u KUBERNETES_SERVICE_HOST -u KUBERNETES_SERVICE_PORT -u KUBERNETES_PORT \
  openshell-gateway --config "$STATE/gateway.toml" >"$STATE/gateway.log" 2>&1 &
GATEWAY_PID=$!
for ((attempt = 0; attempt < 90; attempt++)); do
  curl -fsS http://127.0.0.1:17671/healthz >/dev/null 2>&1 && break
  kill -0 "$GATEWAY_PID" 2>/dev/null || { cat "$STATE/gateway.log" >&2; exit 1; }
  sleep 2
done
curl -fsS http://127.0.0.1:17671/healthz >/dev/null || { echo "OpenShell gateway health check failed" >&2; exit 1; }
openshell gateway add "http://127.0.0.1:17670" --local --name "$NAME"
openshell gateway select "$NAME"

export FULLSEND_OPENSHELL_GATEWAY_NAME="$NAME"
export FULLSEND_OPENSHELL_NETWORK_NAME="$NETWORK"
"$@"
