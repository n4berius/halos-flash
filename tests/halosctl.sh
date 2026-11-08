#!/bin/bash
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
# halosctl against fake bootc, skopeo, systemctl and id.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
f id 'echo "${FAKE_UID:-0}"'
# bootc status prints $FAKE/status.json; other commands are logged, and upgrade stages $FAKE/staged.json.
f bootc 'echo "bootc $*" >> "$FAKE/log"
case "$1" in
  status) cat "$FAKE/status.json" ;;
  upgrade) if [ "${2:-}" = --check ]; then
             [ -z "${FAKE_CHECK_FAILS:-}" ] || { echo "error: 403 Forbidden"; exit 1; }
             if [ -n "${FAKE_NO_UPDATE:-}" ]; then echo "No changes in: docker://x"; else echo "Update available"; fi; exit 0; fi
           [ ! -f "$FAKE/next.json" ] || cp "$FAKE/next.json" "$FAKE/status.json" ;;
  # Stages what the registry has under that name: FAKE_PUSHED_DIGEST when it moved meanwhile.
  switch) jq --arg r "$2" --arg d "${FAKE_PUSHED_DIGEST:-sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe}" ".status.staged = {image: {image: {image: \$r},
            version: \"0.19.0-beta.1\", imageDigest: \$d, timestamp: \"2026-11-06T00:00:00Z\"}}" \
            "$FAKE/status.json" > "$FAKE/s.tmp" && mv "$FAKE/s.tmp" "$FAKE/status.json" ;;
esac'
# skopeo inspect: "<digest> <edition label> <release>" for a tag; for a digest (the staged image)
# just its edition label, FAKE_STAGED_EDITION, or an error when that is unset.
f skopeo 'echo "skopeo $*" >> "$FAKE/log"; ref="${*: -1}"; ed=npu; case "$ref" in *-no-npu) ed=no-npu ;; esac
case "$ref" in
  *@sha256:*) [ -z "${FAKE_STAGED_FAILS:-}" ] || { echo "Error: network unreachable" >&2; exit 1; }; echo "${FAKE_STAGED_EDITION:-}" ;;
  *:beta|*:stable-no-npu|*:0.19.0-alpha.1|*:beta-no-npu|*:0.19.0-alpha.1-no-npu|*:0.19.0-no-npu|*:0.19.0-beta.1) printf "%s %s 0.19.0-beta.1%s\n" "sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe" "${FAKE_EDITION-$ed}" "${FAKE_LABEL_TAIL:-}" ;;
  *:edge) echo "Error: reading manifest edge: 403 Forbidden" >&2; exit 1 ;;
  *) echo "Error: manifest unknown" >&2; exit 1 ;; esac'
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *is-active*) echo "${FAKE_FETCH:-inactive}" ;; esac'
dep() { printf '{"image":{"image":{"image":"%s","transport":"registry"},"version":"%s","timestamp":"2026-11-05T16:58:48Z","imageDigest":"%s"}}' "$@"; }
host() { printf '{"status":{"booted":%s,"staged":%s,"rollback":%s,"rollbackQueued":%s}}' "$1" "${2:-null}" "${3:-null}" "${4:-false}"; }
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 0.19.0 sha256:aaa)" null \
  "$(dep ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2 0.18.23 sha256:old)" > "$work/status.json"
printf 'HALOGEN_IMAGE=img@sha256:1\nHALOGEN_VERSION=0.19.0\nHALOGEN_VARIANT=npu\n' > "$work/release.env"
export PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOS_HISTORY="$work/history" SUDO_USER=owner
# The release workflow sets HALOS_RELEASE for its build; halosctl must read only the image's file.
export HALOS_RELEASE=v9.9.9-from-outside HALOGEN_VARIANT=from-outside
ctl="$repo/files/usr/bin/halosctl"
ok() { echo "ok: $*"; }
has() { grep -qE -- "$1" "$2" || { echo "expected '$1' in $2:" >&2; cat "$2" >&2; exit 1; }; }
hasnt() { if grep -qE -- "$1" "$2"; then echo "did not expect '$1' in $2:" >&2; cat "$2" >&2; exit 1; fi; }

