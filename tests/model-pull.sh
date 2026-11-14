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
[ "$1" = run ] || exit 0
shift; entry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --entrypoint) entry="$2"; shift 2 ;;
    -v|-e|--tmpfs|--security-opt|--cap-drop|--device|--group-add) shift 2 ;;
    -*) shift ;;
    *) shift; break ;;
  esac
done
args=(); for a in "$@"; do args+=("${a//\/models/$FAKE/models}"); done
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
export PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_MODELS_DIR="$work/models" \
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
ok "a link in place of a checkpoint's folder is refused before any container starts"


