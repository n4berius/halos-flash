#!/bin/bash
# scripts/ci-background.sh: a step started in the background is waited for with its output and
# exit status, a slow one fails at its time limit, and a name never started fails at once.
set -euo pipefail
cd "$(dirname "$0")/.."
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
export RUNNER_TEMP="$t"
scripts/ci-background.sh start good bash -c 'sleep 1; echo hello' > /dev/null
scripts/ci-background.sh start bad bash -c 'echo oops; exit 3' > /dev/null
scripts/ci-background.sh start slow sleep 30 > /dev/null
scripts/ci-background.sh wait good 20 > "$t/out"
grep -qx hello "$t/out" || { echo "the output wasn't shown" >&2; exit 1; }
rc=0; scripts/ci-background.sh wait bad 20 > "$t/out" 2>&1 || rc=$?
if [ "$rc" != 3 ] || ! grep -qx oops "$t/out"; then echo "a failure wasn't passed on (exit $rc)" >&2; exit 1; fi
if scripts/ci-background.sh wait slow 2 > /dev/null 2>&1; then echo "a slow step passed its time limit" >&2; exit 1; fi
pkill -f '^sleep 30$' 2> /dev/null || true
if scripts/ci-background.sh wait never 2 > /dev/null 2>&1; then echo "a step never started passed" >&2; exit 1; fi
if scripts/ci-background.sh start 'a/b' true > /dev/null 2>&1; then echo "a name with a slash was taken" >&2; exit 1; fi
echo "ok: background steps pass on their output and status, and time out"