"$ctl" version > "$work/out"
has '^halOS 0\.19\.0, npu edition' "$work/out"; has '^Channel: +none, pinned' "$work/out"
has '^Rollback: +ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2 \(0.18.23\)' "$work/out"
has '^Next boot: +no change staged' "$work/out"
echo HALOS_RELEASE=0.19.0-alpha.1 >> "$work/release.env"
"$ctl" > "$work/out"; has '^halOS 0\.19\.0-alpha\.1,' "$work/out"
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 '0.19.0\u001b[2J' sha256:aaa)" > "$work/s.json"
cp "$work/status.json" "$work/keep.json"; cp "$work/s.json" "$work/status.json"
sed -i '/^HALOS_RELEASE/d' "$work/release.env"; "$ctl" version > "$work/out"
if grep -q $'\e' "$work/out"; then echo "an escape code from bootc status got through" >&2; exit 1; fi
has '^halOS 0\.19\.0\[2J,' "$work/out"
echo HALOS_RELEASE=0.19.0-alpha.1 >> "$work/release.env"; cp "$work/keep.json" "$work/status.json"
ok "version shows the release, edition, channel and rollback image"

if FAKE_UID=1000 "$ctl" version > "$work/out" 2>&1; then echo "ran without root" >&2; exit 1; fi
has 'sudo' "$work/out"
: > "$work/log"
if "$ctl" switch beta < /dev/null > "$work/out" 2>&1; then echo "switched without confirming" >&2; exit 1; fi
has 'add --yes' "$work/out"; hasnt 'bootc switch' "$work/log"
if "$ctl" switch gamma --yes > "$work/out" 2>&1; then echo "took an unknown channel" >&2; exit 1; fi
if "$ctl" switch rc --yes > "$work/out" 2>&1; then echo "switched to a missing image" >&2; exit 1; fi
has 'manifest unknown' "$work/out"; has 'Is there a release for it yet' "$work/out"; hasnt 'bootc switch' "$work/log"
if "$ctl" switch edge --yes > "$work/out" 2>&1; then echo "switched past a registry error" >&2; exit 1; fi
has '403 Forbidden' "$work/out"
if "$ctl" rollback --to '0.19; reboot' --yes > "$work/out" 2>&1; then echo "took a bad version" >&2; exit 1; fi
[ ! -e "$work/history" ] || { echo "history written for refused changes" >&2; exit 1; }
FAKE_UID=1000 "$ctl" --help > "$work/out"; has '^usage: halosctl' "$work/out"
: > "$work/log"; "$ctl" version > /dev/null
[ "$(grep -c '^bootc status' "$work/log")" = 1 ] || { echo "bootc status was read more than once" >&2; exit 1; }
for extra in "rollback 0.19.0-alpha.1 --yes" "upgrade now --yes" "version beta"; do
  # shellcheck disable=SC2086
  if "$ctl" $extra > "$work/out" 2>&1; then echo "ignored the extra word in: $extra" >&2; exit 1; fi
  has 'unexpected' "$work/out"
done
: > "$work/log"
if "$ctl" upgrade --reboot < /dev/null > "$work/out" 2>&1; then echo "upgraded without confirming" >&2; exit 1; fi
hasnt '^bootc upgrade$' "$work/log"; hasnt 'systemctl reboot' "$work/log"
: > "$work/log"
FAKE_NO_UPDATE=1 "$ctl" upgrade < /dev/null > "$work/out" 2>&1 || { echo "upgrade failed with nothing new" >&2; cat "$work/out" >&2; exit 1; }
has 'Already up to date' "$work/out"; hasnt 'add --yes' "$work/out"; hasnt '^bootc upgrade$' "$work/log"
if FAKE_CHECK_FAILS=1 "$ctl" upgrade --yes > "$work/out" 2>&1; then echo "a failed check passed" >&2; exit 1; fi
has '403 Forbidden' "$work/out"; has 'could not check' "$work/out"
cp "$work/status.json" "$work/keep2.json"
host "$(dep ghcr.io/n4berius/halos-flash:alpha 0.19.0-alpha.3 sha256:aaa)" \
  "$(dep ghcr.io/n4berius/halos-flash:alpha 0.19.0-alpha.4 sha256:new4)" > "$work/status.json"
