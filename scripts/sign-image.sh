#!/bin/bash
# Sign a pushed image with cosign twice, then check both signatures (#46):
#  - keyless (GitHub's OIDC identity), recorded in Sigstore's public log, for anyone to audit;
#  - with halOS's own key (COSIGN_PRIVATE_KEY and COSIGN_PASSWORD, repository secrets), which is
#    what machines check: containers/image can only match a keyless signer by email, and
#    GitHub's workflow identity is a URI. The public half ships in the image as
#    /etc/pki/containers/halos-flash.pub and is repeated below.
# Run in a workflow job with `id-token: write`.
# Usage: scripts/sign-image.sh <pushed repo:tag> [other tags of the same image to check ...]
#        scripts/sign-image.sh --verify <repo:tag> ...   (check only, sign nothing)
#        scripts/sign-image.sh --fetch   (only download and check cosign, before anything is
#                                         pushed, so a download failure leaves no unsigned image)
# The first ref gives the digest; one signature covers every tag pointing at it, so sign the
# exact tag first and move channel tags only after, then check them with --verify.
set -euo pipefail
COSIGN_VERSION=v2.6.1
COSIGN_SHA256=064954c5d8c7e3b28188eee5b1727b31c411550bc5fefd41aa672d3c761d103a
# Who may sign: this repository's publishing workflows, on main or on a release tag.
IDENTITY='^https://github\.com/n4berius/halos-flash/\.github/workflows/(build|release|refresh)\.yml@refs/(heads/main|tags/v.+)$'
ISSUER=https://token.actions.githubusercontent.com
# The same as files/etc/pki/containers/halos-flash.pub (tests/static.sh checks they match).
PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEVLXJbN5v2XwGanVGZyWfIrmX3he8
bFysLUF3azuwIUBhmbvNzPERgxn9rDNbraHldK+i4aBedqF6TFkK7l+1vg==
-----END PUBLIC KEY-----'

verify_only=0; [ "${1:-}" != --verify ] || { verify_only=1; shift; }
fetch_only=0; [ "${1:-}" != --fetch ] || { fetch_only=1; shift; }
if [ "$fetch_only" = 1 ]; then [ $# -eq 0 ] && [ "$verify_only" = 0 ]; else [ $# -ge 1 ]; fi \
  || { echo "usage: sign-image.sh [--verify] <repo:tag> [repo:tag ...] | --fetch" >&2; exit 2; }

bin="${RUNNER_TEMP:-/tmp}/cosign-$COSIGN_VERSION"
# GitHub's download servers sometimes answer 504 for a minute or two (the stable refresh of
# 2026-11-09 failed on four in seven seconds), so retry for up to about five minutes. A stalled
# download times out (under 100 kB/s for a minute) and is retried too.
[ -f "$bin" ] || curl -fsSL --retry 8 --retry-max-time 300 --connect-timeout 30 --speed-limit 100000 --speed-time 60 -o "$bin" "https://github.com/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-amd64"
# Checked every time, not only after a download: earlier steps share this folder.
echo "$COSIGN_SHA256  $bin" | sha256sum -c --quiet - || { rm -f "$bin"; exit 1; }
[ "$fetch_only" = 0 ] || exit 0

# Before anything is signed: without the key, stop now rather than leave a half-signed image.
if [ "$verify_only" = 0 ] && { [ -z "${COSIGN_PRIVATE_KEY:-}" ] || [ -z "${COSIGN_PASSWORD:-}" ]; }; then
  echo "COSIGN_PRIVATE_KEY and COSIGN_PASSWORD are not set (repository secrets)" >&2; exit 1
fi

chmod +x "$bin"
cosign() { "$bin" "$@"; }
# cosign reads Docker's credentials file, not podman's.
[ -z "${GITHUB_TOKEN:-}" ] || echo "$GITHUB_TOKEN" | cosign login ghcr.io -u "${GITHUB_ACTOR:?}" --password-stdin

pub="${RUNNER_TEMP:-/tmp}/halos-flash.pub"; printf '%s\n' "$PUBLIC_KEY" > "$pub"
# Both signatures must be there: the keyless one (public audit) and the key one (machines).
verify() {
  cosign verify --certificate-oidc-issuer "$ISSUER" --certificate-identity-regexp "$IDENTITY" "$1" > /dev/null
  cosign verify --key "$pub" "$1" > /dev/null
}
if [ "$verify_only" = 1 ]; then
  for ref in "$@"; do verify "$ref"; echo "verified $ref"; done
  exit 0
fi

# Refs are repo:tag (what the workflows push), with no registry port.
repo="${1%:*}"
digest="$(skopeo inspect --format '{{.Digest}}' "docker://$1")"
case "$digest" in sha256:[0-9a-f]*) ;; *) echo "no digest for $1: $digest" >&2; exit 1 ;; esac
echo "Signing $repo@$digest"
cosign sign --yes "$repo@$digest"
# The key comes from the environment, never a file or the command line.
cosign sign --yes --key env://COSIGN_PRIVATE_KEY "$repo@$digest"
verify "$repo@$digest"
# Machines check through containers/image, which reads the classic "<digest>.sig" tag.
# Both signatures, keyless and key, are layers of that one tag (cosign v2's classic layout).
layers="$(skopeo inspect --raw "docker://$repo:${digest/:/-}.sig" | jq '.layers | length')" \
  || { echo "the signature is not in the .sig tag machines will read" >&2; exit 1; }
[ "${layers:-0}" -ge 2 ] || { echo "the .sig tag holds $layers signature(s), not the keyless and key ones" >&2; exit 1; }
for ref in "$@"; do verify "$ref"; echo "verified $ref"; done
