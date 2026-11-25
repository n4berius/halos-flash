#!/bin/bash
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
# halogenctl bench tools' script against a fake tool-eval-bench, curl and render-config.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/configs"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
# The fake benchmark logs its arguments, folder and key, prints progress events on stderr and
# writes a result like tool-eval-bench 3.1.0's (--json-file). FAKE_SCORE sets the score,
# FAKE_ERROR makes it report a failure, FAKE_DIE makes it stop with nothing written.
f teb 'printf "%s\n" "$*" >> "$FAKE/teb.log"; echo "cwd=$PWD key=${TOOL_EVAL_API_KEY:-}" >> "$FAKE/teb.log"
echo "env proxy=${HTTP_PROXY:-}${http_proxy:-}${ALL_PROXY:-} no_proxy=${NO_PROXY:-}/${no_proxy:-} headers=${TOOL_EVAL_HEADERS:-}" >> "$FAKE/teb.log"
[ -z "${FAKE_DIE:-}" ] || { echo "{\"event\":\"error\",\"message\":\"Server returned 401. Check the URL and \\u001b[2Jkey.\"}" >&2; exit 2; }
echo "DeprecationWarning: not a JSON line" >&2
mkdir -p runs/2026/11; printf "model said \033]0;x\007 \033[2J and \302\233 bye\n" > runs/2026/11/r1.md
out=; for a in "$@"; do [ "${p:-}" = --json-file ] && out="$a"; p="$a"; done
runs=1; case " $* " in *" --trials 3 "*) runs=3 ;; esac
for _ in $(seq "$runs"); do i=0
  for c in TC-01:A TC-02:A TC-03:B; do
    st=pass; [ "${c%:*}" != TC-03 ] || st=fail
    echo "{\"event\":\"scenario_start\",\"scenario_id\":\"${c%:*}\",\"category\":\"${c#*:}\",\"index\":$i,\"total\":3}" >&2
    echo "{\"event\":\"scenario_result\",\"scenario_id\":\"${c%:*}\",\"status\":\"$st\",\"index\":$i,\"total\":3}" >&2
    i=$((i + 1))
  done
done
if [ -n "${FAKE_ERROR:-}" ]; then echo "{\"final_score\":null,\"error\":\"timeout\"}" > "$out"; exit 1; fi
s="${FAKE_SCORE:-67}"
ts=null
[ "$runs" = 1 ] || ts="$(cat <<T
{"trials":3,"final_score_mean":$s,"final_score_stddev":4.2,"pass_at_k":66.7,"pass_hat_k":33.3,
   "per_scenario":{"TC-01":{"mean":2},"TC-02":{"mean":1.5},"TC-03":{"mean":0}},
   "per_category":{"B":{"label":"Parameter \u001b]0;x\u0007Precision","mean_percent":0},"A":{"label":"Tool Selection","mean_percent":87.5}}}
T
)"
cat > "$out" <<EOF
{"schema_version":"1","final_score":$s,"rating":"★★★ Good","deployability":70,"responsiveness":80,
 "total_scenarios":3,"run_id":"r1","status":"completed","report_path":"$PWD/runs/2026/11/r1.md",
 "config":{"model":"halogen-q38fn"},"safety_warnings":["TC-03 \u001b[2Jleaked"],
 "scores":{"final_score":$s,"category_scores":[
   {"category":"A","label":"Tool Selection","percent":100,"pass_count":2,"partial_count":0,"fail_count":0},
   {"category":"B","label":"Parameter \u001b]0;x\u0007Precision","percent":0,"pass_count":0,"partial_count":0,"fail_count":1}],
  "excluded_scenarios":${FAKE_EXCLUDED:-[]},"scenario_results":[{"scenario_id":"TC-01","status":"pass","summary":"ok"},{"scenario_id":"TC-02","status":"pass","summary":"ok"},
   {"scenario_id":"TC-03","status":"fail","summary":"Did not \u001b[31mcall it."}]},
 "trial_statistics":$ts}
EOF'
f curl '[ -z "${FAKE_DOWN:-}" ]'
f df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\nx 1000000 1 ${FAKE_FREE:-900000} 1%% /\n"'
f render 'printf "HALOGEN_CHECKPOINT=/models/flash/mine/model.hgn\nHALOGEN_KV8=${FAKE_KV8:-1}\nHALOGEN_API_KEY_FILE=/run/secrets/x\n"'
printf 'HALOGEN_VERSION=0.20.7\nHALOGEN_VARIANT=npu\nHALOS_RELEASE=0.20.7-1-alpha\nTOOL_EVAL_BENCH_VERSION=3.1.0\n' > "$work/release.env"
echo 'secret-key-123' > "$work/configs/api-key"
export PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_CONFIGS_DIR="$work/configs" \
  HALOGEN_RENDER="$work/bin/render" HALOGEN_TOOL_EVAL_BENCH="$work/bin/teb"
bench="$repo/files/usr/libexec/halogen/bench-tools"
dir="$work/configs/bench/tools"
ok() { echo "ok: $*"; }
fail() { echo "$*" >&2; [ ! -f "$work/out" ] || cat "$work/out" >&2; exit 1; }
has() { grep -qE -- "$1" "$2" || fail "expected '$1' in $2"; }

HTTP_PROXY=http://198.51.100.1:3128 http_proxy=http://198.51.100.1:3128 TOOL_EVAL_HEADERS='X-Leak=1' \
  "$bench" > "$work/out" 2>&1 || fail "the full run failed"
