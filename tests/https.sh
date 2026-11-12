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
# ip -o addr show scope global: two global addresses, a privacy address and one being set up.
cat > "$work/bin/ip" <<'S'
#!/bin/bash
cat <<'A'
2: eth0    inet 192.168.1.20/24 brd 192.168.1.255 scope global dynamic noprefixroute eth0\       valid_lft 86000sec preferred_lft 86000sec
3: tailscale0    inet 100.101.102.103/32 scope global tailscale0\       valid_lft forever preferred_lft forever
2: eth0    inet6 2001:db8::20/64 scope global dynamic noprefixroute \       valid_lft 86000sec preferred_lft 14000sec
2: eth0    inet6 2001:db8::abcd/64 scope global temporary dynamic \       valid_lft 86000sec preferred_lft 14000sec
2: eth0    inet6 2001:db8::beef/64 scope global tentative dynamic \       valid_lft 86000sec preferred_lft 14000sec
A
S
chmod +x "$work/bin/ip"
export PATH="$work/bin:$PATH" HALOS_HTTPS_ETC="$work/etc" HALOS_HTTPS_RUN="$work/run" HALOS_PROXY_STATE="$work/state" \
  HALOS_PROXY_SHARE=/usr/share/halos/proxy RUNTIME_DIRECTORY="$work/rt"
env_of() { cat "$work/run/proxy.env"; }

# Off by default (an upgrade keeps plain HTTP); a value it doesn't know stops Caddy's start, rather
# than serve the key in clear when HTTPS was meant.
[ "$("$h" mode)" = off ] || fail "a machine with no setting isn't on HTTP"
"$h" env; [ "$(env_of)" = "HALOS_PROXY_CONFIG=/usr/share/halos/proxy/Caddyfile" ] || fail "off doesn't give the HTTP Caddyfile: $(env_of)"
printf 'HALOS_HTTPS=Self-signed\n' > "$work/etc/https.env"; [ "$("$h" mode)" = invalid ] || fail "a mistyped mode isn't invalid"
cp "$work/run/proxy.env" "$work/before"
if "$h" env 2> "$work/err"; then fail "a mistyped mode started Caddy"; fi
if ! { grep -q 'halosctl https' "$work/err" && cmp -s "$work/before" "$work/run/proxy.env"; }; then fail "a mistyped mode changed proxy.env or didn't say what to do"; fi
printf 'HALOS_HTTPS=\n' > "$work/etc/https.env"; [ "$("$h" mode)" = off ] || fail "an empty mode isn't off"
ok "no setting is plain HTTP, and a mistyped one stops Caddy's start"

# Self-signed: this machine's names and addresses, and the extra names, each once.
"$h" set self-signed tailscale-box freyja.example 192.168.1.20
grep -qx 'HALOS_HTTPS=self-signed' "$work/etc/https.env" || fail "set didn't write the mode"
"$h" names > "$work/names"
for n in localhost 127.0.0.1 ::1 freyja.lan freyja freyja.local 192.168.1.20 100.101.102.103 2001:db8::20 tailscale-box freyja.example; do
  grep -qxF "$n" "$work/names" || fail "names lacks $n: $(paste -sd' ' "$work/names")"
done
[ "$(grep -cxF 192.168.1.20 "$work/names")" = 1 ] || fail "a name is listed twice"
if grep -qE 'abcd|beef' "$work/names"; then fail "a privacy or tentative IPv6 address was listed"; fi
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

