#!/bin/bash
# The allowlist decides what reaches Halogen.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export XDG_RUNTIME_DIR="$work/run" HALOGEN_CONFIG_FILE="$work/config"
export HALOGEN_FLASH_FILE="$work/flash-checkpoint" HALOGEN_MODELS_DIR="$work/models"
export HALOGEN_RECORDS_DROPIN="$work/20-records.conf"
official=HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn
export HALOGEN_ALLOWED_FILE="$repo/variants/npu/usr/share/halogen/options.allowed"
render="$repo/files/usr/libexec/halogen/render-config"
cat > "$work/config" <<'S'
# a comment
HALOGEN_KV_SLOTS=2
HALOGEN_KV_SLOTS=3
  HALOGEN_TEMPERATURE="1.0"
HALOGEN_API_PORT=9000
HALOGEN_DOWNLOAD=evil/repo
HALOGEN_CHECKPOINT=/tmp/other.hgn
HALOGEN_KV_SLTOS=8
HALOGEN_VISION_TOWER=/models/x
$(touch /tmp/halogen-config-injected)
not a setting
S
out="$("$render" --show 2>"$work/log")"
[ "$(printf '%s\n' "$out")" = "$(printf '%s\nHALOGEN_KV_SLOTS=3\nHALOGEN_TEMPERATURE=1.0' "$official")" ] || { echo "unexpected: $out" >&2; exit 1; }
for word in HALOGEN_API_PORT HALOGEN_DOWNLOAD HALOGEN_CHECKPOINT HALOGEN_KV_SLTOS HALOGEN_VISION_TOWER; do
  grep -q "ignored $word" "$work/log" || { echo "no warning for $word" >&2; exit 1; }
done
grep -qx "halogen-config: HALOGEN_KV_SLOTS is set more than once in $work/config (lines 2 and 3); line 3 is used" "$work/log" \
  || { cat "$work/log" >&2; echo "no warning for a setting written twice" >&2; exit 1; }
[ "$(grep -c 'more than once' "$work/log")" = 1 ] || { echo "a duplicate warning for a setting written once" >&2; exit 1; }
[ ! -e /tmp/halogen-config-injected ] || { echo "the config ran as shell" >&2; exit 1; }
echo "ok: only allowed settings pass, the last value wins with a warning, and the file never runs as shell"

export HALOGEN_ALLOWED_FILE="$repo/variants/no-npu/usr/share/halogen/options.allowed"
echo 'HALOGEN_NPU_MODELS=decider-0.8b' > "$work/config"
[ "$("$render" --show 2>/dev/null)" = "$official" ] || { echo "the no-NPU edition accepted NPU models" >&2; exit 1; }
echo "ok: the no-NPU edition ignores NPU settings"

rm "$work/config"
[ "$("$render" --show 2>/dev/null)" = "$official" ] || exit 1
echo "ok: a missing config falls back to defaults"

# The Flash checkpoint: only one flash pull downloaded and Halogen's verify passed.
export HALOGEN_ALLOWED_FILE="$repo/variants/npu/usr/share/halogen/options.allowed"
echo 'HALOGEN_VISION_TOWER=1' > "$work/config"
ck() { "$render" --show 2>"$work/log" | sed -n 's/^HALOGEN_CHECKPOINT=//p'; }
mkdir -p "$work/models/flash/mine/tokenizer"
printf 'repo=a/b\ncheckpoint=model.hgn\nverified=pass\n' > "$work/models/flash/mine/halos.info"
touch "$work/models/flash/mine/model.hgn"
[ "$(ck)" = /models/qwen38-flash-next-v2.hgn ] || { echo "no choice did not mean official" >&2; exit 1; }
echo official > "$work/flash-checkpoint"
[ "$(ck)" = /models/qwen38-flash-next-v2.hgn ] || exit 1
echo mine > "$work/flash-checkpoint"
[ "$(ck)" = /models/flash/mine/model.hgn ] || { echo "the chosen checkpoint was not used" >&2; exit 1; }
if "$render" --show 2>/dev/null | grep -q '^HALOGEN_VISION_TOWER='; then echo "vision on with no tower beside the checkpoint" >&2; exit 1; fi
grep -q 'ignored HALOGEN_VISION_TOWER' "$work/log" || exit 1
touch "$work/models/flash/mine/qwen38-flash-next-vision.hgn"
"$render" --show 2>/dev/null | grep -qx 'HALOGEN_VISION_TOWER=1' || { echo "vision dropped though the tower is there" >&2; exit 1; }
sed -i 's/^verified=pass$/verified=fail/' "$work/models/flash/mine/halos.info"
if [ "$(ck)" != /models/qwen38-flash-next-v2.hgn ] || ! grep -q "not passed Halogen's verify" "$work/log"; then
  echo "an unverified checkpoint was used" >&2; exit 1
fi
sed -i 's/^verified=fail$/verified=pass/; s/^checkpoint=.*/checkpoint=..\/..\/x.hgn/' "$work/models/flash/mine/halos.info"
[ "$(ck)" = /models/qwen38-flash-next-v2.hgn ] || { echo "a checkpoint path outside its folder was used" >&2; exit 1; }
for bad in ../mine missing '.hidden' 'a b'; do
  printf '%s\n' "$bad" > "$work/flash-checkpoint"
  [ "$(ck)" = /models/qwen38-flash-next-v2.hgn ] || { echo "'$bad' did not fall back to the official checkpoint" >&2; exit 1; }
