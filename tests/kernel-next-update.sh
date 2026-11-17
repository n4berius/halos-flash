#!/bin/bash
# scripts/kernel-next-update.sh against a made-up Koji: which build it picks, what it writes.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/scripts" "$work/bin" "$work/koji"
cp "$repo/scripts/kernel-next-update.sh" "$work/repo/scripts/"
cat > "$work/repo/versions.env" <<'EOF'
HALOGEN_VERSION=0.20.6
KERNEL_NEXT_NVR=7.4.0-0.rc2.19.fc46
KERNEL_NEXT_URL=https://example/old
KERNEL_NEXT_SHA256="kernel:aa kernel-core:bb kernel-modules:cc kernel-modules-core:dd"
EOF
# A Koji tree: folders hold their entries; a listing is Apache-style hrefs.
build() {  # build <version> <release> [key folder] [packages...]
  local v="$1" r="$2" k="${3:-91211fce}" d p pkgs
  shift 2; [ $# -eq 0 ] || shift
  pkgs="${*:-kernel kernel-core kernel-modules kernel-modules-core}"
  d="$work/koji/$v/$r/data/signed/$k/x86_64"
  mkdir -p "$d"
  for p in $pkgs; do echo "$p $v-$r" > "$d/$p-$v-$r.x86_64.rpm"; done
}
cat > "$work/bin/curl" <<'S'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
p="$FAKE_KOJI/${url#https://koji.test/kernel}"; p="${p%/}"
if [ -d "$p" ]; then
  echo '<html><a href="?C=N;O=D">Name</a> <a href="/packages/">Parent Directory</a>'
  for e in "$p"/*; do [ -e "$e" ] || continue; n="${e##*/}"; [ -d "$e" ] && n="$n/"; echo "<a href=\"$n\">$n</a>"; done
elif [ -f "$p" ]; then cat "$p" > "${out:-/dev/stdout}"
else echo "curl: (22) 404" >&2; exit 22; fi
S
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" FAKE_KOJI="$work/koji" KOJI_KERNEL=https://koji.test/kernel
run() { (cd "$work/repo" && scripts/kernel-next-update.sh "$work/body.md") > "$work/out" 2>&1; }
pin() { sed -n "s/^$1=//p" "$work/repo/versions.env"; }

# Snapshots (debug builds), other dist tags and older lines are skipped; the newest plain rc wins.
build 7.3.0 1.fc46
build 7.4.0 0.rc2.19.fc46
build 7.4.0 0.rc2.261111g067c5c24cef2.21.fc46
build 7.4.0 0.rc3.22.fc46
build 7.4.0 0.rc4.261118gabcdef012345.24.fc46
build 7.4.0 0.rc3.23.fc47
run || { cat "$work/out" >&2; exit 1; }
[ "$(pin KERNEL_NEXT_NVR)" = 7.4.0-0.rc3.22.fc46 ] || { cat "$work/out" >&2; echo "picked $(pin KERNEL_NEXT_NVR)" >&2; exit 1; }
[ "$(pin KERNEL_NEXT_URL)" = https://koji.test/kernel/7.4.0/0.rc3.22.fc46/data/signed/91211fce/x86_64 ]
want="$(for p in kernel kernel-core kernel-modules kernel-modules-core; do printf '%s:%s ' "$p" "$(echo "$p 7.4.0-0.rc3.22.fc46" | sha256sum | cut -d' ' -f1)"; done)"
[ "$(pin KERNEL_NEXT_SHA256)" = "\"${want% }\"" ] || { echo "wrong sums: $(pin KERNEL_NEXT_SHA256)" >&2; exit 1; }
grep -q '\*\*7.4.0-0.rc2.19.fc46\*\* to \*\*7.4.0-0.rc3.22.fc46\*\*' "$work/body.md"
echo "ok: the newest plain rc build of the same dist wins over snapshots, other dists and older lines"

# Nothing newer: nothing changes.
cp "$work/repo/versions.env" "$work/before"
run; cmp -s "$work/before" "$work/repo/versions.env"; grep -q 'nothing to do' "$work/out"
# A final release beats its release candidates; a newer line beats both.
build 7.4.0 1.fc46
run; [ "$(pin KERNEL_NEXT_NVR)" = 7.4.0-1.fc46 ]
build 7.5.0 0.rc1.1.fc46
run; [ "$(pin KERNEL_NEXT_NVR)" = 7.5.0-0.rc1.1.fc46 ]
echo "ok: nothing changes when the pin is newest; a final release, then a newer line, win"

# A build whose signed copies are missing a package isn't taken.
rm "$work/koji/7.5.0/0.rc1.1.fc46/data/signed/91211fce/x86_64/kernel-modules-7.5.0-0.rc1.1.fc46.x86_64.rpm"
build 7.5.0 0.rc2.2.fc46 91211fce kernel kernel-core
if run; then echo "took a build without all four packages" >&2; exit 1; fi
grep -q 'no signed copy of all four' "$work/out"
echo "ok: a build without all four signed packages is refused"
