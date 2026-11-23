#!/bin/bash
# Build the helper programs the OS image carries (Containerfile.helpers: bf16-to-hgn,
# halogen-dashboard with dashboard-nodump, Caddy) into <dir>/tree, for scripts/build.sh (#122).
# CI builds them once per run and hands the folder to all four image jobs; a local build.sh
# without HALOS_HELPERS runs this itself, so nothing changes for it.
# <dir>/inputs records what the tree was built from: the base image by digest (the OS image is
# built on that same base, so the helpers' libstdc++, libgomp and glibc are the image's), the two
# pinned upstream commits and a hash of halOS's own sources for them. build.sh refuses a folder
# whose inputs differ from its checkout's.
# Usage: scripts/build-helpers.sh <dir>          build into <dir> (missing or empty)
#        scripts/build-helpers.sh --check <dir>  exit 1 unless <dir> matches this checkout
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env

# The files every helper must have (paths in the tree, as the Containerfile copies them).
TREE_FILES="bf16-to-hgn/bf16-to-hgn bf16-to-hgn/licenses/LICENSE-MIT bf16-to-hgn/licenses/LICENSE-APACHE
bf16-to-hgn/licenses/native/LICENSE bf16-to-hgn/licenses/native/NOTICE dashboard/halogen-dashboard
dashboard/dashboard-nodump.so dashboard/licenses/crates.txt caddy/caddy caddy/licenses/modules.txt
caddy/licenses/go-LICENSE"

inputs() { # $1: the base image by digest
  local sums
  sums="$(find Containerfile.helpers src/caddy src/dashboard-nodump.c -type f -print0 | LC_ALL=C sort -z \
    | xargs -0 sha256sum | sha256sum)"
  echo "image=$FEDORA_BOOTC_IMAGE"
  echo "base=$1"
  echo "bf16_to_hgn=$BF16_TO_HGN_COMMIT"
  echo "halogen_dashboard=$HALOGEN_DASHBOARD_COMMIT"
  echo "sources=${sums%% *}"
}

# The base's repository without its tag: quay.io/fedora/fedora-bootc:45 -> quay.io/fedora/fedora-bootc.
BASE_REPO="${FEDORA_BOOTC_IMAGE%:*}"

check() { # $1: dir
  local dir="$1" base f
  [ -f "$dir/inputs" ] || { echo "$dir has no inputs file: build it with scripts/build-helpers.sh" >&2; return 1; }
  base="$(sed -n 's/^base=//p' "$dir/inputs")"
  case "$base" in
    "$BASE_REPO@sha256:"*) [ "${#base}" = $(( ${#BASE_REPO} + 72 )) ] ;;
    *) false ;;
  esac || { echo "$dir/inputs names an unexpected base: $base" >&2; return 1; }
  if ! diff <(inputs "$base") "$dir/inputs" >&2; then
    echo "$dir was built from other inputs than this checkout's (above: < this checkout, > the folder)" >&2
    return 1
  fi
  for f in $TREE_FILES; do
    if [ -L "$dir/tree/$f" ] || [ ! -f "$dir/tree/$f" ] || [ ! -s "$dir/tree/$f" ]; then
      echo "$dir/tree/$f is missing" >&2; return 1
    fi
  done
}

if [ "${1:-}" = --check ]; then
  [ "$#" = 2 ] || { echo "usage: $0 --check <dir>" >&2; exit 2; }
  check "$2"
  exit
fi
[ "$#" = 1 ] || { echo "usage: $0 <dir> | --check <dir>" >&2; exit 2; }
DIR="$1"
mkdir -p "$DIR"
[ -z "$(ls -A "$DIR")" ] || { echo "$DIR is not empty" >&2; exit 1; }

# The base by digest, so the helpers and every image built from them share one base even if the
# tag moves during the run.
digest="$(skopeo inspect --retry-times 3 --format '{{.Digest}}' "docker://$FEDORA_BOOTC_IMAGE")"
case "$digest" in
  sha256:*) [ "${#digest}" = 71 ] || { echo "bad digest: $digest" >&2; exit 1; } ;;
  *) echo "bad digest: $digest" >&2; exit 1 ;;
esac
base="$BASE_REPO@$digest"
echo "Building the helpers on $FEDORA_BOOTC_IMAGE ($base)"

# --jobs 3: the three helper stages don't depend on each other, so they build side by side.
podman build --pull=newer --jobs 3 -f Containerfile.helpers \
  --build-arg "FEDORA_BOOTC_IMAGE=$base" \
  --build-arg "BF16_TO_HGN_COMMIT=$BF16_TO_HGN_COMMIT" \
  --build-arg "HALOGEN_DASHBOARD_COMMIT=$HALOGEN_DASHBOARD_COMMIT" \
  --output "type=local,dest=$DIR/tree" \
  .
inputs "$base" > "$DIR/inputs"
check "$DIR"
echo "Built the helpers into $DIR"
cat "$DIR/inputs"
