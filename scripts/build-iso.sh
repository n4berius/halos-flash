#!/bin/bash
# Build the USB installer. Needs root Podman and a built OS image in root's storage.
# Usage: sudo [HALOGEN_VARIANT=npu|no-npu] scripts/build-iso.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
VARIANT="${HALOGEN_VARIANT:-npu}"
TARGET="$(scripts/image-ref.sh)"
INSTALLER="localhost/halos-flash-installer:$HALOGEN_VERSION-$VARIANT"
mkdir -p output

podman image exists "$TARGET" || { echo "build or pull $TARGET first" >&2; exit 1; }
# The live installer starts from the same Fedora base as the OS image it carries (#121): the
# digest the image records. Images built before that have no label, and take today's base.
BASE="$(podman image inspect --format '{{index .Labels "io.github.n4berius.halos.base"}}' "$TARGET")"
[[ "$BASE" =~ @sha256:[0-9a-f]{64}$ ]] || BASE="$FEDORA_BOOTC_IMAGE"
echo "Installer base: $BASE"
podman build --pull=newer -t "$INSTALLER" -f Containerfile.installer \
  --build-arg "FEDORA_BOOTC_IMAGE=$BASE" \
  --build-arg "TARGET_IMAGE=$TARGET" --build-arg "HALOGEN_VARIANT=$VARIANT" .

# Upstream's build, because embedding the OS needs newer support than Fedora's package.
podman run --rm --privileged --security-opt label=disable \
  -v /dev:/dev -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$PWD/output:/output" "${IMAGE_BUILDER:?pin IMAGE_BUILDER in versions.env}" \
  build --bootc-ref "$INSTALLER" --bootc-installer-payload-ref "$TARGET" \
  --bootc-default-fs xfs --output-dir /output generic-iso
find output -name '*.iso' -exec ls -lh {} +
