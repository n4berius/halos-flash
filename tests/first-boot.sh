#!/bin/bash
# Runs the first-boot fetch against fake podman and hf commands.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/models" "$work/opt"
export FAKE="$work" HELPER_SRC="$repo/files/usr/libexec/halogen/fetch-in-container"

h="$(printf hello | sha256sum | cut -d' ' -f1)"
cat > "$work/opt/models.txt" <<S
model embed repo=org/embed revision=abc
model rerank repo=org/rerank revision=def devices=embed
model lfm3 repo=org/lfm3 revision=x
model lfm3-fast repo=org/lfm3-fast revision=y
file embed devices/d.hnpm 5 $h
file embed embed.hnpw 5 $h
file lfm3-fast devices/f.hnpm 5 $h
file rerank rerank.hnpw 5 $h
file lfm3 devices/p.hnpm 5 $h
file lfm3 lfm3.hnpw 5 $h
model lfm3-vl repo=org/lfm3-vl revision=z devices=lfm3
file lfm3-vl vis/v.hnpm 5 $h
file lfm3-vl lfm3-vl.hnpw 5 $h
model lfm3-omni repo= revision= devices=lfm3 vis=lfm3-vl
S

cat > "$work/bin/hf" <<'S'
#!/bin/bash
echo "hf $*" >> "$FAKE/hf.log"
echo "Hint: A new version of huggingface_hub (9.9) is available!" >&2
echo "Warning: You are sending unauthenticated requests to the HF Hub." >&2
[ ! -e "$FAKE/fail-hf" ] || { rm "$FAKE/fail-hf"; exit 1; }
shift; repo="$1"; shift; dest=""; files=()
while [ $# -gt 0 ]; do case "$1" in
  --local-dir) dest="$2"; shift 2 ;; --revision|--include) [ "$1" != --include ] || files+=("tokenizer/tokenizer.json"); shift 2 ;;
  *) files+=("$1"); shift ;; esac; done
for f in "${files[@]}"; do mkdir -p "$(dirname "$dest/$f")"; printf hello > "$dest/$f"; done
S
cat > "$work/bin/podman" <<'S'
#!/bin/bash
echo "podman $*" >> "$FAKE/podman.log"
case "$1" in
  image) [ -e "$FAKE/image-present" ] ;;
  pull) [ ! -e "$FAKE/fail-pull" ] || { rm "$FAKE/fail-pull"; exit 1; }; touch "$FAKE/image-present" ;;
  run)
    case " $* " in
      *" verify "*) [ ! -e "$FAKE/fail-verify" ] ;;
      *) echo "$*" > "$FAKE/last-run"
         npu=""; mode=""; bases=""
         for a in "$@"; do case "$a" in NPU_MODELS=*) npu="${a#NPU_MODELS=}" ;; FETCH_MODE=*) mode="${a#FETCH_MODE=}" ;; OWN_BASES=*) bases="${a#OWN_BASES=}" ;; esac; done
         # The probe runs offline: only that run may call Halogen's probe.
         [ "$mode" = probe ] || export NO_PROBE=1
         HALOGEN_PINS="$FAKE/opt/models.txt" HALOGEN_MODELS_ROOT="$FAKE/mount" WEIGHTS_REPO=r WEIGHTS_REVISION=main \
         HALOGEN_NPU_BIN="$FAKE/bin/halogen-npu" FETCH_MODE="$mode" OWN_BASES="$bases" \
         NPU_MODELS="$npu" VISION="" bash "$HELPER_SRC" ;;
    esac ;;