FAKE_NO_UPDATE=1 "$ctl" upgrade < /dev/null > "$work/out" 2>&1
has 'already staged: .*0.19.0-alpha.4.*reboot' "$work/out"; hasnt 'Already up to date' "$work/out"
cp "$work/keep2.json" "$work/status.json"
ok "help needs no root, bootc status is read once, extra words are refused, upgrade asks first, doesn't ask when nothing is new, names a staged update, and shows a failed check"
ok "it needs root, a confirmation, a known channel and an image that exists, and shows registry errors"

"$ctl" switch beta --yes > "$work/out"
has '^bootc switch ghcr.io/n4berius/halos-flash:beta$' "$work/log"
has 'next reboot' "$work/out"; hasnt 'systemctl reboot' "$work/log"
has 'switch +ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 \(0.19.0\) -> ghcr.io/n4berius/halos-flash:beta \(0.19.0-beta.1\) +\(by owner\)' "$work/history"
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 0.19.0 sha256:aaa)" null \
  "$(dep ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2 0.18.23 sha256:old)" > "$work/base.json"
cp "$work/base.json" "$work/status.json"
FAKE_PUSHED_DIGEST=sha256:moved FAKE_LABEL_TAIL=$'\e[2J' "$ctl" switch beta --yes > "$work/out"
has 'changed in the registry' "$work/out"
if grep -q $'\e' "$work/out" "$work/history"; then echo "an escape code from a label got through" >&2; exit 1; fi
sed -i '$d' "$work/history"; cp "$work/base.json" "$work/status.json"
ok "switch beta stages the beta image, records it, and waits for a reboot; a moved tag is reported"

sed -i 's/=npu/=no-npu/' "$work/release.env"
"$ctl" switch release --yes --reboot > "$work/out"
has '^bootc switch ghcr.io/n4berius/halos-flash:stable-no-npu$' "$work/log"; has '^systemctl reboot$' "$work/log"
: > "$work/log"
cp "$work/base.json" "$work/status.json"
FAKE_FETCH=activating "$ctl" switch release --yes --reboot > "$work/out"
has 'Not rebooting' "$work/out"; hasnt '^systemctl reboot$' "$work/log"
sed -i 's/=no-npu/=npu/' "$work/release.env"
cp "$work/base.json" "$work/status.json"
ok "release means stable, the no-NPU edition keeps its suffix, and no reboot during a download"

host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 0.19.0 sha256:aaa)" null \
  "$(dep ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2 0.18.23 sha256:old)" true > "$work/status.json"
"$ctl" version > "$work/out"; has '^Next boot: +ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2 \(0.18.23\) \(rollback queued\)' "$work/out"
: > "$work/log"
if "$ctl" rollback --yes > "$work/out" 2>&1; then echo "a second rollback undid the first" >&2; exit 1; fi
has 'already queued' "$work/out"; hasnt '^bootc rollback$' "$work/log"
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 0.19.0 sha256:aaa)" \
  "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe)" \
  "$(dep ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2 0.18.23 sha256:old)" > "$work/status.json"
"$ctl" switch beta --yes > "$work/out"; has 'Already on beta' "$work/out"   # beta is staged
"$ctl" rollback --yes > "$work/out"
has 'drops the update staged for the next boot: ghcr.io/n4berius/halos-flash:beta' "$work/out"
has '^bootc rollback$' "$work/log"; has 'rollback .*-> ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2' "$work/history"
"$ctl" rollback --to 0.19.0-alpha.1 --yes > "$work/out"
has '^bootc switch ghcr.io/n4berius/halos-flash@sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe$' "$work/log"; has 'pins' "$work/out"
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 0.19.0 sha256:aaa)" > "$work/status.json"
if "$ctl" rollback --yes > "$work/out" 2>&1; then echo "rolled back to nothing" >&2; exit 1; fi
has 'no previous image' "$work/out"
ok "a queued rollback is shown and not undone by a second one; a dropped staged update is named"
ok "rollback goes to the previous image, --to pins an exact release by digest, and says when there is none"

