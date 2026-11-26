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
model lfm3-qad repo=org/lfm3-qad revision=q source=LiquidAI/LFM3-1.7B-GGUF@cd0c74c575b5c416f3011b5b4c298077f26ca8c2
file lfm3-qad devices/q.hnpm 5 $h
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
for f in "${files[@]}"; do
  case "$dest/$f" in "$FAKE/mount/npu/"*) ;; *) [ -z "${FAKE_TOP_RO:-}" ] || { echo "hf wrote $dest/$f with the top of /models read-only" >> "$FAKE/ro-write"; exit 1; } ;; esac
  mkdir -p "$(dirname "$dest/$f")"; printf "${FAKE_CONTENT:-hello}" > "$dest/$f"; done
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
      *" --entrypoint cat "*"/opt/halogen/npu/models.txt "*) cat "$FAKE/opt/models.txt" ;;
      *) echo "$*" > "$FAKE/last-run"
         npu=""; mode=""; bases=""; vision=""
         skip=""
         for a in "$@"; do case "$a" in NPU_MODELS=*) npu="${a#NPU_MODELS=}" ;; FETCH_MODE=*) mode="${a#FETCH_MODE=}" ;; OWN_BASES=*) bases="${a#OWN_BASES=}" ;; VISION=*) vision="${a#VISION=}" ;; SKIP_FLASH=*) skip="${a#SKIP_FLASH=}" ;; esac; done
         # The top of /models read-only: the fake helper may then write only under npu.
         case " $* " in *":/models:ro "*) export FAKE_TOP_RO=1 ;; *) unset FAKE_TOP_RO ;; esac
         # The probe runs offline: only that run may call Halogen's probe.
         [ "$mode" = probe ] || export NO_PROBE=1
         HALOGEN_PINS="$FAKE/opt/models.txt" HALOGEN_MODELS_ROOT="$FAKE/mount" WEIGHTS_REPO=r WEIGHTS_REVISION=main \
         HALOGEN_NPU_BIN="$FAKE/bin/halogen-npu" FETCH_MODE="$mode" OWN_BASES="$bases" \
         NPU_MODELS="$npu" VISION="$vision" SKIP_FLASH="$skip" bash "$HELPER_SRC"; rc=$?
         # What a hostile download could leave behind it (a test plants it here).
         [ ! -f "$FAKE/plant" ] || { bash "$FAKE/plant"; /usr/bin/rm -f "$FAKE/plant"; }
         exit "$rc" ;;
    esac ;;
esac
S
cat > "$work/bin/halogen-npu" <<'S'
#!/bin/bash
# Halogen's probe names the model a checkpoint was tuned from.
[ -z "${NO_PROBE:-}" ] || { echo "probe ran in the download container" >> "$FAKE/probe-leak"; exit 1; }
# Asked for the :qad form (--form qad), it answers with the -qad model, as Halogen 0.20.6's does.
[ "$1" = probe ] && [ -f "$2/config.json" ] && echo "task=generate base=$(cat "$2/base" 2>/dev/null || echo lfm3)$([ "${3:-}${4:-}" = --formqad ] && echo -qad)"
S
# rm that fails on the tokenizer folder itself when asked: what a download that made the models
# folder read-only would cause for a user without root's rights (CI's runner; this test may run as root).
cat > "$work/bin/rm" <<'S'
#!/bin/bash
# FAKE_RM_FAIL=1: the tokenizer folder; a path: that path.
if [ -n "${FAKE_RM_FAIL:-}" ]; then
  t="$FAKE/models/tokenizer"; [ "$FAKE_RM_FAIL" = 1 ] || t="$FAKE_RM_FAIL"
  for a in "$@"; do [ "$a" != "$t" ] || { echo "rm: Permission denied" >&2; exit 1; }; done
fi
exec /usr/bin/rm "$@"
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
# The stamp lives in halogen's own folder; the official files are checked against these hashes
# (the fake hf writes "hello" into every file).
mkdir -p "$work/state"
{ echo "# revision main"; for f in qwen38-flash-next-v2.hgn qwen38-flash-next-ngram.hgn qwen38-flash-next-drafter-r2-ht4.hgn qwen38-flash-next-drafter-r2.hgn qwen38-flash-next-vision.hgn tokenizer/tokenizer.json; do echo "$h  $f"; done; } > "$work/sums"
export HALOGEN_STATE_DIR="$work/state" HALOGEN_WEIGHTS_SUMS="$work/sums"
# Enough memory for the Flash model, so no choice means the official one (the rule's own test is below).
printf 'MemTotal:       131072000 kB\n' > "$work/meminfo"; export HALOGEN_MEMINFO="$work/meminfo"
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
[ -f "$work/state/fetch-stamp" ]
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
# The download container is named (a leftover one is replaced) and gets the folders mounted into
# Halogen's container as mounts of their own, so it can't swap one for a link.
grep '/fetch.sh' "$work/podman.log" | grep -v -- '--network=none' > "$work/dl.log" || true
grep -q -- '--name halogen-fetch-download --replace' "$work/dl.log" || { echo "the download container isn't named and replaced" >&2; exit 1; }
grep -q -- "-v $work/models/npu:/models/npu " "$work/dl.log" || { echo "the download container can rename the npu folder: $(tail -n 1 "$work/dl.log")" >&2; exit 1; }
# An own-checkpoint folder that exists is pinned read-only.
mkdir -p "$work/models/custom"; echo 'HALOGEN_NPU_MODELS=embed,rerank' > "$work/config.env"; : > "$work/podman.log"
"$work/fetch" > /dev/null
grep -q -- "-v $work/models/custom:/models/custom:ro " "$work/podman.log" || { echo "the custom folder isn't pinned read-only in the download container" >&2; exit 1; }
rmdir "$work/models/custom"; echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"; "$work/fetch" > /dev/null
ok "changing the model list triggers a fetch, and verify runs offline with no capabilities"

