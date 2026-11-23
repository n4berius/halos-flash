#!/bin/bash
# Print what went into a built OS image (#121): its labels, release.env (the pins, the Fedora
# base's digest and version, the source commit), the compilers of the build stages and every
# installed package. Read from the image itself, so it describes that exact image. Two of these,
# compared with diff, say what changed between two builds (such as two weekly rebuilds).
# Images built before #121 lack the base, the toolchains and the package file: their packages are
# read with rpm inside the image (no network). The release and refresh workflows run main's copy.
# Usage: scripts/build-info.sh <image in local storage>
set -euo pipefail
image="${1:?usage: build-info.sh <image>}"
dir="$(mktemp -d)"; ctr=""
trap 'if [ -n "$ctr" ]; then podman rm -f "$ctr" > /dev/null; fi; rm -rf "$dir"' EXIT
labels="$(podman image inspect --format '{{range $k, $v := .Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$image" \
  | grep -E '^(org\.opencontainers\.image\.|io\.github\.n4berius\.halos\.)' | sort || true)"
ctr="$(podman create "$image" /bin/true)"
for f in release.env toolchains.txt packages.txt; do
  podman cp "$ctr:/usr/share/halogen/$f" "$dir/$f" 2> /dev/null || true
done
if [ ! -s "$dir/packages.txt" ]; then
  podman run --rm --network=none --entrypoint rpm "$image" \
    -qa --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "$dir/packages.txt"
fi
echo "# halOS build record of $image"
echo "# Image ID: $(podman image inspect --format '{{.Id}}' "$image")"
echo
echo "## Labels"; printf '%s\n' "$labels"
echo
echo "## release.env"; cat "$dir/release.env" 2> /dev/null || echo "(none)"
grep -q '^HALOS_BASE_IMAGE=' "$dir/release.env" 2> /dev/null || echo "(no base digest: built before #121)"
echo
echo "## Toolchains of the build stages"; cat "$dir/toolchains.txt" 2> /dev/null || echo "(not recorded: built before #121)"
echo
echo "## Installed packages ($(wc -l < "$dir/packages.txt"))"; cat "$dir/packages.txt"
