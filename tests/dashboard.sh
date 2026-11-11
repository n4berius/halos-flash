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
f fake-dashboard 'echo "key=$HALOGEN_API_KEY url=$HALOGEN_URL preload=${LD_PRELOAD:-}"'
cc -O2 -shared -fPIC -Wall -Wextra -Werror -o "$work/nodump.so" "$repo/src/dashboard-nodump.c" || fail "dashboard-nodump.c doesn't build"
: > "$work/broken.so"
[ "$(HALOGEN_URL=http://127.0.0.1:8731 HALOS_DASHBOARD_BIN="$work/bin/fake-dashboard" HALOS_DASHBOARD_NODUMP="$work/nodump.so" "$run")" \
  = "key=k3y url=http://127.0.0.1:8731 preload=$work/nodump.so" ] || fail "dashboard-run didn't hand over the key and the library"
for lib in missing.so broken.so; do
  if HALOS_DASHBOARD_BIN="$work/bin/fake-dashboard" HALOS_DASHBOARD_NODUMP="$work/$lib" "$run" > "$work/out" 2>&1; then
    fail "dashboard-run started with $lib instead of its not-dumpable library"
  fi
done
# The library really makes a process not dumpable: as an ordinary user, it can't read its own environ.
if [ "$(id -u)" = 0 ] && [ -x /usr/bin/setpriv ]; then
  install -m 0755 -d "$work/lib" && install -m 0644 "$work/nodump.so" "$work/lib/nodump.so"; chmod 0755 "$work"
  /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups cat /proc/self/environ > /dev/null 2>&1 || fail "the not-dumpable check itself is broken"
  if LD_PRELOAD="$work/lib/nodump.so" /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups cat /proc/self/environ > /dev/null 2>&1; then
    fail "dashboard-nodump.so leaves the process dumpable"
  fi
elif /usr/bin/cat /proc/self/environ > /dev/null && LD_PRELOAD="$work/nodump.so" /usr/bin/cat /proc/self/environ > /dev/null 2>&1; then
  fail "dashboard-nodump.so leaves the process dumpable"
fi
grep -q 'NODUMP:-/usr/lib64/halos/dashboard-nodump.so}' "$run" || fail "dashboard-run doesn't preload the image's library by default"
ok "dashboard-run starts the dashboard not dumpable, with the key, and refuses without the library"

# The unit: never asks systemd (root) to read a file in halogen's folder; its own user; local Halogen.
u="$repo/files/usr/lib/systemd/system/halos-dashboard.service"
if grep -qE '^(LoadCredential|EnvironmentFile|ReadOnlyPaths|BindReadOnlyPaths)=.*(srv|configs)' "$u"; then fail "the unit reads halogen's folder as root"; fi
for want in '^ExecStartPre=\+/usr/libexec/halogen/dashboard-key$' '^DynamicUser=yes$' '^Environment=HALOGEN_URL=http://127.0.0.1:18731$' \
  '^Environment=HALOGEN_DASHBOARD_LISTEN=127.0.0.1:18732$' '^CapabilityBoundingSet=$' '^ProtectSystem=strict$' '^ProtectHome=yes$' '^MemoryMax=' \
  '^CPUQuota=100%$' '^IPAddressDeny=any$' '^IPAddressAllow=localhost$' '^LimitCORE=0$' '^PrivateUsers=yes$' '^IPAccounting=yes$' '^SocketBindAllow=tcp:18732$' '^SocketBindDeny=any$'; do
  grep -qE "$want" "$u" || fail "the unit lacks $want"
done
grep -q 'port="8732"' "$repo/files/usr/lib/firewalld/services/halos-dashboard.xml" || fail "the firewall service isn't port 8732"
ok "the unit runs as its own user against the local Halogen, sandboxed, on 127.0.0.1:18732 behind Caddy"

