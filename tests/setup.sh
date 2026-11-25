#!/bin/bash
# First-boot setup: halosctl setup, the marker prepare leaves on a new install, and the fetch
# waiting for it. Fake runuser, lsblk, cryptsetup, halogen-enroll-tpm and halogenctl.
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/configs" "$work/dev"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
f id 'echo 0'
f runuser 'echo "runuser $*" >> "$FAKE/log"; case "$1 $2 $3" in "-u halogen --"|"-u owner --") ;; *) exit 9 ;; esac; u="$2"; shift 3; FAKE_AS=$u exec "$@"'
# The admin running setup, with or without an SSH key; sshd always takes the keys-only file.
f getent 'case "$1 $2" in "passwd owner") echo "owner:x:1000:1000::$FAKE/home/owner:/bin/bash" ;; *) exit 2 ;; esac'
f sshd 'case "$1" in -T) echo "passwordauthentication no" ;; esac'
f ssh-keygen 'grep -q "^ssh-ed25519 AAAA"'
mkdir -p "$work/home/owner/.ssh" "$work/sshd.d"; chmod 755 "$work/home/owner" "$work/home/owner/.ssh"
f lsblk 'printf "%s\n" "${FAKE_LSBLK-/dev/nvme0n1p3 crypto_LUKS}"'
f cryptsetup 'printf "Tokens:\n%s" "${FAKE_TOKENS:-}"'
f halogen-enroll-tpm 'echo "enroll-tpm" >> "$FAKE/log"'
f halogenctl 'echo "halogenctl $*" >> "$FAKE/log"'
# Unlock over SSH (#13): off until installed; codeberg user alice has one key.
f ssh-unlock 'case "$1" in
  status) if [ -s "$FAKE/installed" ]; then echo "on 1"; else echo off; fi ;;
  choice) echo "${FAKE_CHOICE:-}" ;;
  verify) [ -s "$FAKE/recorded" ] || exit 2 ;;
  record) echo recorded > "$FAKE/recorded"; echo "ssh-unlock record" >> "$FAKE/log" ;;
  fetch) [ "$3" = alice ] && echo "ssh-ed25519 AAAAtest alice" || { echo "no keys for $3" >&2; exit 1; } ;;
  describe) echo "  (ED25519) 256 SHA256:test alice" ;;
  install) cat > "$FAKE/installed"; echo "ssh-unlock install" >> "$FAKE/log" ;;
esac'
# HTTPS (#102): the helper keeps its mode in a file (FAKE_HTTPS before any switch), and setup's
# switch runs halosctl's own https self-signed against it, with Caddy always answering.
f https 'm="$(cat "$FAKE/mode" 2>/dev/null || echo "${FAKE_HTTPS:-off}")"
case "$1" in
  mode) echo "$m" ;;
  set) echo "https $*" >> "$FAKE/log"; [ -z "${FAKE_SET_FAIL:-}" ] || { echo "refused" >&2; exit 1; }; echo "$2" > "$FAKE/mode" ;;
  ca) echo cert ;;
  describe) printf "mode %s\nca AA:BB\nca_until 2036\nnames localhost\n" "$m" ;;
esac'
# Unlock from a tang server (#44): off until bound; the server's key is thpS256.
f tang-unlock 'case "$1" in
  status) if [ -s "$FAKE/tang" ]; then if [ "${2:-}" = --short ]; then cat "$FAKE/tang"; else echo "On: from a tang server"; fi; else echo off; fi ;;
  thumbprints) [ -z "${FAKE_MULTI:-}" ] || echo evilS256; echo thpS256 ;;
  bind) echo "tang-unlock $*" >> "$FAKE/log"; echo "on $2 $3" > "$FAKE/tang" ;;
  secure-boot) [ -z "${FAKE_SB_OFF:-}" ] || exit 1 ;;
esac'
f systemctl 'case "$1" in is-active) echo active ;; esac'
f curl 'echo 200'
f hostname 'echo 192.0.2.7'
printf 'HALOGEN_VARIANT=no-npu\n' > "$work/release.env"
export PATH="$work/bin:$PATH" HALOS_SSH_UNLOCK="$work/bin/ssh-unlock" HALOS_TANG_UNLOCK="$work/bin/tang-unlock" HALOS_HISTORY="$work/history" \
  HALOS_HTTPS_HELPER="$work/bin/https" HALOS_HTTPS_ETC="$work/etc" \
  SUDO_USER=owner HALOS_SSHD_DROPIN="$work/sshd.d/20-halos-keys-only.conf" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_STATE_DIR="$work/state" HALOGEN_CONFIGS_DIR="$work/configs" HALOGEN_DEV="$work/dev"
