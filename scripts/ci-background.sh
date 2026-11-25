#!/bin/bash
# Run a slow CI step in the background while later steps go on, then wait for it where its
# result is needed (iso.yml: freeing disk space, installing the VM tools, pulling the ISO builder).
# Usage: scripts/ci-background.sh start <name> <command> [args...]
#        scripts/ci-background.sh wait <name> [seconds]   print its output, exit with its status
# The state lives in $RUNNER_TEMP/background (or $TMPDIR): <name>.log and, once done, <name>.rc.
set -euo pipefail
dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/background"
mkdir -p "$dir"
cmd="${1:-}"; name="${2:-}"
[[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "usage: $0 start|wait <name> ..." >&2; exit 2; }
case "$cmd" in
  start)
    shift 2
    [ "$#" -gt 0 ] || { echo "usage: $0 start <name> <command> [args...]" >&2; exit 2; }
    rm -f "$dir/$name.rc"
    : > "$dir/$name.log"
    # nohup and setsid: the step that starts it ends long before the command does.
    # The inner bash expands its own $0 (the state path) and $@ (the command).
    # shellcheck disable=SC2016
    nohup setsid bash -c '"$@" > "$0.log" 2>&1; echo $? > "$0.rc.new"; mv "$0.rc.new" "$0.rc"' \
      "$dir/$name" "$@" < /dev/null > /dev/null 2>&1 &
    echo "started $name in the background"
    ;;
  wait)
    limit="${3:-1800}"
    [[ "$limit" =~ ^[0-9]+$ ]] || { echo "bad time limit: $limit" >&2; exit 2; }
    [ -e "$dir/$name.log" ] || [ -e "$dir/$name.rc" ] || { echo "$name was never started" >&2; exit 1; }
    start=$SECONDS
    while [ ! -e "$dir/$name.rc" ]; do
      if [ $((SECONDS - start)) -ge "$limit" ]; then
        echo "$name didn't finish within $limit s; its output so far:" >&2
        cat "$dir/$name.log" >&2 || true
        exit 1
      fi
      sleep 2
    done
    echo "$name finished (waited $((SECONDS - start)) s); its output:"
    cat "$dir/$name.log" || true
    rc="$(cat "$dir/$name.rc")"
    [ "$rc" = 0 ] || echo "$name failed with exit status $rc" >&2
    exit "$rc"
    ;;
  *) echo "usage: $0 start|wait <name> ..." >&2; exit 2 ;;
esac
