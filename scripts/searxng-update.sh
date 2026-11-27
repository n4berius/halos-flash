#!/bin/bash
# Move the bundled web search's SearXNG pin (SEARXNG_VERSION, SEARXNG_IMAGE in versions.env) to the
# newest dated release of SearXNG's own image on Docker Hub (tags <year>.<month>.<day>-<commit>,
# never "latest"). SearXNG releases about every day and parses web pages from the internet, so its
# fixes reach machines only when this pin moves. Never moves back: a newer date wins, and on the same
# date only a tag pushed later than the pin's. The new pin is the image index's digest (as `podman
# pull` by tag would get), checked to be an index with a linux/amd64 image whose revision label is
# the tag's commit, to be what ghcr.io/searxng/searxng serves for the same tag (two registries), and
# that commit to be on SearXNG's master branch on GitHub; a tag dated after tomorrow is refused.
# Writes a pull request description to the given file. Exit 0 with nothing changed when the pin is
# already the newest.
# Usage: scripts/searxng-update.sh pr-body.md
# SEARXNG_TAGS_URL, SEARXNG_COMPARE_URL and SEARXNG_TODAY (YYYY-MM-DD) replace Docker Hub's tag
# list, GitHub's compare address and today's date (for tests).
set -euo pipefail
body="$1"
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
repo=docker.io/searxng/searxng
tags_url="${SEARXNG_TAGS_URL:-https://hub.docker.com/v2/repositories/searxng/searxng/tags?page_size=100&ordering=last_updated}"
tag_re='^20[0-9]{2}\.[0-9]{1,2}\.[0-9]{1,2}-[0-9a-f]{7,40}$'
old="$SEARXNG_VERSION"
[[ "$old" =~ $tag_re ]] || { echo "can't read the current pin: $old" >&2; exit 1; }

compare_url="${SEARXNG_COMPARE_URL:-https://api.github.com/repos/searxng/searxng/compare}"
fetch() { curl -fsSL --proto =https --proto-redir =https --retry 3 "$@"; }
# The list's first page (sorted by last update, so the newest are there): dated names and when each
# was pushed. Several releases share a day, and their commit part orders nothing, so a day's tags are
# ordered by push time.
list="$(fetch "$tags_url" | jq -r '.results[] | "\(.name)\t\(.last_updated // "")"' \
  | while IFS=$'\t' read -r name when; do
      if [[ "$name" =~ $tag_re ]]; then printf '%s\t%s\t%s\n' "${name%%-*}" "$when" "$name"; fi
    done | sort -t $'\t' -k1,1V -k2,2)"
new="$(tail -n 1 <<< "$list" | cut -f 3)"
[ -n "$new" ] || { echo "no dated SearXNG tag found at $tags_url" >&2; exit 1; }
day() { printf '%s\n' "${1%%-*}"; }
uptodate() { echo "SearXNG is on the newest dated release: $old"; exit 0; }
[ "$new" != "$old" ] || uptodate
# An older date never wins (2026.11.9 < 2026.11.23 as versions); on the pin's own date, only a tag
# pushed after the pin's (a pin the list no longer has counts as the newest of its day).
newer_day="$(printf '%s\n%s\n' "$(day "$old")" "$(day "$new")" | sort -V | tail -n 1)"
if [ "$(day "$new")" = "$(day "$old")" ]; then
  old_when="$(awk -F '\t' -v t="$old" '$3 == t { print $2 }' <<< "$list" | tail -n 1)"
  new_when="$(tail -n 1 <<< "$list" | cut -f 2)"
  { [ -n "$old_when" ] && [[ "$new_when" > "$old_when" ]]; } || uptodate
elif [ "$newer_day" = "$(day "$old")" ]; then
  uptodate