esac
S
cat > "$work/bin/halogen-npu" <<'S'
#!/bin/bash
# Halogen's probe names the model a checkpoint was tuned from.
[ -z "${NO_PROBE:-}" ] || { echo "probe ran in the download container" >> "$FAKE/probe-leak"; exit 1; }
[ "$1" = probe ] && [ -f "$2/config.json" ] && echo "task=generate base=$(cat "$2/base" 2>/dev/null || echo lfm3)"
S
chmod +x "$work/bin/"*
ln -s "$work/models" "$work/mount"
export PATH="$work/bin:$PATH"
cat > "$work/release.env" <<'S'
HALOGEN_IMAGE=ghcr.io/x@sha256:1
HALOGEN_VERSION=9.9.9
HALOGEN_WEIGHTS_REPO=r
HALOGEN_WEIGHTS_REVISION=main
S
echo 'HALOGEN_NPU_MODELS=embed,rerank' > "$work/config.env"
echo HALOGEN_NPU_MODELS > "$work/allowed"
export XDG_RUNTIME_DIR="$work/run" HALOGEN_ALLOWED_FILE="$work/allowed" HALOGEN_RENDER="$repo/files/usr/libexec/halogen/render-config"
export HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_CONFIG_FILE="$work/config.env" HALOGEN_MODELS_DIR="$work/models" \
  HALOGEN_FETCH_HELPER="$HELPER_SRC" HALOGEN_MODELS_NEEDED_GIB=0 HALOGEN_RETRY_MAX_S=0 HALOGEN_PROGRESS_S=0 HALOGEN_HF_TOKEN_FILE="$work/hf-token"
# shellcheck disable=SC2317,SC2329 # called by the fetch script, through export -f
sleep() { :; }; export -f sleep
fetch="$repo/files/usr/libexec/halogen/fetch-models"
sed 's/^wait_s=15$/wait_s=0/' "$fetch" > "$work/fetch"; chmod +x "$work/fetch"
ok() { echo "ok: $*"; }

touch "$work/fail-pull" "$work/fail-hf"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ -f "$work/models/qwen38-flash-next-v2.hgn" ] && [ -f "$work/models/tokenizer/tokenizer.json" ]
[ -f "$work/models/.fetch-stamp" ]
ok "first boot retries, then fetches everything and writes the stamp"
if grep -q 'Hint: \|unauthenticated requests' "$work/out"; then echo "hf noise reached the log" >&2; exit 1; fi
grep -q 'no Hugging Face token' "$work/out"
ok "hf's upgrade hints are filtered, and a missing token is explained once"
[ -f "$work/models/embed/devices/d.hnpm" ] || [ -f "$work/models/npu/embed/devices/d.hnpm" ]
ok "shared device files of a dependent NPU model are fetched"

: > "$work/podman.log"; "$work/fetch" >/dev/null
if grep -q ' run ' "$work/podman.log"; then echo "second boot ran a container" >&2; exit 1; fi
ok "second boot starts nothing and downloads nothing"

echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"
"$work/fetch" >/dev/null
grep -q ' run ' "$work/podman.log"
# Halogen's verify reads local files only: no network, no capabilities. The download keeps its network.
grep ' verify ' "$work/podman.log" | grep -q -- '--network=none --cap-drop=all --security-opt no-new-privileges' \
  || { echo "verify ran with network or capabilities" >&2; exit 1; }
if grep '/fetch.sh' "$work/podman.log" | grep -q -- '--network=none'; then echo "the download lost its network" >&2; exit 1; fi
ok "changing the model list triggers a fetch, and verify runs offline with no capabilities"

echo 'hf_secret123' > "$work/hf-token"; rm "$work/models/.fetch-stamp"; : > "$work/podman.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -q "$work/hf-token:/run/secrets/hf-token:ro" "$work/podman.log" && grep -q 'HF_TOKEN_PATH=/run/secrets/hf-token' "$work/podman.log"
if grep -q hf_secret123 "$work/podman.log" "$work/out"; then echo "the token leaked into a command line or log" >&2; exit 1; fi
rm "$work/hf-token"
ok "a Hugging Face token is passed as a read-only file, never as a value"

rm "$work/models/.fetch-stamp"; touch "$work/fail-verify"
if "$work/fetch" >/dev/null 2>&1; then echo "verify failure was ignored" >&2; exit 1; fi
[ ! -f "$work/models/.fetch-stamp" ]
ok "a failed checkpoint check keeps the server from starting"
rm "$work/fail-verify"

echo 'HALOGEN_NPU_MODELS=nonsense,embed,Rerank' > "$work/config.env"
if "$work/fetch" > "$work/out" 2>&1; then echo "unknown model was accepted" >&2; exit 1; fi
grep -q 'no record of NPU model nonsense' "$work/out" && grep -q 'no record of NPU model Rerank' "$work/out"
grep -q '^fetch:   rerank$' "$work/out"
ok "unknown models are all named, with the valid names, and do not retry forever"

