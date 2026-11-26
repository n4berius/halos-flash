#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/dev/accel"; touch "$work/dev/kfd" "$work/dev/accel/accel0"
printf '#!/bin/sh\nexit %s\n' 0 > "$work/clock"; chmod +x "$work/clock"
echo 'HALOGEN_NPU_MODELS=embed' > "$work/effective"
echo 'MemTotal: 130000000 kB' > "$work/mem"
echo 'amdgpu.gttsize=1 ttm.pages_limit=1 iommu=pt' > "$work/cmd"
export HALOGEN_MEMLOCK=unlimited HALOGEN_MODELS_DIR="$work/models"
mkdir -p "$work/models/.prompt-cache" "$work/elsewhere"; chmod 700 "$work/models/.prompt-cache"
run() { HALOGEN_DEV="$work/dev" HALOGEN_EFFECTIVE_FILE="$work/effective" HALOGEN_MEMINFO="$work/mem" HALOGEN_CMDLINE="$work/cmd" \
  HALOGEN_CLOCK="$work/clock" HALOGEN_SYSFS="$work/sys" "$repo/files/usr/libexec/halogen/preflight"; }
expect_fail() { if run >/dev/null 2>&1; then echo "not caught: $1" >&2; exit 1; fi; echo "ok: catches $1"; }
run >/dev/null; echo "ok: healthy host passes"
echo 'MemTotal: 62000000 kB' > "$work/mem"; expect_fail "a large BIOS carve-out"
# Under 100 GiB, Qwen3.8-27B (by its header) may run; a Flash-Next checkpoint of its own may not.
cp "$work/effective" "$work/effective.bak"; mkdir -p "$work/models/flash/q27"
{ printf 'HGN1'; head -c 36 /dev/zero; printf 'qwen3.8-27b-ht4'; head -c 49 /dev/zero; } > "$work/models/flash/q27/model.hgn"
echo 'HALOGEN_CHECKPOINT=/models/flash/q27/model.hgn' >> "$work/effective"
run > /dev/null || { echo "Qwen3.8-27B was refused at 62 GiB" >&2; exit 1; }; echo "ok: Qwen3.8-27B runs under 100 GiB"
{ printf 'HGN1'; head -c 36 /dev/zero; printf 'qwen3.8-flash-next-v2'; head -c 43 /dev/zero; } > "$work/models/flash/q27/model.hgn"
expect_fail "a Flash-Next checkpoint of its own under 100 GiB"
cp "$work/effective.bak" "$work/effective"; rm -rf "$work/models/flash/q27"
echo 'MemTotal: 130000000 kB' > "$work/mem"
echo 'iommu=pt amd_iommu=off' > "$work/cmd"; expect_fail "amd_iommu=off"
echo 'iommu=pt' > "$work/cmd"
# The prompt cache folder: a link in its place (it would be mounted writable into Halogen's
# container), or no folder at all, stops the start.
rmdir "$work/models/.prompt-cache"; expect_fail "a missing prompt cache folder"
ln -s "$work/elsewhere" "$work/models/.prompt-cache"; expect_fail "a link in place of the prompt cache folder"
rm "$work/models/.prompt-cache"; mkdir "$work/models/.prompt-cache"; chmod 755 "$work/models/.prompt-cache"
run > /dev/null 2> "$work/err"; grep -q 'warning: .*mode 755' "$work/err" || { echo "no warning for a readable prompt cache folder" >&2; exit 1; }
chmod 700 "$work/models/.prompt-cache"
# The folders mounted one by one into Halogen's container: a link in one's place stops the start.
mkdir -p "$work/models/npu" "$work/models/decider"; run > /dev/null
rmdir "$work/models/decider"; ln -s "$work/elsewhere" "$work/models/decider"; expect_fail "a link in place of an own-checkpoint folder"
rm "$work/models/decider"; rmdir "$work/models/npu"; ln -s "$work/elsewhere" "$work/models/npu"; expect_fail "a link in place of the NPU models folder"
rm "$work/models/npu"
# Links where Halogen loads files from (the official names, the tokenizer, anything under npu),
# or anything but files and folders there, stop the start.
mkdir -p "$work/models/npu/embed" "$work/models/tokenizer"; : > "$work/models/npu/embed/a.hnpw"; : > "$work/models/tokenizer/tokenizer.json"; run > /dev/null
ln -s "$work/elsewhere" "$work/models/qwen38-flash-next-ngram.hgn"; expect_fail "a link at an official file"; rm "$work/models/qwen38-flash-next-ngram.hgn"
ln -s "$work/elsewhere" "$work/models/qwen38-flash-next-drafter-r2.hgn"; expect_fail "a link at the draft head"; rm "$work/models/qwen38-flash-next-drafter-r2.hgn"
ln -s "$work/elsewhere" "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"; expect_fail "a link at the -ht4 draft head"; rm "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
ln -s "$work/elsewhere" "$work/models/npu/embed/b.hnpw"; expect_fail "a link inside the NPU folder"; rm "$work/models/npu/embed/b.hnpw"
mkfifo "$work/models/npu/embed/fifo"; expect_fail "a FIFO inside the NPU folder"; rm "$work/models/npu/embed/fifo"
ln -s "$work/elsewhere" "$work/models/tokenizer/merges.txt"; expect_fail "a link inside the tokenizer folder"; rm "$work/models/tokenizer/merges.txt"
# A folder that can't be listed hides what is in it (a link at a listed name, say).
# (Empty here: this test may run as root, who would list it anyway.)
mkdir -p "$work/models/npu/hidden"; chmod 0111 "$work/models/npu/hidden"
expect_fail "an NPU folder that can't be listed"; chmod 0755 "$work/models/npu/hidden"; rm -rf "$work/models/npu/hidden"
run > /dev/null; rm -rf "$work/models/npu" "$work/models/tokenizer"
: > "$work/models/LFM"; expect_fail "a file in place of an own-checkpoint folder"; rm "$work/models/LFM"
rm "$work/dev/accel/accel0"; expect_fail "a missing NPU"
touch "$work/dev/accel/accel0"
printf '#!/bin/sh\nexit 1\n' > "$work/clock"; expect_fail "an unheld fabric clock"
printf '#!/bin/sh\nexit 0\n' > "$work/clock"
HALOGEN_MEMLOCK=8192 expect_fail "limited memlock"
if [ "$(id -u)" != 0 ]; then chmod 000 "$work/dev/kfd"; expect_fail "a GPU node it cannot open"; chmod 644 "$work/dev/kfd"; fi