# A link where one of Halogen's model folders belongs stops the fetch before any container runs.
mkdir -p "$work/elsewhere"; ln -s "$work/elsewhere" "$work/models/custom"
echo 'HALOGEN_NPU_MODELS=embed,rerank' > "$work/config.env"; : > "$work/podman.log"
if "$work/fetch" > "$work/out" 2>&1; then echo "the fetch ran with a link at custom" >&2; exit 1; fi
grep -q 'is a link, not a folder' "$work/out" || { cat "$work/out" >&2; exit 1; }
if grep -q ' run ' "$work/podman.log"; then echo "a container ran with a link at custom" >&2; exit 1; fi
rm "$work/models/custom"; echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"
ok "a link in place of a model folder stops the fetch"

# Links a download container could leave at the top of the models folder are never written or
# moved through: the fetch's own notes replace them, and a "version folder" that is a link goes.
echo secret > "$work/private"; mkdir -p "$work/keep/thing"
# (Old names from before the stamp moved to halogen's own folder: removed, never followed.)
ln -s "$work/private" "$work/models/.fetch-stamp"; ln -s "$work/private" "$work/models/.own-bases"
ln -s "$work/keep" "$work/models/npu/1.2.3"
echo 'HALOGEN_NPU_MODELS=embed,rerank' > "$work/config.env"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ "$(cat "$work/private")" = secret ] || { echo "the fetch wrote through a planted link" >&2; exit 1; }
if [ ! -d "$work/keep/thing" ] || [ -e "$work/models/npu/thing" ] || [ -L "$work/models/npu/1.2.3" ]; then echo "the fetch moved folders through a planted link" >&2; exit 1; fi
if [ -L "$work/state/fetch-stamp" ] || [ ! -s "$work/state/fetch-stamp" ]; then echo "the stamp wasn't written" >&2; exit 1; fi
if [ -e "$work/models/.fetch-stamp" ] || [ -L "$work/models/.fetch-stamp" ] || [ -L "$work/models/.own-bases" ]; then echo "the old stamp names in the models folder weren't removed" >&2; exit 1; fi
grep -q 'rm -f -i -t 0 halogen-fetch-download' "$work/podman.log" || { echo "a leftover download container isn't removed first" >&2; exit 1; }
echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"; "$work/fetch" > /dev/null
ok "planted links at the fetch's own files and old version folders are not followed"

# With the official files all there, the download only adds NPU programs: the top of /models is
# read-only to it (npu stays writable, as its own mount), and nothing is hashed.
echo 'HALOGEN_NPU_MODELS=embed,rerank,lfm3' > "$work/config.env"; : > "$work/podman.log"; rm -f "$work/ro-write"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep '/fetch.sh' "$work/podman.log" | grep -v -- '--network=none' > "$work/dl.log" || true
grep -q -- "-v $work/models:/models:ro " "$work/dl.log" || { echo "the download had the top of /models writable with every official file there" >&2; exit 1; }
if [ -e "$work/ro-write" ] || [ ! -f "$work/models/npu/lfm3/lfm3.hnpw" ]; then echo "the NPU download failed with the top read-only" >&2; exit 1; fi
if grep -q "checking the official files" "$work/out"; then echo "the official files were hashed though nothing could change them" >&2; exit 1; fi
ok "with the official files there, the top of /models is read-only to the download and nothing is hashed"

