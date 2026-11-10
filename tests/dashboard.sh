#!/bin/bash
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
# The dashboard (halos-dashboard.service): how it gets Halogen's API key, and the unit's sandbox.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/configs" "$work/run"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
ok() { echo "ok: $*"; }
fail() { echo "$*" >&2; exit 1; }
f id 'case "$*" in "-u halogen") echo 970 ;; "-g halogen") echo 971 ;; *) exec /usr/bin/id "$@" ;; esac'
# setpriv: records how it was asked to run, then runs the command as the caller.
f setpriv 'echo "setpriv $*" >> "$FAKE/setpriv.log"; while [ "$1" != -- ]; do shift; done; shift; exec "$@"'
export FAKE="$work" PATH="$work/bin:$PATH" HALOGEN_CONFIGS_DIR="$work/configs" RUNTIME_DIRECTORY="$work/run"
key="$repo/files/usr/libexec/halogen/dashboard-key"; run="$repo/files/usr/libexec/halogen/dashboard-run"

printf ' abc123\tdef,second-key\nthird\n' > "$work/configs/api-key"
"$key"
[ "$(cat "$work/run/api-key")" = abc123def ] || fail "kept more than the first key's printable characters: $(cat -A "$work/run/api-key")"
[ "$(stat -c %a "$work/run/api-key")" = 600 ] || fail "the key file is readable by others"
grep -qx 'setpriv --reuid=970 --regid=971 --clear-groups -- head -c 1024 .*/configs/api-key' "$work/setpriv.log" \
  || fail "the key wasn't read as the halogen user: $(cat "$work/setpriv.log")"
ok "the key is read as halogen, cut to the first key's printable characters, and kept private"

rm "$work/configs/api-key" "$work/run/api-key"
if "$key" 2> "$work/err"; then fail "no key passed"; fi
grep -q 'no API key' "$work/err" || fail "a missing key gave no message"
[ ! -e "$work/run/api-key" ] || fail "a missing key left a file"
: > "$work/configs/api-key"
if "$key" 2> /dev/null; then fail "an empty key passed"; fi
ok "a missing or empty key fails, so the unit tries again later"

printf 'k3y' > "$work/run/api-key"
f fake-dashboard 'echo "key=$HALOGEN_API_KEY url=$HALOGEN_URL"'
[ "$(HALOGEN_URL=http://127.0.0.1:8731 HALOS_DASHBOARD_BIN="$work/bin/fake-dashboard" "$run")" = "key=k3y url=http://127.0.0.1:8731" ] \
  || fail "dashboard-run didn't hand over the key"
ok "dashboard-run starts the dashboard with the key"

# The unit: never asks systemd (root) to read a file in halogen's folder; its own user; local Halogen.
u="$repo/files/usr/lib/systemd/system/halos-dashboard.service"
if grep -qE '^(LoadCredential|EnvironmentFile|ReadOnlyPaths|BindReadOnlyPaths)=.*(srv|configs)' "$u"; then fail "the unit reads halogen's folder as root"; fi
for want in '^ExecStartPre=\+/usr/libexec/halogen/dashboard-key$' '^DynamicUser=yes$' '^Environment=HALOGEN_URL=http://127.0.0.1:8731$' \
  '^Environment=HALOGEN_DASHBOARD_LISTEN=0.0.0.0:8790$' '^CapabilityBoundingSet=$' '^ProtectSystem=strict$' '^ProtectHome=yes$' '^MemoryMax='; do
  grep -qE "$want" "$u" || fail "the unit lacks $want"
done
grep -q 'port="8790"' "$repo/files/usr/lib/firewalld/services/halos-dashboard.xml" || fail "the firewall service isn't port 8790"
ok "the unit runs as its own user against the local Halogen, sandboxed, on port 8790"
