#!/bin/bash
# The allowlist decides what reaches Halogen.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export XDG_RUNTIME_DIR="$work/run" HALOGEN_CONFIG_FILE="$work/config"
export HALOGEN_FLASH_FILE="$work/flash-checkpoint" HALOGEN_MODELS_DIR="$work/models"
export HALOGEN_RECORDS_DROPIN="$work/20-records.conf" HALOGEN_SEARCH_DROPIN="$work/30-web-search.conf"
# The API key off for the checks below, so they compare only what halogen.env sets; the key's own
# checks are at the end.
# render-config reads a fixed path (halogen can set its manager's environment), so the test runs
# a copy that reads this folder's file instead.
sed -e "s|^api_key_off=/etc/halos/api-key-off$|api_key_off=$work/api-key-off|" \
  -e "s|^search_conf=/etc/halos/web-search.env$|search_conf=$work/web-search.env|" "$repo/files/usr/libexec/halogen/render-config" > "$work/render-config"
grep -q "^search_conf=$work/web-search.env$" "$work/render-config" || { echo "the test couldn't point render-config at its web-search.env" >&2; exit 1; }
chmod +x "$work/render-config"; touch "$work/api-key-off"
official=HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn
export HALOGEN_ALLOWED_FILE="$repo/variants/npu/usr/share/halogen/options.allowed"
render="$work/render-config"
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
# HALOGEN_CK_OVERLAY (Halogen 0.20.6): only none passes, the way back to the checkpoint's own draft head.
printf 'HALOGEN_CK_OVERLAY=/models/qwen38-flash-next-ngram.hgn\n' > "$work/config"
if "$render" --show 2>"$work/log" | grep -q '^HALOGEN_CK_OVERLAY='; then echo "a path reached HALOGEN_CK_OVERLAY" >&2; exit 1; fi
grep -q 'ignored HALOGEN_CK_OVERLAY: the only value halOS accepts is none' "$work/log" || { cat "$work/log" >&2; exit 1; }
printf 'HALOGEN_CK_OVERLAY=none\n' > "$work/config"
"$render" --show 2>/dev/null | grep -qx 'HALOGEN_CK_OVERLAY=none' || { echo "HALOGEN_CK_OVERLAY=none was dropped" >&2; exit 1; }
echo "ok: HALOGEN_CK_OVERLAY passes only as none"

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

# The draft head for your own checkpoint: the official one by default (while the file is there, no
# link, starting as a draft head does); off keeps the built-in head; a file its pull listed and
# checked when chosen; never over a quality sidecar, a converted GGUF or HALOGEN_CK_OVERLAY=none.
export HALOGEN_DRAFTER_CHOICE_FILE="$work/flash-drafter"
dh=/models/qwen38-flash-next-drafter-r2-ht4.hgn
ovl() { "$render" --show 2>"$work/log" | sed -n 's/^HALOGEN_CK_OVERLAY=//p'; }
mkdir -p "$work/models/flash/mine"; printf 'repo=a/b\ncheckpoint=model.hgn\ndrafter=their-drafter.hgn\nown_precision=1\nverified=pass\n' > "$work/models/flash/mine/halos.info"
printf 'HGN1rest' > "$work/models/flash/mine/model.hgn"; printf 'HGN1head' > "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
printf 'HGN1them' > "$work/models/flash/mine/their-drafter.hgn"
echo mine > "$work/flash-checkpoint"; : > "$work/config"
"$render" --show 2> /dev/null > "$work/out"
{ grep -qx "HALOGEN_CK_OVERLAY=$dh" "$work/out" && grep -qx HALOGEN_MTP_GATE_RULE=cost "$work/out" && grep -qx HALOGEN_SAMPLED_GATE=cost "$work/out"; } \
  || { cat "$work/out" >&2; echo "the official draft head or its rules were not the default" >&2; exit 1; }
