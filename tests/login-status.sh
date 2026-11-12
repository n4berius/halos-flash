#!/bin/bash
# The login screen and SSH status line, against fake systemctl, curl, du, halosctl and wall.
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/models" "$work/run"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
f systemctl 'echo "systemctl $* as=${FAKE_AS:-root} rt=${XDG_RUNTIME_DIR:-}" >> "$FAKE/log"; [ -z "${FAKE_NOBUS:-}" ] || exit 1; echo "${FAKE_FETCH:-inactive}"; echo "${FAKE_SERVER:-inactive}"'
f curl 'echo "curl $*" >> "$FAKE/log"; printf "%s" "${FAKE_HEALTH:-000}"'
f setpriv 'echo "setpriv $*" >> "$FAKE/log"; [ "$1 $2 $3 $4" = "--reuid=970 --regid=970 --clear-groups --" ] || exit 9; shift 4; FAKE_AS=halogen exec "$@"'
f runuser 'echo "runuser $*" >> "$FAKE/log"; exit 9'
f du 'printf "%s\t%s\n" "${FAKE_HAVE:-0}" "$*"'
f df 'printf "Avail\n 900\n"'
f halosctl 'echo "halosctl $*" >> "$FAKE/log"; printf "halOS x\nChannel:   edge\nHalogen:   0.19.1 (img)\nImage:     y\nNext boot: no change staged\nRollback:  z\n"'
f agetty 'echo "agetty $*" >> "$FAKE/log"'
f wall 'echo "wall $*" >> "$FAKE/log"'
f hostname 'echo freyja'
printf 'HALOS_RELEASE=0.19.1-beta.1\nHALOGEN_VARIANT=npu\n' > "$work/release.env"
export PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_MODELS_DIR="$work/models" HALOS_RUN_DIR="$work/run"
status="$repo/files/usr/libexec/halogen/login-status"
issue="$work/run/issue.d/50-halos.issue"; motd="$work/run/motd.d/50-halos"
ok() { echo "ok: $*"; }
expect() { grep -qF -- "$2" "$1" || { echo "expected '$2' in $1:" >&2; cat "$1" >&2; exit 1; }; }
run() { : > "$work/log"; "$status" || { echo "login-status failed" >&2; exit 1; }; }

FAKE_FETCH=activating FAKE_HAVE=50 run
expect "$issue" 'halOS 0.19.1-beta.1 (npu edition) - downloading models 40%'
grep -q 'setpriv --reuid=970 --regid=970 --clear-groups -- du' "$work/log" || { echo "du ran as root" >&2; exit 1; }
grep -q 'systemctl --user is-active halogen-fetch.service halogen.service as=halogen rt=/run/user/970' "$work/log" || { echo "the service manager was not asked as halogen" >&2; exit 1; }
if grep -qE 'runuser|--machine' "$work/log"; then echo "a login session was opened" >&2; exit 1; fi
grep -q 'agetty --reload' "$work/log" || { echo "the login prompt was not redrawn" >&2; exit 1; }
FAKE_FETCH=activating FAKE_HAVE=50 run
if grep -q agetty "$work/log"; then echo "redrawn though nothing changed" >&2; exit 1; fi
touch "$work/models/.fetch-stamp"; FAKE_FETCH=activating run
expect "$issue" '- checking models'
FAKE_FETCH=failed run
expect "$issue" 'download failed: sudo halogenctl fetch-logs'
FAKE_SERVER=activating run
expect "$issue" '- starting'
FAKE_SERVER=active FAKE_HEALTH=503 run
expect "$issue" '- starting'
ok "the console line follows the download, the check and the start, and redraws only on a change"

FAKE_SERVER=active FAKE_HEALTH=200 run
expect "$issue" '- ready: http://\4:8731/v1'
expect "$motd" 'ready: http://freyja:8731/v1'
expect "$motd" 'Channel:   edge'
expect "$motd" '900 GiB free'
if grep -qE 'Image:|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$motd"; then echo "the SSH message shows more than it should" >&2; exit 1; fi
grep -q 'wall halOS: Halogen is ready at http://freyja:8731/v1' "$work/log" || { echo "no ready notice" >&2; exit 1; }
grep -q 'curl .*http://127.0.0.1:18731/health' "$work/log" || { echo "login-status doesn't ask Halogen directly" >&2; exit 1; }
if grep -q 'curl .*:8731/health' "$work/log"; then echo "login-status asks through Caddy (an access-log line every 30 s)" >&2; exit 1; fi
FAKE_SERVER=active FAKE_HEALTH=200 run
if grep -q wall "$work/log"; then echo "the ready notice repeated" >&2; exit 1; fi
if grep -q systemctl "$work/log"; then echo "asked the service manager though Halogen answers" >&2; exit 1; fi
if grep -q halosctl "$work/log"; then echo "halosctl ran again within 10 minutes" >&2; exit 1; fi
ok "ready shows the address on the console, the name over SSH, and is announced once"
printf '#!/bin/bash\n[ "$1" = mode ] && echo self-signed\n' > "$work/https"; chmod +x "$work/https"
HALOS_HTTPS_HELPER="$work/https" FAKE_SERVER=active FAKE_HEALTH=200 run
expect "$issue" '- ready: https://\4:8731/v1'
expect "$motd" 'ready: https://freyja:8731/v1'
ok "with HTTPS on, the address says https://"

FAKE_SERVER=failed run
expect "$issue" 'stopped: sudo halogenctl logs'
FAKE_SERVER=inactive run
expect "$issue" 'stopped: sudo halogenctl logs'
[ "$(grep -c '^systemctl' "$work/log")" = 1 ] || { echo "not one service-manager call per run" >&2; exit 1; }
FAKE_NOBUS=1 run
expect "$issue" '- starting up'
ok "a stopped or failed Halogen says where to look, with one service-manager call per run"

# What du prints comes from another user's process: only a number is used.
rm -f "$work/models/.fetch-stamp"
FAKE_FETCH=activating FAKE_HAVE='a[$(touch $FAKE/pwned)]' run
[ ! -e "$work/pwned" ] || { echo "du output ran as a command" >&2; exit 1; }
expect "$issue" 'downloading models 0%'
grep -q "setpriv --reuid=970 --regid=970 --clear-groups -- test -f $work/models/.fetch-stamp" "$work/log" || { echo "the stamp was checked as root" >&2; exit 1; }
ok "du's output is used only as a number, and the stamp is checked as halogen"

# A new install waits for first-boot setup, and the line says how to do it.
mkdir -p "$work/state"; touch "$work/state/setup-pending"
FAKE_FETCH=activating HALOGEN_STATE_DIR="$work/state" run
expect "$issue" '- waiting for setup: sudo halosctl setup'
ok "a new install's line says to run setup"

