#!/bin/bash
# Tab completion for halogenctl, halosctl and halogen-enroll-tpm: every command the tools take
# is offered, and the arguments after it; a folder name never runs as a command.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
dir="$repo/files/usr/share/bash-completion/completions"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "$*" >&2; exit 1; }
# Complete the line as typed (the last word may be partial) and print the offers, one per line.
offers() {
  local fn="$1"; shift
  COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
  "$fn"
  [ "${#COMPREPLY[@]}" = 0 ] || printf '%s\n' "${COMPREPLY[@]}" | sort
}
expect() { local want="$1"; shift; [ "$(offers "$@" | tr '\n' ' ')" = "${want:+$want }" ] || fail "'${*:2}' offered '$(offers "$@" | tr '\n' ' ')', not '$want'"; }
# A tool's case labels at one indent: top-level commands at 2 spaces, subcommands at 6.
labels() { sed -n "s/^$(printf '%*s' "$2" '')\\([a-z][a-z0-9|-]*\\))\\( .*\\)\\{0,1\\}\$/\\1/p" "$1" | tr '|' '\n' | grep -v '^-' | sort -u; }
# Inside one top-level command's block (from '  name)' to its ';;' at 2 spaces).
block() { sed -n "/^  $2)\$/,/^    ;;\$/p" "$1"; }
check_offered() {
  local what="$1" min="$2" got="$3" n=0 c
  while IFS= read -r c; do
    [ -n "$c" ] || continue; n=$((n + 1))
    grep -qx -- "$c" <<< "$got" || fail "$what $c is not offered"
  done
  [ "$n" -ge "$min" ] || fail "only $n commands of $what were found; did the test stop reading the tool?"
}

# shellcheck source=/dev/null
. "$dir/halogenctl"
# shellcheck source=/dev/null
. "$dir/halosctl"
check_offered halogenctl 12 "$(offers _halogenctl halogenctl '')" < <(labels "$repo/files/usr/bin/halogenctl" 2)
check_offered halosctl 6 "$(offers _halosctl halosctl '')" < <(labels "$repo/files/usr/bin/halosctl" 2 | grep -vx help)
for sub in flash model; do
  block "$repo/files/usr/bin/halogenctl" "$sub" > "$work/block"
  check_offered "halogenctl $sub" 3 "$(offers _halogenctl halogenctl "$sub" '')" < <(labels "$work/block" 6)
done
# And the other way: every word offered at the top is a command the tool takes.
for tool in halogenctl halosctl; do
  labels "$repo/files/usr/bin/$tool" 2 > "$work/real"
  while IFS= read -r w; do
    grep -qx -- "$w" "$work/real" || fail "$tool completion offers '$w', which $tool doesn't take"
  done < <(offers "_$tool" "$tool" '')
done
for sub in flash model; do
  block "$repo/files/usr/bin/halogenctl" "$sub" > "$work/block"; labels "$work/block" 6 > "$work/real"
  while IFS= read -r w; do
    grep -qx -- "$w" "$work/real" || fail "halogenctl $sub completion offers '$w', which it doesn't take"
  done < <(offers _halogenctl halogenctl "$sub" '')
done
echo "ok: every command and subcommand of halogenctl and halosctl is offered, and nothing else"

expect "flash" _halogenctl halogenctl fl
expect "--quick" _halogenctl halogenctl bench ''
sed "s|local models=/srv/models names=/run/halos/model-names|local models=$work names=$work/none|" "$dir/halogenctl" > "$work/c"
grep -q "local models=$work names=" "$work/c" || fail "the test couldn't point completion at its folder"
# Names a container could create: run in $work, they would leave pwned files there.
mkdir -p "$work/flash/mine" "$work/flash/.check" "$work/LFM/LFM3-1.7B" "$work/flash/\$(touch\${IFS}pwned)" \
  "$work/LFM/\`touch pwned2\`" "$work/flash/a b" "$work/flash/"$'a\nofficial'
[ -d "$work/flash/\$(touch\${IFS}pwned)" ] || fail "the test couldn't make its crafted folder"
# shellcheck source=/dev/null
. "$work/c"
cd "$work"
offers _halogenctl halogenctl flash use '' > /dev/null; offers _halogenctl halogenctl model remove '' > /dev/null
if [ -e "$work/pwned" ] || [ -e "$work/pwned2" ]; then fail "a folder name ran as a command during completion"; fi
expect "mine official" _halogenctl halogenctl flash use ''
expect "mine" _halogenctl halogenctl flash check ''
expect "mine" _halogenctl halogenctl flash remove m
expect "LFM3-1.7B" _halogenctl halogenctl model remove ''
expect "--yes" _halogenctl halogenctl flash check mine ''
expect "" _halogenctl halogenctl flash pull x --revision ''
mkdir -p "$work/custom/OvisOCR3"; : > "$work/flash/mine/their-drafter.hgn"; : > "$work/flash/mine/model.hgn"
expect "LFM3-1.7B OvisOCR3" _halogenctl halogenctl model pull x --as ''
expect "mine" _halogenctl halogenctl flash pull x --as m
expect "" _halogenctl halogenctl flash convert x --as ''
expect "off official their-drafter.hgn" _halogenctl halogenctl flash drafter mine ''
echo "ok: halogenctl offers options and the plain names of your own checkpoints; a crafted folder name never runs"

