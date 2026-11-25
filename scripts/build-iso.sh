#!/bin/bash
# Build the USB installer. Needs root Podman and a built OS image in root's storage.
# Usage: sudo [HALOGEN_VARIANT=npu|no-npu] scripts/build-iso.sh [installer|iso]
# installer: only the live installer image, which needs no OS image when HALOS_BASE names the base
# (scripts/build-helpers.sh --resolve), so CI builds it beside the OS image. iso: only the ISO,
# from an installer image built before. Neither: both, one after the other.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
VARIANT="${HALOGEN_VARIANT:-npu}"
TARGET="$(scripts/image-ref.sh)"
INSTALLER="localhost/halos-flash-installer:$HALOGEN_VERSION-$VARIANT"
STEP="${1:-all}"
case "$STEP" in all|installer|iso) ;; *) echo "usage: $0 [installer|iso]" >&2; exit 2 ;; esac
mkdir -p output

if [ "$STEP" != iso ]; then
  # The live installer starts from the same Fedora base as the OS image it carries (#121): the
  # digest the image records, or HALOS_BASE, which the OS image's build is then given too. Images
  # built before that label have none, and take today's base.
  if [ -n "${HALOS_BASE:-}" ]; then
    [[ "$HALOS_BASE" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "HALOS_BASE isn't a digest: $HALOS_BASE" >&2; exit 1; }
    BASE="$HALOS_BASE"
  else
    podman image exists "$TARGET" || { echo "build or pull $TARGET first" >&2; exit 1; }
    BASE="$(podman image inspect --format '{{index .Labels "io.github.n4berius.halos.base"}}' "$TARGET")"
    [[ "$BASE" =~ @sha256:[0-9a-f]{64}$ ]] || BASE="$FEDORA_BOOTC_IMAGE"
  fi
  echo "Installer base: $BASE"
  podman build --pull=newer -t "$INSTALLER" -f Containerfile.installer \
    --label "io.github.n4berius.halos.base=$BASE" --build-arg "FEDORA_BOOTC_IMAGE=$BASE" \
    --build-arg "TARGET_IMAGE=$TARGET" --build-arg "HALOGEN_VARIANT=$VARIANT" .
fi
[ "$STEP" != installer ] || exit 0

podman image exists "$TARGET" || { echo "build or pull $TARGET first" >&2; exit 1; }
if [ "$STEP" = iso ]; then
  # An installer built apart from the OS image must be on the base the OS image records.
  podman image exists "$INSTALLER" || { echo "build $INSTALLER first: $0 installer" >&2; exit 1; }
  want="$(podman image inspect --format '{{index .Labels "io.github.n4berius.halos.base"}}' "$TARGET")"
  got="$(podman image inspect --format '{{index .Labels "io.github.n4berius.halos.base"}}' "$INSTALLER")"
  if [[ "$want" =~ @sha256:[0-9a-f]{64}$ ]] && [ "$want" != "$got" ]; then
    echo "the installer was built on ${got:-an unrecorded base}, the OS image on $want" >&2; exit 1
  fi
fi

# Upstream's build, because embedding the OS needs newer support than Fedora's package.
podman run --rm --privileged --security-opt label=disable \
  -v /dev:/dev -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$PWD/output:/output" "${IMAGE_BUILDER:?pin IMAGE_BUILDER in versions.env}" \
  build --bootc-ref "$INSTALLER" --bootc-installer-payload-ref "$TARGET" \
  --bootc-default-fs xfs --output-dir /output generic-iso
find output -name '*.iso' -exec ls -lh {} +
