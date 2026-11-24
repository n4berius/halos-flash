#!/bin/bash
# Print the release channels a release tag should move, most stable first.
# Usage: scripts/channels.sh v0.20.7-2-alpha [file with one tag per line; default: git tags]
#        scripts/channels.sh --sort [alpha|beta|rc|stable] [file]
#   --sort prints the release tags in the file oldest first, only those at least that stable
#   (default: all). next-tag.sh and refresh.yml use it, so every script orders tags one way.
#
# Tags are v<Halogen version>-<halOS number>-<stage> since November 2026 (v0.20.7-1-stable,
# v0.20.7-2-alpha). The halOS number counts up per Halogen version across every stage, so a new
# halOS feature can ship as an alpha after a stable release of the same Halogen version.
# Order: Halogen version, then halOS number, then stage (alpha < beta < rc < stable). Old-style
# tags (v0.20.7-alpha.3, v0.20.7-rc.1, v0.20.7, v0.20.7-r2) count as halOS number 0, ordered as
# before among themselves, so every new-style tag of a Halogen version is newer than all of them.
#
# Each channel points to the newest release that is at least that stable. So a stable release also
# moves rc, beta and alpha, unless one of them already has something newer. A tag that is not the
# newest for any channel (an old release run again) moves none, so a channel never goes backwards.
# This file must stay self-contained: the workflows run main's copy from a temporary folder.
set -euo pipefail
sort_mode=0; min=alpha
if [ "${1:-}" = --sort ]; then
  sort_mode=1; shift
  case "${1:-}" in alpha|beta|rc|stable) min="$1"; shift ;; esac
  tag=""
else
  tag="${1:?usage: channels.sh <tag> [tags-file] | --sort [stage] [tags-file]}"; shift
fi
if [ -n "${1:-}" ]; then tags="$(cat "$1")"; else tags="$(git -C "$(dirname "$0")/.." tag -l 'v*')"; fi
printf '%s\n%s\n' "$tag" "$tags" | awk -v tag="$tag" -v sortmode="$sort_mode" -v min="$min" '
  function key(t,   m, s, n, h) {
    s = 3; n = 0; h = 0
    if (match(t, /^v[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*-(alpha|rc|stable)$/)) {
      split(substr(t, 2), m, /[.-]/)
      h = m[4]
      if (m[5] == "alpha") s = 0; else if (m[5] == "rc") s = 2
    } else if (match(t, /^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+|-r[0-9]+)?$/)) {
      split(substr(t, 2), m, /[.-]/)
      if (m[4] == "alpha") { s = 0; n = m[5] } else if (m[4] == "beta") { s = 1; n = m[5] }
      else if (m[4] == "rc") { s = 2; n = m[5] } else if (m[4] ~ /^r[0-9]+$/) n = substr(m[4], 2)
    } else return ""
    stage[t] = s
    return sprintf("%06d.%06d.%06d.%06d.%d.%06d", m[1], m[2], m[3], h, s, n)
  }
  NF { k = key($1); if (k != "") keys[$1] = k }
  END {
    split("alpha beta rc stable", name, " ")
    if (sortmode) {
      for (c = 0; c < 4; c++) if (name[c + 1] == min) lo = c
      for (t in keys) if (stage[t] >= lo) print keys[t], t
      exit 0
    }
    if (!(tag in keys)) { print "bad tag: " tag > "/dev/stderr"; exit 1 }
    out = ""
    for (c = 3; c >= 0; c--) {
      if (stage[tag] < c) continue
      newest = 1
      for (t in keys) if (stage[t] >= c && keys[t] > keys[tag]) newest = 0
      if (newest) out = out (out == "" ? "" : " ") name[c + 1]
    }
    print out
  }' | if [ "$sort_mode" = 1 ]; then sort | cut -d' ' -f2; else cat; fi
