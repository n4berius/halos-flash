#!/bin/bash
# halogenctl's root-side handling of files the halogen user owns (security audit P1/P2):
# every read and write in /srv/configs goes through runuser, and a crafted HALOGEN_NPU_MODELS
# value in halogen.env can't make root run anything. Fake runuser, systemctl and systemd-run.
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/configs"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
# runuser -u halogen -- cmd...: log it, then run cmd (as this user; the test checks the routing).
f runuser 'echo "runuser $*" >> "$FAKE/log"; [ "$1 $2 $3" = "-u halogen --" ] || exit 9; shift 3; exec "$@"'
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *"is-active --quiet halogen.service"*) [ -z "${FAKE_INACTIVE:-}" ] ;; esac'
# model-pull and render-config, run through systemd-run as halogen.
f systemd-run 'case "$*" in
  *flash-checkpoint\ use\ *|*flash-checkpoint\ remove\ *|*model-pull\ --remove\ *)
    # The real helper, as it runs under the lock; FAKE_BEFORE is what another terminal does
    # while halogenctl was asking.
    echo "systemd-run $*" >> "$FAKE/log"; [ -z "${FAKE_BEFORE:-}" ] || bash -c "$FAKE_BEFORE"
    while [ $# -gt 0 ] && [ "${1#/}" = "$1" ]; do shift; done
    s="$1"; shift; exec "$FAKE_REPO/files/usr/libexec/halogen/${s##*/}" "$@" ;;
  *model-pull*) echo "path=/models/LFM/LFM3-1.7B"; echo "fast=1" ;;
  *render-config*) grep -E "^HALOGEN_(NPU_MODELS|AGENT_GUARD)=" "$FAKE/configs/halogen.env" || true ;;
esac'
mkdir -p "$work/hstate" "$work/locks"
export HALOGEN_STATE_DIR="$work/hstate" PATH="$work/bin:$PATH" HALOGEN_CONFIGS_DIR="$work/configs"
# The helpers that run under a checkpoint's lock run for real (#119); root's GPU lock is here.
export FAKE_REPO="$repo" HALOS_LOCK_DIR="$work/locks" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_RENDER="$work/bin/render-show"
printf 'HALOGEN_IMAGE=x\nHALOGEN_VERSION=0.19.1\n' > "$work/release.env"
f render-show 'grep -E "^HALOGEN_NPU_MODELS=" "$FAKE/configs/halogen.env" || true'
export HALOGEN_ALLOWED_FILE="$repo/variants/npu/usr/share/halogen/options.allowed"
export HALOGEN_LOCKED_FILE="$repo/files/usr/share/halogen/locked.env"
ctl="$repo/files/usr/bin/halogenctl"
ok() { echo "ok: $*"; }

echo secret-key > "$work/configs/api-key"
if ! { [ "$("$ctl" api-key)" = secret-key ] && grep -q "runuser -u halogen -- env -C / cat $work/configs/api-key" "$work/log"; }; then
  echo "api-key was not read as halogen" >&2; exit 1
fi
printf 'hf_abc123\n' | "$ctl" hf-token > /dev/null
if ! { [ "$(cat "$work/configs/hf-token")" = hf_abc123 ] && grep -q 'runuser -u halogen -- env -C / sh -c' "$work/log"; }; then
  echo "hf-token was not written as halogen" >&2; exit 1
fi
"$ctl" hf-token --remove > /dev/null; [ ! -e "$work/configs/hf-token" ]
ok "the API key and HF token are read and written as halogen"

# The audit's reproduction: a HALOGEN_NPU_MODELS value built to run a command through sed's e flag.
printf 'HALOGEN_FLASH_CTX=1\nHALOGEN_NPU_MODELS=a touch %s/pwned|e;#\n' "$work" > "$work/configs/halogen.env"
chmod 0640 "$work/configs/halogen.env"
: > "$work/log"
printf 'y\n' > "$work/answer"
{ sleep 2; cat "$work/answer"; } | script -qec "$ctl model pull LiquidAI/LFM3-1.7B" /dev/null > "$work/out" 2>&1 || true
[ ! -e "$work/pwned" ] || { echo "a value in halogen.env ran a command as root" >&2; exit 1; }
grep -qx 'HALOGEN_NPU_MODELS=a touch .*pwned|e;#,/models/LFM/LFM3-1.7B' "$work/configs/halogen.env" \
  || { echo "the new model was not added as plain text:" >&2; cat "$work/configs/halogen.env" "$work/out" >&2; exit 1; }
grep -qx 'HALOGEN_FLASH_CTX=1' "$work/configs/halogen.env" || { echo "other settings were lost" >&2; exit 1; }
[ "$(stat -c %a "$work/configs/halogen.env")" = 640 ] || { echo "halogen.env lost its 0640 mode" >&2; exit 1; }
grep -q 'runuser -u halogen -- env -C / sh -c' "$work/log" || { echo "halogen.env was not edited as halogen" >&2; exit 1; }
grep -q 'systemctl --user --machine=halogen@.host restart halogen.service' "$work/log"
# A start or restart you ask for clears the crash-loop limit first, so it always runs.
cleared_then() { grep -A1 'reset-failed halogen.service' "$work/log" > "$work/after-reset" || true
  grep -q "$1 halogen.service" "$work/after-reset" || { cat "$work/log" >&2; echo "$1 didn't clear the start limit first" >&2; exit 1; }; }
cleared_then restart
for cmd in restart start; do : > "$work/log"; "$ctl" "$cmd" > /dev/null; cleared_then "$cmd"; done
ok "model pull edits halogen.env as halogen, and a crafted value stays plain text"

printf 'HALOGEN_FLASH_CTX=1\n' > "$work/configs/halogen.env"
{ sleep 2; cat "$work/answer"; } | script -qec "$ctl model pull LiquidAI/LFM3-1.7B" /dev/null > "$work/out" 2>&1 || true
[ "$(tail -n 1 "$work/configs/halogen.env")" = 'HALOGEN_NPU_MODELS=/models/LFM/LFM3-1.7B' ] \
  || { echo "no HALOGEN_NPU_MODELS line was added:" >&2; cat "$work/configs/halogen.env" >&2; exit 1; }
ok "model pull adds HALOGEN_NPU_MODELS when the file has none"

# While a flash check holds the GPU, a restart you ask for, and model pull's offer to restart,
# refuse after the answer, before anything is changed (#139).
exec 7> "$work/locks/gpu.lock"; flock -n 7
printf 'HALOGEN_FLASH_CTX=1\n' > "$work/configs/halogen.env"; : > "$work/log"
{ sleep 2; cat "$work/answer"; } | script -qec "$ctl model pull LiquidAI/LFM3-1.7B" /dev/null > "$work/out" 2>&1 || true
if [ "$(cat "$work/configs/halogen.env")" != HALOGEN_FLASH_CTX=1 ] || grep -q 'restart halogen.service' "$work/log"; then
  cat "$work/out" >&2; echo "model pull changed the settings or restarted Halogen during a flash check" >&2; exit 1
fi
grep -q 'Another halogenctl command is using the GPU' "$work/out" || { cat "$work/out" >&2; exit 1; }
for cmd in restart start; do
  if "$ctl" "$cmd" > "$work/out" 2>&1 || grep -q "$cmd halogen.service" "$work/log"; then echo "$cmd ran during a flash check" >&2; exit 1; fi
done
exec 7>&-
ok "a restart, and model pull's restart, wait for a flash check's GPU"

# model remove deletes as halogen, so a folder link planted by a container can't steer root's rm.
mkdir -p "$work/models/LFM/old-model"; echo w > "$work/models/LFM/old-model/x"
# A removal leaves no process group in the lock (only a pull can go on in the background).
echo 4242 > "$work/hstate/pull-npu-old-model.lock"
: > "$work/log"
{ sleep 2; echo y; } | HALOGEN_MODELS_DIR="$work/models" script -qec "$ctl model remove old-model" /dev/null > "$work/out" 2>&1 || true
[ ! -e "$work/models/LFM/old-model" ] || { echo "model remove didn't delete:" >&2; cat "$work/out" >&2; exit 1; }
grep -q "systemd-run .*model-pull --remove LFM old-model" "$work/log" || { echo "model remove didn't delete as halogen, under the model's lock" >&2; exit 1; }
grep -q 'systemctl start --no-block halos-status.service' "$work/log" || { echo "model remove didn't refresh the names for tab completion" >&2; exit 1; }
[ ! -s "$work/hstate/pull-npu-old-model.lock" ] || { echo "a removal wrote a process group into the model's lock" >&2; exit 1; }
ok "model remove deletes as halogen"

# The folder you are asked about is the one deleted, or nothing is (security audit A1): a link
# in the first folder is skipped when asking, and a folder replaced by a link while you were
# asked doesn't move the removal to another folder of the same name.
mkdir -p "$work/models/decider/same" "$work/models/custom/same" "$work/elsewhere"
echo keep > "$work/models/custom/same/x"
{ sleep 2; echo y; } | FAKE_BEFORE="rm -rf \"$work/models/decider/same\"; ln -s \"$work/elsewhere\" \"$work/models/decider/same\"" HALOGEN_MODELS_DIR="$work/models" \
  script -qec "$ctl model remove same" /dev/null > "$work/out" 2>&1 || true
[ -f "$work/models/custom/same/x" ] || { cat "$work/out" >&2; echo "model remove deleted another folder than the one it asked about" >&2; exit 1; }
grep -q 'changed while you were asked' "$work/out" || { cat "$work/out" >&2; exit 1; }
{ sleep 2; echo n; } | HALOGEN_MODELS_DIR="$work/models" script -qec "$ctl model remove same" /dev/null > "$work/out" 2>&1 || true
grep -q "Delete $work/models/custom/same " "$work/out" || { cat "$work/out" >&2; echo "model remove asked about a link" >&2; exit 1; }
rm -rf "$work/models/decider/same" "$work/models/custom/same" "$work/elsewhere"
ok "model remove deletes only the folder it asked about, never through a link"

# What changed while model remove was asking is checked again under the model's lock (#119): a
# model added to HALOGEN_NPU_MODELS meanwhile is kept, and so is one a pull is writing.
mkdir -p "$work/models/LFM/new-model"; cp "$work/configs/halogen.env" "$work/env.bak"
{ sleep 2; echo y; } | FAKE_BEFORE="echo HALOGEN_NPU_MODELS=/models/LFM/new-model >> \"\$FAKE/configs/halogen.env\"" HALOGEN_MODELS_DIR="$work/models" \
  script -qec "$ctl model remove new-model" /dev/null > "$work/out" 2>&1 || true
