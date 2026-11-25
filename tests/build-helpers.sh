#!/bin/bash
# scripts/build-helpers.sh with fake skopeo and podman: the folder records its inputs, and
# --check (what build.sh runs) refuses a folder built from other inputs or missing a program (#122).
set -euo pipefail
cd "$(dirname "$0")/.."
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"
digest="sha256:$(printf '%064d' 7)"
cat > "$t/bin/skopeo" <<FAKE
#!/bin/bash
echo "$digest"
FAKE
# The fake podman writes every file of the tree into --output's dest and logs its arguments.
cat > "$t/bin/podman" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_LOG"
for a in "$@"; do case "$a" in type=local,dest=*) dest="${a#type=local,dest=}" ;; esac; done
for f in bf16-to-hgn/bf16-to-hgn bf16-to-hgn/licenses/LICENSE-MIT bf16-to-hgn/licenses/LICENSE-APACHE \
  bf16-to-hgn/licenses/native/LICENSE bf16-to-hgn/licenses/native/NOTICE dashboard/halogen-dashboard \
  dashboard/dashboard-nodump.so dashboard/licenses/crates.txt caddy/caddy caddy/licenses/modules.txt \
  caddy/licenses/go-LICENSE bf16-to-hgn/toolchain.txt dashboard/toolchain.txt caddy/toolchain.txt \
  tool-eval-bench/tool_eval_bench/cli/bench.py tool-eval-bench/tool_eval_bench/_version.py \
  tool-eval-bench/licenses/LICENSE tool-eval-bench/toolchain.txt; do mkdir -p "$dest/$(dirname "$f")"; echo x > "$dest/$f"; done
FAKE
chmod +x "$t/bin/"*
export PATH="$t/bin:$PATH" FAKE_LOG="$t/podman.log"
# shellcheck source=versions.env
. ./versions.env
base="${FEDORA_BOOTC_IMAGE%:*}@$digest"

scripts/build-helpers.sh "$t/h" > "$t/out"
if ! grep -qx "image=$FEDORA_BOOTC_IMAGE" "$t/h/inputs" || ! grep -qx "base=$base" "$t/h/inputs"; then
  echo "inputs don't name the base by tag and digest" >&2; exit 1
fi
grep -qx "FEDORA_BOOTC_IMAGE=$base" "$t/podman.log" || { echo "the helpers aren't built on the base by digest" >&2; exit 1; }
if ! grep -qx "BF16_TO_HGN_COMMIT=$BF16_TO_HGN_COMMIT" "$t/podman.log" || ! grep -qx "Containerfile.helpers" "$t/podman.log"; then
  echo "podman wasn't given the pins or Containerfile.helpers" >&2; exit 1
fi
scripts/build-helpers.sh --check "$t/h"
if scripts/build-helpers.sh "$t/h" > /dev/null 2>&1; then echo "built into a folder that isn't empty" >&2; exit 1; fi

refused() { # $1: what was changed; the folder must now be refused
  if scripts/build-helpers.sh --check "$t/c" > /dev/null 2>&1; then echo "--check passed a folder with $1" >&2; exit 1; fi
}
reset() { rm -rf "$t/c"; cp -a "$t/h" "$t/c"; }
reset; sed -i "s/^bf16_to_hgn=.*/bf16_to_hgn=$(printf '%040d' 1)/" "$t/c/inputs"; refused "another bf16-to-hgn commit"
reset; sed -i "s/^sources=.*/sources=$(printf '%064d' 1)/" "$t/c/inputs"; refused "other sources"
reset; sed -i "s|^base=.*|base=quay.io/evil/fedora-bootc@$digest|" "$t/c/inputs"; refused "another base repository"
reset; sed -i "s|^base=.*|base=${FEDORA_BOOTC_IMAGE%:*}@sha256:1|" "$t/c/inputs"; refused "a short digest"
reset; rm "$t/c/tree/caddy/caddy"; refused "no Caddy"
reset; rm "$t/c/tree/dashboard/dashboard-nodump.so"; ln -s /bin/true "$t/c/tree/dashboard/dashboard-nodump.so"; refused "a link"
reset; rm "$t/c/inputs"; refused "no inputs file"
reset; sed -i "s|^base_version=.*|base_version=a b|" "$t/c/inputs"; refused "a bad base version"
reset; sed -i "s|^image=.*|image=${FEDORA_BOOTC_IMAGE%:*}:other|" "$t/c/inputs"; refused "another base tag"
echo "ok: the helpers record their inputs, and build.sh's check refuses other ones"

# --resolve prints the base by digest, and HALOS_BASE (what iso.yml resolved once for the OS image
# and the installer) is built on as given, but only the same repository by a full digest.
[ "$(scripts/build-helpers.sh --resolve | cut -d' ' -f1)" = "$base" ] || { echo "--resolve doesn't print the base by digest" >&2; exit 1; }
HALOS_BASE="$base" scripts/build-helpers.sh "$t/r" > /dev/null
if ! grep -qx "base=$base" "$t/r/inputs" || ! grep -qx "FEDORA_BOOTC_IMAGE=$base" "$t/podman.log"; then
  echo "HALOS_BASE isn't what the helpers are built on" >&2; exit 1
fi
scripts/build-helpers.sh --check "$t/r"
for bad in "quay.io/evil/fedora-bootc@$digest" "${FEDORA_BOOTC_IMAGE%:*}@sha256:1" "$FEDORA_BOOTC_IMAGE"; do
  rm -rf "$t/r"
  if HALOS_BASE="$bad" scripts/build-helpers.sh "$t/r" > /dev/null 2>&1; then echo "HALOS_BASE=$bad was taken" >&2; exit 1; fi
done
# The answer must be the digest asked for.
cat > "$t/bin/skopeo" <<FAKE
#!/bin/bash
echo "sha256:$(printf '%064d' 8)"
FAKE
rm -rf "$t/r"
if HALOS_BASE="$base" scripts/build-helpers.sh "$t/r" > /dev/null 2>&1; then echo "a base that answered with another digest was taken" >&2; exit 1; fi
echo "ok: --resolve names the base by digest, and HALOS_BASE builds on exactly that"
