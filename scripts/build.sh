#!/bin/bash
# Build an OS image, tagged with its Halogen version.
# Usage: [HALOGEN_VARIANT=npu|no-npu] scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
VARIANT="${HALOGEN_VARIANT:-npu}"
TAG="$(scripts/image-ref.sh)"
SOURCE=ghcr.io/peonist-ai/halogen-flash-server
# The halOS release this image is: HALOS_RELEASE (the release's tag, such as 0.19.0-r2), else
# the image tag, else <version>-dev.<commit> for other builds.
if [ -n "${HALOS_RELEASE:-}" ]; then RELEASE="${HALOS_RELEASE#v}"
elif [ -n "${IMAGE_TAG:-}" ] && [ "$IMAGE_TAG" != edge ]; then RELEASE="$IMAGE_TAG"
else RELEASE="$HALOGEN_VERSION-dev.$(git rev-parse --short=7 HEAD 2>/dev/null || echo local)"; fi

if [ -z "$HALOGEN_DIGEST" ]; then
  HALOGEN_DIGEST="$(skopeo inspect --format '{{.Digest}}' "docker://$SOURCE:$HALOGEN_VERSION")"
  echo "Resolved $SOURCE:$HALOGEN_VERSION to $HALOGEN_DIGEST"
fi
case "$HALOGEN_DIGEST" in
  sha256:[0-9a-f]*) [ "${#HALOGEN_DIGEST}" = 71 ] || { echo "bad digest: $HALOGEN_DIGEST" >&2; exit 1; } ;;
  *) echo "bad digest: $HALOGEN_DIGEST" >&2; exit 1 ;;
esac

podman build --pull=newer -t "$TAG" \
  --label "org.opencontainers.image.source=https://github.com/n4berius/halos-flash" \
  --label "org.opencontainers.image.version=$RELEASE" \
  --label "io.github.n4berius.halos.edition=$VARIANT" \
  --build-arg "FEDORA_BOOTC_IMAGE=$FEDORA_BOOTC_IMAGE" \
  --build-arg "HALOGEN_IMAGE=$SOURCE@$HALOGEN_DIGEST" \
  --build-arg "HALOGEN_VERSION=$HALOGEN_VERSION" \
  --build-arg "HALOGEN_VARIANT=$VARIANT" \
  --build-arg "HALOS_RELEASE=$RELEASE" \
  --build-arg "HALOGEN_SOURCE_COMMIT=$HALOGEN_SOURCE_COMMIT" \
  --build-arg "HALOGEN_CLOCK_SHA256=$HALOGEN_CLOCK_SHA256" \
  --build-arg "HALOGEN_LICENSE_SHA256=$HALOGEN_LICENSE_SHA256" \
  --build-arg "HALOGEN_NOTICES_SHA256=$HALOGEN_NOTICES_SHA256" \
  --build-arg "HALOGEN_WEIGHTS_REPO=$HALOGEN_WEIGHTS_REPO" \
  --build-arg "HALOGEN_WEIGHTS_REVISION=$HALOGEN_WEIGHTS_REVISION" \
  --build-arg "BF16_TO_HGN_COMMIT=$BF16_TO_HGN_COMMIT" \
  .
echo "Built $TAG (halOS $RELEASE) with Halogen $HALOGEN_VERSION ($HALOGEN_DIGEST)"