fi
# A date after tomorrow (UTC) is no real release: pinned, it would also stop every later update.
IFS=. read -r y m d <<< "$(day "$new")"
tag_day="$(printf '%04d-%02d-%02d' "$((10#$y))" "$((10#$m))" "$((10#$d))")"
today="${SEARXNG_TODAY:-$(date -u +%F)}"
limit="$(date -u -d "$today + 1 day" +%F)"
[[ ! "$tag_day" > "$limit" ]] || { echo "$repo:$new is dated $tag_day, after tomorrow ($limit): refused" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
skopeo inspect --retry-times 3 --raw "docker://$repo:$new" > "$work/index.json"
digest="sha256:$(sha256sum < "$work/index.json" | cut -c1-64)"
case "$(jq -r '.mediaType // empty' "$work/index.json")" in
  application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json) ;;
  *) echo "$repo:$new isn't an image index" >&2; exit 1 ;;
esac
jq -e '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")] | length > 0' "$work/index.json" > /dev/null \
  || { echo "$repo:$new has no linux/amd64 image" >&2; exit 1; }
# The image says which commit it was built from: it must be the tag's.
rev="$(skopeo inspect --retry-times 3 --override-os linux --override-arch amd64 \
  --format '{{index .Labels "org.opencontainers.image.revision"}}' "docker://$repo@$digest")"
case "$rev" in "${new##*-}"*) ;; *) echo "$repo@$digest says it was built from ${rev:-no commit}, not ${new##*-}" >&2; exit 1 ;; esac
[[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "$repo@$digest names no full commit: ${rev:0:40}" >&2; exit 1; }
# The same tag on SearXNG's other registry must be the same index: one registry's account alone
# can't choose the pin.
skopeo inspect --retry-times 3 --raw "docker://ghcr.io/searxng/searxng:$new" > "$work/ghcr.json"
ghcr="sha256:$(sha256sum < "$work/ghcr.json" | cut -c1-64)"
[ "$ghcr" = "$digest" ] || { echo "ghcr.io/searxng/searxng:$new is $ghcr, not Docker Hub's $digest" >&2; exit 1; }
# And the commit is on SearXNG's master branch on GitHub (behind it, or master itself).
status="$(fetch "$compare_url/$rev...master" | jq -r '.status // empty' || true)"
case "$status" in behind|identical) ;; *) echo "commit $rev isn't on SearXNG's master branch (GitHub says ${status:-nothing})" >&2; exit 1 ;; esac

set_pin() { sed -i "s|^$1=.*|$1=$2|" versions.env; grep -qxF "$1=$2" versions.env; }
set_pin SEARXNG_VERSION "$new"
set_pin SEARXNG_IMAGE "$repo@$digest"

cat > "$body" <<EOF
## Summary

Moves the bundled web search (\`sudo halogenctl web-search bundled\`) from SearXNG **$old** to
**$new**, the newest dated release of SearXNG's own image. Opened by the SearXNG update workflow
(\`.github/workflows/searxng-update.yml\`). SearXNG parses pages from the internet, so its fixes
matter; machines with web search on download the new image at the next start of the search after
the upgrade (about 100 MB). Machines with web search off download nothing.

| Pin | New value |
|---|---|
| \`SEARXNG_VERSION\` | \`$new\` |
| \`SEARXNG_IMAGE\` | \`$repo@$digest\` (the image index, the same on Docker Hub and ghcr.io; its linux/amd64 image says it was built from \`${rev:0:12}\`, a commit on SearXNG's master branch) |

What changed upstream: https://github.com/searxng/searxng/compare/${old##*-}...${new##*-}

## Testing

- [ ] \`tests/run.sh\` passes
- [ ] CI builds both editions, and the install test turns bundled web search on with this image
- [ ] Tested on real hardware, or noted here that it was not: not yet. On freyja after merge, with
  web search on: \`sudo halosctl upgrade\`, reboot, \`sudo halogenctl web-search\` and
  \`sudo halogenctl selftest\`

## Halogen version change

- [x] Not a version change, or \`versions.env\` and the option lists are updated

Merging stays a person's decision.
EOF
echo "SearXNG: $old -> $new ($digest)"