# A missing official file: the top is writable for the download, and afterwards every official
# file is checked. One that doesn't match is removed and the fetch fails (no stamp); the next
# start downloads it again. A link in place of the tokenizer goes, and the tokenizer comes again.
rm "$work/models/qwen38-flash-next-ngram.hgn"; rm -f "$work/state/fetch-stamp"; : > "$work/podman.log"
FAKE_CONTENT=tampered "$work/fetch" > "$work/out" 2>&1 && { echo "a file that doesn't match its hash was accepted" >&2; exit 1; }
grep -q "didn't match this release's hashes and were removed: qwen38-flash-next-ngram.hgn" "$work/out" || { cat "$work/out" >&2; exit 1; }
if [ -e "$work/models/qwen38-flash-next-ngram.hgn" ] || [ -e "$work/state/fetch-stamp" ]; then echo "a bad file was kept, or the stamp written" >&2; exit 1; fi
grep '/fetch.sh' "$work/podman.log" | grep -v -- '--network=none' | grep -q -- "-v $work/models:/models " || { echo "the download had no writable top with a file missing" >&2; exit 1; }
mv "$work/models/tokenizer" "$work/tok-aside"; ln -s "$work/tok-aside" "$work/models/tokenizer"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if [ -L "$work/models/tokenizer" ] || [ ! -f "$work/models/tokenizer/tokenizer.json" ] || [ ! -s "$work/state/fetch-stamp" ]; then echo "the fetch didn't recover" >&2; exit 1; fi
grep -q "checking the official files" "$work/out" || { echo "the official files weren't hashed after a download" >&2; exit 1; }
rm -rf "$work/tok-aside"; echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"; "$work/fetch" > /dev/null
ok "after a download every official file is checked against its hash; a bad one is removed and fetched again"

# A download cut short after the official files landed (here: an unknown NPU model, which the
# download refuses only after the weights) still has them checked by the next fetch, though by
# then they are all there.
rm "$work/models/qwen38-flash-next-ngram.hgn"
echo 'HALOGEN_NPU_MODELS=embed,nosuch' > "$work/config.env"
FAKE_CONTENT=evil "$work/fetch" > "$work/out" 2>&1 && { echo "an unknown NPU model was accepted" >&2; exit 1; }
[ -e "$work/models/qwen38-flash-next-ngram.hgn" ] || { cat "$work/out" >&2; echo "the test needs the file downloaded before the refusal" >&2; exit 1; }
echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"
"$work/fetch" > "$work/out" 2>&1 && { echo "a file from a download cut short was never checked" >&2; exit 1; }
grep -q "removed: qwen38-flash-next-ngram.hgn" "$work/out" || { cat "$work/out" >&2; exit 1; }
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ "$(cat "$work/models/qwen38-flash-next-ngram.hgn")" = hello ] || { echo "the file wasn't fetched again" >&2; exit 1; }
ok "files from a download that was cut short are checked by the next fetch"

# An upgrade to Halogen 0.20.7: everything is there but the new draft head (0.20.6's is kept), and
# the stamp is current. The fetch downloads only the new draft head (the others are there), with
# the top writable, and checks it.
rm -f "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"; printf hello > "$work/models/qwen38-flash-next-drafter-r2.hgn"; : > "$work/podman.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -q 'fetch: downloading qwen38-flash-next-drafter-r2-ht4.hgn from' "$work/out" || { cat "$work/out" >&2; echo "the draft head wasn't downloaded alone" >&2; exit 1; }
{ [ "$(cat "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn")" = hello ] && grep -q "checking the official files" "$work/out"; } \
  || { cat "$work/out" >&2; echo "the draft head wasn't fetched and checked" >&2; exit 1; }
[ "$(cat "$work/models/qwen38-flash-next-drafter-r2.hgn")" = hello ] || { echo "0.20.6's draft head, kept for a rollback, was changed" >&2; exit 1; }
ok "a machine without the -ht4 draft head (Halogen 0.20.7) fetches and checks it, keeping 0.20.6's"
# 0.20.6's draft head, when kept, is checked too: a rollback to 0.20.6 would read it.
rm "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"; printf evil > "$work/models/qwen38-flash-next-drafter-r2.hgn"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "a kept 0.20.6 draft head that differs failed the start" >&2; exit 1; }
{ grep -q "removed 0.20.6's draft head" "$work/out" && [ ! -e "$work/models/qwen38-flash-next-drafter-r2.hgn" ]; } || { cat "$work/out" >&2; echo "the kept 0.20.6 draft head wasn't checked" >&2; exit 1; }
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ ! -e "$work/models/qwen38-flash-next-drafter-r2.hgn" ] || { echo "0.20.6's draft head was downloaded again" >&2; exit 1; }
ok "a kept 0.20.6 draft head is checked, and removed without failing the start when it differs; it is never downloaded"
for f in qwen38-flash-next-drafter-r2-ht4.hgn qwen38-flash-next-drafter-r2.hgn; do
  echo secret > "$work/private-d"; rm -f "$work/models/$f"; ln -s "$work/private-d" "$work/models/$f"
  "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "a link at $f wasn't handled in one run" >&2; exit 1; }
  { [ ! -L "$work/models/$f" ] && [ "$(cat "$work/private-d")" = secret ]; } || { echo "the link at $f stayed, or its target changed" >&2; exit 1; }
  rm -f "$work/private-d"