[ -d "$work/models/LFM/new-model" ] || { cat "$work/out" >&2; echo "model remove deleted a model added to the settings while it asked" >&2; exit 1; }
grep -q 'added meanwhile' "$work/out" || { cat "$work/out" >&2; exit 1; }
cp "$work/env.bak" "$work/configs/halogen.env"
exec 7>> "$work/hstate/pull-npu-new-model.lock"; flock -n 7
{ sleep 2; echo y; } | HALOGEN_MODELS_DIR="$work/models" script -qec "$ctl model remove new-model" /dev/null > "$work/out" 2>&1 || true
exec 7>&-
[ -d "$work/models/LFM/new-model" ] || { echo "model remove deleted a model a pull was writing" >&2; exit 1; }
grep -q 'Another pull of new-model is running' "$work/out" || { cat "$work/out" >&2; exit 1; }
ok "model remove checks again under the model's lock after asking"
# A checkpoint served only in its :qad form counts as in use: refused when asking, and when added
# while asking (the helper's check under the lock).
echo 'HALOGEN_NPU_MODELS=/models/LFM/new-model:qad' >> "$work/configs/halogen.env"
{ sleep 2; echo y; } | HALOGEN_MODELS_DIR="$work/models" script -qec "$ctl model remove new-model" /dev/null > "$work/out" 2>&1 || true
[ -d "$work/models/LFM/new-model" ] || { cat "$work/out" >&2; echo "model remove deleted a model served as :qad" >&2; exit 1; }
{ grep -q 'is in HALOGEN_NPU_MODELS. Take it out' "$work/out" && ! grep -q 'Delete ' "$work/out"; } || { cat "$work/out" >&2; echo "model remove asked about a model served as :qad" >&2; exit 1; }
cp "$work/env.bak" "$work/configs/halogen.env"
{ sleep 2; echo y; } | FAKE_BEFORE="echo HALOGEN_NPU_MODELS=/models/LFM/new-model:qad >> \"\$FAKE/configs/halogen.env\"" HALOGEN_MODELS_DIR="$work/models" \
  script -qec "$ctl model remove new-model" /dev/null > "$work/out" 2>&1 || true
[ -d "$work/models/LFM/new-model" ] || { cat "$work/out" >&2; echo "model remove deleted a model added as :qad while it asked" >&2; exit 1; }
grep -q 'added meanwhile' "$work/out" || { cat "$work/out" >&2; exit 1; }
cp "$work/env.bak" "$work/configs/halogen.env"
ok "a checkpoint served as :qad counts as in use for model remove"

# options: every option this release offers, and which ones halogen.env doesn't mention yet.
template="$repo/variants/npu/usr/share/halogen/halogen.env.default"
grep -v -e '^#HALOGEN_KV8=' -e '^#HALOGEN_ACCESS_LOG=' "$template" | sed 's/^#HALOGEN_MTP_GATE_P=$/HALOGEN_MTP_GATE_P=0.8/' > "$work/configs/halogen.env"
HALOGEN_ENV_TEMPLATE="$template" "$ctl" options --new > "$work/out"
if [ "$(grep -c '^  HALOGEN_' "$work/out")" != 2 ] || ! grep -qE '^  HALOGEN_KV8 +new +.' "$work/out" ||
   ! grep -qE '^  HALOGEN_ACCESS_LOG +new ' "$work/out"; then
  cat "$work/out" >&2; echo "options --new should list exactly the two missing options" >&2; exit 1
fi
HALOGEN_ENV_TEMPLATE="$template" "$ctl" options > "$work/out"
if ! grep -qE '^  HALOGEN_MTP_GATE_P +set ' "$work/out" || ! grep -qE '^  HALOGEN_MTP_DEPTH +commented ' "$work/out"; then
  cat "$work/out" >&2; echo "options should mark set and commented" >&2; exit 1
fi
[ "$(grep -c '^  HALOGEN_' "$work/out")" = "$(grep -cE '^#?HALOGEN_' "$template")" ] || { echo "options missed some" >&2; exit 1; }
cp "$template" "$work/configs/halogen.env"
# Through a file, not a pipe: grep -q stops reading early, and with pipefail that fails the check.
HALOGEN_ENV_TEMPLATE="$template" "$ctl" options --new > "$work/out"
grep -q '^Nothing new' "$work/out" || { cat "$work/out" >&2; echo "a complete file still had new options" >&2; exit 1; }
printf '  HALOGEN_KV8=1\n' >> "$work/configs/halogen.env"
HALOGEN_ENV_TEMPLATE="$template" "$ctl" options > "$work/out"
grep -qE '^  HALOGEN_KV8 +set ' "$work/out" || { cat "$work/out" >&2; echo "an indented setting was not shown as set" >&2; exit 1; }
grep -q 'more than once' "$work/out" && { cat "$work/out" >&2; echo "a duplicate was reported where there is none" >&2; exit 1; }
# A setting this system ignores anyway (API_PORT) and a commented line are not named.
printf 'HALOGEN_KV8=0\n#HALOGEN_MTP_DEPTH=3\nHALOGEN_API_PORT=1\nHALOGEN_API_PORT=2\n' >> "$work/configs/halogen.env"
: > "$work/log"
for cmd in options config status; do
  HALOGEN_ENV_TEMPLATE="$template" "$ctl" "$cmd" > "$work/out" 2>&1 || true
  grep -qx 'Set more than once in halogen.env (only the last line counts): HALOGEN_KV8' "$work/out" \
    || { cat "$work/out" >&2; echo "$cmd didn't name the setting set twice (and only that one)" >&2; exit 1; }
done
grep -q "runuser -u halogen -- env -C / grep -oE" "$work/log" || { echo "the duplicate check read halogen.env as root" >&2; exit 1; }
rm "$work/configs/halogen.env"
if HALOGEN_ENV_TEMPLATE="$template" "$ctl" options --new > "$work/out" 2>&1; then echo "options ran without a readable halogen.env" >&2; exit 1; fi
grep -q 'Run it with sudo' "$work/out" || { cat "$work/out" >&2; exit 1; }
if "$ctl" options --nwe > /dev/null 2>&1; then echo "a misspelled flag was accepted" >&2; exit 1; fi
ok "options lists every option as set, commented or new, and --new only the missing ones; it names settings set twice; it refuses an unreadable file and a wrong flag"

# model list: a clear "none yet" with no own checkpoints, then Halogen's NPU models one per line.
rm -rf "$work/models"; mkdir -p "$work/models/npu/d3-lite" "$work/models/npu/qwen3.5-2b" "$work/models/LFM" "$work/models/decider" "$work/models/custom"
printf 'HALOGEN_NPU_MODELS=qwen3.5-2b:fast\n' > "$work/configs/halogen.env"
HALOGEN_MODELS_DIR="$work/models" "$ctl" model list > "$work/out"
grep -q '^  None yet\. Add one with: sudo halogenctl model pull' "$work/out" || { cat "$work/out" >&2; echo "no 'none yet' line" >&2; exit 1; }
if ! grep -qE '^  d3-lite +no$' "$work/out" || ! grep -qE '^  qwen3\.5-2b +yes$' "$work/out"; then
  cat "$work/out" >&2; echo "NPU models not one per line with IN USE" >&2; exit 1
fi
mkdir -p "$work/models/LFM/my-lfm"; printf 'HALOGEN_NPU_MODELS=/models/LFM/my-lfm\n' > "$work/configs/halogen.env"
HALOGEN_MODELS_DIR="$work/models" "$ctl" model > "$work/out"
if ! grep -qE '^  NAME +FOLDER +SIZE +IN USE$' "$work/out" || ! grep -qE '^  my-lfm +LFM +[0-9.]+[KMG]? +yes$' "$work/out"; then
  cat "$work/out" >&2; echo "own checkpoint not listed" >&2; exit 1
fi
if grep -q 'None yet' "$work/out"; then echo "said none with a checkpoint present" >&2; exit 1; fi
ok "model list is readable: own checkpoints with size and use, then Halogen's models one per line"
# An NPU model your checkpoint runs on, or one the agent guard adds, is in use too; only the fetch's
# plain "path=model" lines count, and only for checkpoints that are served.
mkdir -p "$work/models/custom/OvisOCR3" "$work/models/npu/ovisocr3" "$work/models/npu/lfm3-1.7b" "$work/models/npu/lfm3-1.7b-fast" "$work/models/npu/decider-4b"
printf '/models/custom/OvisOCR3=ovisocr3\n/models/LFM/my-lfm=lfm3-1.7b\n/models/LFM/my-lfm:fast=lfm3-1.7b\n/models/LFM/my-lfm=lfm3-1.7b\n/models/LFM/gone=d3-lite\n/models/LFM/x=bad\033name\n' > "$work/hstate/own-bases"
printf 'HALOGEN_NPU_MODELS=/models/custom/OvisOCR3,/models/LFM/my-lfm:fast,/models/LFM/my-lfm\nHALOGEN_AGENT_GUARD=hold\n' > "$work/configs/halogen.env"
HALOGEN_MODELS_DIR="$work/models" "$ctl" model list > "$work/out"
for want in '^  ovisocr3 +yes, for OvisOCR3$' '^  lfm3-1\.7b +yes, for my-lfm$' '^  lfm3-1\.7b-fast +yes, for my-lfm$' '^  decider-4b +yes, agent guard$' '^  d3-lite +no$' '^  OvisOCR3 +custom +.* yes$'; do
  grep -qE "$want" "$work/out" || { cat "$work/out" >&2; echo "expected '$want'" >&2; exit 1; }
done
if grep -q "$(printf '\033')" "$work/out"; then echo "a control code from .own-bases reached the screen" >&2; exit 1; fi
grep -q 'runuser -u halogen -- env -C / cat .*/own-bases' "$work/log" || { echo "read own-bases as root" >&2; exit 1; }
printf 'HALOGEN_NPU_MODELS=\nHALOGEN_AGENT_GUARD=watch\n' > "$work/configs/halogen.env"
mkdir -p "$work/models/npu/halogen-spotter-0.6b"
HALOGEN_MODELS_DIR="$work/models" "$ctl" model list > "$work/out"
{ grep -qE '^  halogen-spotter-0\.6b +yes, agent guard$' "$work/out" && grep -qE '^  decider-4b +no$' "$work/out"; } \
  || { cat "$work/out" >&2; echo "watch mode: only the spotter is the agent guard's (Halogen 0.20.5)" >&2; exit 1; }