echo 'HALOGEN_SAMPLED_GATE=0.9,0.95' > "$work/config"
"$render" --show 2> /dev/null | grep -qx 'HALOGEN_SAMPLED_GATE=0.9,0.95' || { echo "the user's HALOGEN_SAMPLED_GATE was replaced" >&2; exit 1; }
echo 'HALOGEN_CK_OVERLAY=none' > "$work/config"
{ [ "$(ovl)" = none ] && grep -q 'which wins' "$work/log"; } || { echo "HALOGEN_CK_OVERLAY=none didn't win" >&2; exit 1; }
: > "$work/config"
printf 'other=off\nmine=their-drafter.hgn\n' > "$work/flash-drafter"
[ "$(ovl)" = /models/flash/mine/their-drafter.hgn ] || { echo "the checkpoint's own draft head file wasn't used when chosen" >&2; exit 1; }
printf 'mine=other.hgn\n' > "$work/flash-drafter"; printf 'HGN1x' > "$work/models/flash/mine/other.hgn"
{ [ "$(ovl)" = "$dh" ] && grep -q "isn't one from its pull" "$work/log"; } || { echo "a file the pull didn't list was used" >&2; exit 1; }
printf 'mine=their-drafter.hgn\n' > "$work/flash-drafter"; printf 'XXXXthem' > "$work/models/flash/mine/their-drafter.hgn"
[ "$(ovl)" = "$dh" ] || { echo "a listed file that isn't a draft head was used" >&2; exit 1; }
printf 'HGN1them' > "$work/models/flash/mine/their-drafter.hgn"
printf 'mine=../x\nmine=off\n' > "$work/flash-drafter"
[ -z "$(ovl)" ] || { echo "off didn't keep the built-in head" >&2; exit 1; }
printf 'notmine=off\n' > "$work/flash-drafter"
[ "$(ovl)" = "$dh" ] || { echo "another checkpoint's line was read" >&2; exit 1; }
# official-r2: Halogen 0.20.6's draft head while it is a plain draft head file in /srv/models.
printf 'mine=official-r2\n' > "$work/flash-drafter"
{ [ "$(ovl)" = "$dh" ] && grep -q "0.20.6's draft head" "$work/log"; } || { echo "official-r2 without the file didn't fall back" >&2; exit 1; }
printf 'HGN1r2' > "$work/models/qwen38-flash-next-drafter-r2.hgn"
[ "$(ovl)" = /models/qwen38-flash-next-drafter-r2.hgn ] || { echo "official-r2 wasn't used" >&2; exit 1; }
rm "$work/models/qwen38-flash-next-drafter-r2.hgn"; ln -s "$work/models/flash/mine/their-drafter.hgn" "$work/models/qwen38-flash-next-drafter-r2.hgn"
[ "$(ovl)" = "$dh" ] || { echo "a link at official-r2's name was used" >&2; exit 1; }
rm "$work/models/qwen38-flash-next-drafter-r2.hgn"
# Only for a checkpoint that carries its own precision: with a w4b-style one the setting selects
# the precision sidecar. Unknown (a pull from before this) waits for flash verify.
for p in 0 unknown; do
  sed -i "s/^own_precision=.*/own_precision=$p/" "$work/models/flash/mine/halos.info"
  { [ -z "$(ovl)" ] && grep -q 'carries its own precision' "$work/log"; } || { echo "a draft head was named with own_precision=$p" >&2; exit 1; }
