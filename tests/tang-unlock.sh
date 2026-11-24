#!/bin/bash
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
# Unlock from a tang server (#44): the tang-unlock helper and halosctl tang-unlock, against fake
# clevis, cryptsetup, curl and jose (jq is real). The binding list is a file of clevis luks list
# lines; systemd's TPM token lives in a fake LUKS2 JSON header.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/dev"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
f id 'echo 0'
f lsblk 'echo "/dev/vda3 crypto_LUKS"; echo "crypto_LUKS"'
# cryptsetup: the passphrase is halogentest; the header's tokens are in $FAKE/meta.json.
f cryptsetup 'echo "cryptsetup $*" >> "$FAKE/log"
case "$1" in
  open) [ "$(cat)" = halogentest ] ;;
  luksDump) cat "$FAKE/meta.json" ;;
  luksKillSlot) [ "$2" = -q ] || exit 9 ;;
  token) jq --arg t "$4" "del(.tokens[\$t])" "$FAKE/meta.json" > "$FAKE/m" && mv "$FAKE/m" "$FAKE/meta.json" ;;
esac'
# clevis luks: list prints $FAKE/bindings; bind adds a line (FAKE_BIND_FAIL=<url> fails for that
# server), after checking it got the passphrase on stdin and never -y (which skips the key check).
f clevis 'echo "clevis $*" >> "$FAKE/log"
case "$2" in
  list) cat "$FAKE/bindings" 2> /dev/null || true ;;
  bind) case " $* " in *" -y "*) echo "bind with -y" >&2; exit 9 ;; esac
        [ "$(cat)" = halogentest ] || { echo "no passphrase" >&2; exit 1; }
        pin="${*: -2:1}" cfg="${*: -1}"
        case "$cfg" in *"${FAKE_BIND_FAIL:-none}"*) echo "Unable to fetch advertisement" >&2; exit 1 ;; esac
        n=$(( $(cut -d: -f1 "$FAKE/bindings" 2> /dev/null | sort -n | tail -n 1) + 1 ))
        echo "$n: $pin '"'"'$cfg'"'"'" >> "$FAKE/bindings" ;;
  unbind) s="${*: -1}"; grep -v "^$s: " "$FAKE/bindings" > "$FAKE/b" || true; mv "$FAKE/b" "$FAKE/bindings" ;;
esac'
f systemd-cryptenroll 'echo "cryptenroll $*" >> "$FAKE/log"; [ "$PASSWORD" = halogentest ] || exit 1
jq ".tokens[\"5\"] = {type: \"systemd-tpm2\", keyslots: [\"6\"]}" "$FAKE/meta.json" > "$FAKE/m" && mv "$FAKE/m" "$FAKE/meta.json"'
f curl 'case "$*" in *down*) exit 7 ;; esac; echo "{\"payload\":\"x\"}"'
f jose 'cat > /dev/null; case "$*" in *"thp -i- -a S256"*) echo "S256key0123456789abcdefABCDEF" ;; *"thp -i- -a S1"*) echo "S1key0123456789abcdefABC" ;; *) echo "{}" ;; esac'
printf 'HALOGEN_VARIANT=npu\n' > "$work/release.env"
printf 'luks-1 UUID=1234 none discard\n' > "$work/crypttab"
export PATH="$work/bin:$PATH" HALOS_CRYPTTAB="$work/crypttab" HALOS_TANG_UNLOCK="$repo/files/usr/libexec/halogen/tang-unlock" \
  HALOS_HISTORY="$work/history" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_DEV="$work/dev" SUDO_USER=owner
tang="$HALOS_TANG_UNLOCK" ctl="$repo/files/usr/bin/halosctl" dev=/dev/disk/by-uuid/1234
ok() { echo "ok: $*"; }
has() { grep -qE -- "$1" "$2" || { echo "expected '$1' in $2:" >&2; cat "$2" >&2; exit 1; }; }
hasnt() { if grep -qE -- "$1" "$2"; then echo "did not expect '$1' in $2:" >&2; cat "$2" >&2; exit 1; fi; }
# A header with systemd's TPM token (token 0, key slot 1) beside the passphrase (slot 0).
fresh() { : > "$work/log"; rm -f "$work/bindings"; echo '{"tokens":{"0":{"type":"systemd-tpm2","keyslots":["1"]}}}' > "$work/meta.json"; }
K=S256key0123456789abcdefABCDEF

fresh
"$tang" thumbprints http://10.0.0.5:7500 > "$work/out"; has "^$K S1key0123456789abcdefABC$" "$work/out"
for bad in 'http://a;b' 'ftp://x' 'http://x/$(id)' 'http://x y' 'file:///etc/passwd' 'http://-x'; do
  if "$tang" thumbprints "$bad" > "$work/out" 2>&1; then echo "took $bad as a server address" >&2; exit 1; fi
  has 'not a tang server address' "$work/out"