# self-signed alone keeps the extra names; names given replace them.
"$h" set self-signed; grep -qx 'HALOS_HTTPS_NAMES=tailscale-box freyja.example 192.168.1.20' "$work/etc/https.env" || fail "set without names dropped them"
"$h" set self-signed other.example; grep -qx 'HALOS_HTTPS_NAMES=other.example' "$work/etc/https.env" || fail "names given didn't replace"
"$h" set self-signed tailscale-box freyja.example 192.168.1.20
# An address Caddy didn't start with is noticed, and refresh restarts Caddy only then.
cat > "$work/bin/systemctl" <<'S'
#!/bin/bash
echo "systemctl $*" >> "$FAKE_LOG"; case "$*" in *is-active*) echo active ;; esac
S
chmod +x "$work/bin/systemctl"; export FAKE_LOG="$work/sysctl.log"; : > "$FAKE_LOG"
"$h" env; [ -z "$("$h" uncovered)" ] || fail "uncovered addresses right after start: $("$h" uncovered)"
"$h" refresh; if grep -q restart "$FAKE_LOG"; then fail "refresh restarted Caddy with nothing new"; fi
sed -i 's|, https://100.101.102.103:8731||' "$work/run/proxy.env"
[ "$("$h" uncovered)" = 100.101.102.103 ] || fail "a new address isn't noticed: $("$h" uncovered)"
"$h" refresh > /dev/null; grep -q 'try-restart halos-proxy.service' "$FAKE_LOG" || fail "refresh didn't restart Caddy for a new address"
: > "$FAKE_LOG"; "$h" set off; "$h" refresh; if grep -q restart "$FAKE_LOG"; then fail "refresh acted outside self-signed mode"; fi
"$h" set self-signed tailscale-box freyja.example 192.168.1.20
ok "self-signed alone keeps the extra names, and a new address gets Caddy restarted, only then"

# Names that could break out of the Caddyfile are refused.
# shellcheck disable=SC2016 # literal: a Caddy placeholder must not get through
for bad in 'a b' 'x;y' '{$HOME}' 'a}' '-x' 'http://x' "$(printf 'a\nb')"; do
  if "$h" set self-signed "$bad" 2> /dev/null; then fail "set took the name '$bad'"; fi
done
printf 'HALOS_HTTPS=self-signed\nHALOS_HTTPS_NAMES=good.example {bad} a;b *\n' > "$work/etc/https.env"
mkdir -p "$work/cwd"; touch "$work/cwd/globbed.example"
(cd "$work/cwd" && "$h" names) > "$work/names"
grep -qx good.example "$work/names" || fail "a good extra name was dropped"
if grep -qE '[{};*]' "$work/names"; then fail "a bad name from a hand-edited file got through"; fi
if grep -q globbed "$work/names"; then fail "a * in the names was expanded to file names"; fi
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
if "$h" stage "$work/good.crt" "$work/other.key" 2> /dev/null; then fail "a key of another certificate was taken"; fi
if "$h" stage "$work/good.key" "$work/good.key" 2> /dev/null; then fail "a key was taken as the certificate"; fi
if "$h" stage "$work/old.crt" "$work/old.key" 2> /dev/null || "$h" stage "$work/old.crt" "$work/good.key" 2> /dev/null; then
  fail "an expired certificate was taken"
