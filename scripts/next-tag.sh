#!/bin/bash
# Work out the next release tag, so nobody types one.
# Usage: scripts/next-tag.sh alpha|rc|stable [from-main: 0|1] [tags-file] [released-file]
# tags-file lists every tag (default: git tags), used for numbering. released-file lists the
# tags that were published (default: the same), used to pick what to promote, so a tag whose
# release run failed is never promoted.
# Prints "tag=<tag>" and "source=<main or the tag it promotes>".
#
# alpha builds from main. rc and stable promote the newest release one step less stable (rc
# takes the newest alpha, stable the newest rc), so what ships is the code that was tested;
# from-main=1 builds them from main instead. There is no beta step any more (owner's decision,
# November 2026): old beta tags stay, and the beta channel follows rc and stable. Numbers count up per version:
# v0.19.0-alpha.3 after alpha.2; a second stable of 0.19.0 is v0.19.0-r2.
set -euo pipefail
cd "$(dirname "$0")/.."
release="${1:?usage: next-tag.sh alpha|rc|stable [0|1] [tags-file]}"
from_main="${2:-0}"
if [ -n "${3:-}" ]; then tags="$(cat "$3")"; else tags="$(git tag -l 'v*')"; fi
if [ -n "${4:-}" ]; then released="$(cat "$4")"; else released="$tags"; fi
case "$release" in
  alpha) lower=""; from_main=1 ;;
  beta) echo "beta releases are no longer made: release an rc, which promotes the newest alpha" >&2; exit 1 ;;
  rc) lower=alpha ;;
  stable) lower=rc ;;
  *) echo "unknown release: $release (alpha, rc or stable)" >&2; exit 1 ;;
esac

if [ "$from_main" = 1 ]; then
  # shellcheck source=versions.env
  version="$(. ./versions.env; echo "$HALOGEN_VERSION")"
  source=main
else
  # Within one channel sort -V orders tags correctly (it is only wrong across channels).
  source="$(printf '%s\n' "$released" | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+-$lower\.[0-9]+$" | sort -V | tail -n 1 || true)"
  [ -n "$source" ] || { echo "there is no published $lower release to promote to $release yet; build it from main instead" >&2; exit 1; }
  version="${source#v}"; version="${version%%-*}"
fi

# Highest number used so far for this version and channel, then one more.
next() { printf '%s\n' "$tags" | sed -nE "s/^v${version//./\\.}-$1([0-9]+)$/\\1/p" | sort -n | tail -n 1; }
if [ "$release" = stable ]; then
  if ! printf '%s\n' "$tags" | grep -qx "v$version"; then tag="v$version"
  else n="$(next r)"; tag="v$version-r$(( ${n:-1} + 1 ))"; fi
else
  n="$(next "$release\\.")"; tag="v$version-$release.$(( ${n:-0} + 1 ))"
fi
echo "tag=$tag"
echo "source=$source"