ctl="$repo/files/usr/bin/halosctl"
ok() { echo "ok: $*"; }
# Answers the questions through a terminal, one line each.
# Two closing "n" lines answer the questions a test doesn't name (HTTPS, then the restart), since
# script never passes the end of input on to setup.
answer() { printf '%s\n' "$@" n n > "$work/answers"; : > "$work/log"; rm -f "$work/mode"
  { sleep 1; cat "$work/answers"; } | script -qec "$ctl setup" /dev/null > "$work/out" 2>&1 || true; }

touch "$work/state/setup-pending" "$work/dev/tpmrm0"
answer No n n n n
if grep -q enroll-tpm "$work/log"; then echo "'No' enrolled the TPM" >&2; exit 1; fi
touch "$work/state/setup-pending"
answer maybe Y n n n n
grep -q 'Please answer y or n' "$work/out" || { cat "$work/out" >&2; echo "a wrong answer was not asked again" >&2; exit 1; }
touch "$work/state/setup-pending"
answer y n n n n
grep -qx 'enroll-tpm' "$work/log" || { cat "$work/out" >&2; echo "TPM not enrolled" >&2; exit 1; }
if grep -q 'halogenctl hf-token\|halogenctl settings' "$work/log"; then echo "a declined step ran" >&2; exit 1; fi
[ ! -e "$work/state/setup-pending" ] || { echo "setup didn't release the download" >&2; exit 1; }
grep -q "runuser -u halogen -- rm -f $work/state/setup-pending" "$work/log" || { echo "the marker was removed as root" >&2; exit 1; }
grep -q 'first download' "$work/out" || exit 1
ok "setup enrolls the TPM when asked, skips declined steps, and releases the first download as halogen"

touch "$work/state/setup-pending"
FAKE_TOKENS='  0: systemd-tpm2' answer n n y y
grep -q 'unlocks with the TPM already' "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q enroll-tpm "$work/log"; then echo "enrolled again" >&2; exit 1; fi
grep -qx 'halogenctl hf-token' "$work/log" || { echo "no token step" >&2; exit 1; }
echo 'HALOGEN_FLASH_CTX=1' > "$work/configs/halogen.env"
touch "$work/state/setup-pending"; : > "$work/log"
FAKE_TOKENS='  0: systemd-tpm2' answer n n n y
# The settings screen (halogenctl settings, tested in tests/halogenctl.sh) saves without its own
# restart: setup asks once, at its end.
grep -qx 'halogenctl settings --no-restart' "$work/log" || { cat "$work/log" >&2; echo "the settings screen wasn't opened" >&2; exit 1; }
FAKE_LSBLK='' answer n n
grep -q "isn't encrypted" "$work/out" || exit 1
ok "setup knows an existing TPM binding and an unencrypted disk, and opens the settings screen"

# Unlock over SSH: a user with no keys asks again; a found key is shown, confirmed and installed.
touch "$work/state/setup-pending"
answer n n y 3 bob 3 alice y n n
grep -q 'no keys for bob' "$work/out" || { cat "$work/out" >&2; echo "a user without keys wasn't reported" >&2; exit 1; }
grep -q 'SHA256:test alice' "$work/out" || { cat "$work/out" >&2; echo "the keys weren't shown" >&2; exit 1; }
if ! grep -qx 'ssh-unlock install' "$work/log" || ! grep -qx 'ssh-ed25519 AAAAtest alice' "$work/installed"; then
  cat "$work/out" >&2; echo "the keys weren't installed" >&2; exit 1
