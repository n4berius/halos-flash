#!/bin/bash
# scripts/searxng-update.sh against a made-up Docker Hub: which tag it picks, what it writes, what it
# refuses.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/scripts" "$work/bin"
cp "$repo/scripts/searxng-update.sh" "$work/repo/scripts/"
cat > "$work/repo/versions.env" <<'EOF'
HALOGEN_VERSION=0.21.0
SEARXNG_VERSION=2026.11.23-a7163d091
SEARXNG_IMAGE=docker.io/searxng/searxng@sha256:a7fc607aa6723f5a8982105bcc5ffba4d1b9fc7c6922a31a88d6e4cba49ef12a
EOF
# Docker Hub's tag list: FAKE_TAGS, one "name [pushed]" per line (pushed defaults to a fixed time);
# GitHub's compare answer: FAKE_COMPARE (default behind), logged to compare.log.
cat > "$work/bin/curl" <<'S'
#!/bin/bash
case "$*" in
  *compare.test*) echo "${*: -1}" >> "$FAKE_LOG"; printf '{"status":"%s"}\n' "${FAKE_COMPARE-behind}" ;;
  *) printf '%s\n' "$FAKE_TAGS" | jq -R 'split(" ") | {name: .[0], last_updated: (.[1] // "2026-11-26T10:00:00Z")}' | jq -s '{results: .}' ;;
esac
S
# skopeo: the raw index (FAKE_INDEX, else an OCI index with amd64; ghcr.io's FAKE_GHCR, else the
# same), and the image's revision label.
cat > "$work/bin/skopeo" <<'S'
#!/bin/bash
case "$*" in
  *--raw*ghcr.io*) if [ -n "${FAKE_GHCR:-}" ]; then printf '%s' "$FAKE_GHCR"; else printf '%s' "$(cat "$FAKE_GOOD")"; fi ;;
  *--raw*) if [ -n "${FAKE_INDEX:-}" ]; then printf '%s' "$FAKE_INDEX"; else printf '%s' "$(cat "$FAKE_GOOD")"; fi ;;
  *--format*) echo "${FAKE_REV:-b5605b8f2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
  *) exit 1 ;;
esac
S
chmod +x "$work/bin/curl" "$work/bin/skopeo"
printf '%s' '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}' > "$work/good.json"
export FAKE_GOOD="$work/good.json"
export PATH="$work/bin:$PATH" SEARXNG_TAGS_URL=https://hub.test/tags SEARXNG_COMPARE_URL=https://compare.test \
  SEARXNG_TODAY=2026-11-26 FAKE_LOG="$work/compare.log"
run() { (cd "$work/repo" && scripts/searxng-update.sh "$work/body.md") > "$work/out" 2>&1; }
pin() { sed -n "s/^$1=//p" "$work/repo/versions.env"; }
cp "$work/repo/versions.env" "$work/before"

# "latest", odd names and older dates are skipped; the newest date wins (2026.11.9 < 2026.11.26).
FAKE_TAGS=$'latest\n2026.11.9-0123456ab\n2026.11.26-b5605b8f2\n2026.11.21-c6ee3e9fd\nnightly-b5605b8f2\n2026.11.26-b5605b8f2-arm' run \
  || { cat "$work/out" >&2; exit 1; }
[ "$(pin SEARXNG_VERSION)" = 2026.11.26-b5605b8f2 ] || { cat "$work/out" >&2; echo "picked $(pin SEARXNG_VERSION)" >&2; exit 1; }
want="sha256:$(sha256sum < "$work/good.json" | cut -c1-64)"
[ "$(pin SEARXNG_IMAGE)" = "docker.io/searxng/searxng@$want" ] || { echo "wrong image: $(pin SEARXNG_IMAGE)" >&2; exit 1; }
if ! { grep -q '\*\*2026.11.23-a7163d091\*\* to$' "$work/body.md" && grep -q 'compare/a7163d091...b5605b8f2' "$work/body.md"; }; then
  cat "$work/body.md" >&2; echo "the description doesn't name the move" >&2; exit 1
fi
grep -qx 'https://compare.test/b5605b8f2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...master' "$work/compare.log" \
  || { cat "$work/compare.log" >&2; echo "the commit wasn't checked against SearXNG's master" >&2; exit 1; }