echo 'HALOGEN_NPU_MODELS=' > "$work/config.env"
if HALOGEN_MODELS_NEEDED_GIB=999999999 "$work/fetch" >/dev/null 2>&1; then echo "low disk was accepted" >&2; exit 1; fi
ok "too little disk stops before downloading"

echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"; echo HALOGEN_AGENT_GUARD >> "$work/allowed"
echo 'HALOGEN_AGENT_GUARD=Hold' >> "$work/config.env"
"$work/fetch" > "$work/out" 2>&1 || true
grep -q 'NPU_MODELS=embed,halogen-spotter-0.6b,decider-4b' "$work/podman.log" \
  || { echo "the agent guard's models were not fetched" >&2; exit 1; }
ok "the agent guard's models are fetched when it is turned on"

echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"
rm -rf "$work/models/npu" "$work/models/.fetch-stamp"
mkdir -p "$work/models/npu/9.9.9/embed/devices" "$work/models/npu/9.9.8/embed/devices" "$work/models/npu/9.9.8/old"
printf hello > "$work/models/npu/9.9.9/embed/devices/d.hnpm"; printf hello > "$work/models/npu/9.9.9/embed/embed.hnpw"; printf stale > "$work/models/npu/9.9.8/embed/devices/d.hnpm"
: > "$work/hf.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ "$(cat "$work/models/npu/embed/devices/d.hnpm")" = hello ] || { echo "the current version's copy did not win" >&2; exit 1; }
[ -d "$work/models/npu/old" ] || { echo "a model only in an old version folder was lost" >&2; exit 1; }
if [ -e "$work/models/npu/9.9.9" ] || [ -e "$work/models/npu/9.9.8" ]; then echo "version folders were left behind" >&2; exit 1; fi
if grep -q org/embed "$work/hf.log"; then echo "a moved model was downloaded again" >&2; exit 1; fi
ok "versioned NPU folders move into one folder, the current version's copy wins, and nothing is fetched again"

mkdir -p "$work/models/LFM/mine"; echo '{}' > "$work/models/LFM/mine/config.json"
echo 'HALOGEN_NPU_MODELS=embed,/models/LFM/mine:fast,/models/LFM/mine' > "$work/config.env"
: > "$work/hf.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ -f "$work/models/npu/lfm3/devices/p.hnpm" ] || { echo "the checkpoint's NPU programs were not fetched" >&2; exit 1; }
[ -f "$work/models/npu/lfm3-fast/devices/f.hnpm" ] || { echo "the :fast format's NPU programs were not fetched" >&2; exit 1; }
if [ -e "$work/models/npu/lfm3/lfm3.hnpw" ]; then echo "weights were fetched for your own checkpoint" >&2; exit 1; fi
grep -q 'mine is a lfm3' "$work/out" || { echo "the fetch did not say what the checkpoint is" >&2; exit 1; }
grep -qx '/models/LFM/mine=lfm3' "$work/models/.own-bases" || { cat "$work/models/.own-bases" >&2; echo "the fetch didn't note which NPU model the checkpoint runs on" >&2; exit 1; }
# The checkpoint is probed offline, with the models read-only and no token; the download never probes.
grep 'FETCH_MODE=probe' "$work/podman.log" > "$work/probe-run" || { echo "the checkpoint was not probed first" >&2; exit 1; }
if ! grep -q -- '--network=none' "$work/probe-run" || ! grep -q -- "-v $work/models:/models:ro" "$work/probe-run"; then
  cat "$work/probe-run" >&2; echo "the probe ran with network or writable models" >&2; exit 1