done
echo "ok: the Flash checkpoint is the official one unless a verified one is chosen; vision follows its tower"

# A link in a checkpoint folder could lead to a file that changed after it was checked.
mkdir -p "$work/models/flash/linked"; printf 'checkpoint=model.hgn\nverified=pass\n' > "$work/models/flash/linked/halos.info"
ln -s /etc/hostname "$work/models/flash/linked/model.hgn"; echo linked > "$work/flash-checkpoint"
[ "$(ck)" = /models/qwen38-flash-next-v2.hgn ] || { echo "a linked checkpoint was used" >&2; exit 1; }
grep -q 'holds links' "$work/log" || exit 1
echo "ok: a checkpoint folder holding links falls back to the official checkpoint"


# Request records (#107): off unless halogenctl records on put its mount in place; then counts only
# unless HALOGEN_RECORD_TEXT says otherwise, and a value Halogen would refuse never reaches it.
rm -f "$work/flash-checkpoint"
printf 'HALOGEN_RECORD_TEXT=all\nHALOGEN_RECORD_DAYS=7\n' > "$work/config"
"$render" --show 2> /dev/null > "$work/out"
if grep -q '^HALOGEN_RECORD' "$work/out"; then echo "records settings passed while recording is off" >&2; exit 1; fi
touch "$work/20-records.conf"
rm "$work/config"
"$render" --show 2> /dev/null > "$work/out"
if ! { grep -qx 'HALOGEN_RECORD_DIR=/records' "$work/out" && grep -qx 'HALOGEN_RECORD_TEXT=none' "$work/out"; }; then
  cat "$work/out" >&2; echo "recording on didn't default to counts only" >&2; exit 1
fi
printf 'HALOGEN_RECORD_TEXT=prompt,reply\nHALOGEN_RECORD_GIB=0.5\nHALOGEN_RECORD_DAYS=7\n' > "$work/config"
"$render" --show 2> /dev/null > "$work/out"
if ! { grep -qx 'HALOGEN_RECORD_TEXT=prompt,reply' "$work/out" && grep -qx 'HALOGEN_RECORD_GIB=0.5' "$work/out" \
  && grep -qx 'HALOGEN_RECORD_DAYS=7' "$work/out"; }; then cat "$work/out" >&2; echo "valid records settings were dropped" >&2; exit 1; fi
for bad in 'TEXT=prompt,bogus' 'TEXT=prompt, reply' 'TEXT=,prompt' 'GIB=2GiB' 'DAYS=-1'; do
  echo "HALOGEN_RECORD_$bad" > "$work/config"
  "$render" --show 2> "$work/log" > "$work/out"
  grep -q "ignored HALOGEN_RECORD_${bad%%=*}" "$work/log" || { echo "no warning for $bad" >&2; exit 1; }
  if grep -qx "HALOGEN_RECORD_$bad" "$work/out"; then echo "$bad reached Halogen" >&2; exit 1; fi
done
grep -qx 'HALOGEN_RECORD_TEXT=none' "$work/out" || { echo "a bad text list didn't fall back to none" >&2; exit 1; }
echo "ok: request records are off until turned on, then counts only by default, and bad values never reach Halogen"

# The prompt cache on disk: on (with old versions' files pruned) while the folder exists, unless
# halogenctl cache off; its limit passes only as a whole number, and nothing passes while off.
export HALOGEN_CACHE_CHOICE_FILE="$work/prompt-cache"
rm -f "$work/config" "$work/prompt-cache"; rm -rf "$work/models/.prompt-cache"
"$render" --show 2> /dev/null > "$work/out"
if grep -q '^HALOGEN_CACHE_DIR' "$work/out"; then echo "the disk cache is on without its folder" >&2; exit 1; fi
mkdir -p "$work/models/.prompt-cache"
printf 'HALOGEN_CACHE_DISK_GIB=20\nHALOGEN_CACHE_DIR=/models\n' > "$work/config"
"$render" --show 2> /dev/null > "$work/out"
if ! { grep -qx 'HALOGEN_CACHE_DIR=/cache' "$work/out" && grep -qx 'HALOGEN_CACHE_PRUNE_OLD=1' "$work/out" \
  && grep -qx 'HALOGEN_CACHE_DISK_GIB=20' "$work/out"; }; then cat "$work/out" >&2; echo "the disk cache isn't on with its defaults" >&2; exit 1; fi
printf 'HALOGEN_CACHE_DISK_GIB=lots\nHALOGEN_CACHE_PRUNE_OLD=0\n' > "$work/config"
"$render" --show 2> "$work/log" > "$work/out"
grep -q 'ignored HALOGEN_CACHE_DISK_GIB' "$work/log" || { echo "no warning for a bad cache limit" >&2; exit 1; }
if grep -q '^HALOGEN_CACHE_DISK_GIB' "$work/out" || ! grep -qx 'HALOGEN_CACHE_PRUNE_OLD=0' "$work/out"; then cat "$work/out" >&2; echo "bad limit passed, or keeping old files was overruled" >&2; exit 1; fi
echo off > "$work/prompt-cache"
"$render" --show 2> /dev/null > "$work/out"
if grep -q '^HALOGEN_CACHE_\(DIR\|DISK_GIB\|PRUNE_OLD\)' "$work/out"; then cat "$work/out" >&2; echo "cache settings passed while off" >&2; exit 1; fi
rm -f "$work/config" "$work/prompt-cache"
echo "ok: the prompt cache on disk is on by default, off on request, and only a valid limit reaches Halogen"
