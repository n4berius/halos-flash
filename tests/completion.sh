#!/bin/bash
# Tab completion for halogenctl, halosctl and halogen-enroll-tpm: every command the tools take
# is offered, and the arguments after it.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
dir="$repo/files/usr/share/bash-completion/completions"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "$*" >&2; exit 1; }
# shellcheck source=/dev/null
. "$dir/halogenctl"
# shellcheck source=/dev/null
. "$dir/halosctl"
# Complete the line as typed (the last word may be partial) and print the offers, one per line.
offers() {
  local fn="$1"; shift
  COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
  "$fn"
  printf '%s\n' "${COMPREPLY[@]}" | sort
}
expect() { local want="$1"; shift; [ "$(offers "$@" | tr '\n' ' ')" = "$want " ] || fail "'${*:2}' offered '$(offers "$@" | tr '\n' ' ')', not '$want'"; }

# Every top-level command in each tool's case statement is offered.
for tool in halogenctl halosctl; do
  fn="_$tool"
  got="$(offers "$fn" "$tool" '')"
  for c in $(sed -n 's/^  \([a-z|-]*\))\( .*\)\{0,1\}$/\1/p' "$repo/files/usr/bin/$tool" | tr '|' '\n' | grep -vx -e '-h' -e '--help'); do
    grep -qx -- "$c" <<< "$got" || fail "$tool $c is not offered"
  done
done
echo "ok: every command of halogenctl and halosctl is offered"

expect "flash" _halogenctl halogenctl fl
expect "check list pull remove use verify" _halogenctl halogenctl flash ''
expect "--quick" _halogenctl halogenctl bench ''
expect "list pull remove" _halogenctl halogenctl model ''
mkdir -p "$work/flash/mine" "$work/flash/.check" "$work/LFM/LFM3-1.7B"
sed "s|local models=/srv/models|local models=$work|" "$dir/halogenctl" > "$work/c"
# shellcheck source=/dev/null
. "$work/c"
expect "mine official" _halogenctl halogenctl flash use ''
expect "mine" _halogenctl halogenctl flash check ''
expect "LFM3-1.7B" _halogenctl halogenctl model remove ''
expect "--yes" _halogenctl halogenctl flash check mine ''
echo "ok: halogenctl offers its subcommands, options and the names of your own checkpoints, never hidden folders"

expect "alpha beta edge rc release" _halosctl halosctl switch ''
expect "off on" _halosctl halosctl npu ''
expect "--reboot --to --yes" _halosctl halosctl rollback ''
expect "" _halosctl halosctl rollback --to ''
expect "--check --reboot --yes" _halosctl halosctl upgrade ''
echo "ok: halosctl offers channels, npu on|off and each command's options"
bash -n "$dir/halogen-enroll-tpm" || fail "halogen-enroll-tpm's completion doesn't parse"