has '^env proxy= no_proxy=\*/\* headers=$' "$work/teb.log"
has ' --model halogen-qwen3\.8-flash-next --json-file ' "$work/teb.log"
if grep -q $'[\e\a]\|\xc2\x9b' "$dir/runs/2026/11/r1.md"; then fail "the tool's own report kept the model's escape codes"; fi
has '^model said \]0;x \[2J and  bye$' "$dir/runs/2026/11/r1.md"
has '--trials 3 --temperature 1\.0 --seed 42 --base-url http://127\.0\.0\.1:18731 --backend halogen --model halogen-qwen3\.8-flash-next --json-file ' "$work/teb.log"
has "^cwd=$dir key=secret-key-123\$" "$work/teb.log"
if grep -v '^cwd=' "$work/teb.log" | grep -q 'secret-key-123'; then fail "the key was on the command line"; fi
has '^  run 1 of 3, 1/3 TC-01: pass$' "$work/out"
has '^  run 3 of 3, 2/3 TC-02: pass$' "$work/out"
has '^Score: 67 out of 100 \(±4\.2 between runs\)$' "$work/out"
has '^Reliable \(right in all 3 runs\): 33% of scenarios; right at least once: 67%$' "$work/out"
# Categories from the three runs' means: A (2 + 1.5) / 4 = 88%, B 0%.
has '^  A Tool Selection +88%$' "$work/out"
has '^  B Parameter \]0;xPrecision +0%$' "$work/out"
has '^  TC-03 \[2Jleaked$' "$work/out"
has '^No earlier full run to compare with' "$work/out"
txt="$(ls "$dir/"*.txt)"; json="${txt%.txt}.json"
has '^    HALOGEN_KV8=1$' "$txt"
has '^    TC-03 \(fail\): Did not \[31mcall it\.$' "$txt"
has "Every conversation: $dir/runs/2026/11/r1\\.md" "$txt"
if grep -q 'HALOGEN_KV8' "$work/out"; then fail "the settings list is on the screen, not only in the saved file"; fi
if grep -q $'[\e\a]' "$work/out" "$txt" "$json"; then fail "an escape code from the model reached the report"; fi
if grep -q 'secret-key-123\|API_KEY' "$txt" "$json"; then fail "the report holds the key or its setting"; fi
if [ "$(jq -r '.score' "$json")" != 67 ] || [ "$(jq -r '.system.tool_eval_bench' "$json")" != 3.1.0 ]; then
  fail "the JSON lost the score or the versions"
fi
[ -z "$(find "$dir" -maxdepth 1 -name '.*' -type f)" ] || fail "temporary files were left behind"
ok "a full run uses the leaderboard's settings, gets the key only through its environment, no proxy, and saves a readable report"

: > "$work/teb.log"
sleep 1
FAKE_SCORE=55 FAKE_KV8=0 FAKE_EXCLUDED='["TC-02"]' "$bench" --quick > "$work/out" 2>&1 || fail "the quick run failed"
has '^Not graded: 1 scenario \(TC-02\), because the server timed out or failed\.$' "$work/out"
has '^Score: 55 out of 100, good$' "$work/out"
has '^--short --seed 42 ' "$work/teb.log"
has '^  3/3 TC-03: fail$' "$work/out"
has '^No earlier quick run to compare with' "$work/out"
has '^  TC-03 \(fail\): Did not \[31mcall it\.$' "$work/out"
sleep 1
FAKE_SCORE=58 FAKE_KV8=0 "$bench" > "$work/out" 2>&1 || fail "the second full run failed"
has '^Score: 58 out of 100 .*; last run 67 \(-9\)$' "$work/out"
has '^  A Tool Selection +88% +same$' "$work/out"
has '^  HALOGEN_KV8 1 -> 0$' "$work/out"
latest="$(find "$dir" -maxdepth 1 -name '*.json' | sort | tail -n 1)"
# A link to a good result, a broken file, another shape, two values or an odd name is never used.
ln -s "$latest" "$dir/29991231-235959.json"
echo '{' > "$dir/29991231-235958.json"
jq '.categories = "x"' "$latest" > "$dir/29991231-235957.json"
jq -c . "$latest" | sed 's/^/{"run":"x"} /' > "$dir/29991231-235956.json"
cp "$latest" "$dir/9"$'\e'"]0;x-1.json"
jq '.date = "evil\u001b[2J" | .categories[0].percent = "50"' "$latest" > "$dir/29991231-235955.json"
sleep 1
FAKE_SCORE=58 FAKE_KV8=0 "$bench" > "$work/out" 2>&1 || fail "a run beside odd results failed"
has '^Last run: evil\[2J \(29991231-235955\.json\)' "$work/out"
has '^  A Tool Selection +88% +new$' "$work/out"
if grep -q $'[\e\a]' "$work/out"; then fail "an escape code from an old result reached the screen"; fi
rm "$dir/2999"* "$dir/9"*
ok "a run is compared with the last one of its kind, and odd earlier results are skipped"

n="$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l)"
if FAKE_DOWN=1 "$bench" > "$work/out" 2>&1; then fail "measured a server that isn't answering"; fi
has 'halogenctl status' "$work/out"
if FAKE_ERROR=1 "$bench" > "$work/out" 2>&1; then fail "a failed benchmark passed"; fi
has 'the benchmark failed: timeout' "$work/out"
if FAKE_DIE=1 "$bench" > "$work/out" 2>&1; then fail "a benchmark that stopped passed"; fi
has 'stopped before it gave a result \(exit 2\): Server returned 401\. Check the URL and \[2Jkey\.' "$work/out"
if "$bench" --long > "$work/out" 2>&1; then fail "took an unknown option"; fi
if FAKE_FREE=100000 "$bench" > "$work/out" 2>&1; then fail "ran with the configs volume almost full"; fi
has 'less than 200 MB free' "$work/out"
[ "$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l)" = "$n" ] || fail "a failed run left a report or a temporary file"
ok "it refuses a silent server, an unknown option, a full volume, and a failed or stopped benchmark leaves nothing behind"
