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
  # Every switch must ask for the signature check (#46), and the staged spec then has it.
  switch) [ "$2" = --enforce-container-sigpolicy ] || { echo "switch without the signature check" >&2; exit 3; }
          [ -z "${FAKE_REJECT:-}" ] || { echo "error: Source image rejected: A signature was required, but no signature exists" >&2; exit 1; }
          jq --arg r "$3" --arg d "${FAKE_PUSHED_DIGEST:-sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe}" ".status.staged = {image: {image: {image: \$r},
            version: \"0.19.0-beta.1\", imageDigest: \$d, timestamp: \"${FAKE_STAGED_TS:-2026-11-06T00:00:00Z}\"}}" \
            "$FAKE/status.json" | jq ".spec.image.signature = \"containerPolicy\"" > "$FAKE/s.tmp" && mv "$FAKE/s.tmp" "$FAKE/status.json" ;;
esac'
# skopeo inspect: "<digest> <edition label> <release>" for a tag; for a digest (the staged image)
# just its edition label, FAKE_STAGED_EDITION, or an error when that is unset.
f skopeo 'echo "skopeo $*" >> "$FAKE/log"; ref="${*: -1}"; ed=npu; case "$ref" in *-no-npu) ed=no-npu ;; esac
case "$ref" in
  *@sha256:*) [ -z "${FAKE_STAGED_FAILS:-}" ] || { echo "Error: network unreachable" >&2; exit 1; }
    case "$*" in *"{{.Digest}}"*) printf "%s %s 0.19.0-beta.1\n" "${ref#*@}" "${FAKE_STAGED_EDITION:-}" ;; *) echo "${FAKE_STAGED_EDITION:-}" ;; esac ;;
  *:beta|*:stable-no-npu|*:0.19.0-alpha.1|*:beta-no-npu|*:0.19.0-alpha.1-no-npu|*:0.19.0-no-npu|*:0.19.0-beta.1) printf "%s %s 0.19.0-beta.1%s\n" "sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe" "${FAKE_EDITION-$ed}" "${FAKE_LABEL_TAIL:-}" ;;
  *:edge) echo "Error: reading manifest edge: 403 Forbidden" >&2; exit 1 ;;
  *) echo "Error: manifest unknown" >&2; exit 1 ;; esac'
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *is-active*) echo "${FAKE_FETCH:-inactive}" ;; esac'
dep() { printf '{"image":{"image":{"image":"%s","transport":"registry"},"version":"%s","timestamp":"2026-11-05T16:58:48Z","imageDigest":"%s"}}' "$@"; }
# The image spec's signature mode: containerPolicy once the check is on, insecure on installs from before.
host() { printf '{"spec":{"image":{"signature":"%s"}},"status":{"booted":%s,"staged":%s,"rollback":%s,"rollbackQueued":%s}}' \
  "${FAKE_SIG:-containerPolicy}" "$1" "${2:-null}" "${3:-null}" "${4:-false}"; }
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 0.19.0 sha256:aaa)" null \
  "$(dep ghcr.io/n4berius/halogen-flash-bootc:0.18.23-alpha.2 0.18.23 sha256:old)" > "$work/status.json"
printf 'HALOGEN_IMAGE=img@sha256:1\nHALOGEN_VERSION=0.19.0\nHALOGEN_VARIANT=npu\n' > "$work/release.env"
export PATH="$work/bin:$PATH" HALOS_POLICY="$repo/files/etc/containers/policy.json" HALOGEN_RELEASE_FILE="$work/release.env" HALOS_HISTORY="$work/history" SUDO_USER=owner
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
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:beta$' "$work/log"
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
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:stable-no-npu$' "$work/log"; has '^systemctl reboot$' "$work/log"
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
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash@sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe$' "$work/log"; has 'pins' "$work/out"
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
"$ctl" switch beta --yes > /dev/null; has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:beta$' "$work/log"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.2 sha256:new)" > "$work/status.json"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.2 sha256:new)" \
  "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb | sed 's/2026-11-05T16/2026-11-01T16/')" > "$work/next.json"
"$ctl" upgrade --yes > "$work/out"; has 'Warning: the staged image was built before' "$work/out"
ok "upgrade stages the channel's newest release and records it; history lists every change; an old-name install switches to halos-flash"

