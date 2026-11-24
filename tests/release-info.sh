#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
v="$HALOGEN_VERSION"
check() { [ "$(scripts/release-info.sh "$1" | sed -n "s/^$2=//p")" = "$3" ] || { echo "$1: wrong $2" >&2; exit 1; }; }
# New-style tags: Halogen version, halOS number, stage. Each has its own image tag.
check "v$v-1-alpha" channel alpha
check "v$v-1-alpha" image_tag "$v-1-alpha"
check "v$v-1-alpha" prerelease true
check "v$v-1-alpha" stable_tag ""
check "v$v-12-rc" channel rc
check "v$v-12-rc" image_tag "$v-12-rc"
check "v$v-2-stable" channel stable
check "v$v-2-stable" prerelease false
check "v$v-2-stable" image_tag "$v-2-stable"
check "v$v-2-stable" stable_tag "$v"
# Old-style tags still parse (the weekly rebuild of an old stable release).
check "v$v-alpha.1" channel alpha
check "v$v-alpha.1" image_tag "$v-alpha.1"
check "v$v-beta.2" prerelease true
check "v$v-rc.1" channel rc
check "v$v" channel stable
check "v$v" prerelease false
check "v$v" image_tag "$v"
check "v$v-r2" image_tag "$v"
check "v$v-r2" stable_tag "$v"
for bad in "$v" "v$v-gamma.1" "v$v-alpha" "v0.0.1" "v$v-0-alpha" "v$v-1-beta" "v$v-01-rc" "v$v-1-stable.1" "v$v-1"; do
  if scripts/release-info.sh "$bad" >/dev/null 2>&1; then echo "accepted bad tag $bad" >&2; exit 1; fi
done
echo "ok: release tags are parsed, and bad or mismatched tags are refused"