rm -rf "$work/models/npu/halogen-spotter-0.6b"
# LFM3's :qad form (Halogen 0.20.6): the checkpoint served only as :qad still counts as in use, and
# the -qad NPU model it runs on is marked for it.
mkdir -p "$work/models/npu/lfm3-1.7b-qad"
printf '/models/LFM/my-lfm:qad=lfm3-1.7b-qad\n' > "$work/hstate/own-bases"
printf 'HALOGEN_NPU_MODELS=/models/LFM/my-lfm:qad\n' > "$work/configs/halogen.env"
HALOGEN_MODELS_DIR="$work/models" "$ctl" model list > "$work/out"
{ grep -qE '^  lfm3-1\.7b-qad +yes, for my-lfm$' "$work/out" && grep -qE '^  my-lfm +LFM +.* yes$' "$work/out"; } \
  || { cat "$work/out" >&2; echo "a checkpoint served as :qad wasn't shown in use" >&2; exit 1; }
rm -rf "$work/models/npu/lfm3-1.7b-qad"
rm -rf "$work/models/custom/OvisOCR3" "$work/models/npu/ovisocr3" "$work/models/npu/lfm3-1.7b" "$work/models/npu/lfm3-1.7b-fast" "$work/models/npu/decider-4b" "$work/hstate/own-bases"
printf 'HALOGEN_NPU_MODELS=/models/LFM/my-lfm\n' > "$work/configs/halogen.env"
ok "model list marks NPU models your checkpoints run on, or the agent guard adds, as in use"
# Folder names Halogen's container could create are printed only when plain: no control codes.
mkdir -p "$work/models/LFM/bad$(printf '\033')[31mname" "$work/models/npu/also$(printf '\033')[2Jbad"
HALOGEN_MODELS_DIR="$work/models" "$ctl" model list > "$work/out"
if grep -q "$(printf '\033')" "$work/out"; then echo "a control code reached the screen" >&2; exit 1; fi
grep -qE '^  my-lfm ' "$work/out" || { cat "$work/out" >&2; echo "plain names were dropped too" >&2; exit 1; }
ok "model list prints no folder name with control codes in it"

# No npu folder (the no-NPU edition, or before the first download) and a failing settings read:
# the list still prints and exits 0.
rm -rf "$work/models"; mkdir -p "$work/models/LFM"
printf '#!/bin/bash\nexit 1\n' > "$work/bin/systemd-run"
HALOGEN_MODELS_DIR="$work/models" "$ctl" model list > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "model list failed with no npu folder" >&2; exit 1; }
grep -q '^  None downloaded yet\.' "$work/out" || { cat "$work/out" >&2; echo "no 'None downloaded yet'" >&2; exit 1; }
ok "model list still works with no NPU folder and no readable settings"

# flash: your own Flash checkpoints beside the official one, switched only to verified ones.
f systemd-run 'case "$*" in
  *flash-checkpoint\ use\ *|*flash-checkpoint\ drafter\ *|*flash-checkpoint\ remove\ *|*model-pull\ --remove\ *)
    # The real helper, as it runs under the lock; FAKE_BEFORE is what another terminal does
    # while halogenctl was asking.
    echo "systemd-run $*" >> "$FAKE/log"; [ -z "${FAKE_BEFORE:-}" ] || bash -c "$FAKE_BEFORE"
    while [ $# -gt 0 ] && [ "${1#/}" = "$1" ]; do shift; done
    s="$1"; shift; exec "$FAKE_REPO/files/usr/libexec/halogen/${s##*/}" "$@" ;;
  *render-config*) c="$(cat "$FAKE/configs/flash-checkpoint" 2>/dev/null)"
    if [ -n "${FAKE_FALLBACK:-}" ] || [ -z "$c" ] || [ "$c" = official ]; then
      [ -z "${FAKE_FALLBACK:-}" ] || echo "halogen-config: $c has not passed Halogens verify; using the official one" >&2
      echo HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn
    else echo "HALOGEN_CHECKPOINT=/models/flash/$c/model.hgn"; fi ;;
  *flash-checkpoint*pull*) echo "Downloading..."; echo "name=mine" ;;
  *flash-checkpoint*verify*) echo "verify $*" >> "$FAKE/log" ;;
  *flash-checkpoint\ check-prepare*) echo "prepare $*" >> "$FAKE/log"; [ -z "${FAKE_PREPARE_FAILS:-}" ] || exit 1 ;;
  *flash-checkpoint\ check*) echo "check $*" >> "$FAKE/log"; echo $'"'"'measured \e[2J'"'"'; [ -z "${FAKE_CHECK_FAILS:-}" ] || exit 1 ;;
esac'
fm="$work/fmodels"; mkdir -p "$fm/flash/mine" "$fm/flash/broken" "$fm/flash/partial"
printf 'repo=someone/Mine-HGN\ncommit=0123456789abcdef\ncheckpoint=model.hgn\nverified=pass\nverified_with=0.19.1\n' > "$fm/flash/mine/halos.info"
printf 'repo=someone/Broken\033]0;owned\007\ncheckpoint=model.hgn\nverified=fail\n' > "$fm/flash/broken/halos.info"
export HALOGEN_MODELS_DIR="$fm"
"$ctl" flash list > "$work/out"
if ! grep -qE '^  official +\S+ +yes ' "$work/out" || ! grep -qE '^  mine +\S+ +no +yes, with 0.19.1 +someone/Mine-HGN at 0123456789ab$' "$work/out" ||
   ! grep -qE '^  broken .* FAILED ' "$work/out" || ! grep -qE '^  partial .* incomplete pull' "$work/out" || ! grep -q '^ACTIVE' "$work/out"; then cat "$work/out" >&2; echo "flash list is wrong" >&2; exit 1; fi
if grep -q $'\033' "$work/out"; then echo "flash list printed a terminal escape from halos.info" >&2; exit 1; fi
if "$ctl" flash use mine < /dev/null > "$work/out" 2>&1; then echo "use switched without asking" >&2; exit 1; fi
[ ! -e "$work/configs/flash-checkpoint" ] || { echo "a declined switch changed the setting" >&2; exit 1; }
if "$ctl" flash use broken --yes > "$work/out" 2>&1; then echo "a checkpoint that failed verify was used" >&2; exit 1; fi
if "$ctl" flash use nothing --yes > "$work/out" 2>&1; then echo "a missing checkpoint was used" >&2; exit 1; fi
if "$ctl" flash use ../mine --yes > "$work/out" 2>&1; then echo "a path was accepted as a name" >&2; exit 1; fi
: > "$work/log"
"$ctl" flash use mine --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if [ "$(cat "$work/configs/flash-checkpoint")" != mine ] || ! grep -q 'systemd-run .*flash-checkpoint use mine' "$work/log" ||
   ! grep -q 'systemctl --user --machine=halogen@.host restart halogen.service' "$work/log"; then
  echo "use did not write the choice as halogen and restart" >&2; exit 1
fi
"$ctl" flash list > "$work/out"; grep -qE '^  mine +\S+ +yes ' "$work/out" || { echo "list doesn't show the active one" >&2; exit 1; }
"$ctl" status > "$work/out" 2>/dev/null; grep -q 'flash use official' "$work/out" || { echo "status doesn't say how to go back" >&2; exit 1; }
FAKE_FALLBACK=1 "$ctl" flash list > "$work/out"
if ! grep -qE '^  official +\S+ +yes ' "$work/out" || ! grep -q 'You chose mine, but Halogen serves the official checkpoint: mine has not passed' "$work/out"; then
  cat "$work/out" >&2; echo "list hides that Halogen fell back to official" >&2; exit 1
fi
FAKE_FALLBACK=1 "$ctl" status > "$work/out" 2>/dev/null
grep -q 'you chose mine, but Halogen serves the official one' "$work/out" || { echo "status hides the fallback" >&2; exit 1; }
if "$ctl" flash remove mine --yes > "$work/out" 2>&1; then echo "the active checkpoint was removed" >&2; exit 1; fi
if "$ctl" flash remove official --yes > "$work/out" 2>&1; then echo "official was removable" >&2; exit 1; fi
"$ctl" flash remove broken --yes > /dev/null
if [ -e "$fm/flash/broken" ] || ! grep -q "systemd-run .*flash-checkpoint remove broken" "$work/log"; then
  echo "remove didn't delete as halogen" >&2; exit 1
fi
"$ctl" flash use official --yes > /dev/null
[ "$(cat "$work/configs/flash-checkpoint")" = official ] || exit 1
"$ctl" flash pull someone/Mine-HGN --as mine > "$work/out" 2>/dev/null; grep -q 'sudo halogenctl flash use mine' "$work/out" || { echo "pull doesn't say how to use it" >&2; exit 1; }
"$ctl" flash verify mine > /dev/null; grep -q 'verify mine' "$work/log" || exit 1
ok "flash lists, switches only to verified checkpoints after asking, never removes the active or official one, all as halogen"

# flash drafter <name> [official|off|<file>]: official by default (no line); the choice is written
# as halogen under the checkpoint's lock; a file only when its pull listed it; a restart only for the
# checkpoint Halogen serves, after asking; remove drops the line.
mkdir -p "$fm/flash/spare"; printf 'repo=someone/Spare\ncheckpoint=model.hgn\ndrafter=their-drafter.hgn\nverified=pass\n' > "$fm/flash/spare/halos.info"
printf 'HGN1' > "$fm/flash/spare/their-drafter.hgn"; printf 'HGN1' > "$fm/flash/spare/stray.hgn"
if "$ctl" flash drafter official off > "$work/out" 2>&1; then echo "drafter took official" >&2; exit 1; fi
if "$ctl" flash drafter nothing off > "$work/out" 2>&1; then echo "drafter took a missing checkpoint" >&2; exit 1; fi
if "$ctl" flash drafter spare ../x > "$work/out" 2>&1; then echo "drafter took a path" >&2; exit 1; fi
if "$ctl" flash drafter spare stray.hgn > "$work/out" 2>&1; then echo "drafter took a file the pull didn't list" >&2; exit 1; fi
"$ctl" flash drafter spare > "$work/out"
{ grep -q "official draft head (the default)" "$work/out" && grep -q 'their-drafter.hgn' "$work/out"; } || { cat "$work/out" >&2; exit 1; }
: > "$work/log"
"$ctl" flash drafter spare their-drafter.hgn > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if [ "$(cat "$work/configs/flash-drafter")" != spare=their-drafter.hgn ] || ! grep -q 'systemd-run .*flash-checkpoint drafter spare their-drafter.hgn' "$work/log" \
   || grep -q 'restart halogen.service' "$work/log"; then
  cat "$work/log" "$work/out" >&2; echo "drafter for a checkpoint not served didn't just save the choice as halogen" >&2; exit 1