mkdir -p "$work/sys/class/drm/card0/device"
echo $((20 * 1073741824)) > "$work/sys/class/drm/card0/device/mem_info_gtt_used"
out="$(run 2>&1)"
grep -q 'GTT is already in use' <<< "$out" || { echo "leftover GTT not reported" >&2; exit 1; }
echo "ok: warns about GTT left in use"
out="$(HALOGEN_SERVER_RUNNING=1 run 2>&1)"
if grep -q 'already in use' <<< "$out" || ! grep -q 'by the running server' <<< "$out"; then
  echo "doctor warned about the running server's own GTT" >&2; exit 1
fi
echo "ok: GTT held by the running server is not a warning"
# An adapters/ folder beside the official checkpoint or an own one (Halogen 0.21.0 would read it).
mkdir "$work/models/adapters"; expect_fail "an adapters folder beside the official checkpoint"; rmdir "$work/models/adapters"
mkdir -p "$work/models/flash/mine/adapters"; expect_fail "an adapters folder beside an own checkpoint"
rmdir "$work/models/flash/mine/adapters"; ln -s "$work/elsewhere" "$work/models/flash/mine/adapters"; expect_fail "a link named adapters beside an own checkpoint"
rm "$work/models/flash/mine/adapters"; run > /dev/null; echo "ok: an own checkpoint without adapters passes"
