#!/bin/bash
# Build an OS image, tagged with its Halogen version.
# Usage: [HALOGEN_VARIANT=npu|no-npu] [KERNEL_TRACK=fedora|next] scripts/build.sh
# KERNEL_TRACK=next puts the test kernel versions.env names in place of Fedora 45's (the
# kernel-next images); only main's build workflow and its VM test use it.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
VARIANT="${HALOGEN_VARIANT:-npu}"
KERNEL_TRACK="${KERNEL_TRACK:-fedora}"
case "$KERNEL_TRACK" in fedora|next) ;; *) echo "unknown KERNEL_TRACK: $KERNEL_TRACK (fedora or next)" >&2; exit 1 ;; esac
export KERNEL_TRACK
TAG="$(scripts/image-ref.sh)"
SOURCE=ghcr.io/peonist-ai/halogen-flash-server
# The halOS release this image is: HALOS_RELEASE (the release's tag, such as 0.19.0-r2), else
# the image tag, else <version>-dev.<commit> for other builds.
if [ -n "${HALOS_RELEASE:-}" ]; then RELEASE="${HALOS_RELEASE#v}"
elif [ -n "${IMAGE_TAG:-}" ] && [ "$IMAGE_TAG" != edge ] && [ "$IMAGE_TAG" != kernel-next ]; then RELEASE="$IMAGE_TAG"
else RELEASE="$HALOGEN_VERSION-dev.$(git rev-parse --short=7 HEAD 2>/dev/null || echo local)"; fi
# A test-kernel build says so in its name, so halosctl version and the selftest show it.
if [ "$KERNEL_TRACK" = next ]; then RELEASE="$RELEASE-kernel-next"; fi

if [ -z "$HALOGEN_DIGEST" ]; then
  HALOGEN_DIGEST="$(skopeo inspect --format '{{.Digest}}' "docker://$SOURCE:$HALOGEN_VERSION")"
  echo "Resolved $SOURCE:$HALOGEN_VERSION to $HALOGEN_DIGEST"
fi
case "$HALOGEN_DIGEST" in
  sha256:[0-9a-f]*) [ "${#HALOGEN_DIGEST}" = 71 ] || { echo "bad digest: $HALOGEN_DIGEST" >&2; exit 1; } ;;
  *) echo "bad digest: $HALOGEN_DIGEST" >&2; exit 1 ;;
esac

# Fedora's base is a moving tag (#121): each build takes its newest image, for Fedora's fixes. The
# tag is resolved once, here, to the digest every stage then uses, and the image records it
# (release.env, a label), so two builds can say which base each had. A digest in versions.env
# (repository@sha256:…, such as a release's HALOS_BASE_IMAGE) rebuilds on that exact base; packages still come from
# Fedora's current repositories.
read -r BASE_DIGEST BASE_VERSION < <(skopeo inspect --format '{{.Digest}} {{index .Labels "org.opencontainers.image.version"}}' "docker://$FEDORA_BOOTC_IMAGE")
[[ "$BASE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no digest for $FEDORA_BOOTC_IMAGE: $BASE_DIGEST" >&2; exit 1; }
case "$FEDORA_BOOTC_IMAGE" in
  *@sha256:*) [ "${FEDORA_BOOTC_IMAGE##*@}" = "$BASE_DIGEST" ] || { echo "$FEDORA_BOOTC_IMAGE answered with $BASE_DIGEST" >&2; exit 1; } ;;
esac
[[ "${BASE_VERSION:-}" =~ ^[A-Za-z0-9._+-]+$ ]] || BASE_VERSION=unknown
# repository@digest, without the tag: podman refuses a reference with both.
BASE_REPO="${FEDORA_BOOTC_IMAGE%@*}"
case "${BASE_REPO##*/}" in *:*) BASE_REPO="${BASE_REPO%:*}" ;; esac
BASE_IMAGE="$BASE_REPO@$BASE_DIGEST"
echo "Fedora base: $BASE_IMAGE (version $BASE_VERSION)"
SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$SOURCE_COMMIT" != unknown ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then SOURCE_COMMIT="$SOURCE_COMMIT-modified"; fi

podman build --pull=newer -t "$TAG" \
  --label "org.opencontainers.image.source=https://github.com/n4berius/halos-flash" \
  --label "org.opencontainers.image.version=$RELEASE" \
  --label "io.github.n4berius.halos.edition=$VARIANT" \
  --label "io.github.n4berius.halos.kernel=$KERNEL_TRACK" \
  --label "io.github.n4berius.halos.base=$BASE_IMAGE" \
  --label "org.opencontainers.image.revision=$SOURCE_COMMIT" \
  --build-arg "FEDORA_BOOTC_IMAGE=$BASE_IMAGE" --build-arg "HALOS_BASE_VERSION=$BASE_VERSION" \
  --build-arg "HALOS_SOURCE_COMMIT=$SOURCE_COMMIT" \
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
  --build-arg "HALOGEN_DASHBOARD_COMMIT=$HALOGEN_DASHBOARD_COMMIT" \
  --build-arg "CRUN_PIN_URL=$CRUN_PIN_URL" --build-arg "CRUN_PIN_SHA256=$CRUN_PIN_SHA256" \
  --build-arg "KERNEL_TRACK=$KERNEL_TRACK" --build-arg "KERNEL_NEXT_NVR=$KERNEL_NEXT_NVR" \
  --build-arg "KERNEL_NEXT_URL=$KERNEL_NEXT_URL" --build-arg "KERNEL_NEXT_SHA256=$KERNEL_NEXT_SHA256" \
  .
echo "Built $TAG (halOS $RELEASE, kernel $KERNEL_TRACK) with Halogen $HALOGEN_VERSION ($HALOGEN_DIGEST)"
echo "on $BASE_IMAGE (Fedora base $BASE_VERSION)"
# What went into it, from the image itself: release.env, toolchains and every package.
mkdir -p output
scripts/build-info.sh "$TAG" > "output/build-info-$VARIANT-$KERNEL_TRACK.txt"
echo "Build record: output/build-info-$VARIANT-$KERNEL_TRACK.txt"