fi
"$ctl" flash list > "$work/out"; grep -q 'official draft head, except: spare=their-drafter.hgn' "$work/out" || { cat "$work/out" >&2; echo "flash list doesn't show it" >&2; exit 1; }
printf 'spare\n' > "$work/configs/flash-checkpoint"
if "$ctl" flash drafter spare off < /dev/null > "$work/out" 2>&1; then echo "drafter for the served checkpoint didn't ask" >&2; exit 1; fi
[ "$(cat "$work/configs/flash-drafter")" = spare=their-drafter.hgn ] || { echo "a declined change changed the list" >&2; exit 1; }
: > "$work/log"
"$ctl" flash drafter spare off --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if [ "$(cat "$work/configs/flash-drafter")" != spare=off ] || ! grep -q 'restart halogen.service' "$work/log"; then
  echo "drafter for the served checkpoint didn't save and restart" >&2; exit 1
fi
"$ctl" flash drafter spare official --yes > /dev/null 2>&1
[ ! -s "$work/configs/flash-drafter" ] || { echo "official (the default) left a line" >&2; exit 1; }
# File names as ls shows them, and full paths, stand for the choice; anything outside what halOS
# checked is refused with the list; one argument is the choice for the checkpoint Halogen serves.
printf 'HGN1' > "$fm/qwen38-flash-next-drafter-r2-ht4.hgn"
"$ctl" flash drafter spare off --yes > /dev/null 2>&1
"$ctl" flash drafter spare qwen38-flash-next-drafter-r2-ht4.hgn --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ ! -s "$work/configs/flash-drafter" ] || { cat "$work/configs/flash-drafter" >&2; echo "the official file's name didn't mean official" >&2; exit 1; }
grep -q "doesn't know yet whether spare carries its own precision" "$work/out" || { cat "$work/out" >&2; echo "no note about own_precision" >&2; exit 1; }
if "$ctl" flash drafter spare official-r2 --yes > "$work/out" 2>&1; then echo "official-r2 taken without the file" >&2; exit 1; fi
grep -q 'Choices: official (qwen38-flash-next-drafter-r2-ht4.hgn), off .*their-drafter.hgn' "$work/out" || { cat "$work/out" >&2; echo "a refusal doesn't list the choices" >&2; exit 1; }
printf 'HGN1' > "$fm/qwen38-flash-next-drafter-r2.hgn"
"$ctl" flash drafter spare /var/srv/models/qwen38-flash-next-drafter-r2.hgn --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ "$(cat "$work/configs/flash-drafter")" = spare=official-r2 ] || { echo "the older official draft head's path wasn't taken" >&2; exit 1; }
"$ctl" flash drafter spare /srv/models/flash/spare/their-drafter.hgn --yes > /dev/null 2>&1
[ "$(cat "$work/configs/flash-drafter")" = spare=their-drafter.hgn ] || { echo "the checkpoint's own file by path wasn't taken" >&2; exit 1; }
for bad in /srv/configs/api-key /srv/models/flash/spare/stray.hgn /srv/models/flash/spare/../../configs/x /tmp/x-drafter.hgn /srv/models/qwen38-flash-next-ngram.hgn; do
  if "$ctl" flash drafter spare "$bad" --yes > "$work/out" 2>&1 || ! grep -q '^Choices: .*official-r2' "$work/out"; then
    cat "$work/out" >&2; echo "drafter took $bad, or didn't list the choices" >&2; exit 1
  fi
done
[ "$(cat "$work/configs/flash-drafter")" = spare=their-drafter.hgn ] || { echo "a refused file changed the list" >&2; exit 1; }
printf 'official\n' > "$work/configs/flash-checkpoint"
if "$ctl" flash drafter official > "$work/out" 2>&1 || ! grep -q 'official checkpoint, which always' "$work/out"; then
  cat "$work/out" >&2; echo "drafter without a name while the official checkpoint is served" >&2; exit 1
fi
printf 'spare\n' > "$work/configs/flash-checkpoint"
"$ctl" flash drafter > "$work/out" 2>&1; grep -q '^spare drafts with their-drafter.hgn' "$work/out" || { cat "$work/out" >&2; echo "drafter alone doesn't show the served checkpoint" >&2; exit 1; }
"$ctl" flash drafter official --yes > /dev/null 2>&1
[ ! -s "$work/configs/flash-drafter" ] || { echo "drafter official didn't set the served checkpoint" >&2; exit 1; }
# A checkpoint that lists its own file under an official name: the bare name picks that one, the
# path under /srv/models the official one. own_precision=0 gets its own note.
printf 'drafter=qwen38-flash-next-drafter-r2.hgn\nown_precision=0\n' >> "$fm/flash/spare/halos.info"; printf 'HGN1' > "$fm/flash/spare/qwen38-flash-next-drafter-r2.hgn"
"$ctl" flash drafter spare qwen38-flash-next-drafter-r2.hgn --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ "$(cat "$work/configs/flash-drafter")" = spare=qwen38-flash-next-drafter-r2.hgn ] || { echo "the bare name didn't pick the checkpoint's own file" >&2; exit 1; }
grep -q "doesn't carry its own precision" "$work/out" || { cat "$work/out" >&2; echo "no note for own_precision=0" >&2; exit 1; }
"$ctl" flash drafter spare /srv/models/qwen38-flash-next-drafter-r2.hgn --yes > /dev/null 2>&1
[ "$(cat "$work/configs/flash-drafter")" = spare=official-r2 ] || { echo "the path didn't pick the official file" >&2; exit 1; }
# Under the lock, flash-checkpoint itself refuses official-r2 when a link stands at its name.
rm "$fm/qwen38-flash-next-drafter-r2.hgn"; ln -s "$fm/flash/spare/their-drafter.hgn" "$fm/qwen38-flash-next-drafter-r2.hgn"
if HALOGEN_DRAFTER_CHOICE_FILE="$work/configs/flash-drafter" "$repo/files/usr/libexec/halogen/flash-checkpoint" drafter spare off > "$work/out" 2>&1 \
   && HALOGEN_DRAFTER_CHOICE_FILE="$work/configs/flash-drafter" "$repo/files/usr/libexec/halogen/flash-checkpoint" drafter spare official-r2 > "$work/out" 2>&1; then
  echo "flash-checkpoint took official-r2 through a link" >&2; exit 1
fi
grep -q "official-r2 can't be chosen" "$work/out" || { cat "$work/out" >&2; echo "flash-checkpoint didn't say why" >&2; exit 1; }
sed -i '/^drafter=qwen38-flash-next-drafter-r2.hgn$/d; /^own_precision=0$/d' "$fm/flash/spare/halos.info"; rm "$fm/flash/spare/qwen38-flash-next-drafter-r2.hgn"
"$ctl" flash drafter spare their-drafter.hgn --yes > /dev/null 2>&1
rm "$fm/qwen38-flash-next-drafter-r2-ht4.hgn" "$fm/qwen38-flash-next-drafter-r2.hgn"
printf 'official\n' > "$work/configs/flash-checkpoint"
"$ctl" flash drafter spare off > /dev/null 2>&1
printf 'mine=off\nbad line\n' >> "$work/configs/flash-drafter"
: > "$work/log"
"$ctl" flash remove spare --yes > /dev/null 2>&1 || exit 1
grep -q 'systemctl start --no-block halos-status.service' "$work/log" || { echo "flash remove didn't refresh the names for tab completion" >&2; exit 1; }
[ "$(cat "$work/configs/flash-drafter")" = mine=off ] || { cat "$work/configs/flash-drafter" >&2; echo "remove didn't drop the line, or a bad line was kept" >&2; exit 1; }
: > "$work/configs/flash-drafter"
ok "flash drafter is official by default, saves a choice as halogen, takes only a listed or official file (by name or path), defaults to the served checkpoint, asks and restarts only for the served checkpoint, and remove drops it"

# What another terminal does while flash use or remove asks is checked again under the
# checkpoint's lock (#119), and a checkpoint another command holds is a busy message.
mkdir -p "$fm/flash/other"; printf 'repo=someone/Other\ncheckpoint=model.hgn\nverified=pass\n' > "$fm/flash/other/halos.info"
: > "$work/log"
if FAKE_BEFORE="printf %s other > \"\$FAKE/configs/flash-checkpoint\"" "$ctl" flash remove other --yes > "$work/out" 2>&1 || [ ! -d "$fm/flash/other" ]; then
  cat "$work/out" >&2; echo "flash remove deleted the checkpoint chosen while it asked" >&2; exit 1
fi
grep -q 'chosen meanwhile' "$work/out" || { cat "$work/out" >&2; exit 1; }
echo official > "$work/configs/flash-checkpoint"; : > "$work/log"
if FAKE_BEFORE="sed -i s/verified=pass/verified=fail/ \"$fm/flash/other/halos.info\"" "$ctl" flash use other --yes > "$work/out" 2>&1; then
  echo "flash use chose a checkpoint that failed verify while it asked" >&2; exit 1
fi
if [ "$(cat "$work/configs/flash-checkpoint")" != official ] || grep -q 'restart halogen.service' "$work/log"; then echo "a refused switch changed the choice or restarted" >&2; exit 1; fi
sed -i s/verified=fail/verified=pass/ "$fm/flash/other/halos.info"
if FAKE_BEFORE="rm -rf \"$fm/flash/other\"" "$ctl" flash use other --yes > "$work/out" 2>&1 || grep -q 'restart halogen.service' "$work/log"; then
  echo "flash use chose a checkpoint removed while it asked" >&2; exit 1
