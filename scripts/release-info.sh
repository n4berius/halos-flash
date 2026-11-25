#!/bin/bash
# Turn a git tag into release settings, and refuse tags that do not match versions.env.
# Usage: scripts/release-info.sh v0.20.7-1-alpha
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
tag="${1:?usage: release-info.sh <tag>}"
# New-style tags (since November 2026): v<Halogen version>-<halOS number>-<stage>. Old-style tags
# (v1.2.3-alpha.1, -beta.1, -rc.1, v1.2.3, v1.2.3-r2) are still read, for the weekly rebuild of an
# old stable release.
if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-([1-9][0-9]{0,3})-(alpha|rc|stable)$ ]]; then
  version="${BASH_REMATCH[1]}"; pre="${BASH_REMATCH[3]}"; [ "$pre" != stable ] || pre=""
  # Every new-style release has its own image tag that never moves, stable ones too.
  image_tag="${tag#v}"
elif [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-(alpha|beta|rc)\.([0-9]+)|-r([0-9]+))?$ ]]; then
  version="${BASH_REMATCH[1]}"; pre="${BASH_REMATCH[3]}"
  # An old stable release (and its -rN) was published under the plain version only.
  if [ -n "$pre" ]; then image_tag="${tag#v}"; else image_tag="$version"; fi
else
  echo "bad tag: $tag. Use v1.2.3-1-alpha, v1.2.3-1-rc or v1.2.3-1-stable (Halogen version, halOS number, stage)" >&2
  exit 1
fi
if [ "$version" != "$HALOGEN_VERSION" ]; then
  echo "tag is for Halogen $version, but versions.env pins $HALOGEN_VERSION" >&2
  exit 1
fi
echo "image_tag=$image_tag"
if [ -n "$pre" ]; then
  echo "channel=$pre"
  echo "prerelease=true"
else
  echo "channel=stable"
  echo "prerelease=false"
  # The plain Halogen version tag (0.20.7) follows stable releases and the weekly rebuild.
  echo "stable_tag=$version"
fi
echo "version=$version"
