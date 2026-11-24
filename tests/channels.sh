#!/bin/bash
# Which channels a release moves, against a made-up list of tags (not this checkout's).
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
check() {
  printf '%s\n' "${@:3}" > "$work/tags"
  got="$(scripts/channels.sh "$1" "$work/tags")"
  [ "$got" = "$2" ] || { echo "$1 with tags ${*:3}: moved '$got', expected '$2'" >&2; exit 1; }
}
check v0.19.0-alpha.1 "alpha"                        v0.18.23 v0.18.23-alpha.3
check v0.19.0-beta.1  "beta alpha"                   v0.18.23 v0.19.0-alpha.1
check v0.19.0-rc.1    "rc beta alpha"                v0.19.0-alpha.2 v0.19.0-beta.1
check v0.19.0         "stable rc beta alpha"         v0.19.0-rc.1 v0.19.0-alpha.3
check v0.19.0         "stable rc beta"               v0.19.0-rc.1 v0.19.1-alpha.1
check v0.19.0-r2      "stable rc beta alpha"         v0.19.0 v0.19.0-rc.1
check v0.19.1-alpha.1 "alpha"                        v0.19.0
check v0.19.0-alpha.3 ""                             v0.19.0-alpha.4 v0.19.0-beta.1
check v0.18.23        ""                             v0.19.0
check v0.19.0-beta.2  ""                             v0.19.0-beta.10 v0.18.23   # 10 is newer than 2
check v0.19.0-beta.11 "beta alpha"                   v0.19.0-beta.10 v0.19.0-alpha.9 junk v1.0
check v0.19.0-rc.1    "rc beta alpha"                # the tag is not created yet on a manual run
# New-style tags (v<Halogen>-<halOS number>-<stage>): every one is newer than the old-style tags
# of its Halogen version, and the halOS number counts before the stage.
check v0.20.7-1-alpha "alpha"                        v0.20.7 v0.20.7-r2 v0.20.7-rc.1 v0.20.7-alpha.3
check v0.20.7-1-stable "stable rc beta alpha"        v0.20.7 v0.20.7-r2 v0.20.7-1-rc v0.20.7-1-alpha
check v0.20.7-1-stable "stable rc beta"              v0.20.7-1-rc v0.20.7-2-alpha
check v0.20.7-2-alpha "alpha"                        v0.20.7-1-stable v0.20.7-1-rc v0.20.7-1-alpha
check v0.20.7-2-rc    "rc beta alpha"                v0.20.7-1-stable v0.20.7-2-alpha
check v0.20.7-2-rc    "rc beta"                      v0.20.7-1-stable v0.20.7-3-alpha
check v0.20.7-10-alpha "alpha"                       v0.20.7-9-stable v0.20.7-9-alpha   # 10 is newer than 9
check v0.20.7-1-alpha ""                             v0.20.7-2-alpha
check v0.20.7-1-stable ""                            v0.20.7-2-stable
check v0.20.7-3-stable "stable rc beta alpha"        v0.20.7-2-stable v0.20.7-2-alpha
check v0.20.8-1-alpha "alpha"                        v0.20.7-5-stable v0.20.7-6-alpha
check v0.20.7-6-alpha ""                             v0.20.8-1-alpha
check v0.20.7-r2      ""                             v0.20.7-1-stable
check v0.20.7-r2      "stable rc beta"               v0.20.7-1-alpha
# --sort: oldest first, only those at least the stage asked.
printf '%s\n' v0.20.7-2-alpha v0.20.7 junk v0.20.7-1-stable v0.20.6 v0.20.7-r2 v0.20.7-10-alpha v0.20.7-1-rc > "$work/tags"
got="$(scripts/channels.sh --sort stable "$work/tags" | tr '\n' ' ')"
[ "$got" = "v0.20.6 v0.20.7 v0.20.7-r2 v0.20.7-1-stable " ] || { echo "sorted stable: $got" >&2; exit 1; }
got="$(scripts/channels.sh --sort "$work/tags" | tr '\n' ' ')"
[ "$got" = "v0.20.6 v0.20.7 v0.20.7-r2 v0.20.7-1-rc v0.20.7-1-stable v0.20.7-2-alpha v0.20.7-10-alpha " ] || { echo "sorted: $got" >&2; exit 1; }
for bad in v0.19 v0.20.7-0-alpha v0.20.7-1-beta; do
  if scripts/channels.sh "$bad" "$work/tags" >/dev/null 2>&1; then echo "accepted a bad tag: $bad" >&2; exit 1; fi
done
if scripts/channels.sh v0.19 "$work/tags" >/dev/null 2>&1; then echo "accepted a bad tag" >&2; exit 1; fi
echo "ok: a release moves its channel and every less stable one, never backwards"