fi
grep -q 'No checkpoint called other (any more)' "$work/out" || { cat "$work/out" >&2; echo "a removed checkpoint wasn't named as gone" >&2; exit 1; }
mkdir -p "$fm/flash/other"; printf 'repo=someone/Other\ncheckpoint=model.hgn\nverified=pass\n' > "$fm/flash/other/halos.info"
exec 7>> "$work/hstate/pull-flash-other.lock"; flock -n 7
if "$ctl" flash use other --yes > "$work/out" 2>&1 || "$ctl" flash remove other --yes >> "$work/out" 2>&1; then echo "use or remove ran beside a pull of the same checkpoint" >&2; exit 1; fi
exec 7>&-
if [ ! -d "$fm/flash/other" ] || [ "$(cat "$work/configs/flash-checkpoint")" != official ]; then echo "a busy checkpoint was changed" >&2; exit 1; fi
grep -q 'Another pull, check or other command on other is running' "$work/out" || { cat "$work/out" >&2; exit 1; }
# A folder at the choice's name: the switch fails and says so, instead of seeming to work with
# the choice saved inside that folder (security audit A2).
rm -f "$work/configs/flash-checkpoint"; mkdir "$work/configs/flash-checkpoint"; : > "$work/log"
if "$ctl" flash use other --yes > "$work/out" 2>&1 || grep -q 'restart halogen.service' "$work/log"; then
  cat "$work/out" >&2; echo "flash use reported a switch it couldn't save" >&2; exit 1
fi
grep -q "Couldn't save the choice" "$work/out" || { cat "$work/out" >&2; exit 1; }
[ -z "$(ls -A "$work/configs/flash-checkpoint")" ] || { echo "the choice was saved inside a folder" >&2; exit 1; }
rmdir "$work/configs/flash-checkpoint"; echo official > "$work/configs/flash-checkpoint"
# Switching (back to official too) works whatever stands at .prompt-cache: use starts no
# container. A switch leaves no process group in the lock.
rm -rf "$fm/.prompt-cache"; ln -s "$work/nowhere" "$fm/.prompt-cache"; echo 4242 > "$work/hstate/pull-flash-other.lock"
"$ctl" flash use other --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "flash use failed with .prompt-cache a link" >&2; exit 1; }
[ ! -s "$work/hstate/pull-flash-other.lock" ] || { echo "a switch wrote a process group into the checkpoint's lock" >&2; exit 1; }
"$ctl" flash use official --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "going back to official failed with .prompt-cache a link" >&2; exit 1; }
[ "$(cat "$work/configs/flash-checkpoint")" = official ] || exit 1
rm "$fm/.prompt-cache"
# A flash check holds the GPU with Halogen stopped: a second check, or a switch that restarts
# Halogen, is refused after the answer, without stopping anything. A question left open holds
# nothing, so the second check gets as far as asking.
exec 7> "$work/locks/gpu.lock"; flock -n 7; : > "$work/log"
if "$ctl" flash check mine --yes > "$work/out" 2>&1; then echo "a second flash check ran beside the first" >&2; exit 1; fi
if grep -q -e 'stop halogen' -e 'halogen-flash-check' -e '^prepare ' "$work/log"; then echo "a refused check prepared, stopped Halogen or the running check" >&2; exit 1; fi
if "$ctl" flash use other --yes > "$work/out" 2>&1 || grep -q 'restart halogen.service' "$work/log"; then echo "a switch restarted Halogen during a check" >&2; exit 1; fi
grep -q 'Another halogenctl command is using the GPU' "$work/out" || { cat "$work/out" >&2; exit 1; }
for cmd in "check mine" "use other"; do
  # shellcheck disable=SC2086 # two words on purpose
  "$ctl" flash $cmd < /dev/null > "$work/out" 2>&1 || true
  grep -q 'add --yes' "$work/out" || { cat "$work/out" >&2; echo "flash $cmd took the GPU lock before the question" >&2; exit 1; }
done
exec 7>&-
ok "flash use and remove check again under the checkpoint's lock after asking; a check holds the GPU"

# flash check stops Halogen for the GPU, and starts it again whatever happens.
: > "$work/log"
if "$ctl" flash check mine < /dev/null > "$work/out" 2>&1; then echo "check stopped Halogen without asking" >&2; exit 1; fi
if grep -q 'stop halogen.service' "$work/log"; then echo "a declined check stopped Halogen" >&2; exit 1; fi
"$ctl" flash check mine --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -e 'stop halogen.service' -e '^check ' -e '^prepare ' -e 'start halogen.service' "$work/log" | sed 's/ .*\(stop\|start\) halogen.service/ \1/; s/^\(check\|prepare\) .*/\1/' > "$work/order"
[ "$(tr '\n' ' ' < "$work/order")" = "prepare systemctl stop check systemctl start " ] || { cat "$work/log" >&2; echo "check didn't prepare, stop, measure, then start Halogen" >&2; exit 1; }
grep -q -- '--unit=halogen-flash-check --collect -p RuntimeMaxSec=3h' "$work/log" || { echo "the measurement had no name or time limit" >&2; exit 1; }
grep -q 'stop halogen-flash-check.service' "$work/log" || { echo "the measurement was not stopped before Halogen started" >&2; exit 1; }
if grep -q $'\e' "$work/out"; then echo "a control character from the measurement reached the terminal" >&2; exit 1; fi
: > "$work/log"
if FAKE_PREPARE_FAILS=1 "$ctl" flash check mine --yes > "$work/out" 2>&1; then echo "a failed preparation passed" >&2; exit 1; fi
if grep -q 'stop halogen.service' "$work/log"; then echo "Halogen was stopped although the check couldn't start" >&2; exit 1; fi
# A terminal that goes away during the measurement (writes then fail) must not keep Halogen down:
# the reader stops at the measurement's output, so everything printed after it fails.
: > "$work/log"
{ "$ctl" flash check mine --yes 2>&1 || true; } | { grep -m 1 -q measured || true; } || true
grep -q 'start halogen.service' "$work/log" || { echo "Halogen stayed stopped when the terminal went away" >&2; exit 1; }
# Halogen stopped on purpose stays stopped after a check.
: > "$work/log"
FAKE_INACTIVE=1 "$ctl" flash check mine --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if grep -q 'start halogen.service' "$work/log"; then echo "a check started a Halogen that was stopped before" >&2; exit 1; fi
grep -q 'left stopped' "$work/out" || { cat "$work/out" >&2; echo "no word that Halogen was left stopped" >&2; exit 1; }
: > "$work/log"
if FAKE_CHECK_FAILS=1 "$ctl" flash check mine --yes > "$work/out" 2>&1; then echo "a failed check passed" >&2; exit 1; fi
grep -q 'start halogen.service' "$work/log" || { echo "Halogen stayed stopped after a failed check" >&2; exit 1; }
for bad in official ../mine nothing; do
  if "$ctl" flash check "$bad" --yes > "$work/out" 2>&1; then echo "check took $bad" >&2; exit 1; fi
done
printf 'checked_ppl=3.8109\nchecked_official_ppl=3.8522\nchecked_top1=0.86463\nchecked_kl_median=0.045499\nchecked_with=0.19.1\n' >> "$fm/flash/mine/halos.info"
"$ctl" flash list > "$work/out"
grep -qE '^  mine +perplexity 3\.81 \(official 3\.85\), same next token 86\.5%, KL median 0\.045, with Halogen 0\.19\.1$' "$work/out" \
  || { cat "$work/out" >&2; echo "flash list doesn't show the check" >&2; exit 1; }
# A version planted as text with an escape in it is printed as text, never as an escape.
sed -i 's/^checked_with=.*/checked_with=\\033[2J/; s/^checked_kl_median=.*/checked_kl_median=oops/' "$fm/flash/mine/halos.info"
"$ctl" flash list > "$work/out"
if grep -q $'\033' "$work/out"; then echo "flash list turned planted text into an escape code" >&2; exit 1; fi
grep -qE 'KL median \?, ' "$work/out" || { cat "$work/out" >&2; echo "a value that isn't a number wasn't shown as ?" >&2; exit 1; }
ok "flash check asks, stops Halogen, measures as halogen, starts it again even after a failure, and list shows the result"
# Scripts run as halogen never get root's terminal: no input, and no control characters back.
f systemd-run 'if read -r -t 1 line; then echo "got input: $line" >> "$FAKE/log"; fi
printf "HALOGEN_KV8=1\033]0;owned\007\n"; printf "halogen-config: warn\033[2J\tx\n" >&2; exit "${FAKE_RC:-0}"'
: > "$work/log"
echo typed-by-root | "$ctl" config > "$work/out" 2>&1
if grep -q 'got input' "$work/log"; then echo "a script run as halogen read root's input" >&2; exit 1; fi
if grep -q $'\033\|\007' "$work/out"; then echo "a control character from a script run as halogen reached root's terminal" >&2; exit 1; fi
grep -qF $'halogen-config: warn[2J\tx' "$work/out" || { cat "$work/out" >&2; echo "the script's own output (with tabs) was lost" >&2; exit 1; }
if FAKE_RC=3 "$ctl" doctor > "$work/out" 2>&1; then echo "a failing script run as halogen passed" >&2; exit 1; fi
# doctor shows a failing settings check, even when the other check passes.
f systemd-run 'case "$*" in *render-config*) echo "mkdir: cannot create directory"; exit 1 ;; *) echo "preflight: ok" ;; esac'
if "$ctl" doctor > "$work/out" 2>&1; then echo "doctor hid a failing settings check" >&2; exit 1; fi
grep -q 'cannot create directory' "$work/out" || { cat "$work/out" >&2; echo "doctor hid why the settings check failed" >&2; exit 1; }
ok "scripts run as halogen get no input from root's terminal, can't write control characters to it, and their failures still count"

# status: the service manager's text is halogen's too.
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *" status "*) printf "halogen.service - x\033]52;c;ZWNobyBvd25lZA==\007y\n" ;; esac'
"$ctl" status > "$work/out" 2>&1 || true
if grep -q $'\033' "$work/out"; then echo "status passed a control character from halogen's service manager" >&2; exit 1; fi
grep -q 'halogen.service - x' "$work/out" || { cat "$work/out" >&2; echo "status lost its own text" >&2; exit 1; }
printf 'key\033[2J\n' > "$work/configs/api-key"
[ "$("$ctl" api-key)" = 'key[2J' ] || { echo "api-key printed a control character" >&2; exit 1; }
ok "status and api-key print no control characters the halogen user could have planted"