fi
[ ! -e "$work/etc/https/.pending" ] || fail "a refused pair was left staged"
# Only certificates and the key reach Caddy, whatever else the files held.
{ echo "a comment someone left"; cat "$work/good.crt"; } > "$work/noisy.crt"
"$h" stage "$work/noisy.crt" "$work/good.key"
[ ! -e "$work/etc/https/cert.pem" ] || fail "staging put a certificate in use"
if grep -q comment "$work/etc/https/.pending/cert.pem"; then fail "text around the certificate was kept"; fi
"$h" discard; [ ! -e "$work/etc/https/.pending" ] || fail "discard left the staged pair"
"$h" stage "$work/good.crt" "$work/good.key"; "$h" commit
if [ "$(stat -c %a "$work/etc/https")" != 700 ] || [ "$(stat -c %a "$work/etc/https/key.pem")" != 600 ]; then fail "the key isn't private"; fi
"$h" set custom
"$h" env
if ! { grep -qx 'HALOS_TLS=custom' "$work/run/proxy.env" && grep -qx 'HALOS_API_SITES=https://:8731' "$work/run/proxy.env"; }; then fail "custom env is wrong: $(env_of)"; fi
if ! { cmp -s "$work/rt/key.pem" "$work/good.key" && cmp -s "$work/rt/cert.pem" "$work/good.crt"; }; then fail "the certificate wasn't copied for Caddy"; fi
[ "$(stat -c %a "$work/rt/key.pem")" = 600 ] || fail "the key copy isn't private"
"$h" describe > "$work/d"
if ! { grep -qx 'mode custom' "$work/d" && grep -q '^subject CN=freyja.example' "$work/d" && grep -qx 'expires later' "$work/d"; }; then fail "describe: $(cat "$work/d")"; fi
"$h" stage "$work/soon.crt" "$work/soon.key"; "$h" commit; "$h" describe | grep -qx 'expires soon' || fail "a certificate ending within 14 days isn't flagged"
openssl x509 -in "$work/etc/https/.prev-cert.pem" -noout -subject | grep -q freyja.example || fail "commit didn't keep the previous certificate"
"$h" restore; openssl x509 -in "$work/etc/https/cert.pem" -noout -subject | grep -q freyja.example || fail "restore didn't put the previous certificate back"
ok "your own certificate: refused if wrong or expired, staged until committed, re-encoded, kept private with the previous one, and handed to Caddy"

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
# A link to a real certificate outside Caddy's state, or a folder of Caddy's pointing outside it.
mkdir -p "$work/outside/local"; cp "$work/good.crt" "$work/outside/root.crt"; cp "$work/good.crt" "$work/outside/local/root.crt"
rm "$ca"; ln -s "$work/outside/root.crt" "$ca"
if "$h" ca > "$work/out" 2>&1; then fail "ca followed a link to a certificate outside Caddy's state"; fi
rm "$ca"; mv "$work/state/caddy/pki/authorities/local" "$work/state/caddy/pki/authorities/local.real"
ln -s "$work/outside/local" "$work/state/caddy/pki/authorities/local"
if "$h" ca > "$work/out" 2>&1; then fail "ca followed a folder link outside Caddy's state"; fi
rm "$work/state/caddy/pki/authorities/local"; mv "$work/state/caddy/pki/authorities/local.real" "$work/state/caddy/pki/authorities/local"; cp "$work/good.crt" "$ca"
printf 'HALOS_HTTPS=self-signed\n' > "$work/etc/https.env"; rm "$ca"; cp "$work/good.crt" "$ca"
"$h" describe > "$work/d"; grep -qE '^ca ([0-9A-F]{2}:){31}[0-9A-F]{2}$' "$work/d" || fail "describe has no fingerprint: $(cat "$work/d")"
# A FIFO where the authority should be (only Caddy's user could put one there) can't hold root's tools.
rm "$ca"; mkfifo "$ca"
start=$SECONDS; if timeout 20 "$h" ca > /dev/null 2>&1; then fail "ca read a FIFO"; fi
timeout 20 "$h" describe > "$work/d" || true
[ $((SECONDS - start)) -lt 15 ] || fail "a FIFO at the authority's path held the helper"
grep -qx 'ca none' "$work/d" || fail "describe with a FIFO: $(cat "$work/d")"
ok "ca prints only a certificate, never a file the authority's path was pointed at"

