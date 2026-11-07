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
labels() { sed -n "s/^$(printf '%*s' "$2" '')\\([a-z][a-z|-]*\\))\\( .*\\)\\{0,1\\}\$/\\1/p" "$1" | tr '|' '\n' | grep -v '^-' | sort -u; }
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
echo "ok: every command and subcommand of halogenctl and halosctl is offered"

expect "flash" _halogenctl halogenctl fl
expect "--quick" _halogenctl halogenctl bench ''
sed "s|local models=/srv/models|local models=$work|" "$dir/halogenctl" > "$work/c"
# Names a container could create: run in $work, they would leave pwned files there.
mkdir -p "$work/flash/mine" "$work/flash/.check" "$work/LFM/LFM3-1.7B" "$work/flash/\$(touch\${IFS}pwned)" \
  "$work/LFM/\`touch pwned2\`" "$work/flash/a b"
[ -d "$work/flash/\$(touch\${IFS}pwned)" ] || fail "the test couldn't make its crafted folder"
# shellcheck source=/dev/null
. "$work/c"
cd "$work"
offers _halogenctl halogenctl flash use '' > /dev/null; offers _halogenctl halogenctl model remove '' > /dev/null
[ ! -e "$work/pwned" ] && [ ! -e "$work/pwned2" ] || fail "a folder name ran as a command during completion"
expect "mine official" _halogenctl halogenctl flash use ''
expect "mine" _halogenctl halogenctl flash check ''
expect "mine" _halogenctl halogenctl flash remove m
expect "LFM3-1.7B" _halogenctl halogenctl model remove ''
expect "--yes" _halogenctl halogenctl flash check mine ''
expect "" _halogenctl halogenctl flash pull x --revision ''
echo "ok: halogenctl offers options and the plain names of your own checkpoints; a crafted folder name never runs"

expect "alpha beta edge rc release" _halosctl halosctl switch ''
expect "--reboot --to --yes" _halosctl halosctl rollback ''
expect "" _halosctl halosctl rollback --to ''
expect "--check --reboot --yes" _halosctl halosctl upgrade ''
echo "ok: halosctl offers channels and each command's options"
bash -n "$dir/halogen-enroll-tpm" || fail "halogen-enroll-tpm's completion doesn't parse"