# flash convert: the checks run now, as halogen; the long part starts as its own unit and returns.
f systemd-run 'echo "systemd-run $*" >> "$FAKE/log"; case "$*" in
  *convert-prepare*) [ -z "${FAKE_PREP_FAILS:-}" ] || { echo "isn'"'"'t Qwen3.8 Flash Next weights"; exit 1; }
    echo "Looking up..."; echo "name=conv"; echo "download=700.0 GiB"; echo "result=about 119.2 GiB" ;;
esac'
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *"is-active halogen-flash-convert.service"*) echo "${FAKE_CONV:-inactive}" ;; esac'
: > "$work/log"
if "$ctl" flash convert someone/Flash-BF16 < /dev/null > "$work/out" 2>&1; then echo "started without confirming" >&2; exit 1; fi
grep -q 'add --yes' "$work/out"; if grep -q 'unit=halogen-flash-convert' "$work/log"; then echo "started anyway" >&2; exit 1; fi
"$ctl" flash convert someone/Flash-BF16 --as conv --threads 4 --keep-source --yes > "$work/out" 2>&1
grep -q 'convert-prepare someone/Flash-BF16 --as conv' "$work/log" || { cat "$work/log" >&2; exit 1; }
grep -q -- '--unit=halogen-flash-convert .*-p Nice=10 .*flash-checkpoint convert-run conv --threads 4 --keep-source' "$work/log" \
  || { cat "$work/log" >&2; echo "the conversion wasn't started as its own unit with the options" >&2; exit 1; }
if grep -q 'unit=halogen-flash-convert.*--wait' "$work/log"; then echo "the conversion holds the terminal" >&2; exit 1; fi
grep -q '700.0 GiB of weights' "$work/out" && grep -q 'convert-logs' "$work/out"
: > "$work/log"
if FAKE_PREP_FAILS=1 "$ctl" flash convert someone/Llama --yes > "$work/out" 2>&1; then echo "a refused model started" >&2; exit 1; fi
if grep -q 'unit=halogen-flash-convert' "$work/log"; then echo "started after a refusal" >&2; exit 1; fi
: > "$work/log"
for t in abc 0 99; do
  if "$ctl" flash convert someone/Flash-BF16 --threads "$t" --yes > "$work/out" 2>&1; then echo "took --threads $t" >&2; exit 1; fi
done
if grep -q 'convert-prepare\|unit=halogen-flash-convert' "$work/log"; then echo "a bad --threads got past the start" >&2; exit 1; fi
if FAKE_CONV=active "$ctl" flash convert someone/Flash-BF16 --yes > "$work/out" 2>&1; then echo "a second conversion started" >&2; exit 1; fi
grep -q 'already running' "$work/out"
FAKE_CONV=active "$ctl" flash convert-stop > "$work/out"; grep -q 'stop halogen-flash-convert.service' "$work/log"
ok "flash convert checks first, asks, starts one conversion as its own unit and returns; convert-stop stops it"

# Request records (#107): on/off is a Quadlet drop-in root writes, then a reload and a restart;
# stats and prune run Halogen's own tool inside the container, with only the options it documents.
export HALOGEN_RECORDS_DROPIN="$work/dropin.d/20-records.conf" HALOGEN_LOGS_DIR="$work/logs"
mkdir -p "$work/logs/halogen"
printf 'HALOGEN_IMAGE=ghcr.io/peonist-ai/halogen-flash-server@sha256:abc\n' > "$work/release.env"
export HALOGEN_RELEASE_FILE="$work/release.env"
f id 'if [ "$1" = -u ]; then echo "${FAKE_UID:-0}"; else exec /usr/bin/id "$@"; fi'
# setpriv as halogen: log it, then run what follows env (the fake systemctl below).
f setpriv 'echo "setpriv $*" >> "$FAKE/log"; while [ $# -gt 0 ] && [ "$1" != env ]; do shift; done; exec "$@"'
f curl 'h="${FAKE_HEALTH:-}"; [ -n "$h" ] || h="{\"status\":\"ok\"}"; echo "$h"'
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *"is-active --quiet halogen.service"*) [ -z "${FAKE_INACTIVE:-}" ] ;;
  *"--user is-active halogen.service"*) if [ -n "${FAKE_NOANSWER:-}" ]; then exit 1; elif [ -n "${FAKE_INACTIVE:-}" ]; then echo inactive; exit 3; else echo active; fi ;;
  *"cat halogen.service"*) if [ -z "${FAKE_NOMOUNT:-}" ] && [ -f "$HALOGEN_RECORDS_DROPIN" ]; then echo "ExecStart=podman run -v /srv/logs/halogen:/records x"; fi ;; esac'
f systemd-run 'echo "systemd-run $*" >> "$FAKE/log"; case "$*" in *render-config*) echo HALOGEN_RECORD_TEXT=none ;; *request_records*) echo "turns 3" ;; esac'
: > "$work/log"
"$ctl" records > "$work/out"; grep -q '^Request records: off' "$work/out" || { cat "$work/out" >&2; exit 1; }
if "$ctl" records on < /dev/null > /dev/null 2>&1; then echo "records on ran without --yes or a terminal" >&2; exit 1; fi
[ ! -e "$work/dropin.d/20-records.conf" ] || { echo "records on changed something before asking" >&2; exit 1; }
"$ctl" records on --yes > /dev/null
grep -qx 'Volume=/srv/logs/halogen:/records:noexec,nosuid,nodev' "$work/dropin.d/20-records.conf" || { echo "no records mount" >&2; exit 1; }
if ! { grep -q 'setpriv --reuid=.* env -C / XDG_RUNTIME_DIR=/run/user/.* systemctl --user daemon-reload' "$work/log" && grep -q 'restart halogen.service' "$work/log"; }; then
  cat "$work/log" >&2; echo "records on didn't reload and restart" >&2; exit 1
fi
"$ctl" records > "$work/out"; grep -q '^Request records: on, text kept: none' "$work/out" || { cat "$work/out" >&2; exit 1; }
"$ctl" records stats > "$work/out"
grep -q 'podman exec halogen python3 /halogen/tools/request_records.py stats /records' "$work/log" || { echo "stats didn't run Halogen's tool" >&2; exit 1; }
"$ctl" records prune --days 7 --yes > /dev/null
grep -q 'request_records.py prune /records --days 7$' "$work/log" || { cat "$work/log" >&2; echo "prune didn't pass --days" >&2; exit 1; }
for bad in '--days x' '--gib 1;id' '--session ../x' '--path /etc' ''; do
  # shellcheck disable=SC2086 # split on purpose
  if "$ctl" records prune $bad --yes > /dev/null 2>&1; then echo "prune took '$bad'" >&2; exit 1; fi
done
FAKE_INACTIVE=1 "$ctl" records off --yes > "$work/out" || { cat "$work/out" "$work/log" >&2; exit 1; }
if [ -e "$work/dropin.d/20-records.conf" ] || ! grep -q "next starts" "$work/out"; then cat "$work/out" >&2; echo "records off did not remove the mount" >&2; exit 1; fi
# Off (or stopped): the records kept before are still reached, in a one-off container of the
# pinned image with only that folder, no network and nothing writable but it.
: > "$work/log"; "$ctl" records prune --all --yes > /dev/null
if ! grep -q 'podman run --rm --pull=never --network=none --read-only --cap-drop=all --security-opt no-new-privileges -v /srv/logs/halogen:/records:noexec,nosuid,nodev --entrypoint python3 ghcr.io/peonist-ai/halogen-flash-server@sha256:abc /halogen/tools/request_records.py prune /records --all$' "$work/log"; then
  cat "$work/log" >&2; echo "prune after off didn't reach the kept records" >&2; exit 1
fi
if grep -q 'podman exec' "$work/log"; then echo "prune after off ran in the server's container" >&2; exit 1; fi
# An off cut short (drop-in gone, Halogen still recording): off restarts it.
: > "$work/log"; FAKE_HEALTH='{"request_records":{"written":1}}' "$ctl" records off --yes > /dev/null
grep -q 'restart halogen.service' "$work/log" || { echo "a server still recording wasn't restarted" >&2; exit 1; }
: > "$work/log"; "$ctl" records off --yes > /dev/null
if grep -q 'restart halogen.service' "$work/log"; then echo "off restarted a server that doesn't record" >&2; exit 1; fi
if FAKE_UID=1000 "$ctl" records on --yes > "$work/out" 2>&1 || ! grep -q 'Run it with sudo' "$work/out"; then echo "records on ran without root" >&2; exit 1; fi
"$ctl" records prune --session ab_C-12 --yes > /dev/null || { echo "a base64url hash was refused" >&2; exit 1; }
# A manager that doesn't answer is an error, never "not running" (which would skip the restart).
if FAKE_NOANSWER=1 "$ctl" records on --yes > "$work/out" 2>&1 || ! grep -q "Couldn't ask" "$work/out"; then cat "$work/out" >&2; echo "no answer was taken for stopped" >&2; exit 1; fi
rm -f "$work/dropin.d/20-records.conf"
# A reload that doesn't bring the mount is reported, not called done.
if FAKE_NOMOUNT=1 "$ctl" records on --yes > "$work/out" 2>&1 || ! grep -q "isn't in Halogen's service" "$work/out"; then cat "$work/out" >&2; echo "a missing mount after on wasn't reported" >&2; exit 1; fi
rm -f "$work/dropin.d/20-records.conf"
ok "records on/off mounts the folder (after asking) and restarts; stats and prune run Halogen's tool with checked options, also after off"

# The prompt cache on disk: on by default; off/on write the choice as halogen and restart a running
# Halogen; clear stops it, empties only the folder, and starts it again. All ask first.
# Off also mounts the folder read-only: root's drop-in in the all-users Quadlet folder. The fake
# manager's generated unit follows that file, unless FAKE_STUCK says the reload changed nothing.
export HALOGEN_CACHE_OFF_DROPIN="$work/allusers.d/15-prompt-cache.conf"
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *"is-active halogen.service"*) echo "${FAKE_ACTIVE-active}" ;;
  *"cat halogen.service"*) o=""; if [ -n "${FAKE_STUCK:-}" ]; then o="${FAKE_STUCK#rw}"; elif [ -f "$HALOGEN_CACHE_OFF_DROPIN" ]; then o="ro,"; fi
    if [ "${FAKE_STUCK:-}" = none ]; then echo "ExecStart=podman run -v /srv/models:/models:ro x"
    elif [ "${FAKE_STUCK:-}" = both ]; then echo "ExecStart=podman run -v /srv/models/.prompt-cache:/models/.prompt-cache:ro,noexec -v /srv/models/.prompt-cache:/models/.prompt-cache:noexec x"; else
    echo "ExecStart=podman run -v /srv/models:/models:ro -v /srv/models/.prompt-cache:/models/.prompt-cache:${o}noexec,nosuid,nodev x"; fi ;;
  *daemon-reload*) [ -z "${FAKE_NORELOAD:-}" ] ;; esac'
