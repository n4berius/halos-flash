#!/bin/bash
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
# Unlock over SSH (#13): the ssh-unlock helper against a fake EFI partition and a fake curl, and
# halosctl ssh-unlock on top of it.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v ssh-keygen > /dev/null; then
  # The keys are checked with ssh-keygen itself; CI has it.
  [ -z "${CI:-}" ] || { echo "ssh-keygen is missing" >&2; exit 1; }
  echo "skipped: ssh-keygen is not installed (CI runs these)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/esp"
# Tests run curl as the caller: the fake curl lives where nobody can't reach.
export FAKE="$work" HALOS_ESP="$work/esp" HALOS_FETCH_AS_ROOT=1
h="$repo/files/usr/libexec/halogen/ssh-unlock"
ok() { echo "ok: $*"; }
has() { grep -qE -- "$1" "$2" || { echo "expected '$1' in $2:" >&2; cat "$2" >&2; exit 1; }; }
hasnt() { if grep -qE -- "$1" "$2"; then echo "did not expect '$1' in $2:" >&2; cat "$2" >&2; exit 1; fi; }

ssh-keygen -q -t ed25519 -N '' -C 'me@laptop' -f "$work/k1"
ssh-keygen -q -t ecdsa -N '' -C 'other' -f "$work/k2"
k1="$(cat "$work/k1.pub")"; k2="$(cat "$work/k2.pub")"

# check: plain public keys only, each once; options, private keys and junk are named and skipped.
{ echo "$k1"; echo "$k1"; echo "command=\"sh\" $k1"; echo "# a comment"; echo; echo "ssh-ed25519 AAAA+not/a/key"
  echo "garbage"; cat "$work/k1"; printf '%s\r\n' "$k2"; } | "$h" check > "$work/ok" 2> "$work/err"
[ "$(wc -l < "$work/ok")" = 2 ] || { cat "$work/ok" "$work/err" >&2; echo "expected two keys" >&2; exit 1; }
has '^ssh-ed25519 ' "$work/ok"; has '^ecdsa-sha2-nistp256 ' "$work/ok"; hasnt $'\r' "$work/ok"
has 'line 3 is not a public key' "$work/err"; hasnt 'line (1|2|4|5) ' "$work/err"
# A comment keeps only plain characters: no escape codes, no look-alike or direction characters.
printf '%s\n' "$(cut -d' ' -f1,2 "$work/k1.pub") evil$(printf '\033[2J\xe2\x80\xae')name" | "$h" check > "$work/c"
[ "$(cut -d' ' -f3- "$work/c")" = "evil2Jname" ] || { cat -v "$work/c" >&2; echo "a comment kept control characters" >&2; exit 1; }
if printf 'garbage\n' | "$h" check > /dev/null 2>&1; then echo "check passed with no key" >&2; exit 1; fi
"$h" describe < "$work/ok" > "$work/out"; has 'ED25519.*SHA256:.*me@laptop' "$work/out"; has 'ECDSA.*other' "$work/out"
ok "only plain public keys are taken, each once; anything else is named and skipped"

# install: keys restricted to the passphrase prompt; the host key is made once and kept.
[ "$("$h" status)" = off ]
"$h" install < "$work/ok"
d="$work/esp/halos/ssh-unlock"
[ "$(grep -c '^restrict,pty ' "$d/authorized_keys")" = 2 ] || { cat "$d/authorized_keys" >&2; exit 1; }
[ -s "$d/ssh_host_ed25519_key" ] && ssh-keygen -l -f "$d/ssh_host_ed25519_key.pub" > /dev/null
cp "$d/ssh_host_ed25519_key.pub" "$work/hostkey"
echo "$k2" | "$h" install
cmp -s "$work/hostkey" "$d/ssh_host_ed25519_key.pub" || { echo "changing the keys made a new host key" >&2; exit 1; }
[ "$("$h" status --short)" = "on 1" ]
"$h" status > "$work/out"; has '^on, 1 key' "$work/out"; has 'other' "$work/out"; hasnt 'me@laptop' "$work/out"
has '^known_hosts line: ' "$work/out"
grep -qF " $(cut -d' ' -f1,2 "$work/hostkey")" "$work/out" || { echo "the known_hosts line lacks the host key" >&2; exit 1; }
# The early-boot key gets a name of its own, so it is never trusted for the running system.
host="$(hostname -s 2> /dev/null || hostname)"
has "^known_hosts line: $host-unlock ssh-ed25519 " "$work/out"; has "^      HostKeyAlias $host-unlock$" "$work/out"
# A changed file on the EFI partition can't put escape codes on root's terminal.
printf 'restrict,pty %s x\033[31mred\n' "$k2" > "$d/authorized_keys"
"$h" status > "$work/out"; if grep -q $'\033' "$work/out"; then echo "status printed an escape code" >&2; exit 1; fi
echo "$k2" | "$h" install
if echo garbage | "$h" install 2> /dev/null; then echo "installed no keys" >&2; exit 1; fi
[ "$("$h" status --short)" = "on 1" ] || { echo "a failed install changed the keys" >&2; exit 1; }
"$h" remove; [ "$("$h" status)" = off ]; [ ! -e "$work/esp/halos" ]
ok "install restricts the keys to the passphrase prompt and keeps the host key; remove turns it off"