echo "ok: the newest dated tag wins over latest, odd names and older dates; the pin is the index's digest"

# Several releases on one day: the one pushed last wins, whatever its commit; on the pin's own day
# only a tag pushed after the pin's moves it, so it never moves back.
cp "$work/before" "$work/repo/versions.env"
FAKE_TAGS=$'2026.11.26-fffffff01 2026-11-26T07:00:00Z\n2026.11.26-b5605b8f2 2026-11-26T19:00:00Z\n2026.11.26-c000000aa 2026-11-26T12:00:00Z' run \
  || { cat "$work/out" >&2; exit 1; }
[ "$(pin SEARXNG_VERSION)" = 2026.11.26-b5605b8f2 ] || { echo "picked $(pin SEARXNG_VERSION) of three the same day" >&2; exit 1; }
sed -i 's/^SEARXNG_VERSION=.*/SEARXNG_VERSION=2026.11.23-b5605b8f2/' "$work/repo/versions.env"; cp "$work/repo/versions.env" "$work/sameday"
FAKE_TAGS=$'2026.11.23-b5605b8f2 2026-11-23T19:00:00Z\n2026.11.23-fffffff01 2026-11-23T07:00:00Z' run || { cat "$work/out" >&2; exit 1; }
cmp -s "$work/sameday" "$work/repo/versions.env" || { echo "moved back to an earlier release of the same day" >&2; exit 1; }
FAKE_TAGS=$'2026.11.23-fffffff01 2026-11-23T07:00:00Z' run || { cat "$work/out" >&2; exit 1; }
cmp -s "$work/sameday" "$work/repo/versions.env" || { echo "moved to a same-day tag the list can't order against the pin" >&2; exit 1; }
FAKE_REV=0000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa FAKE_TAGS=$'2026.11.23-b5605b8f2 2026-11-23T07:00:00Z\n2026.11.23-0000000aa 2026-11-23T19:00:00Z' run \
  || { cat "$work/out" >&2; exit 1; }
[ "$(pin SEARXNG_VERSION)" = 2026.11.23-0000000aa ] || { echo "a later release of the pin's day wasn't taken" >&2; exit 1; }
echo "ok: on one day the release pushed last wins, and a same-day release never moves the pin back"

# Nothing newer, or only older: nothing changes.
cp "$work/before" "$work/repo/versions.env"
FAKE_TAGS=$'2026.11.23-a7163d091\n2026.11.20-cd6d28091' run || { cat "$work/out" >&2; exit 1; }
cmp -s "$work/before" "$work/repo/versions.env" || { echo "moved without a newer tag" >&2; exit 1; }
grep -q 'newest dated release' "$work/out"
echo "ok: nothing changes when the pin is the newest, and it never moves back"

# Refused, with nothing changed and each for its own reason: no index, no amd64 image, a revision
# that isn't the tag's, another index on ghcr.io, a commit not on master, a date after tomorrow.
cp "$work/before" "$work/repo/versions.env"
while IFS='|' read -r bad why; do
  if env "$bad" FAKE_TAGS=2026.11.26-b5605b8f2 bash -c "cd '$work/repo' && scripts/searxng-update.sh '$work/body.md'" > "$work/out" 2>&1; then
    echo "took an image with $bad" >&2; exit 1
  fi
  grep -qF -- "$why" "$work/out" || { cat "$work/out" >&2; echo "$bad was refused for another reason" >&2; exit 1; }
  cmp -s "$work/before" "$work/repo/versions.env" || { echo "$bad changed the pin" >&2; exit 1; }
done <<'L'
FAKE_INDEX={"mediaType":"application/vnd.oci.image.manifest.v1+json"}|isn't an image index
FAKE_INDEX={"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"platform":{"os":"linux","architecture":"arm64"}}]}|has no linux/amd64 image
FAKE_REV=0000000000|says it was built from 0000000000
FAKE_GHCR={"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}|not Docker Hub's
FAKE_COMPARE=diverged|isn't on SearXNG's master branch (GitHub says diverged)
FAKE_COMPARE=|isn't on SearXNG's master branch (GitHub says nothing)
SEARXNG_TODAY=2026-11-24|is dated 2026-11-26, after tomorrow (2026-11-25)
L
echo "ok: an image that isn't an index, has no amd64 image, another commit, another index on ghcr.io, a commit off master or a date after tomorrow is refused"
