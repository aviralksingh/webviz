#!/usr/bin/env bash
set -euo pipefail

#
# Build a Docker image for the static Webviz app, and optionally push it.
#
# Usage:
#   tools/docker_image/build_docker_image.sh <dockerhub-username> [tag] [--push]
#
# Examples:
#   tools/docker_image/build_docker_image.sh myuser           # build myuser/webviz:latest
#   tools/docker_image/build_docker_image.sh myuser v1.0.0    # build myuser/webviz:v1.0.0
#   tools/docker_image/build_docker_image.sh myuser --push    # build and push :latest
#   tools/docker_image/build_docker_image.sh myuser v1.0.0 --push
#
# Notes:
# - Uses Dockerfile-static-webviz in tools/docker_image/.
# - You must be logged into Docker Hub (`docker login`) before using --push.
#

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <dockerhub-username> [tag] [--push]" >&2
  exit 1
fi

DOCKERHUB_USER="$1"
shift

TAG="latest"
PUSH=false

if [[ $# -ge 1 ]]; then
  if [[ "$1" == "--push" ]]; then
    PUSH=true
  else
    TAG="$1"
    shift
    if [[ $# -ge 1 && "$1" == "--push" ]]; then
      PUSH=true
    fi
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

IMAGE_NAME="${DOCKERHUB_USER}/webviz:${TAG}"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile-static-webviz"

echo "Building Docker image '${IMAGE_NAME}' from Dockerfile-static-webviz..."
docker build -f "${DOCKERFILE}" -t "${IMAGE_NAME}" "${REPO_ROOT}"
echo "Built image ${IMAGE_NAME}"

if [[ "${PUSH}" == "true" ]]; then
  echo "Pushing Docker image '${IMAGE_NAME}' to Docker Hub..."
  docker push "${IMAGE_NAME}"
  echo "Pushed ${IMAGE_NAME}"
else
  echo "Skipping push (use --push to push to Docker Hub)."
fi

echo "You can run it with:"
echo "  docker run -p 8080:8080 ${IMAGE_NAME}"