done
if "$tang" thumbprints http://down.lan > "$work/out" 2>&1; then echo "a silent server answered" >&2; exit 1; fi
has 'no answer from http://down.lan' "$work/out"
if "$tang" thumbprints http://nas.local:7500 > "$work/out" 2>&1; then echo "a .local name passed" >&2; exit 1; fi
has "a .local name can't be found at boot" "$work/out"
ok "thumbprints shows a server's signing key, and refuses an address that isn't a plain URL or a server that doesn't answer"

[ "$("$tang" status --short)" = off ] || { echo "status isn't off before binding" >&2; exit 1; }
if PASSWORD=wrong "$tang" bind and http://10.0.0.5:7500 "$K" > "$work/out" 2>&1; then echo "bound with a wrong passphrase" >&2; exit 1; fi
has "isn't the disk's passphrase" "$work/out"; [ ! -s "$work/bindings" ]
PASSWORD=halogentest "$tang" bind and http://10.0.0.5:7500 "$K"
has "^1: sss '\\{\"t\":2,\"pins\":\\{\"tpm2\":\\{\"pcr_bank\":\"sha256\",\"pcr_ids\":\"7\"\\},\"tang\":\\[\\{\"url\":\"http://10.0.0.5:7500\",\"thp\":\"$K\"\\}\\]\\}\\}'$" "$work/bindings"
has 'cryptsetup luksKillSlot -q /dev/disk/by-uuid/1234 1' "$work/log"; has 'cryptsetup token remove --token-id 0 ' "$work/log"
[ "$(jq '.tokens | length' "$work/meta.json")" = 0 ] || { echo "the TPM-only token stayed" >&2; exit 1; }
[ "$("$tang" status --short)" = "on and http://10.0.0.5:7500" ] || { "$tang" status --short >&2; echo "wrong state after binding" >&2; exit 1; }
[ "$("$tang" mode)" = and ] && [ "$("$tang" mode "$dev")" = and ]
"$tang" status > "$work/out"; has "when this machine's TPM agrees and a tang server answers" "$work/out"; has '^  server: http://10.0.0.5:7500$' "$work/out"
ok "bind checks the passphrase first, binds TPM and tang with the server's key, and removes the TPM-only unlock"

# Binding again replaces the old binding (new ones first); a failed bind keeps the old ones.
PASSWORD=halogentest "$tang" bind or http://10.0.0.6 "$K" http://10.0.0.7 "$K"
[ "$(cut -d: -f1 "$work/bindings" | paste -sd' ')" = "2 3" ] || { cat "$work/bindings" >&2; echo "the old binding wasn't replaced" >&2; exit 1; }
has "^2: tang '\\{\"url\":\"http://10.0.0.6\"" "$work/bindings"
echo '{"tokens":{"0":{"type":"systemd-tpm2","keyslots":["1"]}}}' > "$work/meta.json"; : > "$work/log"
[ "$("$tang" mode)" = or ] || { echo "a tang binding beside systemd's TPM token isn't 'or'" >&2; exit 1; }
cp "$work/bindings" "$work/before"
if FAKE_BIND_FAIL=10.0.0.9 PASSWORD=halogentest "$tang" bind off http://10.0.0.8 "$K" http://10.0.0.9 "$K" > "$work/out" 2>&1; then echo "a failed bind succeeded" >&2; exit 1; fi
cmp -s "$work/before" "$work/bindings" || { diff "$work/before" "$work/bindings" >&2; echo "a failed bind changed the bindings" >&2; exit 1; }
hasnt 'luksKillSlot' "$work/log"; has 'nothing changed' "$work/out"
ok "binding again replaces the old bindings only once the new ones are made; a failure leaves everything as it was"

PASSWORD=halogentest "$tang" bind off http://10.0.0.8 "$K"
[ "$("$tang" status --short)" = "on off http://10.0.0.8" ] || { "$tang" status --short >&2; exit 1; }
for bad in "http://x;y $K" "http://10.0.0.8 short" "http://10.0.0.8"; do
  # shellcheck disable=SC2086 # split on purpose
  if PASSWORD=halogentest "$tang" bind and $bad > "$work/out" 2>&1; then echo "bound with: $bad" >&2; exit 1; fi
done
"$tang" remove; [ "$("$tang" status --short)" = off ] || { echo "remove left a binding" >&2; exit 1; }
: > "$work/crypttab"; [ "$("$tang" status --short)" = off ]
if "$tang" bind and http://10.0.0.8 "$K" > "$work/out" 2>&1; then echo "bound without an encrypted volume" >&2; exit 1; fi
printf 'luks-1 UUID=1234 none discard\n' > "$work/crypttab"
ok "tang alone, a missing thumbprint or a bad one is refused, remove takes every binding away, and an unencrypted disk is off"

