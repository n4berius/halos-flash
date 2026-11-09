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
f runuser 'echo "runuser $*" >> "$FAKE/log"; [ "$1 $2 $3" = "-u halogen --" ] || exit 9; shift 3; FAKE_AS=halogen exec "$@"'
f lsblk 'printf "%s\n" "${FAKE_LSBLK-/dev/nvme0n1p3 crypto_LUKS}"'
f cryptsetup 'printf "Tokens:\n%s" "${FAKE_TOKENS:-}"'
f halogen-enroll-tpm 'echo "enroll-tpm" >> "$FAKE/log"'
f halogenctl 'echo "halogenctl $*" >> "$FAKE/log"'
f nano 'echo "nano $* as=${FAKE_AS:-root}" >> "$FAKE/log"; echo "HALOGEN_KV_SLOTS=2" >> "$1"'
# Unlock over SSH (#13): off until installed; codeberg user alice has one key.
f ssh-unlock 'case "$1" in
  status) if [ -s "$FAKE/installed" ]; then echo "on 1"; else echo off; fi ;;
  choice) echo "${FAKE_CHOICE:-}" ;;
  fetch) [ "$3" = alice ] && echo "ssh-ed25519 AAAAtest alice" || { echo "no keys for $3" >&2; exit 1; } ;;
  describe) echo "  (ED25519) 256 SHA256:test alice" ;;
  install) cat > "$FAKE/installed"; echo "ssh-unlock install" >> "$FAKE/log" ;;
esac'
printf 'HALOGEN_VARIANT=no-npu\n' > "$work/release.env"
export PATH="$work/bin:$PATH" HALOS_SSH_UNLOCK="$work/bin/ssh-unlock" HALOS_HISTORY="$work/history" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_STATE_DIR="$work/state" HALOGEN_CONFIGS_DIR="$work/configs" HALOGEN_DEV="$work/dev"
ctl="$repo/files/usr/bin/halosctl"
ok() { echo "ok: $*"; }
# Answers the questions through a terminal, one line each.
answer() { printf '%s\n' "$@" > "$work/answers"; : > "$work/log"
  { sleep 1; cat "$work/answers"; } | script -qec "$ctl setup" /dev/null > "$work/out" 2>&1 || true; }

touch "$work/state/setup-pending" "$work/dev/tpmrm0"
answer No n n n
if grep -q enroll-tpm "$work/log"; then echo "'No' enrolled the TPM" >&2; exit 1; fi
touch "$work/state/setup-pending"
answer maybe Y n n n
grep -q 'Please answer y or n' "$work/out" || { cat "$work/out" >&2; echo "a wrong answer was not asked again" >&2; exit 1; }
touch "$work/state/setup-pending"
answer y n n n
grep -qx 'enroll-tpm' "$work/log" || { cat "$work/out" >&2; echo "TPM not enrolled" >&2; exit 1; }
if grep -q 'halogenctl hf-token\|nano' "$work/log"; then echo "a declined step ran" >&2; exit 1; fi
[ ! -e "$work/state/setup-pending" ] || { echo "setup didn't release the download" >&2; exit 1; }
grep -q "runuser -u halogen -- rm -f $work/state/setup-pending" "$work/log" || { echo "the marker was removed as root" >&2; exit 1; }
grep -q 'first download' "$work/out" || exit 1
ok "setup enrolls the TPM when asked, skips declined steps, and releases the first download as halogen"