fi
if grep -q 'hf-token' "$work/probe-run"; then echo "the probe got the HF token" >&2; exit 1; fi
[ ! -e "$work/probe-leak" ] || { echo "the download container probed a checkpoint" >&2; exit 1; }
# A space after the comma still gets the probe (the download splits on spaces too).
echo 'HALOGEN_NPU_MODELS=embed, /models/LFM/mine' > "$work/config.env"
rm -f "$work/models/.fetch-stamp"; : > "$work/podman.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "a space after the comma broke the fetch" >&2; exit 1; }
grep -q 'FETCH_MODE=probe' "$work/podman.log" || { echo "a space after the comma skipped the probe" >&2; exit 1; }
# The probe's answers are checked outside it: anything but path=model stops the fetch.
cp "$work/bin/podman" "$work/podman.real"
printf '#!/bin/bash\ncase " $* " in *FETCH_MODE=probe*) echo "/models/LFM/mine=lfm3"; echo "evil"; exit 0 ;; esac\nexec "%s" "$@"\n' "$work/podman.real" > "$work/bin/podman"
rm -f "$work/models/.fetch-stamp"
if "$work/fetch" > "$work/out" 2>&1; then echo "a bad probe answer was passed on" >&2; exit 1; fi
grep -q "gave an answer halOS doesn't accept" "$work/out" || { cat "$work/out" >&2; exit 1; }
cp "$work/podman.real" "$work/bin/podman"
echo 'HALOGEN_NPU_MODELS=embed,/models/LFM/mine:fast,/models/LFM/mine' > "$work/config.env"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
ok "your own checkpoint gets its NPU programs fetched, and no weights; it is probed offline, and only its plain answers are passed on"

: > "$work/podman.log"; "$work/fetch" >/dev/null 2>&1
if grep -q ' run ' "$work/podman.log"; then echo "an unchanged checkpoint ran the fetch again" >&2; exit 1; fi
echo '{"changed": 1}' > "$work/models/LFM/mine/config.json"
"$work/fetch" >/dev/null 2>&1
grep -q ' run ' "$work/podman.log" || { echo "a changed checkpoint was not checked again" >&2; exit 1; }
ok "a changed checkpoint is checked again"

echo 'HALOGEN_NPU_MODELS=/models/LFM/missing' > "$work/config.env"
if "$work/fetch" > "$work/out" 2>&1; then echo "a missing checkpoint folder was accepted" >&2; exit 1; fi
grep -q 'not a checkpoint folder' "$work/out" || { echo "a missing checkpoint folder was not explained" >&2; exit 1; }
grep -q 'fix /srv/configs/halogen.env' "$work/out" || { echo "the fetch did not say what to fix" >&2; exit 1; }
ok "a missing checkpoint folder is explained and not retried forever"

echo 'HALOGEN_NPU_MODELS=rerank' > "$work/config.env"
rm -rf "$work/models/npu" "$work/models/.fetch-stamp"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ -f "$work/models/npu/rerank/rerank.hnpw" ] || { echo "rerank was not fetched" >&2; exit 1; }
[ -f "$work/models/npu/embed/devices/d.hnpm" ] || { echo "the programs rerank runs on were not fetched" >&2; exit 1; }
if [ -e "$work/models/npu/embed/embed.hnpw" ]; then echo "the other model's weights were fetched too" >&2; exit 1; fi
ok "a model that runs on another's NPU programs fetches only those programs"

# Some of Halogen's models have no download of their own and reuse others' programs, as
# LFM3-Omni-2B does in 0.19.0. Your own checkpoint of one gets those programs.
mkdir -p "$work/models/LFM/omni"; echo '{}' > "$work/models/LFM/omni/config.json"; echo lfm3-omni > "$work/models/LFM/omni/base"
echo 'HALOGEN_NPU_MODELS=/models/LFM/omni' > "$work/config.env"
rm -rf "$work/models/npu" "$work/models/.fetch-stamp"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ -f "$work/models/npu/lfm3/devices/p.hnpm" ] || { echo "the programs it runs on were not fetched" >&2; exit 1; }
[ -f "$work/models/npu/lfm3-vl/vis/v.hnpm" ] || { echo "its picture programs were not fetched" >&2; exit 1; }
if [ -e "$work/models/npu/lfm3-vl/lfm3-vl.hnpw" ]; then echo "another model's weights were fetched" >&2; exit 1; fi
ok "a checkpoint whose model has no download of its own gets the programs it reuses"