# Let's Encrypt: the DNS provider's credentials are staged from stdin, kept root's, and copied for
# Caddy only when the mode needs them; anything missing stops Caddy's start.
printf 'HALOS_HTTPS=\n' > "$work/etc/https.env"
if "$h" set letsencrypt cloudflare halos.example.com 2> /dev/null; then fail "letsencrypt was set without credentials"; fi
if printf 'api_key=x\n' | "$h" dns-stage cloudflare 2> "$work/err"; then fail "a field cloudflare doesn't take was staged"; fi
if printf 'api_token=two words\n' | "$h" dns-stage cloudflare 2> "$work/err"; then fail "a value with a space was staged"; fi
if grep -q 'two words' "$work/err"; then fail "a refused value was printed back"; fi
if printf 'api_key=pk1_x\n' | "$h" dns-stage porkbun 2> /dev/null; then fail "porkbun was staged without its secret key"; fi
if printf 'api_token=short\n' | "$h" dns-stage duckdns 2> /dev/null; then fail "a DuckDNS token of the wrong length was staged"; fi
if printf 'api_key=k\nuser=u\nclient_ip=example.com\n' | "$h" dns-stage namecheap 2> /dev/null; then fail "namecheap took a client_ip that isn't an address"; fi
if printf 'api_token=cf-token-1\n' | "$h" dns-stage cloudflare 2> /dev/null; then fail "a token caddy-dns/cloudflare would refuse (printing it) was staged"; fi
printf 'api_token=cf-token-1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' | "$h" dns-stage cloudflare   # no final newline: still read
"$h" dns-commit
[ "$(cat "$work/etc/https/dns/api_token")" = cf-token-1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ] || fail "the staged token wasn't put in place"
if ! { [ "$(stat -c %a "$work/etc/https/dns")" = 700 ] && [ "$(stat -c %a "$work/etc/https/dns/api_token")" = 600 ]; }; then fail "the credentials aren't root's alone"; fi
for bad in 192.168.1.20 freyja freyja.local box.lan 2001:db8::20 'a.example.com;b' '*.example.com'; do
  if "$h" set letsencrypt cloudflare "$bad" 2> /dev/null; then fail "letsencrypt took $bad, which it can't certify"; fi
done
if "$h" set letsencrypt cloudflare halos.example.com --email not-an-address 2> /dev/null; then fail "a bad email address was set"; fi
"$h" set letsencrypt cloudflare Halos.Example.com --email admin@example.com
if ! { grep -qx 'HALOS_HTTPS_NAMES=halos.example.com' "$work/etc/https.env" && grep -qx 'HALOS_ACME_DNS=cloudflare' "$work/etc/https.env" && grep -qx 'HALOS_ACME_STAGING=0' "$work/etc/https.env"; }; then fail "set letsencrypt wrote: $(cat "$work/etc/https.env")"; fi
"$h" env
if ! { grep -qx 'HALOS_PROXY_CONFIG=/usr/share/halos/proxy/Caddyfile.letsencrypt' "$work/run/proxy.env"   && grep -qx 'HALOS_ACME_API_SITES="https://halos.example.com:8731"' "$work/run/proxy.env"   && grep -qx 'HALOS_ACME_DASH_SITES="https://halos.example.com:8732"' "$work/run/proxy.env"   && grep -qx 'HALOS_ACME_DNS=cloudflare' "$work/run/proxy.env"   && grep -qx 'HALOS_ACME_CA=https://acme-v02.api.letsencrypt.org/directory' "$work/run/proxy.env"   && grep -qx 'HALOS_ACME_EMAIL_SET=yes' "$work/run/proxy.env" && grep -qx 'HALOS_ACME_EMAIL=admin@example.com' "$work/run/proxy.env"; }; then fail "letsencrypt's proxy.env: $(env_of)"; fi
grep -q '^HALOS_API_SITES="https://localhost:8731, .*https://192.168.1.20:8731' "$work/run/proxy.env" || fail "the local names lost halOS's authority: $(env_of)"
if grep '^HALOS_API_SITES=' "$work/run/proxy.env" | grep -q halos.example.com; then fail "a public name is also a local site"; fi
if grep -q cf-token-1- "$work/run/proxy.env"; then fail "the token is in proxy.env"; fi
for f in "$work/rt"/dns_*; do [ ! -e "$f" ] || fail "a DNS credential was copied into Caddy's runtime folder (systemd loads them)"; done
ok "Let's Encrypt: credentials only from stdin, checked, root's, never copied for Caddy; public names only"

