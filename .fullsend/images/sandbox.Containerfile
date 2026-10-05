# Build with the OpenShell v0.0.116 base used by M2. This replaces runtime
# package installation and user creation from strat-pipeline's UBI9 job image.
FROM ghcr.io/nvidia/openshell-community/sandboxes/base@sha256:aeef1c63f00e2913ea002ccb3aaf925f338b5c5d70e63576f0d95c16a138044e

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates coreutils findutils git python3 python3-pip \
    && python3 -m pip install --break-system-packages PyYAML==6.0.3 \
    && rm -rf /var/lib/apt/lists/*
ENV PYTHONDONTWRITEBYTECODE=1
RUN python3 -c 'import yaml; print("PyYAML", yaml.__version__)' \
    && git --version \
    && bash --version | head -n 1
USER sandbox