# The fetch container gets no NPU device: Halogen's probe reads only the checkpoint's config
# and tokenizer. XRT comes with Halogen's image, so none is mounted either.
touch "$work/accel0"
for variant in npu no-npu; do
  sed -i '/^HALOGEN_VARIANT=/d' "$work/release.env"; echo "HALOGEN_VARIANT=$variant" >> "$work/release.env"
  rm -f "$work/models/.fetch-stamp" "$work/last-run"
  HALOGEN_NPU_DEVICE="$work/accel0" "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
  [ -s "$work/last-run" ] || { echo "no fetch container ran" >&2; exit 1; }
  if grep -qi -- '--device\|xilinx\|libxrt' "$work/last-run"; then cat "$work/last-run" >&2; echo "$variant: a device or XRT reached the fetch" >&2; exit 1; fi
done
ok "the fetch container gets no NPU device and no XRT"

# Your own Flash checkpoint is checked again after a Halogen update, before it is served.
# shellcheck disable=SC2016 # expanded when the fake runs
printf '#!/bin/bash\necho "flash-tool $*" >> "$FAKE/flash.log"\n' > "$work/flash-tool"; chmod +x "$work/flash-tool"
mkdir -p "$work/models/flash/mine"; echo mine > "$work/flash-choice"
export HALOGEN_FLASH_TOOL="$work/flash-tool" HALOGEN_FLASH_FILE="$work/flash-choice"
printf 'repo=a/b\nverified=pass\nverified_with=9.9.9\n' > "$work/models/flash/mine/halos.info"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ ! -e "$work/flash.log" ] || { echo "re-checked with the same Halogen" >&2; exit 1; }
printf 'repo=a/b\nverified=pass\nverified_with=0.0.1\n' > "$work/models/flash/mine/halos.info"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -qx 'flash-tool verify mine' "$work/flash.log" || { echo "not re-checked after a Halogen update" >&2; exit 1; }
ok "your own Flash checkpoint is checked again after a Halogen update"

# What is fetched doesn't depend on the chosen checkpoint: the official vision tower stays.
echo HALOGEN_VISION_TOWER >> "$work/allowed"; echo 'HALOGEN_VISION_TOWER=1' >> "$work/config.env"
printf 'repo=a/b\ncheckpoint=model.hgn\nverified=pass\nverified_with=9.9.9\n' > "$work/models/flash/mine/halos.info"
touch "$work/models/flash/mine/model.hgn"; rm -f "$work/models/.fetch-stamp" "$work/last-run"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -q -- '-e VISION=1 ' "$work/last-run" || { cat "$work/last-run" >&2; echo "choosing a checkpoint without a tower stopped the official one being fetched" >&2; exit 1; }
ok "the official vision tower is fetched whichever checkpoint is chosen"

# A new install's first download waits for setup, until it is done or the time limit passes.
mkdir -p "$work/state"; touch "$work/state/setup-pending"; rm -f "$work/models/.fetch-stamp"
HALOGEN_STATE_DIR="$work/state" HALOGEN_SETUP_WAIT_S=0 "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if ! grep -q 'waiting for first-boot setup' "$work/out" || ! grep -q 'no setup after 0 minutes; starting with the defaults' "$work/out"; then
  cat "$work/out" >&2; echo "the time limit didn't release the download" >&2; exit 1
fi
[ ! -e "$work/state/setup-pending" ] || { echo "the marker stayed" >&2; exit 1; }
# Setup finishing while it waits (the fake sleep removes the marker, as halosctl setup would).
touch "$work/state/setup-pending"; rm -f "$work/models/.fetch-stamp"
# shellcheck disable=SC2317,SC2329 # called by the fetch script, through export -f
sleep() { rm -f "$FAKE/state/setup-pending"; }; export -f sleep
HALOGEN_STATE_DIR="$work/state" HALOGEN_SETUP_WAIT_S=3600 "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if grep -q 'no setup after' "$work/out"; then echo "it waited for the time limit though setup was done" >&2; exit 1; fi
grep -q 'models ready' "$work/out" || { cat "$work/out" >&2; exit 1; }
# shellcheck disable=SC2317,SC2329 # called by the fetch script, through export -f
sleep() { :; }; export -f sleep
ok "the first download waits for setup, and starts when it is done or after the time limit"