# Signatures (#46): an install from before the check has an "insecure" spec. Its first upgrade is a
# switch to the same name with the check on, which also fetches the newest image of that name.
: > "$work/log"
FAKE_SIG=insecure host "$(dep ghcr.io/n4berius/halos-flash:beta-no-npu 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
"$ctl" upgrade --check > "$work/out"; has "doesn't check halOS's signature" "$work/out"; hasnt 'bootc (switch|upgrade)' "$work/log"
if "$ctl" upgrade < /dev/null > "$work/out" 2>&1; then echo "turned the check on without confirming" >&2; exit 1; fi
hasnt 'bootc switch' "$work/log"
FAKE_STAGED_EDITION=no-npu "$ctl" upgrade --yes > "$work/out"
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:beta-no-npu$' "$work/log"; hasnt 'bootc upgrade' "$work/log"
has 'upgrade .*:beta-no-npu \(0.19.0-beta.1\) -> ghcr.io/n4berius/halos-flash:beta-no-npu' "$work/history"
: > "$work/log"; FAKE_NO_UPDATE=1 "$ctl" upgrade --yes > "$work/out"; has 'already staged' "$work/out"; hasnt 'bootc switch' "$work/log"
# With a change staged (here npu off), the check goes on for what boots next, not what runs.
: > "$work/log"
FAKE_SIG=insecure host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" \
  "$(dep ghcr.io/n4berius/halos-flash:beta-no-npu 0.19.0-beta.1 sha256:ccc)" > "$work/status.json"
"$ctl" upgrade --yes > "$work/out"
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:beta-no-npu$' "$work/log"
# Pinned by digest, here a no-NPU build: the same build, now checked, whatever its edition.
FAKE_SIG=insecure host "$(dep ghcr.io/n4berius/halos-flash@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd 0.19.0-beta.1 sha256:ddd)" > "$work/status.json"
FAKE_STAGED_EDITION=no-npu "$ctl" upgrade --yes > "$work/out" || { cat "$work/out" >&2; exit 1; }
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash@sha256:d{64}$' "$work/log"
# A removed or changed policy: bootc would refuse; halosctl says how to restore it, and changes nothing.
host "$(dep ghcr.io/n4berius/halos-flash:stable 0.20.0 sha256:aaa)" > "$work/status.json"
: > "$work/log"; echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$work/policy.json"
for cmd in "switch beta" "upgrade"; do
  # shellcheck disable=SC2086 # two words on purpose
  if HALOS_POLICY="$work/policy.json" "$ctl" $cmd --yes > "$work/out" 2>&1; then echo "$cmd ran without the policy" >&2; exit 1; fi
  has '/usr/etc/containers/policy.json' "$work/out"
done
hasnt 'bootc (switch|upgrade$)' "$work/log"
# An unsigned image is refused by bootc: say why, and record nothing.
lines="$(wc -l < "$work/history")"
if FAKE_REJECT=1 "$ctl" rollback --to 0.19.0-alpha.1 --yes > "$work/out" 2>&1; then echo "an unsigned image was taken" >&2; exit 1; fi
has "isn't signed with halOS's key" "$work/out"; has '0.19.1-alpha.3' "$work/out"
[ "$(wc -l < "$work/history")" = "$lines" ] || { echo "a refused switch was recorded" >&2; exit 1; }
"$ctl" version > "$work/out"; has '^Signatures: checked' "$work/out"
FAKE_SIG=insecure host "$(dep ghcr.io/n4berius/halos-flash:stable 0.20.0 sha256:aaa)" > "$work/status.json"
"$ctl" version > "$work/out"; has '^Signatures: not checked yet' "$work/out"
# A policy whose rule names another key file is refused too.
jq '.transports.docker["ghcr.io/n4berius/halos-flash"][0].keyPath = "/tmp/other.pub"' "$repo/files/etc/containers/policy.json" > "$work/policy.json"
host "$(dep ghcr.io/n4berius/halos-flash:stable 0.20.0 sha256:aaa)" > "$work/status.json"
if HALOS_POLICY="$work/policy.json" "$ctl" switch beta --yes > "$work/out" 2>&1; then echo "took a policy with another key" >&2; exit 1; fi
# An older build under the same name (the first signed upgrade) is named, and --reboot waits for
# a look; another channel or rollback --to being older is normal.
FAKE_STAGED_TS=2026-10-01T00:00:00Z "$ctl" switch beta --yes > "$work/out"; hasnt 'built before' "$work/out"
host "$(dep ghcr.io/n4berius/halos-flash:stable 0.20.0 sha256:aaa)" > "$work/status.json"
FAKE_STAGED_TS=2026-10-01T00:00:00Z "$ctl" rollback --to 0.19.0-beta.1 --yes > "$work/out"; hasnt 'built before' "$work/out"
FAKE_SIG=insecure host "$(dep ghcr.io/n4berius/halos-flash:beta 0.20.0 sha256:aaa)" > "$work/status.json"; : > "$work/log"
FAKE_STAGED_TS=2026-10-01T00:00:00Z "$ctl" upgrade --yes --reboot > "$work/out"; has 'built before the one running' "$work/out"
hasnt 'systemctl reboot' "$work/log"
# A replaced public key file is refused too, when the image's copy is there to compare with.
host "$(dep ghcr.io/n4berius/halos-flash:stable 0.20.0 sha256:aaa)" > "$work/status.json"
echo other > "$work/key.pub"
if HALOS_KEY="$work/key.pub" HALOS_IMAGE_KEY="$repo/files/etc/pki/containers/halos-flash.pub" "$ctl" switch beta --yes > "$work/out" 2>&1; then
  echo "took a replaced key file" >&2; exit 1
