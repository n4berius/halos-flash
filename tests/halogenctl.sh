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
f systemctl 'echo "systemctl $*" >> "$FAKE/log"'
# model-pull and render-config, run through systemd-run as halogen.
f systemd-run 'case "$*" in
  *model-pull*) echo "path=/models/LFM/LFM3-1.7B"; echo "fast=1" ;;
  *render-config*) grep "^HALOGEN_NPU_MODELS=" "$FAKE/configs/halogen.env" || true ;;
esac'
export PATH="$work/bin:$PATH" HALOGEN_CONFIGS_DIR="$work/configs"
export HALOGEN_ALLOWED_FILE="$repo/variants/npu/usr/share/halogen/options.allowed"
export HALOGEN_LOCKED_FILE="$repo/files/usr/share/halogen/locked.env"
ctl="$repo/files/usr/bin/halogenctl"
ok() { echo "ok: $*"; }

echo secret-key > "$work/configs/api-key"
if ! { [ "$("$ctl" api-key)" = secret-key ] && grep -q "runuser -u halogen -- cat $work/configs/api-key" "$work/log"; }; then
  echo "api-key was not read as halogen" >&2; exit 1
fi
printf 'hf_abc123\n' | "$ctl" hf-token > /dev/null
if ! { [ "$(cat "$work/configs/hf-token")" = hf_abc123 ] && grep -q 'runuser -u halogen -- sh -c' "$work/log"; }; then
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
grep -q 'runuser -u halogen -- sh -c' "$work/log" || { echo "halogen.env was not edited as halogen" >&2; exit 1; }
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

# model remove deletes as halogen, so a folder link planted by a container can't steer root's rm.
mkdir -p "$work/models/LFM/old-model"; echo w > "$work/models/LFM/old-model/x"
: > "$work/log"
{ sleep 2; echo y; } | HALOGEN_MODELS_DIR="$work/models" script -qec "$ctl model remove old-model" /dev/null > "$work/out" 2>&1 || true
[ ! -e "$work/models/LFM/old-model" ] || { echo "model remove didn't delete:" >&2; cat "$work/out" >&2; exit 1; }
grep -q "runuser -u halogen -- rm -rf -- $work/models/LFM/old-model" "$work/log" || { echo "model remove deleted as root" >&2; exit 1; }
ok "model remove deletes as halogen"

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
grep -q "runuser -u halogen -- grep -oE" "$work/log" || { echo "the duplicate check read halogen.env as root" >&2; exit 1; }
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
  *render-config*) c="$(cat "$FAKE/configs/flash-checkpoint" 2>/dev/null)"
    if [ -n "${FAKE_FALLBACK:-}" ] || [ -z "$c" ] || [ "$c" = official ]; then
      [ -z "${FAKE_FALLBACK:-}" ] || echo "halogen-config: $c has not passed Halogens verify; using the official one" >&2
      echo HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn
    else echo "HALOGEN_CHECKPOINT=/models/flash/$c/model.hgn"; fi ;;
  *flash-checkpoint*pull*) echo "Downloading..."; echo "name=mine" ;;
  *flash-checkpoint*verify*) echo "verify $*" >> "$FAKE/log" ;;
  *flash-checkpoint*check*) echo "check $*" >> "$FAKE/log"; [ -z "${FAKE_CHECK_FAILS:-}" ] || exit 1 ;;
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
if [ "$(cat "$work/configs/flash-checkpoint")" != mine ] || ! grep -q 'runuser -u halogen -- sh -c' "$work/log" ||
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
if [ -e "$fm/flash/broken" ] || ! grep -q "runuser -u halogen -- rm -rf -- $fm/flash/broken" "$work/log"; then
  echo "remove didn't delete as halogen" >&2; exit 1
fi
"$ctl" flash use official --yes > /dev/null
[ "$(cat "$work/configs/flash-checkpoint")" = official ] || exit 1
"$ctl" flash pull someone/Mine-HGN --as mine > "$work/out" 2>/dev/null; grep -q 'sudo halogenctl flash use mine' "$work/out" || { echo "pull doesn't say how to use it" >&2; exit 1; }
"$ctl" flash verify mine > /dev/null; grep -q 'verify mine' "$work/log" || exit 1
ok "flash lists, switches only to verified checkpoints after asking, never removes the active or official one, all as halogen"

# flash check stops Halogen for the GPU, and starts it again whatever happens.
: > "$work/log"
if "$ctl" flash check mine < /dev/null > "$work/out" 2>&1; then echo "check stopped Halogen without asking" >&2; exit 1; fi
if grep -q 'stop halogen.service' "$work/log"; then echo "a declined check stopped Halogen" >&2; exit 1; fi
"$ctl" flash check mine --yes > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -n -e 'stop halogen.service' -e 'check ' -e 'start halogen.service' "$work/log" | cut -d: -f2- | sed 's/ .*\(stop\|start\) halogen.service/ \1/; s/^check .*/check/' > "$work/order"
[ "$(tr '\n' ' ' < "$work/order")" = "systemctl stop check systemctl start " ] || { cat "$work/log" >&2; echo "check didn't stop, measure, then start Halogen" >&2; exit 1; }
: > "$work/log"
if FAKE_CHECK_FAILS=1 "$ctl" flash check mine --yes > "$work/out" 2>&1; then echo "a failed check passed" >&2; exit 1; fi
grep -q 'start halogen.service' "$work/log" || { echo "Halogen stayed stopped after a failed check" >&2; exit 1; }
for bad in official ../mine nothing; do
  if "$ctl" flash check "$bad" --yes > "$work/out" 2>&1; then echo "check took $bad" >&2; exit 1; fi
done
printf 'checked_ppl=3.8109\nchecked_official_ppl=3.8522\nchecked_top1=0.86463\nchecked_kl_median=0.045499\nchecked_with=0.19.1\n' >> "$fm/flash/mine/halos.info"
"$ctl" flash list > "$work/out"
grep -qE '^  mine +perplexity 3\.8109 \(official 3\.8522\), same next token 86\.5%, KL median 0\.045499, with Halogen 0\.19\.1$' "$work/out" \
  || { cat "$work/out" >&2; echo "flash list doesn't show the check" >&2; exit 1; }
ok "flash check asks, stops Halogen, measures as halogen, starts it again even after a failure, and list shows the result"