host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
"$ctl" version > "$work/out"; has '^Channel: +beta' "$work/out"
"$ctl" upgrade --yes > "$work/out"; has 'No new update' "$work/out"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" \
  "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-rc.1 sha256:ccc)" > "$work/next.json"
"$ctl" upgrade --yes > "$work/out"; has 'next reboot' "$work/out"
has 'upgrade .*:beta \(0.19.0-beta.1\) -> ghcr.io/n4berius/halos-flash:beta \(0.19.0-rc.1\)' "$work/history"
"$ctl" version > "$work/out"; has '^Next boot: +ghcr.io/n4berius/halos-flash:beta \(0.19.0-rc.1\)' "$work/out"
"$ctl" history > "$work/out"; [ "$(wc -l < "$work/out")" = 6 ] || { cat "$work/out" >&2; exit 1; }
"$ctl" switch beta > "$work/out"; has 'Already on beta' "$work/out"
: > "$work/log"; "$ctl" upgrade --yes > "$work/out"; has 'No new update' "$work/out"
"$ctl" history > "$work/out"; [ "$(wc -l < "$work/out")" = 6 ] || { echo "an unchanged upgrade was recorded" >&2; exit 1; }
host "$(dep ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2 0.18.23 sha256:old)" > "$work/status.json"
"$ctl" switch beta --yes > /dev/null; has '^bootc switch ghcr.io/n4berius/halos-flash:beta$' "$work/log"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.2 sha256:new)" > "$work/status.json"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.2 sha256:new)" \
  "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb | sed 's/2026-11-05T16/2026-11-01T16/')" > "$work/next.json"
"$ctl" upgrade --yes > "$work/out"; has 'Warning: the staged image was built before' "$work/out"
ok "upgrade stages the channel's newest release and records it; history lists every change; an old-name install switches to halos-flash"

# npu on|off: the other edition on the same channel, or the same exact release (pinned by digest).
mkdir -p "$work/sys/bus/pci/devices/0000:c5:00.1"
export HALOGEN_SYS="$work/sys"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
: > "$work/log"
"$ctl" npu off --yes > "$work/out"
has '^bootc switch ghcr.io/n4berius/halos-flash:beta-no-npu$' "$work/log"
has 'stay in /srv/models' "$work/out"; has 'npu-off .*:beta \(0.19.0-beta.1\) -> ghcr.io/n4berius/halos-flash:beta-no-npu' "$work/history"
"$ctl" npu off --yes > "$work/out"; has 'Already the no-npu edition at the next boot' "$work/out"
# A channel switch while npu off is staged keeps the no-NPU edition.
: > "$work/log"; "$ctl" switch release --yes > /dev/null
has '^bootc switch ghcr.io/n4berius/halos-flash:stable-no-npu$' "$work/log"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
"$ctl" npu on --yes > "$work/out"; has 'Already the npu edition\.' "$work/out"
if "$ctl" npu sideways --yes > "$work/out" 2>&1; then echo "took npu sideways" >&2; exit 1; fi
if "$ctl" npu --yes > "$work/out" 2>&1; then echo "took npu with no word" >&2; exit 1; fi
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 0.19.0 sha256:aaa)" > "$work/status.json"
: > "$work/log"; "$ctl" npu off --yes > "$work/out"
has 'skopeo .*docker://ghcr.io/n4berius/halos-flash:0.19.0-alpha.1-no-npu' "$work/log"
has '^bootc switch ghcr.io/n4berius/halos-flash@sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe$' "$work/log"
# On a pinned machine npu off stages a digest, whose edition can't be read back: npu on, switch
# and rollback --to must refuse rather than guess (the IOMMU could stay off against the ask).
for again in "npu on" "npu off" "switch beta" "rollback --to 0.19.0-alpha.1"; do
  : > "$work/log"
  # shellcheck disable=SC2086
  if "$ctl" $again --yes > "$work/out" 2>&1; then echo "$again guessed the edition of a staged digest" >&2; exit 1; fi
  has 'reboot to it first' "$work/out"; hasnt 'bootc switch' "$work/log"