# Under sudo, completion runs as you and can't read /srv/models: the names come from the list
# root's model-names writes, built here from the same folders (setpriv stands in as a pass-through).
mkdir -p "$work/bin" "$work/LFM/"$'LFM3\nflash evil' "$work/flash/.convert/bigone" "$work/flash/.check"
# shellcheck disable=SC2016 # expanded when the fake runs
printf '#!/bin/bash\n[ "$1 $2 $3 $4" = "--reuid=970 --regid=970 --clear-groups --" ] || exit 9\nshift 4; exec "$@"\n' > "$work/bin/setpriv"
chmod +x "$work/bin/setpriv"
PATH="$work/bin:$PATH" HALOGEN_MODELS_DIR="$work" HALOS_NAMES_GROUP="$(id -gn)" "$repo/files/usr/libexec/halogen/model-names" "$work/names"
for l in "flash mine" "drafter mine their-drafter.hgn" "convert bigone" "own LFM LFM3-1.7B" "own custom OvisOCR3"; do
  grep -qxF -- "$l" "$work/names" || { cat "$work/names" >&2; fail "model-names didn't list '$l'"; }
done
if grep -vE '^(flash|convert) [A-Za-z0-9][A-Za-z0-9._-]*$|^(own [A-Za-z]+|drafter [A-Za-z0-9][A-Za-z0-9._-]*) [A-Za-z0-9][A-Za-z0-9._-]*$' "$work/names"; then
  fail "model-names wrote a line that isn't a plain name"
fi
if grep -qx 'own LFM LFM3' "$work/names"; then fail "a folder name with a line break became a name"; fi
[ "$(stat -c %a "$work/names")" = 640 ] || fail "the names list isn't 0640"
cp -p "$work/names" "$work/names.before"; sleep 1
PATH="$work/bin:$PATH" HALOGEN_MODELS_DIR="$work" HALOS_NAMES_GROUP="$(id -gn)" "$repo/files/usr/libexec/halogen/model-names" "$work/names"
[ "$work/names" -ot "$work/names.before" ] || [ ! "$work/names" -nt "$work/names.before" ] || fail "model-names rewrote an unchanged list"
sed "s|local models=/srv/models names=/run/halos/model-names|local models=$work/unreadable names=$work/names|" "$dir/halogenctl" > "$work/c2"
# A crafted line in the list (the folders are halogen's) still never runs.
# shellcheck disable=SC2016 # meant literally
printf '%s\n' 'flash $(touch${IFS}pwned4)' 'own custom `touch pwned5`' >> "$work/names"
# shellcheck source=/dev/null
. "$work/c2"
expect "mine official" _halogenctl halogenctl flash use ''
expect "bigone" _halogenctl halogenctl flash convert-stop ''
expect "LFM3-1.7B OvisOCR3" _halogenctl halogenctl model remove ''
expect "OvisOCR3" _halogenctl halogenctl model pull x --as O
expect "off official their-drafter.hgn" _halogenctl halogenctl flash drafter mine ''
expect "off official" _halogenctl halogenctl flash drafter other ''
if [ -e "$work/pwned4" ] || [ -e "$work/pwned5" ]; then fail "a listed name ran as a command during completion"; fi
echo "ok: under sudo the names come from root's list, which keeps only plain names"

expect "alpha edge kernel-next rc release" _halosctl halosctl switch ''
expect "--reboot --to --yes" _halosctl halosctl rollback ''
expect "" _halosctl halosctl rollback --to ''
expect "--check --reboot --yes" _halosctl halosctl upgrade ''
expect "balanced low-power performance" _halosctl halosctl power ''
expect "" _halosctl halosctl power balanced ''
echo "ok: halosctl offers channels and each command's options"
# shellcheck source=/dev/null
. "$dir/halogen-enroll-tpm"
# shellcheck disable=SC2016 # the $(...) is the crafted name, meant literally
lsblk() { printf '%s\n' '/dev/nvme0n1p3 crypto_LUKS' '/dev/nvme0n1p2 xfs' '/dev/$(touch${IFS}pwned3) crypto_LUKS'; }
expect "/dev/nvme0n1p3" _halogen_enroll_tpm halogen-enroll-tpm ''
expect "" _halogen_enroll_tpm halogen-enroll-tpm /dev/sd
if [ -e "$work/pwned3" ]; then fail "a device name ran as a command during completion"; fi
echo "ok: halogen-enroll-tpm offers LUKS devices only, matched by hand"