mkdir -p "$HALOGEN_MODELS_DIR/.prompt-cache/sub"; echo x > "$HALOGEN_MODELS_DIR/.prompt-cache/sub/rows"; rm -f "$work/configs/prompt-cache"
"$ctl" cache > "$work/out"; grep -q '^Prompt cache on disk: on ' "$work/out" || { cat "$work/out" >&2; exit 1; }
if "$ctl" cache off < /dev/null > /dev/null 2>&1; then echo "cache off ran without --yes or a terminal" >&2; exit 1; fi
[ ! -e "$work/configs/prompt-cache" ] || { echo "cache off changed something before asking" >&2; exit 1; }
: > "$work/log"; "$ctl" cache off --yes > "$work/out"
[ "$(cat "$work/configs/prompt-cache")" = off ] || { echo "cache off wasn't saved" >&2; exit 1; }
grep -q 'runuser -u halogen -- env -C / sh -c' "$work/log" || { echo "the choice wasn't written as halogen" >&2; exit 1; }
grep -q 'systemctl .* restart halogen.service' "$work/log" || { echo "cache off didn't restart a running Halogen" >&2; exit 1; }
[ -e "$HALOGEN_MODELS_DIR/.prompt-cache/sub/rows" ] || { echo "cache off deleted what was saved" >&2; exit 1; }
grep -qx 'Volume=/srv/models/.prompt-cache:/models/.prompt-cache:ro,noexec,nosuid,nodev' "$HALOGEN_CACHE_OFF_DROPIN" || { echo "cache off didn't make the mount read-only" >&2; exit 1; }
grep -q 'systemctl --user daemon-reload' "$work/log" || { echo "cache off didn't reload halogen's manager" >&2; exit 1; }
"$ctl" cache > "$work/out"; grep -q '^Prompt cache on disk: off ' "$work/out" || { cat "$work/out" >&2; exit 1; }
: > "$work/log"; FAKE_ACTIVE=inactive "$ctl" cache on --yes > /dev/null
[ "$(cat "$work/configs/prompt-cache")" = on ] || { echo "cache on wasn't saved" >&2; exit 1; }
[ ! -e "$HALOGEN_CACHE_OFF_DROPIN" ] || { echo "cache on left the read-only mount" >&2; exit 1; }
if grep -q 'restart halogen.service' "$work/log"; then echo "cache on started a stopped Halogen" >&2; exit 1; fi
# A reload that doesn't change the mount: off still leaves the cache off; on doesn't turn it on.
if FAKE_STUCK=rw "$ctl" cache off --yes > /dev/null 2>&1; then echo "cache off passed with a writable mount" >&2; exit 1; fi
[ "$(cat "$work/configs/prompt-cache")" = off ] || { echo "a failed off left Halogen told about the folder" >&2; exit 1; }
if FAKE_STUCK=ro, "$ctl" cache on --yes > /dev/null 2>&1; then echo "cache on passed with a read-only mount" >&2; exit 1; fi
[ "$(cat "$work/configs/prompt-cache")" = off ] || { echo "cache on told Halogen about a read-only folder" >&2; exit 1; }
"$ctl" cache on --yes > /dev/null; [ "$(cat "$work/configs/prompt-cache")" = on ] || { echo "a half-done on wasn't finished" >&2; exit 1; }
# A unit with no cache mount at all, or a reload that fails: said out loud, the cache left off, and a
# running Halogen restarted so that "off" is true for it too.
: > "$work/log"; if FAKE_STUCK=none "$ctl" cache off --yes > /dev/null 2> "$work/err"; then echo "cache off passed without any cache mount" >&2; exit 1; fi
grep -q 'no cache mount' "$work/err" || { cat "$work/err" >&2; echo "a missing cache mount wasn't explained" >&2; exit 1; }
grep -q 'restart halogen.service' "$work/log" || { echo "a failed off left a running Halogen writing the cache" >&2; exit 1; }
if FAKE_STUCK=both "$ctl" cache off --yes > /dev/null 2> "$work/err"; then echo "two cache mounts in the unit passed as off" >&2; exit 1; fi
grep -q '2 cache mounts' "$work/err" || { cat "$work/err" >&2; echo "two cache mounts weren't named" >&2; exit 1; }
# "Already off" needs the unit's mount read-only too: with the unit still wrong it tries again.
if FAKE_STUCK=none "$ctl" cache off --yes > /dev/null 2>&1; then echo "cache off said already off without a read-only mount" >&2; exit 1; fi
"$ctl" cache off --yes > "$work/out"; grep -q 'already off' "$work/out" || { cat "$work/out" >&2; exit 1; }
if FAKE_NORELOAD=1 "$ctl" cache on --yes > /dev/null 2> "$work/err"; then echo "cache on passed though the reload failed" >&2; exit 1; fi
if ! grep -q "didn't reload" "$work/err" || [ "$(cat "$work/configs/prompt-cache")" != off ]; then cat "$work/err" >&2; echo "a failed reload wasn't explained, or left the cache on" >&2; exit 1; fi
# A stale state (the read-only drop-in there, the choice file saying on): a failed on must not
# leave Halogen told about a read-only folder.
"$ctl" cache off --yes > /dev/null; echo on > "$work/configs/prompt-cache"
if FAKE_STUCK=ro, "$ctl" cache on --yes > /dev/null 2>&1; then echo "cache on passed with a read-only mount" >&2; exit 1; fi
[ "$(cat "$work/configs/prompt-cache")" = off ] || { echo "a failed on from a stale state told Halogen about a read-only folder" >&2; exit 1; }
"$ctl" cache on --yes > /dev/null; [ "$(cat "$work/configs/prompt-cache")" = on ] || { echo "cache on didn't recover" >&2; exit 1; }
if FAKE_ACTIVE='' "$ctl" cache off --yes > /dev/null 2>&1; then echo "an unanswered is-active was taken for stopped" >&2; exit 1; fi
[ "$(cat "$work/configs/prompt-cache")" = on ] || { echo "cache off saved the choice before it knew whether Halogen runs" >&2; exit 1; }
grep -q 'setpriv .* systemctl --user is-active halogen.service' "$work/log" || { echo "is-active wasn't asked over halogen's own socket" >&2; exit 1; }
# A delete that fails still starts Halogen again, and doesn't say Deleted.
f find 'case "$*" in *-delete*) exit 1 ;; *) exec /usr/bin/find "$@" ;; esac'
: > "$work/log"; if "$ctl" cache clear --yes > "$work/out" 2>&1; then echo "a failed delete was reported as done" >&2; exit 1; fi
grep -q ' start halogen.service' "$work/log" || { echo "a failed delete left Halogen stopped" >&2; exit 1; }
rm "$work/bin/find"
: > "$work/log"; FAKE_ACTIVE=deactivating "$ctl" cache clear --yes > /dev/null
grep -q ' stop halogen.service' "$work/log" || { echo "cache clear deleted under a Halogen that was still stopping" >&2; exit 1; }
echo x > "$HALOGEN_MODELS_DIR/.prompt-cache/rows"
: > "$work/log"; "$ctl" cache clear --yes > /dev/null
if [ ! -d "$HALOGEN_MODELS_DIR/.prompt-cache" ] || [ -n "$(ls -A "$HALOGEN_MODELS_DIR/.prompt-cache")" ]; then echo "cache clear didn't empty the folder, or removed it" >&2; exit 1; fi
grep -n 'halogen.service' "$work/log" | tr '\n' ' ' | grep -q 'stop halogen.service.* start halogen.service' || { cat "$work/log" >&2; echo "cache clear didn't stop and start Halogen" >&2; exit 1; }
# A folder the container made unreadable is still emptied; a link in place of the folder is refused.
mkdir -p "$HALOGEN_MODELS_DIR/.prompt-cache/locked"; echo x > "$HALOGEN_MODELS_DIR/.prompt-cache/locked/rows"; chmod 000 "$HALOGEN_MODELS_DIR/.prompt-cache/locked"
"$ctl" cache clear --yes > /dev/null
[ -z "$(ls -A "$HALOGEN_MODELS_DIR/.prompt-cache")" ] || { echo "cache clear left an unreadable folder behind" >&2; exit 1; }
rmdir "$HALOGEN_MODELS_DIR/.prompt-cache"; mkdir "$work/elsewhere"; echo keep > "$work/elsewhere/file"; ln -s "$work/elsewhere" "$HALOGEN_MODELS_DIR/.prompt-cache"
if "$ctl" cache clear --yes > /dev/null 2>&1; then echo "cache clear accepted a link in place of the folder" >&2; exit 1; fi
[ -e "$work/elsewhere/file" ] || { echo "cache clear deleted through a link" >&2; exit 1; }
rm "$HALOGEN_MODELS_DIR/.prompt-cache"; mkdir "$HALOGEN_MODELS_DIR/.prompt-cache"
if FAKE_UID=1000 "$ctl" cache > /dev/null 2>&1; then echo "cache status answered without root (it would always say on)" >&2; exit 1; fi
if FAKE_UID=1000 "$ctl" cache clear --yes > /dev/null 2>&1; then echo "cache clear ran without root" >&2; exit 1; fi
if "$ctl" cache wipe > /dev/null 2>&1; then echo "an unknown cache command was accepted" >&2; exit 1; fi
ok "cache shows its state; off, on and clear ask, act as halogen, and restart or stop Halogen only when it runs"

