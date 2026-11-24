#!/bin/bash
# Work out the next release tag, so nobody types one.
# Usage: scripts/next-tag.sh alpha|rc|stable [from-main: 0|1] [tags-file] [released-file]
# tags-file lists every tag (default: git tags), used for numbering. released-file lists the
# tags that were published (default: the same), used to pick what to promote, so a tag whose
# release run failed is never promoted.
# Prints "tag=<tag>", "source=<main or the tag it promotes>" and "retry=<0|1>".
#
# Tags are v<Halogen version>-<halOS number>-<stage> (v0.20.7-1-stable, v0.20.7-2-alpha; owner's
# decision, November 2026). alpha builds main under the next halOS number: one more than the
# highest any tag of that Halogen version has, in any stage, published or not. It starts at 1 for
# each new Halogen version. rc and stable promote the newest published release one step less
# stable and keep its number (rc takes the newest alpha, stable the newest rc), so what ships is
# the code that was tested; from-main=1 builds them from main under the next number instead.
# There is no beta step any more: old beta tags stay, and the beta channel follows rc and stable.
#
# retry=1: the promoted tag already exists but was never published (its release run failed).
# The workflow then runs that release again on the same tag and commit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."
release="${1:?usage: next-tag.sh alpha|rc|stable [0|1] [tags-file] [released-file]}"
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
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
printf '%s\n' "$released" > "$work/released"

if [ "$from_main" = 1 ]; then
  # shellcheck source=versions.env
  version="$(. ./versions.env; echo "$HALOGEN_VERSION")"
  # Highest halOS number of this Halogen version in any tag so far, then one more.
  n="$(printf '%s\n' "$tags" | sed -nE "s/^v${version//./\\.}-([1-9][0-9]{0,3})-(alpha|rc|stable)$/\\1/p" | sort -n | tail -n 1)"
  number=$(( ${n:-0} + 1 ))
  [ "$number" -le 9999 ] || { echo "the halOS number for Halogen $version is used up (9999)" >&2; exit 1; }
  source=main
else
  # The newest published new-style release of the stage below, in the one order channels.sh uses.
  source="$("$here/channels.sh" --sort "$lower" "$work/released" | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]{0,3}-$lower$" | tail -n 1 || true)"
  [ -n "$source" ] || { echo "there is no published $lower release in the current numbering (such as v0.20.7-1-$lower) to promote to $release yet; release $([ "$lower" = alpha ] && echo "an alpha" || echo "an rc") first, or build it from main" >&2; exit 1; }
  rest="${source#v}"; version="${rest%%-*}"; rest="${rest#*-}"; number="${rest%%-*}"
fi

tag="v$version-$number-$release"
retry=0
if printf '%s\n' "$tags" | grep -qxF "$tag"; then
  if printf '%s\n' "$released" | grep -qxF "$tag"; then
    echo "$tag is already released. For something newer, release an alpha first (or $release from main)." >&2
    exit 1
  fi
  retry=1
fi
echo "tag=$tag"
echo "source=$source"
echo "retry=$retry"
