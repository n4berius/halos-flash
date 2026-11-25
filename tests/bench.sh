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
       printf "halogen-bench: m, ctx 262144, reps 3, effort low\nendpoint x\n\n"
       echo "{\"model\":\"halogen-q38fn\",\"context\":262144,\"reps\":3,\"rows\":[
         {\"test\":\"pp2048\",\"drafter\":\"mtp\",\"tokens\":2049,\"mean\":${FAKE_PP:-1701.234},\"stdev\":3.21},
         {\"test\":\"tg128\",\"drafter\":\"mt\u001b[2Jp\",\"tokens\":128,\"mean\":${FAKE_TG:-64.567},\"stdev\":9.1}],
         \"halos_cold\":{\"passes\":[{\"tokens\":2049,\"cached\":${FAKE_CACHED:-40}},{\"tokens\":2050,\"cached\":${FAKE_CACHED:-40}}]}}" ;;
esac'
f curl '[ -z "${FAKE_DOWN:-}" ]'
f clock '[ -z "${FAKE_CLOCK_LOOSE:-}" ]'
f render 'printf "HALOGEN_CHECKPOINT=/models/flash/mine/model.hgn\nHALOGEN_KV8=${FAKE_KV8:-1}\nHALOGEN_API_KEY_FILE=/run/secrets/x\n"; echo "halogen-config: noise" >&2'
printf 'HALOGEN_IMAGE=ghcr.io/peonist-ai/halogen-flash-server@sha256:1\nHALOGEN_VERSION=0.19.1\nHALOGEN_VARIANT=npu\nHALOS_RELEASE=0.19.1-beta.1\n' > "$work/release.env"
echo 'secret-key-123' > "$work/configs/api-key"
printf 'Compal\n' > "$work/sys/class/dmi/id/board_vendor"; printf 'Halo\e[2J\n' > "$work/sys/class/dmi/id/board_name"
printf '04.01\n' > "$work/sys/class/dmi/id/bios_version"; printf 'performance\n' > "$work/sys/firmware/acpi/platform_profile"
echo 'BOOT_IMAGE=x amdgpu.gttsize=126976 iommu=pt quiet' > "$work/cmdline"
export PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_CONFIGS_DIR="$work/configs" \
  HALOGEN_RENDER="$work/bin/render" HALOGEN_SYS="$work/sys" HALOGEN_CMDLINE="$work/cmdline" HALOGEN_CLOCK="$work/bin/clock" \
  HALOGEN_BENCH_COLD="$repo/files/usr/share/halogen/bench-cold.py"
bench="$repo/files/usr/libexec/halogen/bench"
ok() { echo "ok: $*"; }
fail() { echo "$*" >&2; [ ! -f "$work/out" ] || cat "$work/out" >&2; exit 1; }
has() { grep -qE -- "$1" "$2" || fail "expected '$1' in $2"; }

"$bench" > "$work/out" 2>&1 || fail "the benchmark failed"
txt="$(ls "$work/configs/bench/"*.txt)"; json="${txt%.txt}.json"
[ -f "$json" ] || fail "no JSON report"
has '^halOS benchmark, .*, full run \(3 passes per test\)' "$txt"
has '^Setup: halOS 0\.19\.1-beta\.1 \(npu edition\), Halogen 0\.19\.1, Flash checkpoint mine \(your own\),' "$txt"
has 'power profile performance, fabric clock held\.' "$txt"
has '^    HALOGEN_KV8=1$' "$txt"
has 'amdgpu\.gttsize=126976; iommu=pt' "$txt"
has '^  2K tokens +1,701 tok/s +±0\.2% +1\.2 s$' "$txt"
has '^  128 tokens +64\.6 tok/s +±14\.1% +2\.0 s$' "$txt"
has 'draft head mt\[2Jp/mtp' "$txt"
has 'Prompt cache: default' "$txt"
has '^No earlier full run to compare with' "$txt"
if grep -q 'Warning' "$txt"; then fail "a cold run was flagged as served from the cache"; fi
if grep -q 'HALOGEN_KV8' "$work/out"; then fail "the settings list is on the screen, not only in the saved file"; fi
has 'Saved: ' "$work/out"
if grep -q $'\e' "$txt" "$json"; then fail "an escape code from firmware got into the report"; fi
if grep -q 'API_KEY' "$txt" "$json"; then fail "the report names the API key setting"; fi
if grep -q 'secret-key-123' "$txt" "$json"; then fail "the report holds the API key"; fi
[ "$(jq -r '.bench.rows | length' "$json")" = 2 ] || fail "the JSON lost the rows"
[ "$(jq -r '.system.halogen' "$json")" = 0.19.1 ] || fail "the JSON lost the system facts"
sleep 1
FAKE_CLOCK_LOOSE=1 "$bench" --quick > "$work/out" 2>&1 || fail "the run failed with the clock not held"
has 'fabric clock NOT held' "$work/out"
has '^No earlier quick run to compare with' "$work/out"
ok "a full run saves a text and a JSON report with the system facts, and no key or escape codes"

# A second full run is compared with the first; a quick run never with a full one.
sleep 1
FAKE_PP=1801.5 FAKE_KV8=0 "$bench" > "$work/out" 2>&1 || fail "the second full run failed"
has '^  2K tokens +1,802 tok/s +±0\.2% +1\.1 s +\+5\.9% +faster$' "$work/out"
has '^  128 tokens +64\.6 tok/s +±14\.1% +2\.0 s +0\.0% +about the same$' "$work/out"
has '^Last run: .* UTC \([0-9]{8}-[0-9]{6}\.json\)\. Changed since then:$' "$work/out"
has '^  HALOGEN_KV8 1 -> 0$' "$work/out"
latest="$(find "$work/configs/bench" -name '*.json' | sort | tail -n 1)"
first="$(find "$work/configs/bench" -name '*.json' | sort | head -n 1)"
[ "$(jq -r .compared_with "$latest")" = "$(basename "$first")" ] || fail "the JSON doesn't name the run it was compared with"
sleep 1
# Writing 5% faster is a change: its spread is mostly the prompt types, not noise between runs.
FAKE_PP=1690 FAKE_TG=67.8 FAKE_KV8=0 "$bench" > "$work/out" 2>&1 || fail "the third full run failed"
has '^  2K tokens +1,690 tok/s +±0\.2% +1\.2 s +-6\.2% +slower$' "$work/out"
has '^  128 tokens +67\.8 tok/s .* \+5\.0% +faster$' "$work/out"
has 'Nothing in the setup changed since then\.' "$work/out"
sleep 1
FAKE_PP=1720 FAKE_TG=67.8 FAKE_KV8=0 "$bench" > "$work/out" 2>&1 || fail "the fourth full run failed"
has '^  2K tokens +1,720 tok/s .* \+1\.8% +about the same$' "$work/out"
has '^Since the last full run: no change beyond the normal variation\.$' "$work/out"
latest="$(find "$work/configs/bench" -name '*.json' | sort | tail -n 1)"
# A link (even to a good report), a broken file, a report of another shape, an odd name or one
# with escape codes among the reports is never used, never stops the run, and nothing is printed raw.
ln -s "$latest" "$work/configs/bench/29991231-235959.json"
echo '{' > "$work/configs/bench/29991231-235958.json"
jq '.system = "x"' "$latest" > "$work/configs/bench/29991231-235957.json"
jq -c . "$latest" | sed 's/^/{"run":"x"} /' > "$work/configs/bench/29991231-235956.json"
# A report from before the cold prompts (no halos_cold): its reading speeds may be the cache's.
jq 'del(.bench.halos_cold)' "$latest" > "$work/configs/bench/29991231-235960.json"
cp "$latest" "$work/configs/bench/9"$'\e'"]0;x-1.json"
jq '.date = "evil\u001b[2J" | .system.halogen = "0.1\u001b]0;x\u0007" | .bench.rows[0].mean = "1700"' \
  "$latest" > "$work/configs/bench/29991231-235955.json"
sleep 1
FAKE_PP=1690 FAKE_KV8=0 "$bench" > "$work/out" 2>&1 || fail "a run beside odd reports failed"
has '^Last run: evil\[2J \(29991231-235955\.json\)' "$work/out"
has '^  Halogen 0\.1\]0;x -> 0\.19\.1$' "$work/out"
has '^  2K tokens +1,690 tok/s .*\(not in the last run\)$' "$work/out"
if grep -q $'[\e\a]' "$work/out"; then fail "an escape code from an old report reached the screen"; fi
rm "$work/configs/bench/2999"* "$work/configs/bench/9"*
ok "a run is compared with the last one of its kind: faster, slower or about the same, and what changed"

# A run whose prefill passes the cache mostly answered says so.
sleep 1
FAKE_CACHED=2000 "$bench" > "$work/out" 2>&1 || fail "a warm run failed"
has '^Warning: 2 prompt-reading passes were mostly answered from the prompt cache, so the reading speeds are too high\.' "$work/out"
sleep 1
"$bench" > "$work/out" 2>&1 || fail "the run after a warm one failed"
if grep -q Warning "$work/out"; then fail "a cold run after a warm one was flagged"; fi
warm="$(find "$work/configs/bench" -name '*.json' | sort | tail -n 2 | head -n 1)"
if grep -qF "($(basename "$warm"))" "$work/out"; then fail "a run the cache answered was used as the last run"; fi
has '^Last run: .* \([0-9]{8}-[0-9]{6}\.json\)' "$work/out"
ok "a prefill the prompt cache answered is flagged and never compared with, nor are reports from before the cold prompts"

# bench-cold.py, against a stand-in for Halogen's tool: every prefill prompt starts with this
# run's word, the tool's own arguments reach it, and its JSON gains the passes with their cache hits.
cat > "$work/tool.py" <<'T'
import json, sys
calls = []
def lead_line(i):
    return "lead%d " % i
def ask(api, prompt, max_tokens, drafter, effort):
    calls.append(prompt)
    return {"usage": {"prompt_tokens": 300 if prompt.endswith("long") else 20}, "timings": {"cache_n": 7}}, 0.5
def main():
    ask("a", lead_line(0) + "short", 1, None, "low")
    ask("a", lead_line(1) + "long", 1, None, "low")
    ask("a", "tg prompt", 128, None, "low")
    print("header line\n")
    print(json.dumps({"argv": sys.argv[1:], "calls": calls, "rows": [{"test": "pp512"}]}))
    return 0
T
for i in 1 2; do
  python3 -I -c "$(cat "$repo/files/usr/share/halogen/bench-cold.py")" "$work/tool.py" --api x -r 3 > "$work/cold$i" \
    || fail "bench-cold.py failed"
done
[ "$(head -n 1 "$work/cold1")" = "header line" ] || fail "bench-cold.py lost the tool's header"
sed -n '/^{/,$p' "$work/cold1" > "$work/cold1.json"
jq -e '.argv == ["--api", "x", "-r", "3"] and (.calls[0] | test("^Run [0-9a-f]{12}\\. lead0 short$"))
       and (.calls[2] == "tg prompt") and .halos_cold.passes == [{"tokens": 300, "cached": 7}]' "$work/cold1.json" > /dev/null \
  || fail "bench-cold.py didn't make the prompts new or count the passes: $(cat "$work/cold1.json")"
[ "$(sed -n '/^{/,$p' "$work/cold2" | jq -r '.calls[0]')" != "$(jq -r '.calls[0]' "$work/cold1.json")" ] \
  || fail "two runs sent the same prompt"
# A tool that keeps lead_line but no longer uses it for the timed prompts: nothing gets the word.
sed 's/ask("a", lead_line(1) + "long"/ask("a", "same " + "long"/' "$work/tool.py" > "$work/tool3.py"
grep -q '"same "' "$work/tool3.py" || fail "the test couldn't make its changed tool"
if python3 -I -c "$(cat "$repo/files/usr/share/halogen/bench-cold.py")" "$work/tool3.py" > "$work/out" 2>&1; then
  fail "bench-cold.py reported a tool whose timed prompts it couldn't make new"
fi
has "only 0 of 1 prompt-reading passes started with this run's word" "$work/out"
if grep -q '"rows"' "$work/out"; then fail "bench-cold.py printed results it couldn't vouch for"; fi
printf 'def main():\n    return 0\n' > "$work/tool2.py"
if python3 -I -c "$(cat "$repo/files/usr/share/halogen/bench-cold.py")" "$work/tool2.py" > "$work/out" 2>&1; then
  fail "bench-cold.py ran a tool it can't make cold"
fi
has "Halogen's sweep tool has changed \(no lead_line, ask\)" "$work/out"
ok "bench-cold.py gives each run new prompts and counts the prompt cache's share, and refuses a changed tool"

has '--network=host --read-only --tmpfs /tmp --cap-drop=all --security-opt no-new-privileges -e HALOGEN_API_KEY ' "$work/podman.log"
has '-p 512,2048,8192,32768 -n 128 -r 3 --json' "$work/podman.log"
has 'ghcr\.io/peonist-ai/halogen-flash-server@sha256:1 -I -c # halogenctl bench runs' "$work/podman.log"
has '^sys\.exit\(rc\) /halogen/tools/halogen-bench\.py --api http://127\.0\.0\.1:18731 -p ' "$work/podman.log"
has '^key=secret-key-123$' "$work/podman.log"
grep -v '^key=' "$work/podman.log" > "$work/args" || true
if grep -q 'secret-key-123' "$work/args"; then fail "the key was on podman's command line"; fi
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