# halosctl: the key must be confirmed (or given), TPM and tang is the default with a TPM, tang
# alone without one; renew keeps the servers and the mode.
fresh; touch "$work/dev/tpmrm0"
if "$ctl" tang-unlock on http://10.0.0.5:7500 --yes > "$work/out" 2>&1; then echo "--yes without --thp trusted a key" >&2; exit 1; fi
has 'give each server.s key with --thp' "$work/out"; [ ! -s "$work/bindings" ]
if "$ctl" tang-unlock on http://10.0.0.5:7500 --thp otherkey0123456789abcdefXYZ --yes > "$work/out" 2>&1; then echo "a wrong key was trusted" >&2; exit 1; fi
has "doesn't sign with the key otherkey" "$work/out"; [ ! -s "$work/bindings" ]
PASSWORD=halogentest "$ctl" tang-unlock on http://10.0.0.5:7500 --thp "$K" --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
has "TPM agrees" "$work/out"; [ "$("$tang" mode)" = and ]
has 'tang-unlock +off -> on and' "$work/history"
# The S1 thumbprint (older tang servers print it) is taken too.
PASSWORD=halogentest "$ctl" tang-unlock on http://10.0.0.6 --tpm or --thp S1key0123456789abcdefABC --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ "$("$tang" status --short)" = "on or http://10.0.0.6" ] || { "$tang" status --short >&2; exit 1; }
has 'cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7' "$work/log"
PASSWORD=halogentest "$ctl" tang-unlock renew --thp "$K" --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ "$("$tang" status --short)" = "on or http://10.0.0.6" ] || { "$tang" status --short >&2; echo "renew changed the servers or the mode" >&2; exit 1; }
has "^3: tang " "$work/bindings"
if "$ctl" tang-unlock renew --tpm and --yes > "$work/out" 2>&1; then echo "renew changed the mode" >&2; exit 1; fi
if "$ctl" tang-unlock on http://10.0.0.5 --tpm maybe --thp "$K" --yes > "$work/out" 2>&1; then echo "took --tpm maybe" >&2; exit 1; fi
if "$ctl" ssh-unlock on --thp "$K" --yes > "$work/out" 2>&1; then echo "--thp went with another command" >&2; exit 1; fi
has 'go with tang-unlock on' "$work/out"
rm "$work/dev/tpmrm0"
if PASSWORD=halogentest "$ctl" tang-unlock on http://10.0.0.5 --tpm and --thp "$K" --yes > "$work/out" 2>&1; then echo "--tpm and without a TPM" >&2; exit 1; fi
has 'no TPM found' "$work/out"
PASSWORD=halogentest "$ctl" tang-unlock on http://10.0.0.5 --thp "$K" --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ "$("$tang" mode)" = off ] || { echo "without a TPM the default isn't tang alone" >&2; exit 1; }
"$ctl" tang-unlock off --yes > "$work/out"; [ "$("$tang" status --short)" = off ]; has 'tang-unlock +on off -> off' "$work/history"
"$ctl" tang-unlock off --yes > "$work/out"; has 'already off' "$work/out"
ok "halosctl trusts only a key given or confirmed, defaults to TPM and tang with a TPM and tang alone without, renews with the same servers and mode, and turns it off"

# halogen-enroll-tpm adds no TPM-only unlock beside a binding made to need the network.
for m in and off; do
  fresh; PASSWORD=halogentest "$tang" bind "$m" http://10.0.0.5 "$K"; : > "$work/log"
  if "$repo/files/usr/bin/halogen-enroll-tpm" > "$work/out" 2>&1; then echo "enrolled the TPM beside tang ($m)" >&2; exit 1; fi
  hasnt cryptenroll "$work/log"; has 'unlocks from a tang server' "$work/out"
done
fresh; PASSWORD=halogentest "$tang" bind or http://10.0.0.5 "$K"; : > "$work/log"
PASSWORD=halogentest "$repo/files/usr/bin/halogen-enroll-tpm" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
has 'cryptenroll --wipe-slot=tpm2' "$work/log"
# A TPM-only token left beside TPM and tang (removal failed, or enrolled by hand) reads as "or":
# the TPM alone unlocks then. Clevis tokens that can't be read are "unknown", and enrolling refuses.
fresh; PASSWORD=halogentest "$tang" bind and http://10.0.0.5 "$K"
echo '{"tokens":{"0":{"type":"systemd-tpm2","keyslots":["1"]}}}' > "$work/meta.json"
[ "$("$tang" mode)" = or ] || { echo "a TPM-only token beside TPM and tang isn't reported as 'or'" >&2; exit 1; }
rm -f "$work/bindings"; echo '{"tokens":{"0":{"type":"clevis","keyslots":["2"]}}}' > "$work/meta.json"
rc=0; "$tang" mode > "$work/out" || rc=$?; [ "$rc" = 3 ] && has '^unknown$' "$work/out"
: > "$work/log"
if PASSWORD=halogentest "$repo/files/usr/bin/halogen-enroll-tpm" > "$work/out" 2>&1; then echo "enrolled beside unreadable clevis tokens" >&2; exit 1; fi
hasnt cryptenroll "$work/log"; has "Couldn't read whether a tang server" "$work/out"
ok "halogen-enroll-tpm refuses a TPM-only unlock beside TPM and tang or tang alone, and re-enrolls beside 'or'; a leftover TPM token reads 'or', and unreadable clevis tokens fail closed"