fi
has "isn't halOS's key" "$work/out"
ok "every switch asks bootc to check signatures; the first upgrade turns the check on (by tag or digest); a missing or changed policy or an unsigned image is explained; version says whether updates are checked; an older build is named"

# npu on|off: the other edition on the same channel, or the same exact release (pinned by digest).
mkdir -p "$work/sys/bus/pci/devices/0000:c5:00.1"
export HALOGEN_SYS="$work/sys"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
: > "$work/log"
"$ctl" npu off --yes > "$work/out"
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:beta-no-npu$' "$work/log"
has 'stay in /srv/models' "$work/out"; has 'npu-off .*:beta \(0.19.0-beta.1\) -> ghcr.io/n4berius/halos-flash:beta-no-npu' "$work/history"
"$ctl" npu off --yes > "$work/out"; has 'Already the no-npu edition at the next boot' "$work/out"
# A channel switch while npu off is staged keeps the no-NPU edition.
: > "$work/log"; "$ctl" switch release --yes > /dev/null
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:stable-no-npu$' "$work/log"
host "$(dep ghcr.io/n4berius/halos-flash:beta 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
"$ctl" npu on --yes > "$work/out"; has 'Already the npu edition\.' "$work/out"
if "$ctl" npu sideways --yes > "$work/out" 2>&1; then echo "took npu sideways" >&2; exit 1; fi
if "$ctl" npu --yes > "$work/out" 2>&1; then echo "took npu with no word" >&2; exit 1; fi
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0-alpha.1 0.19.0 sha256:aaa)" > "$work/status.json"
: > "$work/log"; "$ctl" npu off --yes > "$work/out"
has 'skopeo .*docker://ghcr.io/n4berius/halos-flash:0.19.0-alpha.1-no-npu' "$work/log"
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash@sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe$' "$work/log"
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
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:beta-no-npu$' "$work/log"
cp "$work/pinned.json" "$work/status.json"; : > "$work/log"
FAKE_STAGED_EDITION=no-npu "$ctl" npu on --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
# The staged build's own release (its version label), which the fake bootc gives every switch.
has 'skopeo .*docker://ghcr.io/n4berius/halos-flash:0.19.0-beta.1 *$' "$work/log"; has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash@sha256:' "$work/log"
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
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:beta-no-npu$' "$work/log"; has 'After: .*\(0\.19\.0-beta\.1\)' "$work/out"
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
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:beta$' "$work/log"; has 'shows no AMD NPU' "$work/out"
printf '0x1022\n' > "$work/sys/bus/pci/devices/0000:c5:00.1/vendor"; printf '0x17f0\n' > "$work/sys/bus/pci/devices/0000:c5:00.1/device"
host "$(dep ghcr.io/n4berius/halos-flash:beta-no-npu 0.19.0-beta.1 sha256:bbb)" > "$work/status.json"
"$ctl" npu on --yes > "$work/out"; hasnt 'shows no AMD NPU' "$work/out"
sed -i 's/=no-npu/=npu/' "$work/release.env"
# A plain version tag keeps moving; a queued rollback must boot first.
host "$(dep ghcr.io/n4berius/halos-flash:0.19.0 0.19.0 sha256:aaa)" > "$work/status.json"
: > "$work/log"; "$ctl" npu off --yes > /dev/null
has '^bootc switch --enforce-container-sigpolicy ghcr.io/n4berius/halos-flash:0.19.0-no-npu$' "$work/log"
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
if "$ctl" power balanced --reboot > "$work/out" 2>&1; then echo "took --reboot, which power ignores" >&2; exit 1; fi
[ "$(cat "$HALOS_PROFILE_FILE")" = low-power ] || { echo "a refused change was saved" >&2; exit 1; }
if FAKE_UID=1000 "$ctl" power balanced > "$work/out" 2>&1; then echo "ran without root" >&2; exit 1; fi
# At boot: the saved choice, performance when none, and a choice the firmware lacks fails loudly.
"$HALOS_PLATFORM_PROFILE" apply 2> "$work/out" && { echo "applied a profile the firmware lacks" >&2; exit 1; }
has 'not a profile this firmware offers' "$work/out"; [ "$(cat "$acpi/platform_profile")" = low-power ]
rm "$HALOS_PROFILE_FILE"; "$HALOS_PLATFORM_PROFILE" apply; [ "$(cat "$acpi/platform_profile")" = performance ]
# Firmware without performance: the default is no error, and the profile stays as it is.
echo 'low-power balanced' > "$acpi/platform_profile_choices"; echo balanced > "$acpi/platform_profile"
"$HALOS_PLATFORM_PROFILE" apply > "$work/out"; has 'no performance profile' "$work/out"; [ "$(cat "$acpi/platform_profile")" = balanced ]
rm "$acpi/platform_profile"; "$HALOS_PLATFORM_PROFILE" apply
if "$ctl" power > "$work/out" 2>&1; then echo "showed a profile on a machine without one" >&2; exit 1; fi
has 'offers no power profile' "$work/out"
ok "power shows, saves and sets the firmware profile at once, refuses one the firmware lacks, and boot applies the choice or performance"

