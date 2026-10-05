# CI job image: M2's validated Podman-in-k3s image plus the Fullsend CLI and
# the matching OpenShell 0.0.116 CLI/gateway binaries.
FROM golang:1.26.5-bookworm AS fullsend-build
ARG FULLSEND_REPO=https://github.com/jctanner/fullsend.git
ARG FULLSEND_FEATURE_REF=8f628aec6d113181914e2a2307fce17488e2c4b4
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --filter=blob:none "$FULLSEND_REPO" /src \
    && git -C /src checkout --detach "$FULLSEND_FEATURE_REF" \
    && cd /src && go build -trimpath -o /fullsend ./cmd/fullsend

FROM quay.io/aipcc/agentic-ci/podman@sha256:672706f01b9d7155d3e4595d7920d6608b7f462674fd1bfcaf5c80ea7e802784
USER 0
ARG OPENSHELL_SOURCE_SHA=d1155aa70042d3e2ee49dbfa15346b108b7c1d92
ARG OPENSHELL_VERSION=0.0.116
COPY --from=fullsend-build /fullsend /usr/local/bin/fullsend
RUN curl -fsSL "https://raw.githubusercontent.com/NVIDIA/OpenShell/${OPENSHELL_SOURCE_SHA}/install.sh" -o /tmp/openshell-install.sh \
    && OPENSHELL_VERSION="v${OPENSHELL_VERSION}" sh /tmp/openshell-install.sh \
    && rm -f /tmp/openshell-install.sh \
    && fullsend --help >/dev/null \
    && openshell --version | grep -F "${OPENSHELL_VERSION}"