done
[ -f "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn" ] || { echo "the draft head wasn't fetched after its link went" >&2; exit 1; }
ok "a link at either draft head's name goes, and the current one is fetched in the same run"
# LFM3's :qad form (Halogen 0.20.6): the probe is asked for that form, as Halogen's start does,
# and the -qad model's NPU programs are fetched; the id is noted with its suffix.
mkdir -p "$work/models/LFM/q"; echo '{}' > "$work/models/LFM/q/config.json"
echo 'HALOGEN_NPU_MODELS=embed,/models/LFM/q:qad' > "$work/config.env"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "a :qad entry was refused" >&2; exit 1; }
[ -f "$work/models/npu/lfm3-qad/devices/q.hnpm" ] || { cat "$work/out" >&2; echo "the :qad form's NPU programs weren't fetched" >&2; exit 1; }
grep -qx '/models/LFM/q:qad=lfm3-qad' "$work/state/own-bases" || { cat "$work/state/own-bases" >&2; echo "the :qad id wasn't noted" >&2; exit 1; }
# The stamp covers the folder's 4-bit file: a new or replaced one is checked again at the next start.
"$work/fetch" > "$work/out" 2>&1; grep -q "already match" "$work/out" || { cat "$work/out" >&2; echo "a second fetch of the same :qad entry didn't match" >&2; exit 1; }
echo q > "$work/models/LFM/q/LFM3-1.7B-QAD-Q4_0.gguf"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if grep -q "already match" "$work/out"; then echo "a new 4-bit file in a :qad folder didn't change the stamp" >&2; exit 1; fi
rm -rf "$work/models/LFM/q"; echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"
ok "an LFM3 :qad entry is probed in that form and its NPU programs are fetched"

# A vision tower kept while the tower is off is checked too, and a file in tokenizer/ that isn't
# one of this release's goes.
printf evil > "$work/models/qwen38-flash-next-vision.hgn"; printf x > "$work/models/tokenizer/added_tokens.json"
rm "$work/models/qwen38-flash-next-ngram.hgn"; printf 'HALOGEN_NPU_MODELS=embed\nHALOGEN_VISION_TOWER=\n' > "$work/config.env"
"$work/fetch" > "$work/out" 2>&1 && { echo "a tampered vision tower was accepted while it was off" >&2; exit 1; }
if [ -e "$work/models/qwen38-flash-next-vision.hgn" ] || [ -e "$work/models/tokenizer/added_tokens.json" ]; then cat "$work/out" >&2; echo "a bad tower or a stray tokenizer file was kept" >&2; exit 1; fi
echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"; "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
ok "a kept vision tower is checked while off, and stray tokenizer files are removed"

# A download that leaves a link in place of the tokenizer and a folder it can't be removed from
# never makes the check delete through the link: the fetch stops instead.
mkdir -p "$work/victim/sub"; echo key > "$work/victim/api-key"; echo x > "$work/victim/sub/more"
rm "$work/models/qwen38-flash-next-ngram.hgn"
printf '/usr/bin/rm -rf "%s/models/tokenizer"; ln -s "%s/victim" "%s/models/tokenizer"\n' "$work" "$work" "$work" > "$work/plant"
FAKE_RM_FAIL=1 "$work/fetch" > "$work/out" 2>&1 && { cat "$work/out" >&2; ls -la "$work/models" >&2; echo "the fetch went on past a link it couldn't remove" >&2; exit 1; }
if [ "$(cat "$work/victim/api-key" 2>/dev/null)" != key ] || [ ! -f "$work/victim/sub/more" ]; then echo "the check deleted files through a link" >&2; exit 1; fi
/usr/bin/rm -f "$work/models/tokenizer"; "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ -f "$work/models/tokenizer/tokenizer.json" ] || { echo "the fetch didn't recover" >&2; exit 1; }
ok "a link in place of the tokenizer that can't be removed stops the fetch, and nothing is deleted through it"

# The models live on a volume of their own: a stamp left after they went doesn't stop the fetch.
rm "$work/models/qwen38-flash-next-v2.hgn"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if grep -q "already match" "$work/out" || [ ! -f "$work/models/qwen38-flash-next-v2.hgn" ]; then echo "a stamp outlived the models it describes" >&2; exit 1; fi
ok "a missing official file is fetched again even with a matching stamp"

# After the download, npu holds only what the image's record lists: a link anywhere goes (and a
# link alone is reason enough to leave the fast path), as does a file the record doesn't list in
# a known model's folder; hf's .cache stays, and a folder of a model the record doesn't know is
# left (an older release's, for a rollback).
echo secret > "$work/private"; ln -s "$work/private" "$work/models/npu/embed/extra.hnpw"
printf x > "$work/models/npu/embed/planted.elf"
mkdir -p "$work/models/npu/embed/.cache/huggingface" "$work/models/npu/oldmodel"
printf x > "$work/models/npu/embed/.cache/huggingface/meta"; printf x > "$work/models/npu/oldmodel/keep.hnpw"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if grep -q "already match" "$work/out"; then echo "a link under npu took the fast path" >&2; exit 1; fi
if [ -e "$work/models/npu/embed/extra.hnpw" ] || [ -L "$work/models/npu/embed/extra.hnpw" ] || [ -e "$work/models/npu/embed/planted.elf" ]; then
  cat "$work/out" >&2; echo "a link or an unlisted file stayed under npu" >&2; exit 1