done
# With an edition label on the staged image, its edition is read instead of guessed.
cp "$work/status.json" "$work/pinned.json"
: > "$work/log"
FAKE_STAGED_EDITION=no-npu "$ctl" npu off --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
has 'Already the no-npu edition at the next boot' "$work/out"; hasnt 'bootc switch' "$work/log"
FAKE_STAGED_EDITION=no-npu "$ctl" switch beta --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
has '^bootc switch ghcr.io/n4berius/halos-flash:beta-no-npu$' "$work/log"
cp "$work/pinned.json" "$work/status.json"; : > "$work/log"
FAKE_STAGED_EDITION=no-npu "$ctl" npu on --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
# The staged build's own release (its version label), which the fake bootc gives every switch.
has 'skopeo .*docker://ghcr.io/n4berius/halos-flash:0.19.0-beta.1 *$' "$work/log"; has '^bootc switch ghcr.io/n4berius/halos-flash@sha256:' "$work/log"
cp "$work/pinned.json" "$work/status.json"
# A staged rollback --to to another release keeps that release when the edition changes.
host "$(dep ghcr.io/n4berius/halos-flash:0.19.1-alpha.3 0.19.1-alpha.3 sha256:aaa)" \
  "$(dep ghcr.io/n4berius/halos-flash@sha256:1111111111111111111111111111111111111111111111111111111111111111 0.19.0-alpha.1 sha256:111)" > "$work/status.json"
: > "$work/log"
FAKE_STAGED_EDITION=npu "$ctl" npu off --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
has 'skopeo .*docker://ghcr.io/n4berius/halos-flash:0.19.0-alpha.1-no-npu *$' "$work/log"
hasnt 'skopeo .*0.19.1-alpha.3-no-npu' "$work/log"
# Offline, it says so rather than blaming the image.
if FAKE_STAGED_FAILS=1 "$ctl" npu off --yes > "$work/out" 2>&1; then echo "guessed the edition offline" >&2; exit 1; fi
has 'check the network' "$work/out"
cp "$work/pinned.json" "$work/status.json"
# A tag whose image says it is the other edition is refused; an image without the label is taken.
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"; : > "$work/log"
if FAKE_EDITION=npu "$ctl" npu off --yes > "$work/out" 2>&1; then echo "switched to an image labelled the wrong edition" >&2; exit 1; fi
has 'is the npu edition in the registry, not no-npu' "$work/out"; hasnt 'bootc switch' "$work/log"
FAKE_EDITION='' "$ctl" npu off --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
has '^bootc switch ghcr.io/n4berius/halos-flash:beta-no-npu$' "$work/log"; has 'After: .*\(0\.19\.0-beta\.1\)' "$work/out"
cp "$work/pinned.json" "$work/status.json"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.2 sha256:ccc)" > "$work/status.json"
"$ctl" npu off --yes > "$work/out"; has 'Staged for the next boot, and replaced by this: ghcr.io/n4berius/halos-flash:beta \(0.19.0-beta.2\)' "$work/out"
has 'can read all of it' "$work/out"
host "$(dep ghcr.io/n4berius/halos-flash@sha256:aaa 0.19.0 sha256:aaa)" > "$work/status.json"
sed -i 's/^HALOS_RELEASE=.*/HALOS_RELEASE=0.19.1-dev.abc1234/' "$work/release.env"
host "$(dep ghcr.io/n4berius/halos-flash@sha256:aaa 0.19.1-dev.abc1234 sha256:aaa)" > "$work/status.json"
if "$ctl" npu off --yes > "$work/out" 2>&1; then echo "guessed a tag for an untagged build" >&2; exit 1; fi
has 'Follow a channel first' "$work/out"
sed -i 's/^HALOS_RELEASE=.*/HALOS_RELEASE=0.19.0-alpha.1/' "$work/release.env"
# npu on from the no-NPU edition warns on a machine with no NPU, not on one with it.
sed -i 's/=npu/=no-npu/' "$work/release.env"
host "$(dep ghcr.io/n4berius/halos-flash:beta-no-npu 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
: > "$work/log"; "$ctl" npu on --yes > "$work/out"
has '^bootc switch ghcr.io/n4berius/halos-flash:beta$' "$work/log"; has 'shows no AMD NPU' "$work/out"
printf '0x1022\n' > "$work/sys/bus/pci/devices/0000:c5:00.1/vendor"; printf '0x17f0\n' > "$work/sys/bus/pci/devices/0000:c5:00.1/device"
host "$(dep ghcr.io/n4berius/halos-flash:beta-no-npu 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
"$ctl" npu on --yes > "$work/out"; hasnt 'shows no AMD NPU' "$work/out"
sed -i 's/=no-npu/=npu/' "$work/release.env"
# A plain version tag keeps moving; a queued rollback must boot first.
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0 0.19.0 sha256:aaa)" > "$work/status.json"
: > "$work/log"; "$ctl" npu off --yes > /dev/null
has '^bootc switch ghcr.io/n4berius/halos-flash:0.19.0-no-npu$' "$work/log"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" null \
  "$(dep ghcr.io/n4berius/halos-flash:alpha 0.19.0-alpha.1 sha256:aaa)" true > "$work/status.json"
