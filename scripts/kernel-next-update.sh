#!/bin/bash
# Move kernel-next's pinned test kernel (KERNEL_NEXT_* in versions.env) to the newest plain build
# of Fedora's kernel on Koji: a release candidate's own build (0.rcN.M.<dist>) or a final release
# (M.<dist>), never a git snapshot (0.rcN.<date>g<commit>.M.<dist>, which Rawhide builds with its
# debug options on). Same Fedora dist tag as the current pin (a new one is signed with a key the
# base image may not carry yet), same kernel line or newer.
# Downloads the four packages the image swaps in and records their sha256; the image build then
# checks them again, their Fedora signature and the kernel's Secure Boot signature, and refuses a
# debug build. Writes a pull request description to the given file. Exit 0 with nothing changed
# when the pin is already the newest.
# Usage: scripts/kernel-next-update.sh pr-body.md
# KOJI_KERNEL replaces Koji's kernel folder (for tests).
set -euo pipefail
body="$1"
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
koji="${KOJI_KERNEL:-https://kojipkgs.fedoraproject.org/packages/kernel}"
packages="kernel kernel-core kernel-modules kernel-modules-core"
old="$KERNEL_NEXT_NVR"
dist="${old##*.}"
[[ "$dist" =~ ^fc[0-9]+$ ]] || { echo "can't read the dist tag of $old" >&2; exit 1; }
old_ver="${old%%-*}"

# The names in an Apache/Koji folder listing, one per line, without the trailing slash.
listing() {
  curl -fsSL --retry 3 "$1/" | grep -o 'href="[^"?/][^"]*"' | sed -e 's/^href="//' -e 's/"$//' -e 's#/$##'
}
# A sort key: version, then a final release above its release candidates, then rc and build.
key() {  # key <version> <release>
  local v="$1" r="$2" rc=999 n
  if [[ "$r" =~ ^0\.rc([0-9]+)\.([0-9]+)\.$dist$ ]]; then rc="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
  elif [[ "$r" =~ ^([0-9]+)\.$dist$ ]]; then n="${BASH_REMATCH[1]}"
  else return 1; fi
  printf '%s %03d %06d\n' "$v" "$rc" "$n"
}

best=""; best_key=""
while read -r v; do
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  # The same line as the pin or newer.
  [ "$(printf '%s\n%s\n' "$old_ver" "$v" | sort -V | head -n 1)" = "$old_ver" ] || continue
  while read -r r; do
    k="$(key "$v" "$r")" || continue
    if [ -z "$best_key" ] || { [ "$k" != "$best_key" ] && [ "$(printf '%s\n%s\n' "$best_key" "$k" | sort -V | tail -n 1)" = "$k" ]; }; then
      best="$v-$r"; best_key="$k"
    fi
  done < <(listing "$koji/$v")
done < <(listing "$koji")
[ -n "$best" ] || { echo "no plain $dist kernel build at or after $old_ver on Koji" >&2; exit 1; }
old_key="$(key "$old_ver" "${old#*-}")" || { echo "the current pin $old isn't a plain build" >&2; exit 1; }
if [ "$best" = "$old" ] || [ "$(printf '%s\n%s\n' "$old_key" "$best_key" | sort -V | tail -n 1)" = "$old_key" ]; then
  echo "kernel-next is on the newest plain build ($old); nothing to do"
  exit 0
fi

# Koji's signed copies: one key folder holding all four packages.
v="${best%%-*}"; r="${best#*-}"
signed="$koji/$v/$r/data/signed"
keydir=""
while read -r k; do
  [[ "$k" =~ ^[0-9a-f]{8}$ ]] || continue
  have="$(listing "$signed/$k/x86_64")"
  ok=1
  for p in $packages; do grep -qxF "$p-$best.x86_64.rpm" <<< "$have" || ok=0; done
  if [ "$ok" = 1 ]; then keydir="$k"; break; fi
done < <(listing "$signed")
[ -n "$keydir" ] || { echo "Koji has no signed copy of all four packages of kernel $best yet; try again later" >&2; exit 1; }
url="$signed/$keydir/x86_64"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
sums=""
for p in $packages; do
  curl -fsSL --retry 3 -o "$work/$p.rpm" "$url/$p-$best.x86_64.rpm"
  sums="$sums $p:$(sha256sum < "$work/$p.rpm" | cut -d' ' -f1)"
done
sums="${sums# }"

set_pin() { sed -i "s|^$1=.*|$1=$2|" versions.env; grep -qxF "$1=$2" versions.env; }
set_pin KERNEL_NEXT_NVR "$best"
set_pin KERNEL_NEXT_URL "$url"
set_pin KERNEL_NEXT_SHA256 "\"$sums\""

cat > "$body" <<EOF
## Summary

Moves kernel-next's test kernel from **$old** to **$best**, Fedora's newest plain build (not a
debug snapshot). Opened by the kernel-next update workflow
(\`.github/workflows/kernel-next-update.yml\`). Only the \`kernel-next\` images change; releases and
\`edge\` keep Fedora 45's own kernel.

| Pin | New value |
|---|---|
| \`KERNEL_NEXT_NVR\` | \`$best\` |
| \`KERNEL_NEXT_URL\` | Koji's signed copies (key folder \`$keydir\`) |
| \`KERNEL_NEXT_SHA256\` | the four packages' sha256, taken from that download |

The image build checks again: each package's sha256 and Fedora's signature, that it is not a debug
build, that it carries the GPU and NPU drivers, and that its Secure Boot signature checks out against
the base image's shim.

## Testing

- [ ] \`tests/run.sh\` passes
- [ ] CI builds both editions, and the kernel-next install test passes
- [ ] Tested on real hardware, or noted here that it was not: not yet. On freyja after merge:
  \`sudo halosctl upgrade\` (on kernel-next), reboot, \`sudo halogenctl selftest\`

## Halogen version change

- [x] Not a version change, or \`versions.env\` and the option lists are updated

Merging stays a person's decision.
EOF
echo "kernel-next: $old -> $best"
