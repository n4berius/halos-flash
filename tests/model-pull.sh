#!/bin/bash
# halogenctl model pull's helper against fake podman, hf and halogen-npu.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/models"
export FAKE="$work"

cat > "$work/bin/podman" <<'S'
#!/bin/bash
# Runs the requested program on the host, with /models mapped to the test's folder.
echo "podman $*" >> "$FAKE/podman.log"
# Removing the container ends a "container" that ignores SIGTERM (FAKE_HANG below).
if [ "$1" = rm ] && [ -s "$FAKE/hang.pid" ]; then kill -9 "$(cat "$FAKE/hang.pid")" 2> /dev/null; fi
[ "$1" = run ] || exit 0
shift; entry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --entrypoint) entry="$2"; shift 2 ;;
    -v|-e|--tmpfs|--security-opt|--cap-drop|--device|--group-add|--name) shift 2 ;;
    -*) shift ;;
    *) shift; break ;;
  esac
done
args=(); for a in "$@"; do args+=("${a//\/models/$FAKE/models}"); done
# FAKE_HANG=<entrypoint>: that step's "container" ignores SIGTERM until it is removed.
if [ "${FAKE_HANG:-}" = "$entry" ]; then trap '' TERM INT HUP; sleep 30 & echo "$!" > "$FAKE/hang.pid"; wait; exit 1; fi
case "$entry" in
  hf) dir=""; for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" != --local-dir ] || dir="${args[i+1]}"; done
      echo "Hint: update hf"; mkdir -p "$dir"; echo '{}' > "$dir/config.json"; echo w > "$dir/model.safetensors" ;;
  /usr/local/bin/halogen-npu) echo "task=generate base=${FAKE_BASE:-lfm3-1.7b}" ;;
  awk) args[${#args[@]}-1]="$FAKE/models.txt"; awk "${args[@]}" ;;
esac
S
chmod +x "$work/bin/podman"
printf 'model lfm3-1.7b repo=a\nmodel lfm3-1.7b-fast repo=a\nmodel d1-2b repo=b\n' > "$work/models.txt"
printf 'HALOGEN_IMAGE=img@sha256:1\nHALOGEN_VARIANT=npu\n' > "$work/release.env"
mkdir -p "$work/state"
export HALOGEN_STATE_DIR="$work/state" PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_MODELS_DIR="$work/models" \
  HALOGEN_HF_TOKEN_FILE="$work/none" HALOGEN_PROGRESS_S=0
pull="$repo/files/usr/libexec/halogen/model-pull"
ok() { echo "ok: $*"; }

out="$("$pull" LiquidAI/LFM3-1.7B 2>&1)"
[ -f "$work/models/LFM/LFM3-1.7B/model.safetensors" ] && [ ! -e "$work/models/.pull" ]
grep -qx 'path=/models/LFM/LFM3-1.7B' <<< "$out" && grep -qx 'fast=1' <<< "$out"
if grep -q 'Hint:' <<< "$out"; then echo "hf noise reached the user" >&2; exit 1; fi
grep -q -- "--exclude \*.gguf" "$work/podman.log"
grep 'halogen-npu' "$work/podman.log" | grep -q -- '--network=none -e HF_HUB_OFFLINE=1' || { echo "the probe of an untrusted checkpoint had network" >&2; exit 1; }
if grep 'entrypoint hf' "$work/podman.log" | grep -q -- '--network=none'; then echo "the download lost its network" >&2; exit 1; fi
# Every container of the pull has the pull's name (a leftover one is replaced), one left by an
# interrupted pull is removed before anything else, and the last one when the pull ends.
if grep '^podman run' "$work/podman.log" | grep -v -q -- '--name halogen-pull-npu-LFM3-1.7B --replace '; then echo "a pull container wasn't named" >&2; exit 1; fi
head -n 1 "$work/podman.log" | grep -qx 'podman rm -f -i -t 0 halogen-pull-npu-LFM3-1.7B' || { echo "a leftover pull container isn't removed first" >&2; exit 1; }
tail -n 1 "$work/podman.log" | grep -qx 'podman rm -f -i -t 0 halogen-pull-npu-LFM3-1.7B' || { echo "the pull's container isn't removed at the end" >&2; exit 1; }
# Each step sees only the checkpoint's own folder: the download writable, the probe read-only.
if grep -q -- "-v $work/models:/models " "$work/podman.log"; then echo "a step saw all of /srv/models" >&2; exit 1; fi
grep 'entrypoint hf' "$work/podman.log" | grep -q -- "-v $work/models/.pull/LFM3-1.7B:/models/.pull/LFM3-1.7B " \
  || { echo "the download didn't get its own folder" >&2; exit 1; }
grep 'halogen-npu' "$work/podman.log" | grep -q -- ":/models/.pull/LFM3-1.7B:ro " \
  || { echo "the probe's folder wasn't read-only" >&2; exit 1; }
ok "an LFM3 checkpoint lands in LFM, with its path and :fast named, and other formats skipped; only the download has network"
# An option with no value at the end stops with a message (it used to loop forever).
for opt in --revision --as; do
  if timeout 5 "$pull" LiquidAI/LFM3-1.7B "$opt" > "$work/out" 2>&1; then echo "$opt with no value was accepted" >&2; exit 1; fi
  grep -qF -- "$opt needs a value" "$work/out" || { cat "$work/out" >&2; echo "$opt with no value hung or said nothing" >&2; exit 1; }
done
ok "--revision or --as with no value stops with a message"
# The probe's words reach the screen without control codes, and only a plain model name is used.
FAKE_BASE="$(printf 'lfm3\033[2J')" "$pull" LiquidAI/Odd --as odd > "$work/out" 2>&1 || true
if grep -q "$(printf '\033')" "$work/out"; then echo "a control code from the probe reached the screen" >&2; exit 1; fi
ok "the probe's output reaches the screen without control codes"

FAKE_BASE=d1-2b "$pull" LiquidAI/d1-2B --as my-d1 --revision abc > "$work/out" 2>&1
[ -d "$work/models/decider/my-d1" ] && grep -qx 'path=/models/decider/my-d1' "$work/out"
if grep -qx 'fast=1' "$work/out"; then echo "offered :fast where none exists" >&2; exit 1; fi
grep -q -- '--revision abc' "$work/podman.log"
ok "a d1-2B lands in decider under the chosen name and revision"

# Halogen 0.20: OvisOCR3 (document parsing) is an own checkpoint like any other, in custom.
FAKE_BASE=ovisocr3 "$pull" ATH-MaaS/OvisOCR3 > "$work/out" 2>&1
if [ ! -d "$work/models/custom/OvisOCR3" ] || ! grep -qx 'path=/models/custom/OvisOCR3' "$work/out"; then
  cat "$work/out" >&2; echo "OvisOCR3 didn't land in custom under its own name" >&2; exit 1
fi
ok "an OvisOCR3 lands in custom as OvisOCR3"

: > "$work/podman.log"
"$pull" LiquidAI/LFM3-1.7B > /dev/null 2>&1
grep -q -- "--local-dir $work/models/LFM/LFM3-1.7B\|--local-dir /models/LFM/LFM3-1.7B" "$work/podman.log"
ok "pulling a name you have updates it in place"

for bad in "nonsense" "a/b --as ../x" "a/b --as .hidden"; do
  # shellcheck disable=SC2086
  if "$pull" $bad > /dev/null 2>&1; then echo "accepted: $bad" >&2; exit 1; fi
done
sed -i 's/=npu/=no-npu/' "$work/release.env"
if "$pull" LiquidAI/LFM3-1.7B > /dev/null 2>&1; then echo "the no-NPU edition pulled an NPU checkpoint" >&2; exit 1; fi
ok "bad repos and names, and the no-NPU edition, are refused"
if grep -q -- '--device' "$work/podman.log"; then echo "model pull gave a container the NPU device" >&2; exit 1; fi
echo "ok: model pull's containers get no NPU device"

# A link where the checkpoint's folder (or its parent) belongs is never mounted: the download
# would land in whatever it points to.
sed -i "s/=no-npu/=npu/" "$work/release.env"
mkdir -p "$work/secret"; rm -rf "$work/models/LFM/LFM3-1.7B"; ln -s "$work/secret" "$work/models/LFM/LFM3-1.7B"
: > "$work/podman.log"
if "$pull" LiquidAI/LFM3-1.7B > "$work/out" 2>&1; then echo "a pull went through a link at the checkpoint's folder" >&2; exit 1; fi
grep -q "isn't a plain folder" "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q ' run ' "$work/podman.log" || [ -n "$(ls -A "$work/secret")" ]; then echo "a container was started with the link's target" >&2; exit 1; fi
rm "$work/models/LFM/LFM3-1.7B"
# The same for the folder new pulls start in: nothing is made through the link.
rm -rf "$work/models/.pull"; ln -s "$work/secret" "$work/models/.pull"
if "$pull" LiquidAI/LFM3-9B > "$work/out" 2>&1; then echo "a pull went through a link at .pull" >&2; exit 1; fi
if [ -n "$(ls -A "$work/secret")" ]; then echo "a folder was made through the link at .pull" >&2; exit 1; fi
rm "$work/models/.pull"
ok "a link in place of a checkpoint's folder is refused before any container starts"

# One pull of a name at a time: a second one stops before it removes or starts any container.
exec 8>> "$work/state/pull-npu-Busy.lock"; flock -n 8
: > "$work/podman.log"
if "$pull" LiquidAI/Busy > "$work/out" 2>&1; then echo "two pulls of one name ran at once" >&2; exit 1; fi
grep -q "Another pull of Busy is running" "$work/out" || { cat "$work/out" >&2; exit 1; }
if [ -s "$work/podman.log" ]; then echo "the second pull touched a container: $(cat "$work/podman.log")" >&2; exit 1; fi
exec 8>&-
ok "a second pull of the same name stops before it touches the first one's container"

# A stop (TERM to the whole unit, as systemd sends it) removes the container at once, though the
# container ignores the signal: the pull doesn't wait for it. During the download (in a pipeline)
# and during the check for a :fast format (a plain command, where bash would hold its trap until
# the client returned).
for step in hf awk; do
  : > "$work/podman.log"; rm -f "$work/hang.pid"
  FAKE_HANG="$step" setsid "$pull" LiquidAI/Hang > "$work/out" 2>&1 &
  p=$!
  for _ in $(seq 100); do [ -s "$work/hang.pid" ] && break; sleep 0.1; done
  [ -s "$work/hang.pid" ] || { cat "$work/out" >&2; echo "the fake download never started" >&2; exit 1; }
  [ "$(ps -o pgid= -p "$p" | tr -d ' ')" = "$p" ] || { echo "the test needs the pull in a process group of its own" >&2; exit 1; }
  kill -TERM -- "-$p"
  for _ in $(seq 50); do kill -0 "$p" 2> /dev/null || break; sleep 0.1; done
  if kill -0 "$p" 2> /dev/null; then kill -9 -- "-$p"; echo "the pull kept waiting on a container that ignores TERM" >&2; exit 1; fi
  rc=0; wait "$p" || rc=$?
  [ "$rc" = 143 ] || { cat "$work/out" >&2; echo "the stopped pull exited $rc" >&2; exit 1; }
  if kill -0 "$(cat "$work/hang.pid")" 2> /dev/null; then echo "the container outlived the stop" >&2; exit 1; fi
  [ "$(grep -c -x 'podman rm -f -i -t 0 halogen-pull-npu-Hang' "$work/podman.log")" -ge 2 ] || { cat "$work/podman.log" >&2; exit 1; }
  rm -f "$work/hang.pid"; rm -rf "$work/models/.pull" "$work/models/LFM/Hang"
done
ok "a stop during a pull removes its container at once"


