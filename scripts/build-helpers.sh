#!/bin/bash
# Build the helper programs the OS image carries (Containerfile.helpers: bf16-to-hgn,
# halogen-dashboard with dashboard-nodump, Caddy, tool-eval-bench) into <dir>/tree, for scripts/build.sh (#122).
# CI builds them once per run and hands the folder to all four image jobs; a local build.sh
# without HALOS_HELPERS runs this itself, so nothing changes for it.
# <dir>/inputs records what the tree was built from: the base image by digest and its version label (the OS image is
# built on that same base, so the helpers' libstdc++, libgomp and glibc are the image's), the
# pinned upstream commits and a hash of halOS's own sources for them. build.sh refuses a folder
# whose inputs differ from its checkout's.
# Usage: scripts/build-helpers.sh <dir>          build into <dir> (missing or empty)
#        scripts/build-helpers.sh --check <dir>  exit 1 unless <dir> matches this checkout
#        scripts/build-helpers.sh --resolve      print the base by digest and its version label
# HALOS_BASE=<repository@sha256:...>: build on that base, as --resolve printed it, instead of
# resolving the tag again (the ISO workflow starts the installer on it meanwhile, so both share it).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env

# The files every helper must have (paths in the tree, as the Containerfile copies them).
TREE_FILES="bf16-to-hgn/bf16-to-hgn bf16-to-hgn/licenses/LICENSE-MIT bf16-to-hgn/licenses/LICENSE-APACHE
bf16-to-hgn/licenses/native/LICENSE bf16-to-hgn/licenses/native/NOTICE dashboard/halogen-dashboard
dashboard/dashboard-nodump.so dashboard/licenses/crates.txt caddy/caddy caddy/licenses/modules.txt
caddy/licenses/go-LICENSE bf16-to-hgn/toolchain.txt dashboard/toolchain.txt caddy/toolchain.txt
tool-eval-bench/tool_eval_bench/cli/bench.py tool-eval-bench/tool_eval_bench/_version.py
tool-eval-bench/licenses/LICENSE tool-eval-bench/toolchain.txt"

inputs() { # $1: the base image by digest, $2: its version label
  local sums
  sums="$(find Containerfile.helpers src/caddy src/dashboard-nodump.c -type f -print0 | LC_ALL=C sort -z \
    | xargs -0 sha256sum | sha256sum)"
  echo "image=$FEDORA_BOOTC_IMAGE"
  echo "base=$1"
  echo "base_version=$2"
  echo "bf16_to_hgn=$BF16_TO_HGN_COMMIT"
  echo "halogen_dashboard=$HALOGEN_DASHBOARD_COMMIT"
  echo "tool_eval_bench=$TOOL_EVAL_BENCH_COMMIT $TOOL_EVAL_BENCH_VERSION"
  echo "sources=${sums%% *}"
}

# The base's repository without tag or digest (a registry's :port stays). containers/image
# refuses a reference with both a tag and a digest, so a pinned digest is asked for as
# repository@digest (#121).
BASE_REPO="${FEDORA_BOOTC_IMAGE%@*}"
case "${BASE_REPO##*/}" in *:*) BASE_REPO="${BASE_REPO%:*}" ;; esac
BASE_ASK="$FEDORA_BOOTC_IMAGE"
case "$FEDORA_BOOTC_IMAGE" in *@*) BASE_ASK="$BASE_REPO@${FEDORA_BOOTC_IMAGE##*@}" ;; esac

