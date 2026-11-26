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
# Docker Hub's tag list: FAKE_TAGS, one name per line.
cat > "$work/bin/curl" <<'S'
#!/bin/bash
printf '%s\n' "$FAKE_TAGS" | jq -R . | jq -s '{results: map({name: .})}'
S
# skopeo: the raw index (FAKE_INDEX, else an OCI index with amd64), and the image's revision label.
cat > "$work/bin/skopeo" <<'S'
#!/bin/bash
case "$*" in
  *--raw*) if [ -n "${FAKE_INDEX:-}" ]; then printf '%s' "$FAKE_INDEX"; else printf '%s' "$(cat "$FAKE_GOOD")"; fi ;;
  *--format*) echo "${FAKE_REV:-b5605b8f2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
  *) exit 1 ;;
esac
S
chmod +x "$work/bin/curl" "$work/bin/skopeo"
printf '%s' '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}' > "$work/good.json"
export FAKE_GOOD="$work/good.json"
export PATH="$work/bin:$PATH" SEARXNG_TAGS_URL=https://hub.test/tags
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
echo "ok: the newest dated tag wins over latest, odd names and older dates; the pin is the index's digest"

# Nothing newer, or only older: nothing changes.
cp "$work/before" "$work/repo/versions.env"
FAKE_TAGS=$'2026.11.23-a7163d091\n2026.11.20-cd6d28091' run || { cat "$work/out" >&2; exit 1; }
cmp -s "$work/before" "$work/repo/versions.env" || { echo "moved without a newer tag" >&2; exit 1; }
grep -q 'newest dated release' "$work/out"
echo "ok: nothing changes when the pin is the newest, and it never moves back"

# Refused, with nothing changed: no index, no amd64 image, a revision that isn't the tag's.
for bad in 'FAKE_INDEX={"mediaType":"application/vnd.oci.image.manifest.v1+json"}' \
    'FAKE_INDEX={"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"platform":{"os":"linux","architecture":"arm64"}}]}' \
    'FAKE_REV=0000000000'; do
  if env "$bad" FAKE_TAGS=2026.11.26-b5605b8f2 bash -c "cd '$work/repo' && scripts/searxng-update.sh '$work/body.md'" > "$work/out" 2>&1; then
    echo "took an image with $bad" >&2; exit 1
  fi
  cmp -s "$work/before" "$work/repo/versions.env" || { echo "$bad changed the pin" >&2; exit 1; }
done
echo "ok: an image that isn't an index, has no amd64 image or another commit is refused"