# ssh-passwords (#94 audit): keys-only SSH logins, never without the admin's own key, checked by
# sshd -t before the reload.
mkdir -p "$work/home/owner/.ssh" "$work/sshd.d"
export HALOS_SSHD_DROPIN="$work/sshd.d/20-halos-keys-only.conf"
f getent 'case "$1 $2" in "passwd owner") echo "owner:x:1000:1000::$FAKE/home/owner:/bin/bash" ;; *) exit 2 ;; esac'
f sshd 'echo "sshd $*" >> "$FAKE/log"; [ -z "${FAKE_SSHD_BAD:-}" ] || exit 1
  if [ "$1" = -T ]; then if [ -e "$HALOS_SSHD_DROPIN" ] && [ -z "${FAKE_EARLIER_YES:-}" ]; then echo "passwordauthentication no"; else echo "passwordauthentication yes"; fi; fi'
f ssh-keygen 'grep -q "^ssh-ed25519 AAAA"'
f runuser '[ "$1 $2 $3" = "-u owner --" ] || exit 9; shift 3; exec "$@"'
chmod 755 "$work/home/owner" "$work/home/owner/.ssh"
: > "$work/log"
"$ctl" ssh-passwords > "$work/out"; has 'keys or passwords' "$work/out"
if "$ctl" ssh-passwords off --yes > "$work/out" 2>&1; then echo "turned passwords off without a key" >&2; exit 1; fi
has 'could lock you out' "$work/out"; [ ! -e "$HALOS_SSHD_DROPIN" ]
echo "ssh-ed25519 AAAAkey owner@laptop" > "$work/home/owner/.ssh/authorized_keys"
if FAKE_SSHD_BAD=1 "$ctl" ssh-passwords off --yes > "$work/out" 2>&1; then echo "kept a config sshd refused" >&2; exit 1; fi
[ ! -e "$HALOS_SSHD_DROPIN" ] || { echo "a refused config stayed" >&2; exit 1; }
# A setting sshd reads first wins over ours: refused, nothing kept.
if FAKE_EARLIER_YES=1 "$ctl" ssh-passwords off --yes > "$work/out" 2>&1; then echo "kept a setting sshd doesn't use" >&2; exit 1; fi
[ ! -e "$HALOS_SSHD_DROPIN" ] || exit 1
# A .ssh others can write to: sshd would ignore the key, so it counts as none.
chmod 777 "$work/home/owner/.ssh"
if "$ctl" ssh-passwords off --yes > /dev/null 2>&1; then echo "took a key sshd would ignore" >&2; exit 1; fi
chmod 755 "$work/home/owner/.ssh"
"$ctl" ssh-passwords off --yes > "$work/out"
grep -qx 'PasswordAuthentication no' "$HALOS_SSHD_DROPIN"; has 'try-reload-or-restart sshd' "$work/log"
has 'ssh-passwords +on -> off +\(by owner\)' "$work/history"
"$ctl" ssh-passwords > "$work/out"; has 'keys only' "$work/out"
"$ctl" ssh-passwords on --yes > "$work/out"; [ ! -e "$HALOS_SSHD_DROPIN" ]; has 'ssh-passwords +off -> on' "$work/history"
ok "ssh-passwords off needs the admin's key and a config sshd accepts; on undoes it; both are recorded"