# fetch: https only, from the three sites; a user with none, or no such user, says so.
cat > "$work/bin/curl" <<'C'
#!/bin/bash
echo "curl $*" >> "$FAKE/curl.log"
case "${*: -1}" in
  https://codeberg.org/alice.keys|https://github.com/alice.keys|https://gitlab.com/alice.keys) cat "$FAKE/k1.pub" "$FAKE/k2.pub" ;;
  https://codeberg.org/empty.keys) echo "# Note: This user hasn't uploaded any SSH keys." ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
C
chmod +x "$work/bin/curl"; export PATH="$work/bin:$PATH"
for site in github gitlab codeberg; do "$h" fetch "$site" alice > "$work/out"; [ "$(wc -l < "$work/out")" = 2 ]; done
has "--proto =https .*https://github.com/alice.keys" "$work/curl.log"
has 'https://gitlab.com/alice.keys' "$work/curl.log"; has 'https://codeberg.org/alice.keys' "$work/curl.log"
if "$h" fetch codeberg empty > /dev/null 2> "$work/err"; then echo "a user with no keys passed" >&2; exit 1; fi
has 'empty has no public keys on codeberg.org' "$work/err"
if "$h" fetch github nobody > /dev/null 2> "$work/err"; then echo "a missing user passed" >&2; exit 1; fi
has '404' "$work/err"
: > "$work/curl.log"
for bad in '../alice' 'a b' '-x' 'a..b' "$(printf 'a\nb')" 'alice/../x'; do
  if "$h" fetch github "$bad" > /dev/null 2>&1; then echo "took the user name '$bad'" >&2; exit 1; fi
done
[ ! -s "$work/curl.log" ] || { echo "asked the network for a bad user name" >&2; exit 1; }
if "$h" fetch sourcehut alice > /dev/null 2>&1; then echo "took an unknown site" >&2; exit 1; fi
ok "fetch takes keys over https from GitHub, GitLab or Codeberg, and refuses bad names before asking"

# halosctl ssh-unlock on top of it.
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
f id 'echo 0'
f lsblk 'echo "${FAKE_FSTYPE:-crypto_LUKS}"'
printf 'HALOGEN_VARIANT=npu\n' > "$work/release.env"
export HALOGEN_RELEASE_FILE="$work/release.env" HALOS_HISTORY="$work/history" HALOS_SSH_UNLOCK="$h" SUDO_USER=owner
ctl="$repo/files/usr/bin/halosctl"
"$ctl" ssh-unlock > "$work/out"; has '^off$' "$work/out"
if "$ctl" ssh-unlock on --codeberg alice < /dev/null > "$work/out" 2>&1; then echo "turned on without confirming" >&2; exit 1; fi
has 'add --yes' "$work/out"; [ "$("$h" status --short)" = off ]
if "$ctl" ssh-unlock on --yes < /dev/null > "$work/out" 2>&1; then echo "turned on with no keys" >&2; exit 1; fi
has 'name the keys' "$work/out"
if FAKE_FSTYPE=xfs "$ctl" ssh-unlock on --codeberg alice --yes > "$work/out" 2>&1; then echo "turned on without encryption" >&2; exit 1; fi
has "isn't encrypted" "$work/out"
if "$ctl" ssh-unlock off --github alice --yes > "$work/out" 2>&1; then echo "took keys for off" >&2; exit 1; fi
if "$ctl" ssh-unlock on --key 'not a key' --yes > "$work/out" 2>&1; then echo "took a bad --key" >&2; exit 1; fi
[ "$("$h" status --short)" = off ]
"$ctl" ssh-unlock on --gitlab alice --key "$k1" --yes > "$work/out"
[ "$("$h" status --short)" = "on 2" ] || { echo "duplicate keys from two sources were kept twice" >&2; "$h" status >&2; exit 1; }
has 'known_hosts line' "$work/out"; has 'ssh <name>-unlock' "$work/out"
has 'ssh-unlock +off -> on +\(by owner\)' "$work/history"
"$ctl" ssh-unlock off --yes > "$work/out"; [ "$("$h" status --short)" = off ]; has 'ssh-unlock +on -> off' "$work/history"
"$ctl" ssh-unlock off --yes > "$work/out"; has 'already off' "$work/out"
if "$ctl" history --github alice > "$work/out" 2>&1; then echo "took --github outside ssh-unlock" >&2; exit 1; fi
has 'go with ssh-unlock on' "$work/out"
ok "halosctl ssh-unlock asks first, needs encryption and keys, merges sources, records changes and turns off"
