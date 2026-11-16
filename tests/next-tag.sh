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
  [ "$got" = "tag=$3 source=$4 " ] || { echo "$1 (from main $2) with ${*:5}: got '$got', expected tag=$3 source=$4" >&2; exit 1; }
}
check alpha 0 "v$v-alpha.1" main
check alpha 0 "v$v-alpha.3" main "v$v-alpha.1" "v$v-alpha.2" v0.0.1-alpha.9
check alpha 0 "v$v-alpha.11" main "v$v-alpha.10" "v$v-alpha.9"
check rc 0 "v0.18.23-rc.1" v0.18.23-alpha.3 v0.18.23-alpha.3 v0.18.23-alpha.10x v0.18.23-alpha.2
check rc 0 "v0.18.23-rc.2" v0.18.23-alpha.10 v0.18.23-alpha.10 v0.18.23-alpha.9 v0.18.23-rc.1
# An rc promotes the newest alpha, also when old betas exist (they are not promoted any more).
check rc 0 "v0.18.23-rc.1" v0.18.23-alpha.5 v0.18.23-beta.2 v0.18.23-beta.1 v0.18.23-alpha.5
check stable 0 "v0.18.23" v0.18.23-rc.1 v0.18.23-rc.1
check stable 0 "v0.18.23-r2" v0.18.23-rc.2 v0.18.23-rc.2 v0.18.23
check stable 0 "v0.18.23-r4" v0.18.23-rc.2 v0.18.23-rc.2 v0.18.23 v0.18.23-r3 v0.18.23-r2
check stable 1 "v$v" main "v$v-rc.1" v0.18.23
check rc 1 "v$v-rc.1" main "v$v-alpha.4"
check rc 0 "v0.20.0-rc.1" v0.20.0-alpha.1 v0.19.0-alpha.9 v0.20.0-alpha.1
# A tag whose release run failed (no release) is counted, but never promoted.
printf '%s\n' v0.19.0-alpha.1 v0.19.0-alpha.2 > "$work/tags"; echo v0.19.0-alpha.1 > "$work/released"
got="$(scripts/next-tag.sh rc 0 "$work/tags" "$work/released" | tr '\n' ' ')"
[ "$got" = "tag=v0.19.0-rc.1 source=v0.19.0-alpha.1 " ] || { echo "promoted an unreleased tag: $got" >&2; exit 1; }
got="$(scripts/next-tag.sh alpha 0 "$work/tags" "$work/released" | sed -n 's/^tag=//p')"
[ "$got" = "v$v-alpha.3" ] || [ "$v" != 0.19.0 ] || { echo "reused a tag number: $got" >&2; exit 1; }
for bad in "rc 0" "stable 0" "gamma 0" "beta 0" "beta 1"; do
  : > "$work/tags"
  # shellcheck disable=SC2086
  if scripts/next-tag.sh $bad "$work/tags" > /dev/null 2>&1; then echo "accepted: $bad with no tags" >&2; exit 1; fi
done
# A tag it makes from main is one the release workflow accepts.
printf '%s\n' "v$v-alpha.4" > "$work/tags"
for r in alpha stable; do
  t="$(scripts/next-tag.sh "$r" 1 "$work/tags" | sed -n 's/^tag=//p')"
  scripts/release-info.sh "$t" > /dev/null
done
echo "ok: the next tag counts up per channel, rc and stable promote the one below, and beta is refused"