done
sed -i '/^own_precision=/d' "$work/models/flash/mine/halos.info"
[ -z "$(ovl)" ] || { echo "a draft head was named without own_precision" >&2; exit 1; }
sed -i 's/^verified=pass$/own_precision=1\nverified=pass/' "$work/models/flash/mine/halos.info"
# A drafter= line naming the checkpoint itself, or a name a draft head can't have, is never used.
printf 'mine=model.hgn\n' > "$work/flash-drafter"; printf 'drafter=model.hgn\n' >> "$work/models/flash/mine/halos.info"
[ "$(ovl)" = "$dh" ] || { echo "the checkpoint itself was named as its draft head" >&2; exit 1; }
printf 'notmine=off\n' > "$work/flash-drafter"
echo official > "$work/flash-checkpoint"
[ -z "$(ovl)" ] || { echo "the official checkpoint got a draft head path (its entrypoint finds it)" >&2; exit 1; }
echo mine > "$work/flash-checkpoint"
touch "$work/models/flash/mine/model.overlay.hgn"
{ [ -z "$(ovl)" ] && grep -q 'quality sidecar' "$work/log"; } || { echo "a draft head replaced a quality sidecar" >&2; exit 1; }
rm "$work/models/flash/mine/model.overlay.hgn"
{ printf 'HGN1'; head -c 46 /dev/zero; printf 'qwen-gguf'; head -c 60 /dev/zero; } > "$work/models/flash/mine/model.hgn"
{ [ -z "$(ovl)" ] && grep -q "converted GGUF" "$work/log"; } || { echo "a draft head was named for a converted GGUF" >&2; exit 1; }
printf 'HGN1rest' > "$work/models/flash/mine/model.hgn"
printf 'XXXXhead' > "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
[ -z "$(ovl)" ] || { echo "an official file that isn't a draft head was named" >&2; exit 1; }
rm "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"; ln -s "$work/models/flash/mine/their-drafter.hgn" "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
{ [ -z "$(ovl)" ] && grep -q "isn't downloaded" "$work/log"; } || { echo "a link at the draft head's name was used" >&2; exit 1; }
rm "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
[ -z "$(ovl)" ] || { echo "a missing draft head was named" >&2; exit 1; }
# A checkpoint in Peonist's layout (named qwen38-flash-next-*.hgn, with a draft head file under
# Halogen's own name beside it): Halogen's entrypoint would pick that file by itself, so off says
# none and a quality sidecar is named outright.
mkdir -p "$work/models/flash/peo"; printf 'repo=a/b\ncheckpoint=qwen38-flash-next-v2-ft.hgn\ndrafter=qwen38-flash-next-drafter-r2.hgn\nown_precision=1\nverified=pass\n' > "$work/models/flash/peo/halos.info"
printf 'HGN1' > "$work/models/flash/peo/qwen38-flash-next-v2-ft.hgn"; printf 'HGN1' > "$work/models/flash/peo/qwen38-flash-next-drafter-r2.hgn"
printf 'HGN1head' > "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
echo peo > "$work/flash-checkpoint"; : > "$work/config"
[ "$(ovl)" = "$dh" ] || { echo "Peonist's layout didn't get the official draft head" >&2; exit 1; }
printf 'peo=off\n' > "$work/flash-drafter"
[ "$(ovl)" = none ] || { echo "off left Halogen to pick the folder's draft head" >&2; exit 1; }
: > "$work/flash-drafter"; printf 'x' > "$work/models/flash/peo/qwen38-flash-next-v2-ft.overlay.hgn"
[ "$(ovl)" = /models/flash/peo/qwen38-flash-next-v2-ft.overlay.hgn ] || { echo "the sidecar wasn't named, so the folder's draft head would replace it" >&2; exit 1; }
rm -f "$work/flash-drafter" "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"; rm -rf "$work/models/flash/mine" "$work/models/flash/peo"
echo "ok: your own checkpoint drafts with the official draft head by default, with its repository's when chosen, and never over a sidecar or HALOGEN_CK_OVERLAY=none"


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
export HALOGEN_CACHE_CHOICE_FILE="$work/prompt-cache" HALOGEN_CACHE_OFF_DROPIN="$work/cache-off.conf"
rm -f "$work/config" "$work/prompt-cache"; rm -rf "$work/models/.prompt-cache"
"$render" --show 2> /dev/null > "$work/out"
if grep -q '^HALOGEN_CACHE_DIR' "$work/out"; then echo "the disk cache is on without its folder" >&2; exit 1; fi
mkdir -p "$work/models/.prompt-cache"
printf 'HALOGEN_CACHE_DISK_GIB=20\nHALOGEN_CACHE_DIR=/models\n' > "$work/config"
"$render" --show 2> /dev/null > "$work/out"
if ! { grep -qx 'HALOGEN_CACHE_DIR=/models/.prompt-cache' "$work/out" && grep -qx 'HALOGEN_CACHE_PRUNE_OLD=1' "$work/out" \
  && grep -qx 'HALOGEN_CACHE_DISK_GIB=20' "$work/out"; }; then cat "$work/out" >&2; echo "the disk cache isn't on with its defaults" >&2; exit 1; fi
printf 'HALOGEN_CACHE_DISK_GIB=lots\nHALOGEN_CACHE_PRUNE_OLD=0\n' > "$work/config"
"$render" --show 2> "$work/log" > "$work/out"
grep -q 'ignored HALOGEN_CACHE_DISK_GIB' "$work/log" || { echo "no warning for a bad cache limit" >&2; exit 1; }
if grep -q '^HALOGEN_CACHE_DISK_GIB' "$work/out" || ! grep -qx 'HALOGEN_CACHE_PRUNE_OLD=0' "$work/out"; then cat "$work/out" >&2; echo "bad limit passed, or keeping old files was overruled" >&2; exit 1; fi
echo off > "$work/prompt-cache"
"$render" --show 2> /dev/null > "$work/out"
if grep -q '^HALOGEN_CACHE_\(DIR\|DISK_GIB\|PRUNE_OLD\)' "$work/out"; then cat "$work/out" >&2; echo "cache settings passed while off" >&2; exit 1; fi
# The read-only drop-in alone (the choice file says on, or is gone) also keeps Halogen from being told.
rm -f "$work/prompt-cache"; : > "$work/cache-off.conf"
"$render" --show 2> /dev/null > "$work/out"
if grep -q '^HALOGEN_CACHE_DIR' "$work/out"; then echo "Halogen is told about a cache folder mounted read-only" >&2; exit 1; fi
rm -f "$work/config" "$work/prompt-cache" "$work/cache-off.conf"
echo "ok: the prompt cache on disk is on by default, off on request, and only a valid limit reaches Halogen"