touch "$work/state/setup-pending"
FAKE_TOKENS='  0: systemd-tpm2' answer n y y
grep -q 'unlocks with the TPM already' "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q enroll-tpm "$work/log"; then echo "enrolled again" >&2; exit 1; fi
grep -qx 'halogenctl hf-token' "$work/log" || { echo "no token step" >&2; exit 1; }
echo 'HALOGEN_FLASH_CTX=1' > "$work/configs/halogen.env"
touch "$work/state/setup-pending"; : > "$work/log"
FAKE_TOKENS='  0: systemd-tpm2' answer n n y
if ! grep -qE '^nano /tmp/.*/halogen.env as=root$' "$work/log"; then cat "$work/log" >&2; echo "the editor didn't run as root on a private copy" >&2; exit 1; fi
if grep -q "nano $work/configs" "$work/log"; then echo "the editor opened halogen's file directly" >&2; exit 1; fi
grep -qx 'HALOGEN_KV_SLOTS=2' "$work/configs/halogen.env" || { echo "the edit was not saved" >&2; exit 1; }
grep -q "runuser -u halogen -- sh -c" "$work/log" || { echo "the edit was not written back as halogen" >&2; exit 1; }
FAKE_LSBLK='' answer n n
grep -q "isn't encrypted" "$work/out" || exit 1
ok "setup knows an existing TPM binding and an unencrypted disk, and edits settings as halogen"

# Unlock over SSH: a user with no keys asks again; a found key is shown, confirmed and installed.
touch "$work/state/setup-pending"
answer n y 3 bob 3 alice y n n
grep -q 'no keys for bob' "$work/out" || { cat "$work/out" >&2; echo "a user without keys wasn't reported" >&2; exit 1; }
grep -q 'SHA256:test alice' "$work/out" || { cat "$work/out" >&2; echo "the keys weren't shown" >&2; exit 1; }
if ! grep -qx 'ssh-unlock install' "$work/log" || ! grep -qx 'ssh-ed25519 AAAAtest alice' "$work/installed"; then
  cat "$work/out" >&2; echo "the keys weren't installed" >&2; exit 1
fi
touch "$work/state/setup-pending"
answer n n n
grep -q 'set up already' "$work/out" || { cat "$work/out" >&2; echo "an existing SSH unlock wasn't named" >&2; exit 1; }
rm "$work/installed"
# The installer's choice sets the defaults: SSH only means Enter declines the TPM.
touch "$work/state/setup-pending"
FAKE_CHOICE=ssh answer '' n n n
grep -q 'At install you chose: SSH' "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q enroll-tpm "$work/log"; then echo "Enter enrolled the TPM after choosing SSH only" >&2; exit 1; fi
touch "$work/state/setup-pending"
FAKE_CHOICE=both answer '' n n n
grep -qx enroll-tpm "$work/log" || { cat "$work/out" >&2; echo "Enter didn't enroll the TPM after choosing it" >&2; exit 1; }
ok "setup offers unlocking over SSH, asks again when an account has no keys, installs the confirmed ones, and defaults to the installer's choice"

# Run again later: nothing pending, so it offers a restart instead.
answer n n n n y
grep -qx 'halogenctl restart' "$work/log" || { cat "$work/out" >&2; echo "no restart offered" >&2; exit 1; }
touch "$work/state/setup-pending"
"$ctl" setup --skip < /dev/null > "$work/out" 2>&1
[ ! -e "$work/state/setup-pending" ] || { echo "--skip kept the marker" >&2; exit 1; }
if "$ctl" setup < /dev/null > "$work/out" 2>&1; then echo "setup ran without a terminal" >&2; exit 1; fi
grep -q -- '--skip' "$work/out" || exit 1
ok "setup runs again any time, --skip releases the download at once, and without a terminal it says so"

# prepare marks setup pending only on a new install (no halogen.env yet), never on upgrades.
f install 'a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done; exec /usr/bin/install "${a[@]}"'
f selinuxenabled 'exit 1'
echo 'HALOGEN_FLASH_CTX=1' > "$work/default.env"
rm -rf "$work/configs" "$work/state"; mkdir -p "$work/models"
prep() { HALOGEN_MODELS_DIR="$work/models" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_ENV_DEFAULT="$work/default.env" \
  "$repo/files/usr/libexec/halogen/prepare" > /dev/null 2>&1; }
prep
[ -e "$work/state/setup-pending" ] || { echo "a new install got no marker" >&2; exit 1; }
rm "$work/state/setup-pending"; prep
[ ! -e "$work/state/setup-pending" ] || { echo "a later boot marked setup pending again" >&2; exit 1; }
ok "only a new install waits for setup"
