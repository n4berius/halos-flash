#!/bin/bash
# build.sh resolves the Fedora base once to repository@digest, builds every stage on it and
# records it (#121). Fakes skopeo, podman and git; builds nothing.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/src/scripts"
cp "$repo/scripts/build.sh" "$repo/scripts/build-helpers.sh" "$repo/scripts/image-ref.sh" "$work/src/scripts/"
cp "$repo/versions.env" "$repo/Containerfile.helpers" "$work/src/"
mkdir -p "$work/src/src"; cp -r "$repo/src/caddy" "$repo/src/dashboard-nodump.c" "$work/src/src/"
printf '#!/bin/bash\necho record\n' > "$work/src/scripts/build-info.sh"
a="sha256:$(printf 'a%.0s' {1..64})"; b="sha256:$(printf 'b%.0s' {1..64})"
cat > "$work/bin/skopeo" <<FAKE
#!/bin/bash
echo "\$*" > "$work/asked"
case "\$*" in *@$b*) echo "$b <no value>" ;; *) echo "$a 45.20261120.0" ;; esac
FAKE
# The fake podman logs the OS build's arguments; for the helpers' build (--output) it writes
# their tree and logs the arguments apart.
cat > "$work/bin/podman" <<FAKE
#!/bin/bash
for a in "\$@"; do case "\$a" in type=local,dest=*) dest="\${a#type=local,dest=}" ;; esac; done
if [ -n "\${dest:-}" ]; then
  printf '%s\n' "\$@" > "$work/podman-helpers"
  for f in bf16-to-hgn/bf16-to-hgn bf16-to-hgn/licenses/LICENSE-MIT bf16-to-hgn/licenses/LICENSE-APACHE \
    bf16-to-hgn/licenses/native/LICENSE bf16-to-hgn/licenses/native/NOTICE dashboard/halogen-dashboard \
    dashboard/dashboard-nodump.so dashboard/licenses/crates.txt caddy/caddy caddy/licenses/modules.txt \
    caddy/licenses/go-LICENSE bf16-to-hgn/toolchain.txt dashboard/toolchain.txt caddy/toolchain.txt; do
    mkdir -p "\$dest/\$(dirname "\$f")"; echo x > "\$dest/\$f"
  done
else
  printf '%s\n' "\$@" > "$work/podman"
fi
FAKE
# shellcheck disable=SC2016 # the fake's own $1
printf '#!/bin/bash\ncase "$1" in rev-parse) echo 0123abc ;; esac\n' > "$work/bin/git"
chmod +x "$work"/bin/* "$work/src/scripts/"*
# Without the release job's settings (HALOGEN_VARIANT=no-npu would name another record file).
build() { sed -i "s|^FEDORA_BOOTC_IMAGE=.*|FEDORA_BOOTC_IMAGE=$1|" "$work/src/versions.env"; env -u HALOGEN_VARIANT -u KERNEL_TRACK -u IMAGE_TAG -u IMAGE_NAME -u HALOS_RELEASE -u HALOS_HELPERS PATH="$work/bin:$PATH" "$work/src/scripts/build.sh" > "$work/out" 2>&1; }
has() { grep -qxF -- "$1" "$work/podman" || { echo "podman wasn't given: $1" >&2; cat "$work/podman" >&2; exit 1; }; }

build quay.io/fedora/fedora-bootc:45
has "FEDORA_BOOTC_IMAGE=quay.io/fedora/fedora-bootc@$a"
has "io.github.n4berius.halos.base=quay.io/fedora/fedora-bootc@$a"
has "HALOS_BASE_VERSION=45.20261120.0"
has "HALOS_SOURCE_COMMIT=0123abc"
grep -qxF "FEDORA_BOOTC_IMAGE=quay.io/fedora/fedora-bootc@$a" "$work/podman-helpers" \
  || { echo "the helpers weren't built on the same digest" >&2; exit 1; }
grep -q -- "--build-context" "$work/podman" || { echo "the OS build didn't get the helpers" >&2; exit 1; }
grep -q "docker://quay.io/fedora/fedora-bootc:45" "$work/asked"
grep -q '^record$' "$work/src/output/build-info-npu-fedora.txt"
build "registry.example:5000/fedora/fedora-bootc:45"
has "FEDORA_BOOTC_IMAGE=registry.example:5000/fedora/fedora-bootc@$a"
echo "ok: a tag is resolved to the digest every stage gets, and recorded with the base's version and the commit"

build "quay.io/fedora/fedora-bootc@$b"
has "FEDORA_BOOTC_IMAGE=quay.io/fedora/fedora-bootc@$b"
has "HALOS_BASE_VERSION=unknown"
build "quay.io/fedora/fedora-bootc:45@$b"
grep -q "docker://quay.io/fedora/fedora-bootc@$b" "$work/asked"
has "FEDORA_BOOTC_IMAGE=quay.io/fedora/fedora-bootc@$b"
if build "quay.io/fedora/fedora-bootc@sha256:$(printf 'c%.0s' {1..64})"; then echo "a digest the registry didn't answer with was used" >&2; exit 1; fi
grep -q "answered with $a" "$work/out"
echo "ok: a pinned digest is used as is (also beside a tag), and refused when the registry answers with another"