# The API key switch: on by default; off asks (or needs --yes), writes root's off file and restarts
# a running Halogen; on removes it; the bare command still prints the key, and only root switches.
export HALOS_API_KEY_OFF_FILE="$work/etc-halos/api-key-off"
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *"is-active halogen.service"*) echo "${FAKE_ACTIVE-active}" ;; esac'
"$ctl" api-key status > "$work/out"; grep -q '^API key: on' "$work/out" || { cat "$work/out" >&2; exit 1; }
if "$ctl" api-key off < /dev/null > /dev/null 2>&1; then echo "api-key off ran without --yes or a terminal" >&2; exit 1; fi
[ ! -e "$HALOS_API_KEY_OFF_FILE" ] || { echo "api-key off changed something before asking" >&2; exit 1; }
if FAKE_UID=1000 "$ctl" api-key off --yes > "$work/out" 2>&1 || ! grep -q 'Run it with sudo' "$work/out"; then echo "api-key off ran without root" >&2; exit 1; fi
: > "$work/log"; "$ctl" api-key off --yes > /dev/null
[ -f "$HALOS_API_KEY_OFF_FILE" ] || { echo "api-key off wrote no off file" >&2; exit 1; }
grep -q 'restart halogen.service' "$work/log" || { echo "api-key off didn't restart a running Halogen" >&2; exit 1; }
"$ctl" api-key status > "$work/out"; grep -q '^API key: off' "$work/out" || { cat "$work/out" >&2; exit 1; }
"$ctl" status > "$work/out" 2>&1 || true; grep -q '^API key: off' "$work/out" || { cat "$work/out" >&2; echo "status didn't say the key is off" >&2; exit 1; }
echo secret-key > "$work/configs/api-key"; [ "$("$ctl" api-key)" = secret-key ] || { echo "the bare command no longer prints the key" >&2; exit 1; }
: > "$work/log"; FAKE_ACTIVE=inactive "$ctl" api-key on > /dev/null
[ ! -e "$HALOS_API_KEY_OFF_FILE" ] || { echo "api-key on left the off file" >&2; exit 1; }
if grep -q 'restart halogen.service' "$work/log"; then echo "api-key on started a stopped Halogen" >&2; exit 1; fi
if FAKE_ACTIVE=x "$ctl" api-key off --yes > "$work/out" 2>&1 || [ -e "$HALOS_API_KEY_OFF_FILE" ]; then echo "no answer from the manager was taken for stopped" >&2; exit 1; fi
# A folder at the off file's name: off says it failed (the key stays on), never "off".
mkdir -p "$HALOS_API_KEY_OFF_FILE"
if "$ctl" api-key off --yes > "$work/out" 2>&1 || ! grep -q 'stays on' "$work/out"; then cat "$work/out" >&2; echo "off reported success with a folder at the off file's name" >&2; exit 1; fi
rm -rf "$HALOS_API_KEY_OFF_FILE"
if "$ctl" api-key open > /dev/null 2>&1; then echo "api-key took an unknown word" >&2; exit 1; fi
ok "api-key on/off writes root's off file after asking and restarts a running Halogen; the bare command prints the key"

# Web search (halogenctl web-search): root's drop-in puts Halogen on the search network and wants
# the search unit; root's web-search.env says which search. An external URL is checked (shape, then
# a JSON search from this machine) before anything changes. All ask first.
mkdir -p "$work/etc-halos"
export HALOGEN_SEARCH_DROPIN="$work/dropin.d/30-web-search.conf" HALOS_SEARCH_CONF="$work/etc-halos/web-search.env" \
  HALOS_SEARCH_WAIT=1 HALOS_FETCH_AS_ROOT=1
printf 'HALOGEN_IMAGE=x\nSEARXNG_VERSION=2026.11.23-a7163d091\n' > "$work/release.env"
f systemctl 'echo "systemctl $*" >> "$FAKE/log"; case "$*" in *"is-active halogen.service"*) echo "${FAKE_ACTIVE-active}" ;;
  *"is-active halos-search"*) echo active ;;
  *"cat halogen.service"*) if [ -z "${FAKE_NOJOIN:-}" ] && [ -f "$HALOGEN_SEARCH_DROPIN" ]; then echo "ExecStart=podman run --network halogen-internal --network halos-search:ip=10.89.250.3 x"; fi ;; esac'
f curl 'echo "curl $*" >> "$FAKE/log"; case "$*" in *healthz*) [ -n "${FAKE_SEARCH_DOWN:-}" ] || echo OK ;;
  *format=json*) if [ -n "${FAKE_NOJSON:-}" ]; then echo "<html>"; else echo "{\"results\":[]}"; fi ;; esac'
: > "$work/log"
"$ctl" web-search > "$work/out"; grep -q '^Web search: off' "$work/out" || { cat "$work/out" >&2; exit 1; }
if "$ctl" web-search bundled < /dev/null > /dev/null 2>&1; then echo "web-search bundled ran without --yes or a terminal" >&2; exit 1; fi
if [ -e "$HALOGEN_SEARCH_DROPIN" ] || [ -e "$HALOS_SEARCH_CONF" ]; then echo "web-search bundled changed something before asking" >&2; exit 1; fi
if FAKE_UID=1000 "$ctl" web-search bundled --yes > "$work/out" 2>&1 || ! grep -q 'Run it with sudo' "$work/out"; then echo "web-search ran without root" >&2; exit 1; fi
"$ctl" web-search bundled --yes > "$work/out" || { cat "$work/out" "$work/log" >&2; exit 1; }
want_dropin='[Unit]|Wants=halos-search.service|After=halos-search.service|[Container]|Network=halos-search.network:ip=10.89.250.3|Sysctl=net.ipv6.conf.eth1.disable_ipv6=1|'
[ "$(grep -v '^#' "$HALOGEN_SEARCH_DROPIN" | tr '\n' '|')" = "$want_dropin" ] || { cat "$HALOGEN_SEARCH_DROPIN" >&2; echo "bundled wrote another drop-in" >&2; exit 1; }
# The selftest's config-files line excuses exactly what halogenctl writes.
grep -qF "'$want_dropin'" "$repo/files/usr/libexec/halogen/selftest" || { echo "the selftest doesn't know the bundled drop-in" >&2; exit 1; }
grep -qx 'HALOS_WEB_SEARCH=bundled' "$HALOS_SEARCH_CONF" || { echo "bundled wrote no mode" >&2; exit 1; }
for w in 'systemctl --user daemon-reload' 'systemctl --user stop halos-search-relay.service' 'systemctl --user start halos-search.service' 'restart halogen.service'; do
  grep -qF "$w" "$work/log" || { cat "$work/log" >&2; echo "bundled didn't run: $w" >&2; exit 1; }
done
"$ctl" web-search > "$work/out"; grep -q '^Web search: on, with SearXNG on this machine' "$work/out" || { cat "$work/out" >&2; exit 1; }
# Addresses that can't work, or carry what mustn't reach the relay's settings: refused, nothing changed.
cp "$HALOS_SEARCH_CONF" "$work/conf.before"
for bad in 'ftp://search.example.com' 'search.example.com' 'https://user:pw@search.example.com' 'https://search.local' \
    'http://127.0.0.1:8888' 'http://localhost:8888' 'https://search.example.com/a?b=c' 'https://search.example.com/a#x' \
    'https://search.example.com:99999' 'https://sea$rch.example.com' 'https://search.example.com/a b' 'http://10.89.250.2:8080' \
    'https://-x.example.com' 'https://search.example.com/../x' 'http://[fd00::5]:8888' 'http://0.0.0.0:8888'; do
  if "$ctl" web-search external "$bad" --yes > "$work/out" 2>&1; then echo "external took '$bad'" >&2; exit 1; fi
  cmp -s "$HALOS_SEARCH_CONF" "$work/conf.before" || { echo "'$bad' changed the settings" >&2; exit 1; }
done
if "$ctl" web-search external > /dev/null 2>&1; then echo "external ran without a URL" >&2; exit 1; fi
# A server that doesn't answer JSON (search: formats without json) is refused before anything changes.
if FAKE_NOJSON=1 "$ctl" web-search external https://search.example.com --yes > "$work/out" 2>&1 || ! grep -q 'formats' "$work/out"; then
  cat "$work/out" >&2; echo "a server without JSON was taken" >&2; exit 1
fi
cmp -s "$HALOS_SEARCH_CONF" "$work/conf.before" || { echo "a refused server changed the settings" >&2; exit 1; }
: > "$work/log"
"$ctl" web-search external https://search.example.com:8443/searx/ --yes > "$work/out" || { cat "$work/out" "$work/log" >&2; exit 1; }
if ! { grep -qx 'HALOS_WEB_SEARCH=external' "$HALOS_SEARCH_CONF" && grep -qx 'HALOS_SEARCH_UPSTREAM=https://search.example.com:8443' "$HALOS_SEARCH_CONF" \
  && grep -qx 'HALOS_SEARCH_PATH=/searx' "$HALOS_SEARCH_CONF"; }; then cat "$HALOS_SEARCH_CONF" >&2; echo "external wrote other settings" >&2; exit 1; fi
grep -qx 'Wants=halos-search-relay.service' "$HALOGEN_SEARCH_DROPIN" || { echo "external's drop-in doesn't want the relay" >&2; exit 1; }
grep -qF "'${want_dropin//halos-search.service/halos-search-relay.service}'" "$repo/files/usr/libexec/halogen/selftest" || { echo "the selftest doesn't know the relay's drop-in" >&2; exit 1; }
for w in 'curl -q -fsS -G -m 20 --max-filesize 4194304 --proto =http,https --proto-redir =http,https --data-urlencode q=halOS --data format=json https://search.example.com:8443/searx/search' \
    'systemctl --user stop halos-search.service' 'systemctl --user restart halos-search-relay.service' 'healthz' 'restart halogen.service'; do
  grep -qF -- "$w" "$work/log" || { cat "$work/log" >&2; echo "external didn't run: $w" >&2; exit 1; }
done
grep -qF '127.0.0.1:18730/searx/healthz' "$work/log" || { echo "the relay's health was asked without the path" >&2; exit 1; }
# A reload that leaves Halogen off the search network is reported, not called done.
if FAKE_NOJOIN=1 "$ctl" web-search bundled --yes > "$work/out" 2>&1 || ! grep -q "isn't on the search network" "$work/out"; then cat "$work/out" >&2; echo "a missing network after on wasn't reported" >&2; exit 1; fi
: > "$work/log"; FAKE_ACTIVE=inactive "$ctl" web-search off --yes > "$work/out" || { cat "$work/out" >&2; exit 1; }
if [ -e "$HALOGEN_SEARCH_DROPIN" ] || [ -e "$HALOS_SEARCH_CONF" ]; then echo "off left Halogen's drop-in or the mode" >&2; exit 1; fi
grep -qF 'systemctl --user stop halos-search.service halos-search-relay.service' "$work/log" || { echo "off didn't stop the search" >&2; exit 1; }
if grep -q 'restart halogen.service' "$work/log"; then echo "off started a stopped Halogen" >&2; exit 1; fi
"$ctl" web-search off --yes > "$work/out"; grep -q 'already off' "$work/out" || { cat "$work/out" >&2; exit 1; }
if FAKE_ACTIVE=x "$ctl" web-search bundled --yes > "$work/out" 2>&1; then echo "no answer from the manager was taken for stopped" >&2; exit 1; fi
rm -f "$HALOGEN_SEARCH_DROPIN" "$HALOS_SEARCH_CONF"
if "$ctl" web-search on > /dev/null 2>&1; then echo "web-search took an unknown word" >&2; exit 1; fi
ok "web-search bundled/external/off write Halogen's drop-in and the mode after asking, check your URL first, and restart a running Halogen"
