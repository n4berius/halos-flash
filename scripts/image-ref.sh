#!/bin/bash
# Print the image name for an edition: 0.18.23 with the NPU, 0.18.23-no-npu without it.
# IMAGE_TAG replaces the version, such as 0.18.23-alpha.1 or edge. Without one, a test-kernel
# build (KERNEL_TRACK=next) is 0.18.23-kernel-next locally, so it never takes the plain name.
# IMAGE_NAME replaces the repository, for builds pushed to your own registry.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
case "${HALOGEN_VARIANT:-npu}" in
  npu) suffix="" ;;
  no-npu) suffix="-no-npu" ;;
  *) echo "unknown edition: $HALOGEN_VARIANT" >&2; exit 1 ;;
esac
tag="${IMAGE_TAG:-$HALOGEN_VERSION}"
if [ -z "${IMAGE_TAG:-}" ] && [ "${KERNEL_TRACK:-fedora}" = next ]; then tag="$tag-kernel-next"; fi
echo "${IMAGE_NAME:-ghcr.io/n4berius/halos-flash}:$tag$suffix"