fi
if [ ! -f "$work/models/npu/embed/.cache/huggingface/meta" ] || [ ! -f "$work/models/npu/oldmodel/keep.hnpw" ] || [ ! -f "$work/models/npu/embed/embed.hnpw" ]; then
  echo "the cleanup removed hf's cache, a listed file or an unknown model's folder" >&2; exit 1
fi
[ "$(cat "$work/private")" = secret ] || { echo "the cleanup followed a link" >&2; exit 1; }
grep -q -- "--network=none --read-only --cap-drop=all --security-opt no-new-privileges --entrypoint cat" "$work/podman.log" || { echo "the record wasn't read offline" >&2; exit 1; }
rm -rf "$work/models/npu/oldmodel"
ok "after a download, npu keeps only what the image's record lists"

# A link at a known model's folder that can't be removed (the download made npu read-only): the
# cleanup never walks it, and the fetch stops; the files it points at stay.
mkdir -p "$work/victim2/sub"; echo key > "$work/victim2/api-key"; echo x > "$work/victim2/sub/more"
printf 'ln -s "%s/victim2" "%s/models/npu/lfm3-vl"\n' "$work" "$work" > "$work/plant"
rm -f "$work/state/fetch-stamp"
FAKE_RM_FAIL="$work/models/npu/lfm3-vl" "$work/fetch" > "$work/out" 2>&1 && { cat "$work/out" >&2; echo "the fetch went on past a link in npu it couldn't remove" >&2; exit 1; }
if [ "$(cat "$work/victim2/api-key" 2>/dev/null)" != key ] || [ ! -f "$work/victim2/sub/more" ]; then echo "the npu cleanup deleted files through a link" >&2; exit 1; fi
[ -e "$work/state/npu-unclean" ] || { echo "a cleanup that stopped left no marker" >&2; exit 1; }
# The marker keeps the next fetch off the fast path, even with the link gone and the stamp there.
/usr/bin/rm -f "$work/models/npu/lfm3-vl"; "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -q "already match" "$work/out" || { cat "$work/out" >&2; echo "the fast path never came back" >&2; exit 1; }
: > "$work/state/npu-unclean"; "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if grep -q "already match" "$work/out" || [ -e "$work/state/npu-unclean" ]; then echo "a cleanup still owed took the fast path" >&2; exit 1; fi
ok "a link at an NPU model's folder that can't be removed stops the fetch, and a cleanup still owed is done next time"

# A file name with a newline in it doesn't pass for a listed file.
printf x > "$work/models/npu/embed/a
embed.hnpw"
: > "$work/state/npu-unclean"; "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ ! -e "$work/models/npu/embed/a
embed.hnpw" ] || { echo "a name with a newline passed for a listed file" >&2; exit 1; }
ok "names are matched exactly against the record"
# The same for a folder whose name holds a newline: its file's path reads as two lines, the second
# a listed name.
mkdir -p "$work/models/npu/embed/a
embed"; printf x > "$work/models/npu/embed/a
embed/embed.hnpw"
: > "$work/state/npu-unclean"; "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ ! -e "$work/models/npu/embed/a
embed/embed.hnpw" ] || { echo "a path with a newline passed for a listed file" >&2; exit 1; }
/usr/bin/rm -rf "$work/models/npu/embed/a
embed"
ok "a folder name with a newline doesn't pass for a listed file either"

# A link in npu with the official files there: the download still has the top of /models
# read-only and hashes nothing (the npu state is only the fast path's business), and the link goes.
ln -s "$work/victim" "$work/models/npu/embed/stray"; : > "$work/podman.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep '/fetch.sh' "$work/podman.log" | grep -v -- '--network=none' > "$work/dl.log" || true
grep -q -- "-v $work/models:/models:ro " "$work/dl.log" || { cat "$work/out" >&2; echo "a link in npu made the top of /models writable to the download" >&2; exit 1; }
if grep -q "checking the official files" "$work/out" || [ -e "$work/state/weights-unchecked" ]; then echo "a link in npu made the fetch hash the official files" >&2; exit 1; fi
[ ! -L "$work/models/npu/embed/stray" ] || { echo "the link in npu was left" >&2; exit 1; }
ok "a link in npu doesn't open the official files to the download, and is removed"

# The tokenizer check matches names exactly too: tokenizer.json<newline>evil isn't tokenizer.json.
printf x > "$work/models/tokenizer/tokenizer.json
evil"
: > "$work/state/weights-unchecked"; "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ ! -e "$work/models/tokenizer/tokenizer.json
evil" ] || { echo "a tokenizer file named with a newline passed for a listed one" >&2; exit 1; }
ok "a tokenizer file whose name holds a newline is removed"