"$h" set letsencrypt cloudflare halos.example.com --staging
if ! { "$h" env; grep -qx 'HALOS_ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory' "$work/run/proxy.env" && grep -qx 'HALOS_ACME_EMAIL_SET=no' "$work/run/proxy.env"; }; then fail "staging, without email: $(env_of)"; fi
# A second provider's credentials replace the first; restore puts them back (halosctl, on failure).
printf 'api_key=pk1_a\napi_secret_key=sk1_b\n' | "$h" dns-stage porkbun
"$h" dns-commit
if ! { [ "$(cat "$work/etc/https/dns/provider")" = porkbun ] && [ ! -e "$work/etc/https/dns/api_token" ]; }; then fail "the old provider's token stayed"; fi
"$h" dns-restore
if ! { [ "$(cat "$work/etc/https/dns/provider")" = cloudflare ] && [ "$(cat "$work/etc/https/dns/api_token")" = cf-token-1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ]; }; then fail "restore didn't put cloudflare's back"; fi
# Fail closed: a missing credential or provider stops Caddy's start.
cp "$work/run/proxy.env" "$work/before"
rm "$work/etc/https/dns/api_token"
if "$h" env 2> "$work/err"; then fail "letsencrypt without its token started"; fi
cmp -s "$work/before" "$work/run/proxy.env" || fail "a failed start changed proxy.env"
grep -q 'halosctl https' "$work/err" || fail "the failure doesn't say what to do"
sed -i 's/^HALOS_ACME_DNS=.*/HALOS_ACME_DNS=route53/' "$work/etc/https.env"
if "$h" env 2> /dev/null; then fail "an unknown DNS provider started"; fi
[ "$("$h" describe | sed -n 's/^mode //p')" = letsencrypt ] || fail "describe doesn't name the mode"
ok "staging, a second provider and restore, and fail-closed on a missing credential or provider"
# Audit (#108): a token pasted without field= is never printed back; a malformed token in the file
# (hand-edited) stops the start without reaching Caddy, whose Cloudflare plugin would print it.
if printf 'cfut_PASTEDSECRETPASTEDSECRETPASTEDSECRET\n' | "$h" dns-stage cloudflare 2> "$work/err"; then fail "a bare token was staged"; fi
if grep -q PASTEDSECRET "$work/err"; then fail "a bare token was printed back"; fi
printf 'api_token=cf-token-1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' | "$h" dns-stage cloudflare; "$h" dns-commit
"$h" set letsencrypt cloudflare halos.example.com
printf 'bad token HANDEDITED' > "$work/etc/https/dns/api_token"
if "$h" env 2> "$work/err"; then fail "a malformed token on disk started Caddy"; fi
if grep -q HANDEDITED "$work/err"; then fail "a malformed token was printed"; fi
# A good token with extra newlines: Caddy would pass one on, and the plugin would print it.
printf 'cf-token-1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n\n' > "$work/etc/https/dns/api_token"
if "$h" env 2> /dev/null; then fail "a token file with trailing newlines started Caddy"; fi
# set --check: names and email checked without credentials, nothing written.
cp "$work/etc/https.env" "$work/before"
"$h" set --check letsencrypt porkbun other.example.com || fail "set --check needed credentials"
if "$h" set --check letsencrypt porkbun box.local 2> /dev/null; then fail "set --check took .local"; fi
cmp -s "$work/before" "$work/etc/https.env" || fail "set --check wrote the settings"
if "$h" dns-forget 2> /dev/null; then fail "dns-forget removed the credentials Let's Encrypt is using"; fi
# Back to self-signed: the public names aren't kept as extra names.
"$h" set self-signed
grep -qx 'HALOS_HTTPS_NAMES=' "$work/etc/https.env" || fail "self-signed kept the Let's Encrypt names: $(cat "$work/etc/https.env")"
"$h" dns-forget; [ ! -e "$work/etc/https/dns" ] || fail "dns-forget left the credentials"
ok "a pasted or hand-edited token is never printed or given to Caddy; set --check; forget"