# dashboard: the service and its firewall port, together, with the state kept in files here.
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; d="$FAKE/dash-on"
  case "$*" in *"is-enabled halos-dashboard"*) [ -e "$d" ] && echo enabled || echo disabled ;;
    *"is-active halos-dashboard"*) [ -e "$d" ] && echo active || echo inactive ;;
    *"enable --now halos-dashboard"*) [ -z "${FAKE_DASH_FAIL:-}" ] || exit 1; touch "$d" ;;
    *"disable --now halos-dashboard"*) rm -f "$d" ;; *is-active*) echo "${FAKE_FETCH:-inactive}" ;; esac'
f firewall-cmd 'echo "firewall-cmd $*" >> "$FAKE/log"; p="$FAKE/dash-port"
  case "$*" in *--query-service=halos-dashboard*) [ -e "$p" ] ;; *"--permanent --add-service=halos-dashboard"*) touch "$p" ;;
    *"--permanent --remove-service=halos-dashboard"*) rm -f "$p" ;; esac'
f hostname 'echo "192.0.2.7 fd00::7"'
: > "$work/log"; "$ctl" dashboard > "$work/out"; has '^Dashboard: off' "$work/out"
"$ctl" dashboard on > "$work/out"; has 'http://192.0.2.7:8790' "$work/out"; has 'no login' "$work/out"
has 'enable --now halos-dashboard.service' "$work/log"; has 'firewall-cmd --quiet --permanent --add-service=halos-dashboard' "$work/log"
has 'firewall-cmd --quiet --add-service=halos-dashboard' "$work/log"; has 'dashboard +off -> on +\(by owner\)' "$work/history"
"$ctl" dashboard > "$work/out"; has '^Dashboard: on \(active\), at http://192.0.2.7:8790' "$work/out"; has 'open to your network' "$work/out"
rm "$work/dash-port"; "$ctl" dashboard > "$work/out"; has 'closed in the firewall' "$work/out"
"$ctl" dashboard on > /dev/null; [ "$(grep -cE 'dashboard +off -> on' "$work/history")" = 1 ] || { echo "a second on was recorded" >&2; exit 1; }
"$ctl" dashboard off > "$work/out"; has 'port 8790 closed' "$work/out"; [ ! -e "$work/dash-on" ] && [ ! -e "$work/dash-port" ]
has 'dashboard +on -> off' "$work/history"
"$ctl" dashboard off > "$work/out"; has 'already off' "$work/out"
if FAKE_DASH_FAIL=1 "$ctl" dashboard on > "$work/out" 2>&1; then echo "a failed start passed" >&2; exit 1; fi
has "didn't start" "$work/out"
for bad in "on off" "maybe" "on --reboot" "on --yes"; do
  # shellcheck disable=SC2086 # the words are the arguments
  if "$ctl" dashboard $bad > /dev/null 2>&1; then echo "took dashboard $bad" >&2; exit 1; fi
done
if FAKE_UID=1000 "$ctl" dashboard on > /dev/null 2>&1; then echo "ran without root" >&2; exit 1; fi
ok "dashboard on/off starts or stops it and opens or closes its port together, records changes, and shows the address"
