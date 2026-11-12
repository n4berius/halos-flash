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
  *model-pull*) echo "path=/models/LFM/LFM3-1.7B"; echo "fast=1" ;;
  *render-config*) grep -E "^HALOGEN_(NPU_MODELS|AGENT_GUARD)=" "$FAKE/configs/halogen.env" || true ;;
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
# An NPU model your checkpoint runs on, or one the agent guard adds, is in use too; only the fetch's
# plain "path=model" lines count, and only for checkpoints that are served.
mkdir -p "$work/models/custom/OvisOCR3" "$work/models/npu/ovisocr3" "$work/models/npu/lfm3-1.7b" "$work/models/npu/lfm3-1.7b-fast" "$work/models/npu/decider-4b"
printf '/models/custom/OvisOCR3=ovisocr3\n/models/LFM/my-lfm=lfm3-1.7b\n/models/LFM/my-lfm:fast=lfm3-1.7b\n/models/LFM/my-lfm=lfm3-1.7b\n/models/LFM/gone=d3-lite\n/models/LFM/x=bad\033name\n' > "$work/models/.own-bases"
printf 'HALOGEN_NPU_MODELS=/models/custom/OvisOCR3,/models/LFM/my-lfm:fast,/models/LFM/my-lfm\nHALOGEN_AGENT_GUARD=hold\n' > "$work/configs/halogen.env"
HALOGEN_MODELS_DIR="$work/models" "$ctl" model list > "$work/out"
for want in '^  ovisocr3 +yes, for OvisOCR3$' '^  lfm3-1\.7b +yes, for my-lfm$' '^  lfm3-1\.7b-fast +yes, for my-lfm$' '^  decider-4b +yes, agent guard$' '^  d3-lite +no$' '^  OvisOCR3 +custom +.* yes$'; do
  grep -qE "$want" "$work/out" || { cat "$work/out" >&2; echo "expected '$want'" >&2; exit 1; }
done
if grep -q "$(printf '\033')" "$work/out"; then echo "a control code from .own-bases reached the screen" >&2; exit 1; fi
grep -q 'runuser -u halogen -- cat .*\.own-bases' "$work/log" || { echo "read .own-bases as root" >&2; exit 1; }
rm -rf "$work/models/custom/OvisOCR3" "$work/models/npu/ovisocr3" "$work/models/npu/lfm3-1.7b" "$work/models/npu/lfm3-1.7b-fast" "$work/models/npu/decider-4b" "$work/models/.own-bases"
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
  *"cat halogen.service"*) if [ -z "${FAKE_NOMOUNT:-}" ] && [ -f "$HALOGEN_RECORDS_DROPIN" ]; then echo "ExecStart=podman run -v /srv/logs/halogen:/records x"; fi ;; esac'
f systemd-run 'echo "systemd-run $*" >> "$FAKE/log"; case "$*" in *render-config*) echo HALOGEN_RECORD_TEXT=none ;; *request_records*) echo "turns 3" ;; esac'
: > "$work/log"
"$ctl" records > "$work/out"; grep -q '^Request records: off' "$work/out" || { cat "$work/out" >&2; exit 1; }
if "$ctl" records on < /dev/null > /dev/null 2>&1; then echo "records on ran without --yes or a terminal" >&2; exit 1; fi
[ ! -e "$work/dropin.d/20-records.conf" ] || { echo "records on changed something before asking" >&2; exit 1; }
"$ctl" records on --yes > /dev/null
grep -qx 'Volume=/srv/logs/halogen:/records:noexec,nosuid,nodev' "$work/dropin.d/20-records.conf" || { echo "no records mount" >&2; exit 1; }
if ! { grep -q 'setpriv --reuid=.* env XDG_RUNTIME_DIR=/run/user/.* systemctl --user daemon-reload' "$work/log" && grep -q 'restart halogen.service' "$work/log"; }; then
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
# A reload that doesn't bring the mount is reported, not called done.
if FAKE_NOMOUNT=1 "$ctl" records on --yes > "$work/out" 2>&1 || ! grep -q "isn't in Halogen's service" "$work/out"; then cat "$work/out" >&2; echo "a missing mount after on wasn't reported" >&2; exit 1; fi
rm -f "$work/dropin.d/20-records.conf"
ok "records on/off mounts the folder (after asking) and restarts; stats and prune run Halogen's tool with checked options, also after off"
