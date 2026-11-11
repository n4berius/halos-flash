#!/bin/bash
# HTTPS for the front door (/usr/libexec/halogen/https): the mode, the names a self-signed
# certificate covers, what halos-proxy gets before Caddy starts, and certificate checks.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
h="$repo/files/usr/libexec/halogen/https"
fail() { echo "https: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
mkdir -p "$work/bin" "$work/etc" "$work/run" "$work/rt" "$work/state/caddy/pki/authorities/local"
cat > "$work/bin/hostname" <<'S'
#!/bin/bash
case "${1:-}" in -I) echo "192.168.1.20 100.101.102.103 2001:db8::20 " ;; *) echo freyja.lan ;; esac
S
chmod +x "$work/bin/hostname"
export PATH="$work/bin:$PATH" HALOS_HTTPS_ETC="$work/etc" HALOS_HTTPS_RUN="$work/run" HALOS_PROXY_STATE="$work/state" \
  HALOS_PROXY_SHARE=/usr/share/halos/proxy RUNTIME_DIRECTORY="$work/rt"
env_of() { cat "$work/run/proxy.env"; }

# Off by default (an upgrade keeps plain HTTP), and anything unknown counts as off.
[ "$("$h" mode)" = off ] || fail "a machine with no setting isn't on HTTP"
"$h" env; [ "$(env_of)" = "HALOS_PROXY_CONFIG=/usr/share/halos/proxy/Caddyfile" ] || fail "off doesn't give the HTTP Caddyfile: $(env_of)"
printf 'HALOS_HTTPS=sometimes\n' > "$work/etc/https.env"; [ "$("$h" mode)" = off ] || fail "an unknown mode isn't off"
ok "no setting, or an unknown one, is plain HTTP"

# Self-signed: this machine's names and addresses, and the extra names, each once.
"$h" set self-signed tailscale-box freyja.example 192.168.1.20
grep -qx 'HALOS_HTTPS=self-signed' "$work/etc/https.env" || fail "set didn't write the mode"
"$h" names > "$work/names"
for n in localhost 127.0.0.1 ::1 freyja.lan freyja freyja.local 192.168.1.20 100.101.102.103 2001:db8::20 tailscale-box freyja.example; do
  grep -qxF "$n" "$work/names" || fail "names lacks $n: $(paste -sd' ' "$work/names")"
done
[ "$(grep -cxF 192.168.1.20 "$work/names")" = 1 ] || fail "a name is listed twice"
"$h" env
grep -qx 'HALOS_PROXY_CONFIG=/usr/share/halos/proxy/Caddyfile.https' "$work/run/proxy.env" || fail "self-signed doesn't give Caddyfile.https"
grep -qx 'HALOS_TLS=internal' "$work/run/proxy.env" || fail "self-signed doesn't use Caddy's authority"
grep -q '^HALOS_API_SITES="https://localhost:8731, https://127.0.0.1:8731, https://\[::1\]:8731, ' "$work/run/proxy.env" \
  || fail "the API sites are wrong: $(env_of)"
grep -q 'https://\[2001:db8::20\]:8731' "$work/run/proxy.env" || fail "an IPv6 address isn't bracketed"
grep '^HALOS_DASH_SITES=' "$work/run/proxy.env" > "$work/dash"
grep -q 'https://192.168.1.20:8732' "$work/dash" || fail "the dashboard has no site for the LAN address"
if grep -q '\[' "$work/dash"; then fail "the dashboard (IPv4 only) got IPv6 sites"; fi
[ "$(stat -c %a "$work/run/proxy.env")" = 644 ] || fail "proxy.env isn't 644"
ok "self-signed covers this machine's names and addresses and the extra names, the dashboard on IPv4"

# Names that could break out of the Caddyfile are refused.
# shellcheck disable=SC2016 # literal: a Caddy placeholder must not get through
for bad in 'a b' 'x;y' '{$HOME}' 'a}' '-x' 'http://x' "$(printf 'a\nb')"; do
  if "$h" set self-signed "$bad" 2> /dev/null; then fail "set took the name '$bad'"; fi
done
printf 'HALOS_HTTPS=self-signed\nHALOS_HTTPS_NAMES=good.example {bad} a;b\n' > "$work/etc/https.env"
"$h" names > "$work/names"
grep -qx good.example "$work/names" || fail "a good extra name was dropped"
if grep -qE '[{};]' "$work/names"; then fail "a bad name from a hand-edited file got through"; fi
ok "names that aren't plain host names or addresses are refused, also from a hand-edited file"