# The API key (sudo halogenctl api-key on|off): required unless root's off file is there, and
# halogen.env can never set it or point it elsewhere.
printf 'HALOGEN_API_KEY=open\nHALOGEN_API_KEY_FILE=/models/x\n' > "$work/config"
rm -f "$work/api-key-off"
out="$("$render" --show 2>"$work/log")"
grep -qx 'HALOGEN_API_KEY_FILE=/run/secrets/halogen-api-key' <<< "$out" || { echo "the key isn't required by default: $out" >&2; exit 1; }
if grep -q '^HALOGEN_API_KEY=' <<< "$out"; then echo "halogen.env set HALOGEN_API_KEY" >&2; exit 1; fi
touch "$work/api-key-off"
out="$("$render" --show 2>"$work/log")"
if grep -q '^HALOGEN_API_KEY' <<< "$out"; then echo "the key is still required while off: $out" >&2; exit 1; fi
grep -q 'the API key is off' "$work/log" || { echo "no warning while the key is off" >&2; exit 1; }
rm "$work/api-key-off"; mkdir "$work/api-key-off"
"$render" --show 2>/dev/null | grep -qx 'HALOGEN_API_KEY_FILE=/run/secrets/halogen-api-key' || { echo "a folder at the off file's name turned the key off" >&2; exit 1; }
echo "ok: the API key is required unless root's off file is there"
# The real script: no variable can point it at another off file.
HALOGEN_API_KEY_OFF_FILE="$work/api-key-off" "$repo/files/usr/libexec/halogen/render-config" --show 2>/dev/null \
  | grep -qx 'HALOGEN_API_KEY_FILE=/run/secrets/halogen-api-key' || { echo "an environment variable turned the key off" >&2; exit 1; }
echo "ok: the environment can't turn the key off"

# Web search: the URL only while root's drop-in puts Halogen on the search network, always the
# search container's address, with your SearXNG's path for external; never from halogen.env.
ws() { "$render" --show 2>"$work/log" | sed -n 's/^HALOGEN_WEB_SEARCH_URL=//p'; }
echo 'HALOGEN_WEB_SEARCH_URL=http://evil.example.com' > "$work/config"
printf 'HALOS_WEB_SEARCH=bundled\n' > "$work/web-search.env"
[ -z "$(ws)" ] || { echo "web search reached Halogen without the drop-in" >&2; exit 1; }
touch "$work/30-web-search.conf"
[ "$(ws)" = http://10.89.250.2:8080 ] || { echo "bundled web search didn't give the search container's address" >&2; exit 1; }
printf 'HALOS_WEB_SEARCH=external\nHALOS_SEARCH_UPSTREAM=https://search.example.com\nHALOS_SEARCH_PATH=/searx\n' > "$work/web-search.env"
[ "$(ws)" = http://10.89.250.2:8080/searx ] || { echo "external web search lost its path" >&2; exit 1; }
for bad in '/a?b' '/../x' '/a b' 'x'; do
  printf 'HALOS_WEB_SEARCH=external\nHALOS_SEARCH_PATH=%s\n' "$bad" > "$work/web-search.env"
  if ! { [ -z "$(ws)" ] && grep -q 'web search stays off' "$work/log"; }; then echo "a bad path '$bad' reached Halogen" >&2; exit 1; fi
done
printf 'HALOS_WEB_SEARCH=other\n' > "$work/web-search.env"
if ! { [ -z "$(ws)" ] && grep -q 'names no mode' "$work/log"; }; then echo "an unknown mode turned web search on" >&2; exit 1; fi
rm -f "$work/30-web-search.conf" "$work/web-search.env"
echo "ok: web search reaches Halogen only through halogenctl's drop-in, at the search container's address"