# With the stamp matching, a link inside tokenizer/ or at the vision tower's name (the tower off)
# is removed rather than left behind a "models already match" (preflight would refuse it).
"$work/fetch" > /dev/null 2>&1
echo secret > "$work/private"
for planted in tokenizer/merges.txt qwen38-flash-next-vision.hgn; do
  /usr/bin/rm -f "$work/models/$planted"; ln -s "$work/private" "$work/models/$planted"
  "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
  [ ! -L "$work/models/$planted" ] || { echo "a link at $planted was left in place" >&2; exit 1; }
  # A tokenizer file removed is fetched again in the same run (the tower is off: nothing to fetch).
  case "$planted" in tokenizer/*) if grep -q "already match" "$work/out"; then echo "a link at $planted took the fast path" >&2; exit 1; fi ;; esac
done
[ "$(cat "$work/private")" = secret ] || { echo "a write went through a planted link" >&2; exit 1; }
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -q "already match" "$work/out" || { cat "$work/out" >&2; echo "the fast path didn't come back" >&2; exit 1; }
ok "a link in tokenizer/ or at the vision tower's name leaves the fast path and is removed"

echo 'hf_secret123' > "$work/hf-token"; rm "$work/state/fetch-stamp"; : > "$work/podman.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -q "$work/hf-token:/run/secrets/hf-token:ro" "$work/podman.log" && grep -q 'HF_TOKEN_PATH=/run/secrets/hf-token' "$work/podman.log"
if grep -q hf_secret123 "$work/podman.log" "$work/out"; then echo "the token leaked into a command line or log" >&2; exit 1; fi
rm "$work/hf-token"
ok "a Hugging Face token is passed as a read-only file, never as a value"

rm "$work/state/fetch-stamp"; touch "$work/fail-verify"
if "$work/fetch" >/dev/null 2>&1; then echo "verify failure was ignored" >&2; exit 1; fi
[ ! -f "$work/state/fetch-stamp" ]
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
echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"; echo 'HALOGEN_AGENT_GUARD=watch' >> "$work/config.env"
: > "$work/podman.log"
"$work/fetch" > "$work/out" 2>&1 || true
{ grep -q 'NPU_MODELS=embed,halogen-spotter-0.6b' "$work/podman.log" && ! grep -q 'decider-4b' "$work/podman.log"; } \
  || { cat "$work/podman.log" >&2; echo "watch should fetch only the spotter (Halogen 0.20.5 loads decider-4b only for hold)" >&2; exit 1; }
ok "the agent guard's watch mode fetches only the spotter"

echo 'HALOGEN_NPU_MODELS=embed' > "$work/config.env"
rm -rf "$work/models/npu" "$work/state/fetch-stamp"
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
grep -qx '/models/LFM/mine=lfm3' "$work/state/own-bases" || { cat "$work/state/own-bases" >&2; echo "the fetch didn't note which NPU model the checkpoint runs on" >&2; exit 1; }
# The checkpoint is probed offline, with the models read-only and no token; the download never probes.
grep 'FETCH_MODE=probe' "$work/podman.log" > "$work/probe-run" || { echo "the checkpoint was not probed first" >&2; exit 1; }
if ! grep -q -- '--network=none' "$work/probe-run" || ! grep -q -- "-v $work/models:/models:ro" "$work/probe-run"; then
  cat "$work/probe-run" >&2; echo "the probe ran with network or writable models" >&2; exit 1
fi
if grep -q 'hf-token' "$work/probe-run"; then echo "the probe got the HF token" >&2; exit 1; fi
[ ! -e "$work/probe-leak" ] || { echo "the download container probed a checkpoint" >&2; exit 1; }
# A space after the comma still gets the probe (the download splits on spaces too).
echo 'HALOGEN_NPU_MODELS=embed, /models/LFM/mine' > "$work/config.env"
rm -f "$work/state/fetch-stamp"; : > "$work/podman.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "a space after the comma broke the fetch" >&2; exit 1; }
grep -q 'FETCH_MODE=probe' "$work/podman.log" || { echo "a space after the comma skipped the probe" >&2; exit 1; }
# The probe's answers are checked outside it: anything but path=model stops the fetch.
cp "$work/bin/podman" "$work/podman.real"
printf '#!/bin/bash\ncase " $* " in *FETCH_MODE=probe*) echo "/models/LFM/mine=lfm3"; echo "evil"; exit 0 ;; esac\nexec "%s" "$@"\n' "$work/podman.real" > "$work/bin/podman"
rm -f "$work/state/fetch-stamp"
if "$work/fetch" > "$work/out" 2>&1; then echo "a bad probe answer was passed on" >&2; exit 1; fi
grep -q "gave an answer halOS doesn't accept" "$work/out" || { cat "$work/out" >&2; exit 1; }
cp "$work/podman.real" "$work/bin/podman"
echo 'HALOGEN_NPU_MODELS=embed,/models/LFM/mine:fast,/models/LFM/mine' > "$work/config.env"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -qx '/models/LFM/mine:fast=lfm3' "$work/state/own-bases" || { cat "$work/state/own-bases" >&2; echo "the :fast id wasn't noted" >&2; exit 1; }
ok "your own checkpoint gets its NPU programs fetched, and no weights; it is probed offline, and only its plain answers are passed on"
# A machine from before the note: the stamp matches, but there is no .own-bases. Fetch once more.
rm "$work/state/own-bases"; : > "$work/podman.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ -f "$work/state/own-bases" ] || { cat "$work/out" >&2; echo "an unchanged machine never wrote .own-bases" >&2; exit 1; }

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
rm -rf "$work/models/npu" "$work/state/fetch-stamp"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ -f "$work/models/npu/rerank/rerank.hnpw" ] || { echo "rerank was not fetched" >&2; exit 1; }
[ -f "$work/models/npu/embed/devices/d.hnpm" ] || { echo "the programs rerank runs on were not fetched" >&2; exit 1; }
if [ -e "$work/models/npu/embed/embed.hnpw" ]; then echo "the other model's weights were fetched too" >&2; exit 1; fi
ok "a model that runs on another's NPU programs fetches only those programs"

# Some of Halogen's models have no download of their own and reuse others' programs, as
# LFM3-Omni-2B does in 0.19.0. Your own checkpoint of one gets those programs.
mkdir -p "$work/models/LFM/omni"; echo '{}' > "$work/models/LFM/omni/config.json"; echo lfm3-omni > "$work/models/LFM/omni/base"
echo 'HALOGEN_NPU_MODELS=/models/LFM/omni' > "$work/config.env"
rm -rf "$work/models/npu" "$work/state/fetch-stamp"
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
  rm -f "$work/state/fetch-stamp" "$work/last-run"
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
# A checkpoint another command is working on (verify answers 75) is said to be checked at the
# next start, not to have failed.
printf '#!/bin/bash\nexit 75\n' > "$work/flash-tool"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if grep -q 'failed the check' "$work/out" || ! grep -q 'serves it as checked by Halogen 0.0.1, not .*checked again at the next start' "$work/out"; then cat "$work/out" >&2; echo "a busy checkpoint was reported as failed" >&2; exit 1; fi
# shellcheck disable=SC2016 # expanded when the fake runs
printf '#!/bin/bash\necho "flash-tool $*" >> "$FAKE/flash.log"\n' > "$work/flash-tool"
ok "your own Flash checkpoint is checked again after a Halogen update"

# No choice on a machine with less memory than the Flash model needs: Qwen3.8-27B is pulled
# (render-config then serves it), once; a failed pull doesn't stop the start.
rm -f "$work/flash.log" "$work/flash-choice"; printf 'MemTotal:       65536000 kB\n' > "$work/meminfo"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -qx 'flash-tool pull 27b' "$work/flash.log" || { cat "$work/out" >&2; echo "a 64 GiB machine with no choice didn't pull the 27B" >&2; exit 1; }
rm -f "$work/flash.log"; echo auto > "$work/flash-choice"
mkdir -p "$work/models/flash/qwen3.8-27b"; printf 'repo=a/b\nverified=pass\nverified_with=9.9.9\n' > "$work/models/flash/qwen3.8-27b/halos.info"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ ! -e "$work/flash.log" ] || { cat "$work/flash.log" >&2; echo "a 27B already there was pulled or checked again" >&2; exit 1; }
printf 'repo=a/b\nverified=pass\nverified_with=0.0.1\n' > "$work/models/flash/qwen3.8-27b/halos.info"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -qx 'flash-tool verify qwen3.8-27b' "$work/flash.log" || { echo "the 27B chosen by memory wasn't checked again after a Halogen update" >&2; exit 1; }
rm -rf "$work/flash.log" "$work/models/flash/qwen3.8-27b"; echo official > "$work/flash-choice"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
[ ! -e "$work/flash.log" ] || { echo "flash use official still pulled the 27B" >&2; exit 1; }
printf '#!/bin/bash\nexit 1\n' > "$work/flash-tool"; rm -f "$work/flash-choice"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "a failed 27B pull stopped the start" >&2; exit 1; }
grep -q "Qwen3.8-27B didn't download" "$work/out" || { cat "$work/out" >&2; echo "a failed 27B pull wasn't said" >&2; exit 1; }
# shellcheck disable=SC2016 # expanded when the fake runs
printf '#!/bin/bash\necho "flash-tool $*" >> "$FAKE/flash.log"\n' > "$work/flash-tool"
# Owner's choice: such a machine doesn't download the Flash model; flash use official does.
mkdir -p "$work/aside" "$work/models/flash/qwen3.8-27b"; mv "$work/models"/qwen38-flash-next-*.hgn "$work/models/tokenizer" "$work/aside/"
printf 'repo=a/b\nverified=pass\nverified_with=9.9.9\n' > "$work/models/flash/qwen3.8-27b/halos.info"
rm -f "$work/flash-choice" "$work/hf.log" "$work/podman.log"; printf 'MemTotal:       65536000 kB\n' > "$work/meminfo"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "a small machine without the Flash model failed the fetch" >&2; exit 1; }
if grep -qs 'qwen38-flash-next\|tokenizer' "$work/hf.log" || [ -e "$work/models/qwen38-flash-next-v2.hgn" ]; then cat "$work/hf.log" >&2; echo "a small machine downloaded the Flash model" >&2; exit 1; fi
{ grep -q 'SKIP_FLASH=1' "$work/last-run" && grep -q ':/models:ro ' "$work/last-run"; } || { cat "$work/last-run" >&2; echo "the download wasn't told to skip the Flash model, or got the top writable" >&2; exit 1; }
if grep -q ' verify ' "$work/podman.log"; then echo "the missing Flash model was verified" >&2; exit 1; fi
grep -q "not downloading the Flash model" "$work/out" || { cat "$work/out" >&2; echo "skipping the Flash model wasn't said" >&2; exit 1; }
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -q 'models already match this release' "$work/out" || { cat "$work/out" >&2; echo "a small machine fetched again with nothing changed" >&2; exit 1; }
printf '#!/bin/bash\nexit 1\n' > "$work/flash-tool"; mv "$work/models/flash/qwen3.8-27b" "$work/aside/q27"
if "$work/fetch" > "$work/out" 2>&1 || ! grep -q "Halogen can't start" "$work/out"; then cat "$work/out" >&2; echo "a small machine with neither model let Halogen start" >&2; exit 1; fi
mv "$work/aside/q27" "$work/models/flash/qwen3.8-27b"
# shellcheck disable=SC2016 # expanded when the fake runs
printf '#!/bin/bash\necho "flash-tool $*" >> "$FAKE/flash.log"\n' > "$work/flash-tool"
echo official > "$work/flash-choice"; rm -f "$work/hf.log"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
{ grep -q 'qwen38-flash-next-v2.hgn' "$work/hf.log" && ! grep -q 'SKIP_FLASH' "$work/last-run"; } || { cat "$work/out" >&2; echo "flash use official didn't download the Flash model" >&2; exit 1; }
rm -rf "$work/models"/qwen38-flash-next-*.hgn "$work/models/tokenizer" "$work/models/flash/qwen3.8-27b"; mv "$work/aside"/* "$work/models/"; rm -f "$work/state/fetch-stamp"
echo mine > "$work/flash-choice"; printf 'MemTotal:       131072000 kB\n' > "$work/meminfo"
ok "with no choice, a machine under 100 GiB pulls Qwen3.8-27B and skips the Flash model; flash use official downloads it"

# What is fetched doesn't depend on the chosen checkpoint: the official vision tower stays.
echo HALOGEN_VISION_TOWER >> "$work/allowed"; echo 'HALOGEN_VISION_TOWER=1' >> "$work/config.env"
printf 'repo=a/b\ncheckpoint=model.hgn\nverified=pass\nverified_with=9.9.9\n' > "$work/models/flash/mine/halos.info"
touch "$work/models/flash/mine/model.hgn"; rm -f "$work/state/fetch-stamp" "$work/last-run"
"$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
grep -q -- '-e VISION=1 ' "$work/last-run" || { cat "$work/last-run" >&2; echo "choosing a checkpoint without a tower stopped the official one being fetched" >&2; exit 1; }
ok "the official vision tower is fetched whichever checkpoint is chosen"

# A new install's first download waits for setup, until it is done or the time limit passes.
mkdir -p "$work/state"; touch "$work/state/setup-pending"; rm -f "$work/state/fetch-stamp"
HALOGEN_STATE_DIR="$work/state" HALOGEN_SETUP_WAIT_S=0 "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if ! grep -q 'waiting for first-boot setup' "$work/out" || ! grep -q 'no setup after 0 minutes; starting with the defaults' "$work/out"; then
  cat "$work/out" >&2; echo "the time limit didn't release the download" >&2; exit 1
fi
[ ! -e "$work/state/setup-pending" ] || { echo "the marker stayed" >&2; exit 1; }
# Setup finishing while it waits (the fake sleep removes the marker, as halosctl setup would).
touch "$work/state/setup-pending"; rm -f "$work/state/fetch-stamp"
# shellcheck disable=SC2317,SC2329 # called by the fetch script, through export -f
sleep() { rm -f "$FAKE/state/setup-pending"; }; export -f sleep
HALOGEN_STATE_DIR="$work/state" HALOGEN_SETUP_WAIT_S=3600 "$work/fetch" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
if grep -q 'no setup after' "$work/out"; then echo "it waited for the time limit though setup was done" >&2; exit 1; fi
grep -q 'models ready' "$work/out" || { cat "$work/out" >&2; exit 1; }
# shellcheck disable=SC2317,SC2329 # called by the fetch script, through export -f
sleep() { :; }; export -f sleep
ok "the first download waits for setup, and starts when it is done or after the time limit"