# Custom: the certificate is checked, kept private, and copied for Caddy's user at start.
o() { openssl "$@" 2> /dev/null; }
mk() { o req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1.key" -out "$1.crt" -subj "/CN=$2" -days "$3"; }
mk "$work/good" freyja.example 30
mk "$work/other" other.example 30
mk "$work/soon" soon.example 5
o req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$work/old.key" -out "$work/old.crt" -subj /CN=old -not_before 20200101000000Z -not_after 20200201000000Z \
  || o x509 -req -in <(o req -new -key "$work/good.key" -subj /CN=old) -signkey "$work/good.key" -days -1 -out "$work/old.crt"
if "$h" set custom 2> /dev/null; then fail "custom was set with no certificate installed"; fi
if "$h" install "$work/good.crt" "$work/other.key" 2> /dev/null; then fail "a key of another certificate was taken"; fi
if "$h" install "$work/good.key" "$work/good.key" 2> /dev/null; then fail "a key was taken as the certificate"; fi
if "$h" install "$work/old.crt" "$work/old.key" 2> /dev/null || "$h" install "$work/old.crt" "$work/good.key" 2> /dev/null; then
  fail "an expired certificate was taken"
fi
"$h" install "$work/good.crt" "$work/good.key"
if [ "$(stat -c %a "$work/etc/https")" != 700 ] || [ "$(stat -c %a "$work/etc/https/key.pem")" != 600 ]; then fail "the key isn't private"; fi
"$h" set custom
"$h" env
if ! { grep -qx 'HALOS_TLS=custom' "$work/run/proxy.env" && grep -qx 'HALOS_API_SITES=https://:8731' "$work/run/proxy.env"; }; then fail "custom env is wrong: $(env_of)"; fi
if ! { cmp -s "$work/rt/key.pem" "$work/good.key" && cmp -s "$work/rt/cert.pem" "$work/good.crt"; }; then fail "the certificate wasn't copied for Caddy"; fi
[ "$(stat -c %a "$work/rt/key.pem")" = 600 ] || fail "the key copy isn't private"
"$h" describe > "$work/d"
if ! { grep -qx 'mode custom' "$work/d" && grep -q '^subject CN=freyja.example' "$work/d" && grep -qx 'expires later' "$work/d"; }; then fail "describe: $(cat "$work/d")"; fi
"$h" install "$work/soon.crt" "$work/soon.key"; "$h" describe | grep -qx 'expires soon' || fail "a certificate ending within 14 days isn't flagged"
ok "your own certificate: a wrong key, a non-certificate and an expired one are refused; it is kept private and handed to Caddy"

# Fail closed: custom without its files stops Caddy's start and leaves the last settings alone.
cp "$work/run/proxy.env" "$work/before"
rm "$work/etc/https/key.pem"
if "$h" env 2> "$work/err"; then fail "custom without its key started"; fi
grep -q 'halosctl https' "$work/err" || fail "the failure doesn't say what to do"
cmp -s "$work/before" "$work/run/proxy.env" || fail "a failed start changed proxy.env"
if ls "$work/run"/.proxy.env.* > /dev/null 2>&1; then fail "a failed start left a temporary file"; fi
ok "custom without its certificate doesn't start, rather than serve in clear"

# The authority's certificate: only a certificate is ever printed, whatever the file is.
ca="$work/state/caddy/pki/authorities/local/root.crt"
if "$h" ca 2> /dev/null; then fail "ca printed something with no authority"; fi
cp "$work/good.crt" "$ca"; "$h" ca | grep -q 'BEGIN CERTIFICATE' || fail "ca doesn't print the certificate"
printf 'root:secret-hash:1:2:3\n' > "$work/secret"; rm "$ca"; ln -s "$work/secret" "$ca"
if "$h" ca > "$work/out" 2>&1; then fail "ca followed a link to a non-certificate"; fi
if grep -q secret "$work/out"; then fail "ca printed the linked file"; fi
printf 'HALOS_HTTPS=self-signed\n' > "$work/etc/https.env"; rm "$ca"; cp "$work/good.crt" "$ca"
"$h" describe > "$work/d"; grep -qE '^ca ([0-9A-F]{2}:){31}[0-9A-F]{2}$' "$work/d" || fail "describe has no fingerprint: $(cat "$work/d")"
ok "ca prints only a certificate, never a file the authority's path was pointed at"