fi
touch "$work/state/setup-pending"; rm -f "$work/recorded"
answer n n n n
grep -q 'set up already' "$work/out" || { cat "$work/out" >&2; echo "an existing SSH unlock wasn't named" >&2; exit 1; }
grep -qx 'ssh-unlock record' "$work/log" || { echo "setup didn't record the installer's keys" >&2; exit 1; }
rm "$work/installed"
# The installer's choice sets the defaults: SSH only means Enter declines the TPM.
touch "$work/state/setup-pending"
FAKE_CHOICE=ssh answer '' n n n n
grep -q 'At install you chose: SSH' "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q enroll-tpm "$work/log"; then echo "Enter enrolled the TPM after choosing SSH only" >&2; exit 1; fi
touch "$work/state/setup-pending"
FAKE_CHOICE=both answer '' n n n n
grep -qx enroll-tpm "$work/log" || { cat "$work/out" >&2; echo "Enter didn't enroll the TPM after choosing it" >&2; exit 1; }
FAKE_CHOICE=none FAKE_LSBLK='' answer n n
if grep -q 'At install you chose' "$work/out"; then echo "an unencrypted disk got an unlock choice line" >&2; exit 1; fi
# With a key, the admin is offered keys-only SSH logins: Enter keeps passwords, y turns them off.
echo "ssh-ed25519 AAAAkey owner@laptop" > "$work/home/owner/.ssh/authorized_keys"
FAKE_TOKENS='  0: systemd-tpm2' answer n n '' n n
grep -q 'Allow only keys for SSH logins' "$work/out" || { cat "$work/out" >&2; echo "keys-only wasn't offered" >&2; exit 1; }
[ ! -e "$work/sshd.d/20-halos-keys-only.conf" ] || { echo "Enter turned passwords off" >&2; exit 1; }
grep -qx 'halogenctl hf-token' "$work/log" && { echo "an answer shifted onto the token step" >&2; exit 1; }
FAKE_TOKENS='  0: systemd-tpm2' answer n n y n n
grep -qx 'PasswordAuthentication no' "$work/sshd.d/20-halos-keys-only.conf" || { cat "$work/out" >&2; echo "y didn't turn passwords off" >&2; exit 1; }
rm -f "$work/home/owner/.ssh/authorized_keys" "$work/sshd.d/20-halos-keys-only.conf"
ok "setup offers unlocking over SSH, asks again when an account has no keys, installs the confirmed ones, defaults to the installer's choice, and offers keys-only logins to an admin with a key"

# Unlock from a tang server: the key is shown and must be confirmed; with a TPM, "and" is the
# default; once bound that way, no TPM-only unlock is offered beside it.
touch "$work/state/setup-pending"
answer n y http://10.0.0.5:7500 n n n n
grep -q 'thpS256' "$work/out" || { cat "$work/out" >&2; echo "the server's key wasn't shown" >&2; exit 1; }
if grep -q 'tang-unlock bind' "$work/log"; then echo "a key not confirmed was trusted" >&2; exit 1; fi
grep -q 'Skipped. Later: sudo halosctl tang-unlock on' "$work/out" || { cat "$work/out" >&2; exit 1; }
touch "$work/state/setup-pending"
answer n y http://10.0.0.5:7500 y '' n n n
grep -qx 'tang-unlock bind and http://10.0.0.5:7500 thpS256' "$work/log" || { cat "$work/out" "$work/log" >&2; echo "setup didn't bind with TPM and tang" >&2; exit 1; }
grep -q 'tang-unlock  *off -> on and' "$work/history" || { cat "$work/history" >&2; echo "the change wasn't recorded" >&2; exit 1; }
grep -q 'first download' "$work/out" || { cat "$work/out" >&2; echo "setup stopped after the tang step" >&2; exit 1; }
touch "$work/state/setup-pending"
answer n n n
grep -q 'no TPM-only unlock is added' "$work/out" || { cat "$work/out" >&2; exit 1; }
grep -q 'set up already (sudo halosctl tang-unlock' "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q enroll-tpm "$work/log"; then echo "a TPM-only unlock was offered beside TPM and tang" >&2; exit 1; fi
rm -f "$work/tang"; : > "$work/log"
# Several signing keys: the one pasted is pinned, never the first listed; "y" is not a key.
touch "$work/state/setup-pending"
FAKE_MULTI=1 answer n y http://10.0.0.5:7500 y n n n
if grep -q 'tang-unlock bind' "$work/log"; then cat "$work/log" >&2; echo "a key was pinned without being pasted" >&2; exit 1; fi
touch "$work/state/setup-pending"
FAKE_MULTI=1 answer n y http://10.0.0.5:7500 thpS256 '' n n n
grep -qx 'tang-unlock bind and http://10.0.0.5:7500 thpS256' "$work/log" || { cat "$work/out" "$work/log" >&2; echo "the pasted key wasn't the one pinned" >&2; exit 1; }
rm -f "$work/tang"; : > "$work/log"
# Secure Boot off: no TPM unlock is offered, and tang is bound alone.
touch "$work/state/setup-pending"
FAKE_SB_OFF=1 answer y http://10.0.0.5:7500 y '' n n n
grep -q 'Secure Boot is off, so a TPM unlock would protect nothing' "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q enroll-tpm "$work/log"; then echo "a TPM unlock was offered with Secure Boot off" >&2; exit 1; fi
grep -qx 'tang-unlock bind off http://10.0.0.5:7500 thpS256' "$work/log" || { cat "$work/out" "$work/log" >&2; echo "setup didn't bind tang alone with Secure Boot off" >&2; exit 1; }
rm -f "$work/tang"
ok "setup offers unlocking from a tang server, trusts only a key the person confirms, binds TPM and tang (tang alone with Secure Boot off), and then offers no TPM-only unlock"