: > "$work/log"
if "$ctl" npu off --yes > "$work/out" 2>&1; then echo "npu ignored a queued rollback" >&2; exit 1; fi
has 'rollback is queued' "$work/out"; hasnt 'bootc switch' "$work/log"
ok "npu off/on switch edition on the same channel or pinned release, keep it through a later channel switch, refuse an untagged build, and warn when there is no NPU"

# power: the firmware's power profile, saved in /etc/halos and set at once by platform-profile.
acpi="$work/sys/firmware/acpi"; mkdir -p "$acpi"
export HALOS_PROFILE_FILE="$work/etc-halos/platform-profile" HALOS_PLATFORM_PROFILE="$repo/files/usr/libexec/halogen/platform-profile"
echo balanced > "$acpi/platform_profile"; echo 'low-power balanced performance' > "$acpi/platform_profile_choices"
: > "$work/log"; "$ctl" power > "$work/out"
has '^Power profile: balanced$' "$work/out"; has 'performance \(the default\)' "$work/out"; has 'They differ' "$work/out"
hasnt 'bootc' "$work/log"
"$ctl" power performance > "$work/out"
[ "$(cat "$acpi/platform_profile")" = performance ] || { echo "power did not set the profile" >&2; exit 1; }
[ "$(cat "$HALOS_PROFILE_FILE")" = performance ] || { echo "power did not save the choice" >&2; exit 1; }
has 'power +balanced -> performance' "$work/history"
"$ctl" power low-power > "$work/out"; has 'serves slower at low-power' "$work/out"
"$ctl" power low-power > "$work/out"; has '^Already low-power' "$work/out"
echo 'balanced performance' > "$acpi/platform_profile_choices"
if "$ctl" power low-power > "$work/out" 2>&1; then echo "set a profile the firmware does not offer" >&2; exit 1; fi
has 'does not offer low-power' "$work/out"
if "$ctl" power 'quiet;reboot' > "$work/out" 2>&1; then echo "took an unknown profile" >&2; exit 1; fi
if "$ctl" power balanced extra > "$work/out" 2>&1; then echo "took two profiles" >&2; exit 1; fi
[ "$(cat "$HALOS_PROFILE_FILE")" = low-power ] || { echo "a refused change was saved" >&2; exit 1; }
if FAKE_UID=1000 "$ctl" power balanced > "$work/out" 2>&1; then echo "ran without root" >&2; exit 1; fi
# At boot: the saved choice, performance when none, and a choice the firmware lacks fails loudly.
"$HALOS_PLATFORM_PROFILE" apply 2> "$work/out" && { echo "applied a profile the firmware lacks" >&2; exit 1; }
has 'not a profile this firmware offers' "$work/out"; [ "$(cat "$acpi/platform_profile")" = low-power ]
rm "$HALOS_PROFILE_FILE"; "$HALOS_PLATFORM_PROFILE" apply; [ "$(cat "$acpi/platform_profile")" = performance ]
rm "$acpi/platform_profile"; "$HALOS_PLATFORM_PROFILE" apply
if "$ctl" power > "$work/out" 2>&1; then echo "showed a profile on a machine without one" >&2; exit 1; fi
has 'offers no power profile' "$work/out"
ok "power shows, saves and sets the firmware profile at once, refuses one the firmware lacks, and boot applies the choice or performance"
