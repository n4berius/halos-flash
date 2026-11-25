#!/bin/bash
# The next release tag, against made-up tag lists (not this checkout's).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
v="$HALOGEN_VERSION"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
check() {  # release from-main expected-tag expected-source tags...
  printf '%s\n' "${@:5}" > "$work/tags"
  got="$(scripts/next-tag.sh "$1" "$2" "$work/tags" | tr '\n' ' ')"
  [ "$got" = "tag=$3 source=$4 retry=0 " ] || { echo "$1 (from main $2) with ${*:5}: got '$got', expected tag=$3 source=$4" >&2; exit 1; }
}
# alpha: the next halOS number of versions.env's Halogen version, counted over every stage.
check alpha 0 "v$v-1-alpha" main
check alpha 0 "v$v-1-alpha" main "v$v" "v$v-r2" "v$v-rc.1" "v$v-alpha.3"
check alpha 0 "v$v-2-alpha" main "v$v-1-stable" "v$v-1-rc" "v$v-1-alpha"
check alpha 0 "v$v-11-alpha" main "v$v-10-alpha" "v$v-9-stable" v0.0.1-40-alpha
check alpha 1 "v$v-4-alpha" main "v$v-3-stable" "v$v-1-alpha"
# rc and stable promote the newest published release one step down and keep its number.
check rc 0 "v0.18.23-3-rc" v0.18.23-3-alpha v0.18.23-3-alpha v0.18.23-2-alpha v0.18.23-2-rc
check rc 0 "v0.18.23-10-rc" v0.18.23-10-alpha v0.18.23-10-alpha v0.18.23-9-alpha
check rc 0 "v0.20.0-1-rc" v0.20.0-1-alpha v0.19.0-7-alpha v0.20.0-1-alpha v0.20.0-alpha.9
check stable 0 "v0.18.23-2-stable" v0.18.23-2-rc v0.18.23-2-rc v0.18.23-1-stable v0.18.23-3-alpha
# from main: the next number, straight to that stage.
check stable 1 "v$v-3-stable" main "v$v-2-alpha" "v$v-1-stable" v0.18.23-9-alpha
check rc 1 "v$v-1-rc" main "v$v-rc.4" "v$v"
# Old-style tags are never promoted: an rc needs a new-style alpha.
printf '%s\n' "v$v-alpha.3" "v$v-rc.1" > "$work/tags"
if scripts/next-tag.sh rc 0 "$work/tags" > /dev/null 2>&1; then echo "promoted an old-style alpha" >&2; exit 1; fi
if scripts/next-tag.sh stable 0 "$work/tags" > /dev/null 2>&1; then echo "promoted an old-style rc" >&2; exit 1; fi
# A tag whose release run failed (no release) is counted, but never promoted.
printf '%s\n' "v$v-1-alpha" "v$v-2-alpha" > "$work/tags"; echo "v$v-1-alpha" > "$work/released"
got="$(scripts/next-tag.sh rc 0 "$work/tags" "$work/released" | tr '\n' ' ')"
[ "$got" = "tag=v$v-1-rc source=v$v-1-alpha retry=0 " ] || { echo "promoted an unreleased tag: $got" >&2; exit 1; }
got="$(scripts/next-tag.sh alpha 0 "$work/tags" "$work/released" | sed -n 's/^tag=//p')"
[ "$got" = "v$v-3-alpha" ] || { echo "reused a tag number: $got" >&2; exit 1; }
# A promotion whose tag exists without a release (its run failed) is run again on that tag.
printf '%s\n' "v$v-1-alpha" "v$v-1-rc" > "$work/tags"; echo "v$v-1-alpha" > "$work/released"
got="$(scripts/next-tag.sh rc 0 "$work/tags" "$work/released" | tr '\n' ' ')"
[ "$got" = "tag=v$v-1-rc source=v$v-1-alpha retry=1 " ] || { echo "didn't retry: $got" >&2; exit 1; }
# ...but one already released is refused.
printf '%s\n' "v$v-1-alpha" "v$v-1-rc" > "$work/released"
if scripts/next-tag.sh rc 0 "$work/tags" "$work/released" > /dev/null 2>&1; then echo "released the same rc twice" >&2; exit 1; fi
for bad in "rc 0" "stable 0" "gamma 0" "beta 0" "beta 1"; do
  : > "$work/tags"
  # shellcheck disable=SC2086
  if scripts/next-tag.sh $bad "$work/tags" > /dev/null 2>&1; then echo "accepted: $bad with no tags" >&2; exit 1; fi
done
# A tag it makes is one the release workflow accepts.
printf '%s\n' "v$v-4-alpha" > "$work/tags"
for r in alpha rc stable; do
  t="$(scripts/next-tag.sh "$r" 1 "$work/tags" | sed -n 's/^tag=//p')"
  scripts/release-info.sh "$t" > /dev/null
  [ "$(scripts/channels.sh "$t" "$work/tags")" != "" ] || { echo "$t would move no channel" >&2; exit 1; }
done
echo "ok: the next tag counts the halOS number up per Halogen version, rc and stable promote the one below, and beta is refused"
