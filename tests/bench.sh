#!/bin/bash
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
# halogenctl bench's script against fake podman, curl and render-config.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/configs" "$work/sys/class/dmi/id" "$work/sys/firmware/acpi"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
# podman run logs its arguments and the key it got through the environment, then prints a sweep.
f podman 'case "$1" in
  image) [ -z "${FAKE_NO_IMAGE:-}" ] ;;
  run) printf "%s\n" "$*" >> "$FAKE/podman.log"; echo "key=${HALOGEN_API_KEY:-}" >> "$FAKE/podman.log"
       [ -z "${FAKE_BENCH_FAILS:-}" ] || { echo "cannot reach /health" >&2; exit 2; }
       echo "{\"model\":\"halogen-q38fn\",\"context\":262144,\"reps\":3,\"rows\":[
         {\"test\":\"pp2048\",\"drafter\":\"mtp\",\"tokens\":2049,\"mean\":1701.234,\"stdev\":3.21},
         {\"test\":\"tg128\",\"drafter\":\"mtp\",\"tokens\":128,\"mean\":64.567,\"stdev\":9.1}]}" ;;
esac'
f curl '[ -z "${FAKE_DOWN:-}" ]'
f systemctl 'echo active'
f render 'printf "HALOGEN_CHECKPOINT=/models/flash/mine/model.hgn\nHALOGEN_KV8=1\nHALOGEN_API_KEY_FILE=/run/secrets/x\n"; echo "halogen-config: noise" >&2'
printf 'HALOGEN_IMAGE=ghcr.io/peonist-ai/halogen-flash-server@sha256:1\nHALOGEN_VERSION=0.19.1\nHALOGEN_VARIANT=npu\nHALOS_RELEASE=0.19.1-beta.1\n' > "$work/release.env"
echo 'secret-key-123' > "$work/configs/api-key"
printf 'Compal\n' > "$work/sys/class/dmi/id/board_vendor"; printf 'Halo\e[2J\n' > "$work/sys/class/dmi/id/board_name"
printf '04.01\n' > "$work/sys/class/dmi/id/bios_version"; printf 'performance\n' > "$work/sys/firmware/acpi/platform_profile"
echo 'BOOT_IMAGE=x amdgpu.gttsize=126976 iommu=pt quiet' > "$work/cmdline"
export PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_CONFIGS_DIR="$work/configs" \
  HALOGEN_RENDER="$work/bin/render" HALOGEN_SYS="$work/sys" HALOGEN_CMDLINE="$work/cmdline"
bench="$repo/files/usr/libexec/halogen/bench"
ok() { echo "ok: $*"; }
fail() { echo "$*" >&2; [ ! -f "$work/out" ] || cat "$work/out" >&2; exit 1; }
has() { grep -qE -- "$1" "$2" || fail "expected '$1' in $2"; }

"$bench" > "$work/out" 2>&1 || fail "the benchmark failed"
txt="$(ls "$work/configs/bench/"*.txt)"; json="${txt%.txt}.json"
[ -f "$json" ] || fail "no JSON report"
has '^halOS 0\.19\.1-beta\.1, npu edition, Halogen 0\.19\.1' "$txt"
has '^Flash checkpoint: mine \(your own\)' "$txt"
has 'HALOGEN_KV8=1' "$txt"
has 'amdgpu\.gttsize=126976; iommu=pt' "$txt"
has 'platform profile: performance' "$txt"
has '^pp2048 +mtp +2049 +1701\.23 ± 3\.21' "$txt"
has '^tg128 +mtp +128 +64\.57 ± 9\.1' "$txt"
has 'Saved: ' "$work/out"
if grep -q $'\e' "$txt" "$json"; then fail "an escape code from firmware got into the report"; fi
if grep -q 'API_KEY' "$txt" "$json"; then fail "the report names the API key setting"; fi
if grep -q 'secret-key-123' "$txt" "$json"; then fail "the report holds the API key"; fi
[ "$(jq -r '.bench.rows | length' "$json")" = 2 ] || fail "the JSON lost the rows"
[ "$(jq -r '.system.halogen' "$json")" = 0.19.1 ] || fail "the JSON lost the system facts"
ok "a full run saves a text and a JSON report with the system facts, and no key or escape codes"

has '--network=host --read-only --tmpfs /tmp --cap-drop=all --security-opt no-new-privileges -e HALOGEN_API_KEY ' "$work/podman.log"
has '-p 512,2048,8192,32768 -n 128 -r 3 --json' "$work/podman.log"
has '^key=secret-key-123$' "$work/podman.log"
if grep -v '^key=' "$work/podman.log" | grep -q 'secret-key-123'; then fail "the key was on podman's command line"; fi
if grep -qE -- '(-v|--volume|--device) ' "$work/podman.log"; then fail "the sweep got a mount or a device"; fi
: > "$work/podman.log"
"$bench" --quick > "$work/out" 2>&1 || fail "the quick run failed"
has '-p 2048 -n 128 -r 1 --json' "$work/podman.log"
ok "the sweep runs with no mounts, devices or capabilities, gets the key only through its environment, and --quick is short"

n="$(find "$work/configs/bench" -mindepth 1 | wc -l)"
if FAKE_DOWN=1 "$bench" > "$work/out" 2>&1; then fail "measured a server that isn't answering"; fi
has 'halogenctl status' "$work/out"
if FAKE_NO_IMAGE=1 "$bench" > "$work/out" 2>&1; then fail "ran without Halogen's image"; fi
if FAKE_BENCH_FAILS=1 "$bench" > "$work/out" 2>&1; then fail "a failed sweep passed"; fi
has 'measurement failed' "$work/out"
if "$bench" --long > "$work/out" 2>&1; then fail "took an unknown option"; fi
[ "$(find "$work/configs/bench" -mindepth 1 | wc -l)" = "$n" ] || fail "a failed run left a report or a temporary file"
ok "it refuses a silent server, a missing image, an unknown option, and a failed sweep leaves nothing behind"