check() { # $1: dir
  local dir="$1" base version f
  [ -f "$dir/inputs" ] || { echo "$dir has no inputs file: build it with scripts/build-helpers.sh" >&2; return 1; }
  base="$(sed -n 's/^base=//p' "$dir/inputs")"
  version="$(sed -n 's/^base_version=//p' "$dir/inputs")"
  if ! [[ "$base" =~ ^.+@sha256:[0-9a-f]{64}$ ]] || [ "${base%@*}" != "$BASE_REPO" ]; then
    echo "$dir/inputs names an unexpected base: $base" >&2; return 1
  fi
  case "$BASE_ASK" in
    *@*) [ "$base" = "$BASE_ASK" ] || { echo "$dir was built on $base, not the pinned $BASE_ASK" >&2; return 1; } ;;
  esac
  [[ "$version" =~ ^[A-Za-z0-9._+-]+$ ]] || { echo "$dir/inputs has a bad base_version: $version" >&2; return 1; }
  if ! diff <(inputs "$base" "$version") "$dir/inputs" >&2; then
    echo "$dir was built from other inputs than this checkout's (above: < this checkout, > the folder)" >&2
    return 1
  fi
  for f in $TREE_FILES; do
    if [ -L "$dir/tree/$f" ] || [ ! -f "$dir/tree/$f" ] || [ ! -s "$dir/tree/$f" ]; then
      echo "$dir/tree/$f is missing" >&2; return 1
    fi
  done
}

# Fedora's base is a moving tag (#121): it is resolved once to the digest the helpers and every
# image built from them use, so they share one base even if the tag moves during the run.
# A digest in versions.env (repository@sha256:...) rebuilds on that exact base.
resolve() { # $1: what to ask for; sets base and version
  local ask="$1" digest=""
  version=""
  read -r digest version < <(skopeo inspect --retry-times 3 \
    --format '{{.Digest}} {{index .Labels "org.opencontainers.image.version"}}' "docker://$ask") || true
  [[ "${digest:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no digest for $ask: ${digest:-}" >&2; exit 1; }
  case "$ask" in
    *@*) [ "${ask##*@}" = "$digest" ] || { echo "$ask answered with $digest" >&2; exit 1; } ;;
  esac
  [[ "${version:-}" =~ ^[A-Za-z0-9._+-]+$ ]] || version=unknown
  base="$BASE_REPO@$digest"
}

case "${1:-}" in
  --check)
    [ "$#" = 2 ] || { echo "usage: $0 --check <dir>" >&2; exit 2; }
    check "$2"
    exit ;;
  --resolve)
    [ "$#" = 1 ] || { echo "usage: $0 --resolve" >&2; exit 2; }
    resolve "$BASE_ASK"
    echo "$base $version"
    exit ;;
esac
[ "$#" = 1 ] || { echo "usage: $0 <dir> | --check <dir> | --resolve" >&2; exit 2; }
DIR="$1"
mkdir -p "$DIR"
[ -z "$(ls -A "$DIR")" ] || { echo "$DIR is not empty" >&2; exit 1; }

if [ -n "${HALOS_BASE:-}" ]; then
  # Already resolved (--resolve): only the same repository by digest, and a pinned digest only as itself.
  if ! [[ "$HALOS_BASE" =~ ^.+@sha256:[0-9a-f]{64}$ ]] || [ "${HALOS_BASE%@*}" != "$BASE_REPO" ]; then
    echo "HALOS_BASE names an unexpected base: $HALOS_BASE" >&2; exit 1
  fi
  case "$BASE_ASK" in
    *@*) [ "$HALOS_BASE" = "$BASE_ASK" ] || { echo "HALOS_BASE $HALOS_BASE isn't the pinned $BASE_ASK" >&2; exit 1; } ;;
  esac
  resolve "$HALOS_BASE"
else
  resolve "$BASE_ASK"
fi
echo "Building the helpers on $FEDORA_BOOTC_IMAGE ($base, version $version)"

# --jobs 4: the four helper stages don't depend on each other, so they build side by side.
podman build --pull=newer --jobs 4 -f Containerfile.helpers \
  --build-arg "FEDORA_BOOTC_IMAGE=$base" \
  --build-arg "BF16_TO_HGN_COMMIT=$BF16_TO_HGN_COMMIT" \
  --build-arg "HALOGEN_DASHBOARD_COMMIT=$HALOGEN_DASHBOARD_COMMIT" \
  --build-arg "TOOL_EVAL_BENCH_COMMIT=$TOOL_EVAL_BENCH_COMMIT" \
  --build-arg "TOOL_EVAL_BENCH_VERSION=$TOOL_EVAL_BENCH_VERSION" \
  --output "type=local,dest=$DIR/tree" \
  .
inputs "$base" "$version" > "$DIR/inputs"
check "$DIR"
echo "Built the helpers into $DIR"
cat "$DIR/inputs"
