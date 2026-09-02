#!/usr/bin/env bash
# Run the functional test locally in Docker.
#
# Builds the policy sets with cfbs, builds an Ubuntu image with CFEngine
# installed via `cf-remote install --clients localhost`, and runs
# tests/functional.sh as root in a privileged container. The swap file is placed
# on a Docker volume, because swap files are not supported on the overlay root
# filesystem of a container.
#
# Requirements: cfbs, docker.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out"
image="manage-swap-test"
volume="manage-swap-test"
export SWAP_PATH="/swap/manage-swap-test/swapfile"

bash "$here/build-policies.sh"

mkdir -p "$out/docker"
cat > "$out/docker/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# sudo is needed by cf-remote even when running as root; python3 must be present
# before CFEngine is installed so its package modules can use it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      util-linux bsdutils procps ca-certificates sudo python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*
RUN pip3 install --break-system-packages --no-cache-dir cf-remote
RUN cf-remote install --clients localhost --edition community
ENV PATH="/var/cfengine/bin:${PATH}"
DOCKERFILE
docker build -q -t "$image" "$out/docker" >/dev/null

docker volume rm -f "$volume" >/dev/null 2>&1 || true
docker run --rm --privileged \
  -v "$volume:/swap" \
  -v "$out/policies:/policies:ro" \
  -v "$here/functional.sh:/functional.sh:ro" \
  -e SWAP_PATH -e POLICIES=/policies \
  "$image" bash /functional.sh
docker volume rm -f "$volume" >/dev/null 2>&1 || true