# HTTPS: a new install (root's own marker, which prepare leaves) is offered it with Enter for yes,
# and setup runs halosctl's own https self-signed; a failure doesn't stop setup; on when it is on
# already, never asked. The marker goes once the step is answered.
touch "$work/state/setup-pending" "$work/new-install"
FAKE_TOKENS='  0: systemd-tpm2' answer n n n n ''
grep -qx 'https set self-signed' "$work/log" || { cat "$work/out" >&2; echo "Enter didn't turn HTTPS on for a new install" >&2; exit 1; }
grep -q 'sudo halosctl https ca' "$work/out" || { cat "$work/out" >&2; echo "no word on trusting the authority" >&2; exit 1; }
grep -q 'https  *off -> self-signed' "$work/history" || { cat "$work/history" >&2; echo "the switch wasn't recorded" >&2; exit 1; }
[ ! -e "$work/new-install" ] || { echo "the new-install marker outlived the answer" >&2; exit 1; }
# The default follows root's marker, not halogen's setup-pending (gone after 30 minutes or --skip).
touch "$work/new-install"
FAKE_TOKENS='  0: systemd-tpm2' answer n n n n ''
grep -qx 'https set self-signed' "$work/log" || { cat "$work/out" >&2; echo "a new install whose setup-pending had gone lost its HTTPS default" >&2; exit 1; }
touch "$work/state/setup-pending" "$work/new-install"
FAKE_SET_FAIL=1 FAKE_TOKENS='  0: systemd-tpm2' answer n n n n y
{ grep -q "That didn't work, so it's still plain HTTP" "$work/out" && grep -q 'first download' "$work/out"; } \
  || { cat "$work/out" >&2; echo "a failed HTTPS switch stopped setup, or said the wrong thing" >&2; exit 1; }
FAKE_HTTPS=invalid FAKE_TOKENS='  0: systemd-tpm2' answer n n n n y
grep -q 'holds an unknown setting' "$work/out" || { cat "$work/out" >&2; echo "a broken https.env wasn't named" >&2; exit 1; }
touch "$work/state/setup-pending"
FAKE_HTTPS=custom FAKE_TOKENS='  0: systemd-tpm2' answer n n n n y
grep -q 'HTTPS is on already (custom)' "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q '^https set' "$work/log"; then echo "HTTPS was switched though it was on" >&2; exit 1; fi
touch "$work/state/setup-pending"
FAKE_TOKENS='  0: systemd-tpm2' answer n n n n n
if grep -q '^https set' "$work/log"; then echo "'n' turned HTTPS on" >&2; exit 1; fi
grep -q 'Kept plain HTTP' "$work/out" || exit 1
ok "setup offers HTTPS to a new install (Enter for yes), goes on when it fails, and leaves an HTTPS setting alone"

# Run again later: nothing pending, so Enter keeps plain HTTP (an upgrade stays on HTTP until
# its owner says so), and it offers a restart instead.
answer n n n n n '' y
if grep -q '^https set' "$work/log"; then echo "Enter turned HTTPS on for a machine that isn't new" >&2; exit 1; fi
grep -qx 'halogenctl restart' "$work/log" || { cat "$work/out" >&2; echo "no restart offered" >&2; exit 1; }
touch "$work/state/setup-pending"; : > "$work/log"
"$ctl" setup --skip < /dev/null > "$work/out" 2>&1
[ ! -e "$work/state/setup-pending" ] || { echo "--skip kept the marker" >&2; exit 1; }
if grep -q '^https set' "$work/log"; then echo "--skip touched HTTPS" >&2; exit 1; fi
if "$ctl" setup < /dev/null > "$work/out" 2>&1; then echo "setup ran without a terminal" >&2; exit 1; fi
grep -q -- '--skip' "$work/out" || exit 1
ok "setup runs again any time, --skip releases the download at once, and without a terminal it says so"

# prepare marks setup pending only on a new install (no halogen.env yet), never on upgrades.
f install 'a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done; exec /usr/bin/install "${a[@]}"'
f selinuxenabled 'exit 1'
echo 'HALOGEN_FLASH_CTX=1' > "$work/default.env"
rm -rf "$work/configs" "$work/state"; mkdir -p "$work/models"
prep() { HALOS_STATE_DIR="$work/halos" HALOGEN_MODELS_DIR="$work/models" HALOGEN_LOGS_DIR="$work/logs" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_ENV_DEFAULT="$work/default.env" \
  "$repo/files/usr/libexec/halogen/prepare" > /dev/null 2>&1; }
prep
[ -e "$work/state/setup-pending" ] || { echo "a new install got no marker" >&2; exit 1; }
rm "$work/state/setup-pending"; prep
[ ! -e "$work/state/setup-pending" ] || { echo "a later boot marked setup pending again" >&2; exit 1; }
ok "only a new install waits for setup"
