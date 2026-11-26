#!/bin/bash
# Move the bundled web search's SearXNG pin (SEARXNG_VERSION, SEARXNG_IMAGE in versions.env) to the
# newest dated release of SearXNG's own image on Docker Hub (tags <year>.<month>.<day>-<commit>,
# never "latest"). SearXNG releases about every day and parses web pages from the internet, so its
# fixes reach machines only when this pin moves. Never moves back. The new pin is the image index's
# digest (as `podman pull` by tag would get), checked to be an index with a linux/amd64 image whose
# revision label is the tag's commit. Writes a pull request description to the given file. Exit 0
# with nothing changed when the pin is already the newest.
# Usage: scripts/searxng-update.sh pr-body.md
# SEARXNG_TAGS_URL replaces Docker Hub's tag list (for tests).
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

# The newest dated tag in the list's first page (sorted by last update, so the newest are there).
new="$(curl -fsSL --proto =https --proto-redir =https --retry 3 "$tags_url" \
  | jq -r '.results[].name' | grep -E "$tag_re" | sort -V | tail -n 1 || true)"
[ -n "$new" ] || { echo "no dated SearXNG tag found at $tags_url" >&2; exit 1; }
# Dates sort as versions (2026.11.9 < 2026.11.23); the commit part only breaks a tie.
if [ "$new" = "$old" ] || [ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n 1)" = "$old" ]; then
  echo "SearXNG is on the newest dated release: $old"; exit 0
fi

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
| \`SEARXNG_IMAGE\` | \`$repo@$digest\` (the image index; its linux/amd64 image says it was built from \`${rev:0:12}\`) |

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
