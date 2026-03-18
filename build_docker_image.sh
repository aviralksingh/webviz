#!/usr/bin/env bash
set -euo pipefail

# Convenience wrapper to build and push a Docker image for the static Webviz app.
# Delegates to tools/docker_image/build_docker_image.sh.
#
# Usage:
#   ./build_docker_image.sh <dockerhub-username> [tag]
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/tools/docker_image/build_docker_image.sh" "$@"