# Caddy (halos-proxy.service) in front: the only one listening to the network on 8731 and 8732.
p="$repo/files/usr/lib/systemd/system/halos-proxy.service"; px="$repo/files/usr/share/halos/proxy"
cf="$px/Caddyfile"; sc="$px/sites.caddy"; cs="$px/Caddyfile.https"
q="$repo/files/etc/containers/systemd/users/970/halogen.container"
for want in '^ExecStart=/usr/libexec/halogen/caddy run --config \$\{HALOS_PROXY_CONFIG\} --adapter caddyfile$' '^DynamicUser=yes$' \
  '^ExecStartPre=\+/usr/libexec/halogen/https env$' '^Environment=HALOS_PROXY_CONFIG=/run/halos-https/missing$' '^EnvironmentFile=-/run/halos-https/proxy.env$' \
  '^CapabilityBoundingSet=$' '^NoNewPrivileges=yes$' '^ProtectSystem=strict$' '^PrivateUsers=yes$' '^MemoryMax=' '^LimitCORE=0$' \
  '^SocketBindAllow=tcp:8731$' '^SocketBindAllow=tcp:8732$' '^SocketBindDeny=any$' '^SystemCallFilter=@system-service$' '^EnvironmentFile=-/etc/halos/proxy.env$' '^Environment=GOMEMLIMIT=' '^ExecStartPre=/usr/libexec/halogen/caddy validate --config \$\{HALOS_PROXY_CONFIG\} --adapter caddyfile$'; do
  grep -qE "$want" "$p" || fail "halos-proxy.service lacks $want"
done
grep -qx 'PublishPort=127.0.0.1:18731:8731' "$q" || fail "Halogen is published beyond this machine"
grep -E '^PublishPort=' "$q" > "$work/ports"
if grep -vqx 'PublishPort=127.0.0.1:18731:8731' "$work/ports"; then fail "Halogen has another published port"; fi
for want in '^	admin off$' '^	auto_https off$' '^import /usr/share/halos/proxy/sites\.caddy$' '^http://:8731 \{$' '^http://:8732 \{$' \
  '^	import api$' '^	import dashboard$'; do
  grep -qE "$want" "$cf" || fail "the Caddyfile lacks $want"
done
for want in '^\(api\) \{$' '^\(dashboard\) \{$' '^	reverse_proxy 127\.0\.0\.1:18731 \{$' \
  '^	reverse_proxy 127\.0\.0\.1:18732 \{$' '^		flush_interval -1$' \
  '^	@outside not remote_ip 127\.0\.0\.0/8 ::1/128 10\.0\.0\.0/8 172\.16\.0\.0/12 192\.168\.0\.0/16 169\.254\.0\.0/16 fe80::/10 100\.64\.0\.0/10 fc00::/7 \{\$HALOS_DASHBOARD_ALLOW\}$' \
  '^	abort @outside$' '^			request>headers delete$' '^			request>uri regexp "\\\?\.\*" "\?\(query removed\)"$' '^	bind 0\.0\.0\.0$' \
  '^	tls internal$' '^	tls \{\$RUNTIME_DIRECTORY\}/cert\.pem \{\$RUNTIME_DIRECTORY\}/key\.pem$'; do
  grep -qE "$want" "$sc" || fail "sites.caddy lacks $want"
done
# HTTPS: the redirect from http:// on the same port, no port 80, no admin, never the system's trust store.
for want in '^	admin off$' '^	auto_https disable_redirects$' '^	skip_install_trust$' '^			http_redirect$' '^		protocols h1 h2$' \
  '^\{\$HALOS_API_SITES\} \{$' '^\{\$HALOS_DASH_SITES\} \{$' '^	import tls_\{\$HALOS_TLS\}$'; do
  grep -qE "$want" "$cs" || fail "Caddyfile.https lacks $want"
done
if cat "$cf" "$sc" "$cs" | grep -qiE 'log_credentials|header_up -?Authorization'; then fail "the Caddyfile would log or drop the API key"; fi
ok "Caddy alone faces the network: Halogen and the dashboard on 127.0.0.1, the dashboard only for private networks"
