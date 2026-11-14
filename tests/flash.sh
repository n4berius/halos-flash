#!/bin/bash
# halogenctl flash pull and verify's helper against fake podman (hf, Python, Halogen's tools).
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/models/tokenizer" "$work/repo/tokenizer"
export FAKE="$work"
echo '{"official": true}' > "$work/models/tokenizer/tokenizer.json"
echo '{"official vocab": 1}' > "$work/models/tokenizer/vocab.json"; echo '#official merges' > "$work/models/tokenizer/merges.txt"

# The fake repository: its files, and the listing Hugging Face would give for them.
commit=0123456789abcdef0123456789abcdef01234567
put() { mkdir -p "$(dirname "$work/repo/$1")"; printf '%s' "$2" > "$work/repo/$1"; }
listing() {
  echo "commit $commit"
  (cd "$work/repo" && find . -type f | sed 's|^\./||' | sort) | while read -r f; do
    size="$(stat -c %s "$work/repo/$f")"
    blob="$({ printf 'blob %d\0' "$size"; cat "$work/repo/$f"; } | sha1sum | cut -d' ' -f1)"
    case "$f" in *.hgn|*.safetensors) sha="$(sha256sum "$work/repo/$f" | cut -d' ' -f1)" ;; *) sha=- ;; esac
    printf 'file\t%s\t%s\t%s\t%s\n' "$f" "$size" "$sha" "$blob"
  done
}
reset_repo() {
  rm -rf "$work/repo"; mkdir -p "$work/repo"
  put model.hgn checkpoint; put qwen38-flash-next-ngram.hgn table; put qwen38-flash-next-vision.hgn eyes
  put tokenizer/tokenizer.json '{"custom": true}'; put tokenizer/chat_template.jinja '{{ x }}'
  put tokenizer/evil.py 'import os'; put README.md hello; put model.safetensors.bin pickle
}

cat > "$work/bin/podman" <<'S'
#!/bin/bash
# Plays the pinned image: /models is the test's folder, and the entrypoint picks the tool.
echo "podman $*" >> "$FAKE/podman.log"
[ "$1" = run ] || exit 0
shift; entry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --entrypoint) entry="$2"; shift 2 ;;
    -v|-e|--tmpfs|--security-opt|--cap-drop|--device|--group-add|--ulimit) shift 2 ;;
    -*) shift ;;
    *) shift; break ;;
  esac
done
case "$entry" in
  python3) cat > /dev/null; if [ -n "${FAKE_HUB_ERROR:-}" ]; then echo "error $FAKE_HUB_ERROR"; else cat "$FAKE/listing"; fi ;;
  hf) shift; shift; files=(); dir=""; rev=""
      while [ $# -gt 0 ]; do case "$1" in
        --local-dir) dir="${2/\/models/$FAKE/models}"; shift 2 ;; --revision) rev="$2"; shift 2 ;;
        *) files+=("$1"); shift ;; esac; done
      echo "hf $rev ${files[*]}" >> "$FAKE/hf.log"
      echo "Hint: update hf"
      for f in "${files[@]}"; do mkdir -p "$(dirname "$dir/$f")"; cp "$FAKE/repo/$f" "$dir/$f"; done
      [ -z "${FAKE_CORRUPT:-}" ] || printf 'x' >> "$dir/$FAKE_CORRUPT" ;;
  /usr/local/bin/flash_serve) echo "loading"; echo "${FAKE_FACTS-61.2 0 1}" ;;
  "") if [ "$1" = ppl ]; then
        echo "ppl ${*:2}" >> "$FAKE/ppl.log"; echo "halogen ppl: prose" >&2
        [ "$2" != "${FAKE_PPL_FAIL:-none}" ] || exit 1
        out=""; prev=""; for a in "$@"; do [ "$prev" != --ref-out ] || out="$a"; prev="$a"; done
        if [ -n "$out" ]; then echo ref > "${out/\/models/$FAKE/models}"; echo '{"file":"o","tokens":297052,"ppl":3.8522}'
        else echo '{"file":"m","tokens":297052,"ppl":3.8109,"ref":{"topk":128,"kl":{"mean":0.136478,"median":0.045499,"p90":0.3,"p99":1.444613,"max":11.7},"top1_agreement":0.86463}}'; fi
        exit 0
      fi
      [ "$1" = verify ] || exit 9; echo "verify $2" >> "$FAKE/verify.log"
      case "$2" in *"${FAKE_BAD:-none}"*) echo "FAIL $2"; exit 1 ;; *) echo "PASS $2" ;; esac ;;
  *) exit 9 ;;
esac
S
cat > "$work/bin/df" <<'S'
#!/bin/bash
printf 'Avail\n%s\n' "${FAKE_FREE:-999999999999}"
S
chmod +x "$work/bin/podman" "$work/bin/df"
printf 'HALOGEN_IMAGE=img@sha256:1\nHALOGEN_VERSION=9.9.9\nHALOGEN_VARIANT=no-npu\n' > "$work/release.env"
export HALOGEN_FLASH_FILE="$work/flash-checkpoint"
export PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_MODELS_DIR="$work/models" \
  HALOGEN_HF_TOKEN_FILE="$work/none" HALOGEN_PROGRESS_S=0
tool="$repo/files/usr/libexec/halogen/flash-checkpoint"
ok() { echo "ok: $*"; }
fail() { echo "$*" >&2; [ ! -f "$work/out" ] || cat "$work/out" >&2; exit 1; }
info() { sed -n "s/^$2=//p" "$work/models/flash/$1/halos.info"; }
pull() { listing > "$work/listing"; : > "$work/hf.log"; : > "$work/verify.log"; "$tool" pull "$@" > "$work/out" 2>&1; }

reset_repo
pull someone/My-Flash-HGN --as mine || fail "a good pull failed"
d="$work/models/flash/mine"
{ [ "$(cat "$d/model.hgn")" = checkpoint ] && [ "$(cat "$d/qwen38-flash-next-ngram.hgn")" = table ]; } || fail "files missing"
{ [ -f "$d/qwen38-flash-next-vision.hgn" ] && grep -q custom "$d/tokenizer/tokenizer.json"; } || fail "vision or tokenizer missing"
{ [ ! -e "$d/README.md" ] && [ ! -e "$d/model.safetensors.bin" ] && [ ! -e "$d/tokenizer/evil.py" ]; } || fail "files Halogen doesn't load were downloaded"
grep -qx "hf $commit model.hgn qwen38-flash-next-vision.hgn tokenizer/chat_template.jinja tokenizer/tokenizer.json" "$work/hf.log" || fail "not fetched at the exact commit: $(cat "$work/hf.log")"
{ [ "$(info mine repo)" = someone/My-Flash-HGN ] && [ "$(info mine commit)" = "$commit" ] && [ "$(info mine checkpoint)" = model.hgn ]; } || fail "info wrong"
{ [ "$(info mine verified)" = pass ] && [ "$(info mine verified_with)" = 9.9.9 ]; } || fail "verify not recorded"
grep -qx "verify /models/flash/mine/model.hgn" "$work/verify.log" || fail "the checkpoint was not verified"
if grep -q ngram "$work/verify.log"; then fail "verify was given the lookup table, which it doesn't take"; fi
grep -qx 'name=mine' "$work/out" || fail "no name line"
if grep -q '^Hint' "$work/out"; then fail "hf noise reached the output"; fi
grep 'podman run' "$work/podman.log" | grep ' verify ' | grep -q -- '--network=none --cap-drop=all' || fail "verify was not offline and without capabilities"
grep 'podman run' "$work/podman.log" | grep -- '--entrypoint hf' > "$work/runs"
grep -q -- '--cap-drop=all' "$work/runs" || fail "the download kept capabilities"
if grep -v -- "-v $work/models/flash/mine:/models/flash/mine " "$work/runs" | grep -q .; then fail "the download saw more than its own folder"; fi
grep 'podman run' "$work/podman.log" | grep -- '--entrypoint python3' > "$work/runs"
if grep -q -- ' -v ' "$work/runs"; then fail "the listing had a folder mounted"; fi
grep 'podman run' "$work/podman.log" | grep -e ' verify ' -e flash_serve > "$work/runs"
if grep -q -- '--network=none --cap-drop=all' "$work/runs"; then :; else fail "a check tool had network or capabilities"; fi
if grep -v -- "-v $work/models:/models:ro " "$work/runs" | grep -q .; then fail "a check tool could write the models"; fi
ok "a pull fetches only what Halogen loads, at the exact commit, checks it and records it"

# A checkpoint that carries its own lookup table doesn't need the 48 GB file.
FAKE_FACTS='61.2 1 1' pull someone/My-Flash-HGN --as own-table || fail "pull failed"
[ ! -e "$work/models/flash/own-table/qwen38-flash-next-ngram.hgn" ] || fail "the table was downloaded though the checkpoint carries one"
rm "$work/repo/qwen38-flash-next-ngram.hgn"
if FAKE_FACTS='61.2 0 1' pull someone/No-Table --as no-table; then fail "a checkpoint with no table anywhere was accepted"; fi
grep -q 'needs a lookup table' "$work/out" || fail "no explanation"
ok "the lookup table is fetched only when the checkpoint needs it, and a missing one is refused"

reset_repo; rm -r "$work/repo/tokenizer"
pull someone/No-Tokenizer --as no-tok || fail "pull failed"
{ grep -q official "$work/models/flash/no-tok/tokenizer/tokenizer.json" && [ ! -L "$work/models/flash/no-tok/tokenizer" ]; } || fail "official tokenizer not copied"
ok "a repository without a tokenizer gets a copy of the official one"
# A tokenizer/ with only a chat template and settings (Signal-3.8-Flash-Next-HGN-v2) gets the
# official vocabulary; its own chat template stays. A checkpoint pulled before the fix is filled
# in by verify.
reset_repo; rm "$work/repo/tokenizer/tokenizer.json"; put tokenizer/tokenizer_config.json '{"own": 1}'
pull someone/Half-Tokenizer --as half > "$work/out" 2>&1 || { cat "$work/out" >&2; fail "pull failed"; }
d="$work/models/flash/half/tokenizer"
{ grep -q official "$d/tokenizer.json" && grep -q official "$d/vocab.json" && grep -q official "$d/merges.txt" && grep -q own "$d/tokenizer_config.json" && [ -f "$d/chat_template.jinja" ]; } || fail "the vocabulary wasn't added, or the repository's own files were replaced"
grep -q 'official vocabulary was added (tokenizer.json vocab.json merges.txt)' "$work/out" || fail "the pull didn't say what it added"
# A pull again drops the added files with everything the repository lacks, and puts them back.
pull someone/Half-Tokenizer --as half > "$work/out" 2>&1 || { cat "$work/out" >&2; fail "the second pull failed"; }
grep -q official "$d/tokenizer.json" || fail "a pull again lost the added vocabulary"
[ "$(info half verified)" = pass ] || fail "a filled-in tokenizer didn't pass"
rm "$d/tokenizer.json"; "$tool" verify half > "$work/out" 2>&1 || { cat "$work/out" >&2; fail "verify didn't fill in the tokenizer"; }
grep -q official "$d/tokenizer.json" || fail "verify didn't add the vocabulary"
mv "$work/models/tokenizer/tokenizer.json" "$work/tok.bak"; rm "$d/tokenizer.json"
if "$tool" verify half > "$work/out" 2>&1; then fail "a checkpoint with no tokenizer.json passed"; fi
[ "$(info half verified)" = fail ] || fail "it wasn't recorded as failed, so flash use would switch to it"
mv "$work/tok.bak" "$work/models/tokenizer/tokenizer.json"
# A repository with a vocabulary of its own but no tokenizer.json is not mixed with the official one.
reset_repo; rm "$work/repo/tokenizer/tokenizer.json"; put tokenizer/vocab.json '{"own vocab": 1}'
if pull someone/Own-Vocab --as ownvocab > "$work/out" 2>&1; then fail "a vocabulary of its own was mixed with the official tokenizer"; fi
grep -q 'vocabulary of its own (vocab.json)' "$work/out" || { cat "$work/out" >&2; fail "no explanation"; }
[ ! -e "$work/models/flash/ownvocab/tokenizer/tokenizer.json" ] || fail "the official tokenizer.json was added beside its own vocabulary"
[ "$(info ownvocab verified)" = fail ] || fail "it wasn't recorded as failed"
ok "a tokenizer without tokenizer.json gets the official vocabulary, and one still without it, or with its own vocabulary, fails verify"

reset_repo
if FAKE_CORRUPT=model.hgn pull someone/Corrupt --as corrupt; then fail "a file with the wrong hash was accepted"; fi
{ grep -q "does not match" "$work/out" && [ ! -f "$work/models/flash/corrupt/halos.info" ]; } || fail "a bad file was recorded"
if FAKE_BAD=model.hgn pull someone/Bad --as bad; then fail "a file that fails verify was accepted"; fi
[ "$(info bad verified)" = fail ] || fail "the failed verify was not recorded"
ok "a file that differs from the repository or fails Halogen's verify can't be used"

put other.hgn second
if pull someone/Two; then fail "an ambiguous repository was accepted"; fi
grep -q 'several checkpoints.*model.hgn.*other.hgn' "$work/out" || fail "the choices were not listed"
pull someone/Two --file other.hgn --as two || fail "--file was refused"
{ [ "$(info two checkpoint)" = other.hgn ] && [ ! -e "$work/models/flash/two/model.hgn" ]; } || fail "the wrong checkpoint was fetched"
rm -rf "$work/repo"; mkdir -p "$work/repo"; put Model-Q4-00001-of-00002.gguf g
if pull someone/Gguf; then fail "a GGUF repository was accepted"; fi
grep -q "GGUF" "$work/out" || fail "no GGUF explanation"
ok "several checkpoints need --file, and GGUF repositories are explained"

reset_repo
for bad in '--as ../x' '--as official' '--as .hidden' '--revision -x' "--as a;b"; do
  # shellcheck disable=SC2086 # split on purpose: option and value
  if pull someone/Good $bad; then fail "accepted: $bad"; fi
done
if pull 'some one/x'; then fail "a bad repository name was accepted"; fi
if pull someone/Other --as mine; then fail "a name holding another repository was reused"; fi
grep -q 'already holds someone/My-Flash-HGN' "$work/out" || fail "no explanation"
{ [ ! -e "$work/models/flash/x" ] && [ ! -e "$work/models/x" ]; } || fail "something was created outside"
ok "names and revisions are checked, and a name holding another repository isn't overwritten"

if FAKE_FREE=1000 pull someone/Big --as big; then fail "a pull with no room was started"; fi
{ grep -q 'more and .* free' "$work/out" && [ ! -s "$work/hf.log" ]; } || fail "it downloaded before checking the room"
if FAKE_HUB_ERROR='401 Client Error' pull someone/Private --as private; then fail "a hub error was ignored"; fi
grep -q 'hf-token' "$work/out" || fail "no hint about a token"
ok "the free space is checked before the first byte, and hub errors are explained"

: > "$work/verify.log"
FAKE_BAD=model.hgn "$tool" verify bad > "$work/out" 2>&1 && fail "verify of a bad file passed"
[ "$(info bad verified)" = fail ]
"$tool" verify mine > "$work/out" 2>&1 || fail "verify of a good file failed"
{ [ "$(info mine verified)" = pass ] && [ "$(grep -c . "$work/verify.log")" -ge 3 ]; } || fail "verify again did not check every file"
"$tool" verify ../mine > "$work/out" 2>&1 && fail "verify took a path"
ok "verify checks a pulled checkpoint again and records the answer"

# Pulling again: never the one Halogen serves, and unchecked from the first byte until it passes.
echo mine > "$work/flash-checkpoint"
if pull someone/My-Flash-HGN --as mine; then fail "the served checkpoint was replaced"; fi
grep -q 'Switch first' "$work/out" || fail "no explanation"
echo official > "$work/flash-checkpoint"
if FAKE_CORRUPT=model.hgn pull someone/My-Flash-HGN --as mine; then fail "a corrupt update was accepted"; fi
[ "$(info mine verified)" = no ] || fail "a failed update left the old verified mark"
pull someone/My-Flash-HGN --as mine || fail "a clean update failed"
[ "$(info mine verified)" = pass ] || fail "a clean update was not marked verified"
if FAKE_CORRUPT=tokenizer/tokenizer.json pull someone/My-Flash-HGN --as mine; then fail "a changed tokenizer file was accepted"; fi
ok "pulling again never replaces the served checkpoint, and an update is unchecked until it passes"

# Links are never checked or served, and an empty folder never passes.
pull someone/My-Flash-HGN --as linked > /dev/null || fail "pull failed"
rm "$work/models/flash/linked/model.hgn"; ln -s /etc/hostname "$work/models/flash/linked/model.hgn"
if "$tool" verify linked > "$work/out" 2>&1; then fail "a link passed verify"; fi
mkdir -p "$work/models/flash/empty"; printf 'repo=a/b\nverified=pass\n' > "$work/models/flash/empty/halos.info"
if "$tool" verify empty > "$work/out" 2>&1; then fail "a folder with no checkpoint passed verify"; fi
[ "$(info empty verified)" = fail ] || fail "the empty folder was not marked failed"
for bad in -x _x; do if "$tool" pull someone/X --as "$bad" > "$work/out" 2>&1; then fail "the name $bad was accepted"; fi; done
ok "links and empty folders fail verify, and names start with a letter or digit"

# A new commit without a file an older pull had: the old file goes, so it can't be loaded.
reset_repo; put model.overlay.hgn sidecar
pull someone/Sidecar --as side || fail "pull failed"
[ -f "$work/models/flash/side/model.overlay.hgn" ] || fail "the overlay was not fetched"
grep -q 'model.overlay.hgn' "$work/hf.log" || fail "the overlay was not requested"
rm "$work/repo/model.overlay.hgn" "$work/repo/tokenizer/chat_template.jinja"
pull someone/Sidecar --as side || fail "the second pull failed"
if [ -e "$work/models/flash/side/model.overlay.hgn" ] || [ -e "$work/models/flash/side/tokenizer/chat_template.jinja" ]; then
  fail "files from the older commit were left beside the new checkpoint"
fi
ok "files an older pull left behind are removed"

# A lookup table identical to the official one is shared, not downloaded again.
reset_repo; cp "$work/repo/qwen38-flash-next-ngram.hgn" "$work/models/qwen38-flash-next-ngram.hgn"
pull someone/Same-Table --as same || fail "pull failed"
[ "$(stat -c %i "$work/models/flash/same/qwen38-flash-next-ngram.hgn")" = "$(stat -c %i "$work/models/qwen38-flash-next-ngram.hgn")" ] || fail "the table was not shared"
if grep -q ngram "$work/hf.log"; then fail "the shared table was downloaded"; fi
printf 'other' > "$work/models/qwen38-flash-next-ngram.hgn"
pull someone/Same-Table --as differs || fail "pull failed"
grep -q ngram "$work/hf.log" || fail "a different table was not downloaded"
ok "a lookup table identical to the official one is shared rather than downloaded"

# A new commit with a different lookup table replaces the old one, never writing through a link.
reset_repo; cp "$work/repo/qwen38-flash-next-ngram.hgn" "$work/models/qwen38-flash-next-ngram.hgn"
pull someone/Moving-Table --as moving || fail "pull failed"
put qwen38-flash-next-ngram.hgn newtab
pull someone/Moving-Table --as moving || fail "a new table was not taken"
[ "$(cat "$work/models/flash/moving/qwen38-flash-next-ngram.hgn")" = newtab ] || fail "the old table stayed"
[ "$(cat "$work/models/qwen38-flash-next-ngram.hgn")" = table ] || fail "the official table was changed"
ok "a new commit's lookup table replaces the old one, and the official table is never changed"


# flash check: Halogen's ppl against a reference dump of the official checkpoint, on wikitext-2.
cat > "$work/bin/curl" <<'S'
#!/bin/bash
echo "curl $*" >> "$FAKE/curl.log"
[ -z "${FAKE_CURL_FAIL:-}" ] || exit 22
case "$*" in
  *offset=0\&*) echo '{"num_rows_total":200,"rows":[{"row":{"text":""}},{"row":{"text":" = A = \n"}}]}' ;;
  *) echo '{"num_rows_total":200,"rows":[{"row":{"text":" b \n"}}]}' ;;
esac
S
chmod +x "$work/bin/curl"
corpus=$' = A = \n b \n'
HALOGEN_CORPUS_SHA="$(printf '%s' "$corpus" | sha256sum | cut -d' ' -f1)"
export HALOGEN_CORPUS_SHA HALOGEN_CORPUS_URL="https://x/rows?d=1"
sed -i 's/^verified=.*/verified=pass/' "$work/models/flash/mine/halos.info"
: > "$work/ppl.log"
"$tool" check mine > "$work/out" 2>&1 || fail "a check failed"
[ "$(cat "$work/models/flash/.check/wikitext-2-raw-test.txt")" = "$(printf '%s' "$corpus")" ] || fail "the text was not joined from its pages"
[ -f "$work/models/flash/.check/official-9.9.9.ref" ] || fail "no reference dump"
grep -q '^ppl /models/qwen38-flash-next-v2.hgn --corpus /models/flash/.check/wikitext-2-raw-test.txt --ref-out /models/flash/.check/official-9.9.9.ref.new --json$' "$work/ppl.log" || fail "the official run was wrong: $(cat "$work/ppl.log")"
grep -q '^ppl /models/flash/mine/model.hgn --corpus .* --ref /models/flash/.check/official-9.9.9.ref --worst 5 --json$' "$work/ppl.log" || fail "the checkpoint run was wrong"
{ [ "$(info mine checked_ppl)" = 3.8109 ] && [ "$(info mine checked_official_ppl)" = 3.8522 ] && [ "$(info mine checked_kl_median)" = 0.045499 ] && [ "$(info mine checked_with)" = 9.9.9 ]; } || fail "the result was not recorded"
grep -qE 'perplexity +3\.81 +official 3\.85 ' "$work/out" || fail "no perplexity line"
grep -qE 'same next token +86\.5%' "$work/out" || fail "no agreement line"
grep -q 'median 0.045, mean 0.136, p99 1.44' "$work/out" || fail "no KL line"
grep 'podman run' "$work/podman.log" | grep ' ppl ' > "$work/runs"
grep ' --ref-out ' "$work/runs" | grep -q -- "-v $work/models:/models:ro --tmpfs /models/.prompt-cache:ro,size=4k,notmpcopyup -v $work/models/flash/.check:/models/flash/.check:rw -v $work/models/tokenizer:/tokenizer:ro -e HALOGEN_TOKENIZER=/tokenizer --network=none --cap-drop=all" \
  || fail "the official run had more than the GPU, read-only models with the prompt cache hidden, its own folder and the official tokenizer: $(head -n 1 "$work/runs")"
grep ' --ref ' "$work/runs" | grep -q -- "-v $work/models/flash/.check:/models/flash/.check:ro -v $work/models/tokenizer:/tokenizer:ro " \
  || fail "the checkpoint's run could write the reference, or read another tokenizer"
ok "flash check measures against the official checkpoint offline, with the official tokenizer, and records the result"

: > "$work/ppl.log"; : > "$work/curl.log"
"$tool" check mine > "$work/out" 2>&1 || fail "a second check failed"
if grep -q -- '--ref-out' "$work/ppl.log"; then fail "the official checkpoint was measured again"; fi
[ ! -s "$work/curl.log" ] || fail "the text was downloaded again"
rm "$work/models/flash/.check/wikitext-2-raw-test.txt"
if HALOGEN_CORPUS_SHA=0000 "$tool" check mine > "$work/out" 2>&1; then fail "a text with the wrong hash was used"; fi
grep -q "didn't match its known hash" "$work/out" || fail "no hash message"
[ ! -e "$work/models/flash/.check/wikitext-2-raw-test.txt" ] || fail "a bad text was kept"
if FAKE_CURL_FAIL=1 "$tool" check mine > "$work/out" 2>&1; then fail "a failed download passed"; fi
sed -i 's/^verified=.*/verified=fail/' "$work/models/flash/mine/halos.info"
if "$tool" check mine > "$work/out" 2>&1; then fail "checked an unverified checkpoint"; fi
sed -i 's/^verified=.*/verified=pass/' "$work/models/flash/mine/halos.info"
for bad in ../x official .hidden; do
  if "$tool" check "$bad" > "$work/out" 2>&1; then fail "took the name $bad"; fi
done
rm -f "$work/models/flash/.check/official-9.9.9.ref" "$work/models/flash/.check/official-9.9.9.json"
if FAKE_PPL_FAIL=/models/qwen38-flash-next-v2.hgn "$tool" check mine > "$work/out" 2>&1; then fail "a failed reference run passed"; fi
[ ! -e "$work/models/flash/.check/official-9.9.9.ref" ] || fail "a failed reference run left a dump"
ok "flash check reuses the reference and text, refuses a wrong text, an unverified checkpoint and bad names, and keeps no half results"

# Converting full-precision weights (halogenctl flash convert): a fake bf16-to-hgn that writes the
# layout the real one publishes, and a systemd-run that records the sandbox it was run in.
cat > "$work/bin/b2h" <<'S'
#!/bin/bash
echo "b2h $*" >> "$FAKE/b2h.log"
cmd="$1"; shift; src=""; out=""
while [ $# -gt 0 ]; do case "$1" in --source) src="$2"; shift 2 ;; --output) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -f "$src/model.safetensors.index.json" ] || { echo "missing index" >&2; exit 1; }
case "$cmd" in
  convert) [ -z "${FAKE_CONVERT_FAIL:-}" ] || { echo "error: unsupported tensor" >&2; exit 1; }
    mkdir -p "$out/tokenizer"; echo converted > "$out/model.hgn"; echo table > "$out/qwen38-flash-next-ngram.hgn"
    echo eyes > "$out/qwen38-flash-next-vision.hgn"; cp "$src/tokenizer.json" "$out/tokenizer/"; cp "$src/config.json" "$out/"
    echo '{"schema": 2}' > "$out/conversion-manifest.json"; echo '{"published": true}' ;;
  verify) echo '{"ok": true}' ;;
esac
S
cat > "$work/bin/sdrun" <<'S'
#!/bin/bash
echo "systemd-run $*" >> "$FAKE/sdrun.log"
while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; -*) shift ;; *) break ;; esac; done; exec "$@"
S
chmod +x "$work/bin/b2h" "$work/bin/sdrun"
export HALOS_BF16_TO_HGN="$work/bin/b2h" HALOS_SYSTEMD_RUN="$work/bin/sdrun" HALOS_CONVERT_OUT_BYTES=1000
bf16_repo() { # mtp vision: whether the index lists them
  rm -rf "$work/repo"; mkdir -p "$work/repo"
  put config.json '{"architectures": ["Qwen4ExpForConditionalGeneration"], "model_type": "qwen4_exp"}'
  local keys='"model.layers.0.mlp.gate.weight": "model-00001-of-00002.safetensors"'
  [ "$1" != 1 ] || keys+=', "mtp.layers.0.mlp.gate.weight": "model-00002-of-00002.safetensors"'
  [ "$2" != 1 ] || keys+=', "model.visual.blocks.0.attn.qkv.weight": "model-00002-of-00002.safetensors"'
  put model.safetensors.index.json "{\"weight_map\": {$keys}}"
  for f in tokenizer.json tokenizer_config.json chat_template.jinja merges.txt generation_config.json; do put "$f" "{\"$f\": 1}"; done
  put model-00001-of-00002.safetensors weights1; put model-00002-of-00002.safetensors weights2; put README.md hi
}
prepare() { listing > "$work/listing"; : > "$work/hf.log"; "$tool" convert-prepare "$@" > "$work/out" 2>&1; }
run() { listing > "$work/listing"; : > "$work/hf.log"; : > "$work/verify.log"; : > "$work/b2h.log"; : > "$work/sdrun.log"; "$tool" convert-run "$@" > "$work/out" 2>&1; }

bf16_repo 1 1
prepare someone/Flash-BF16 --as conv || fail "a good convert-prepare failed"
grep -qx 'name=conv' "$work/out" || fail "no name"
src="$work/models/flash/.convert/conv/source"
{ [ -f "$src/config.json" ] && [ -f "$src/chat_template.jinja" ] && [ ! -e "$src/model-00001-of-00002.safetensors" ]; } \
  || fail "prepare should fetch only the small files"
grep -q "hf $commit model.safetensors.index.json config.json" "$work/hf.log" || fail "small files not fetched at the commit: $(cat "$work/hf.log")"
prepare someone/Flash-BF16 --as conv2 || fail "a second prepare failed"
grep -q '^download=' "$work/out" || fail "no sizes"
rm -rf "$work/models/flash/.convert/conv2"
# Another repository under the same name starts from nothing: no tokenizer file of the first.
echo stale > "$src/vocab.json"
prepare someone/Other-Flash-BF16 --as conv || fail "a prepare of another repo failed"
[ ! -e "$src/vocab.json" ] || fail "a file of another repository stayed in the source"
prepare someone/Flash-BF16 --as conv > /dev/null || fail "prepare again failed"
ok "convert-prepare fetches only the small files, at the exact commit, and says what the conversion needs"

for case in "0 1:MTP head" "1 0:vision tower"; do
  read -r mtp vision <<< "${case%%:*}"; bf16_repo "$mtp" "$vision"
  if prepare someone/Flash-BF16 --as part; then fail "an incomplete model was taken"; fi
  grep -q "no ${case#*:}" "$work/out" || fail "expected 'no ${case#*:}'"
  [ ! -e "$work/models/flash/.convert/part/source/model-00001-of-00002.safetensors" ] || fail "weights downloaded for a refused model"
done
bf16_repo 1 1; put config.json '{"architectures": ["LlamaForCausalLM"], "model_type": "llama"}'
if prepare someone/Llama --as llama; then fail "another model was taken"; fi
grep -q "isn't Qwen3.8 Flash Next weights (model_type llama)" "$work/out" || fail "wrong message for another model"
# The index names the weights: a file it doesn't name is ignored, one the repository lacks refused.
bf16_repo 1 1; put extra.safetensors junk; put sub/other.safetensors junk
prepare someone/Flash-BF16 --as extra || fail "unrelated safetensors files refused: $(cat "$work/out")"
grep -qx 'download=.*' "$work/out"; rm -rf "$work/models/flash/.convert/extra"
rm "$work/repo/model-00002-of-00002.safetensors"
if prepare someone/Flash-BF16 --as gone; then fail "a shard the repository lacks was taken"; fi
grep -q "names model-00002-of-00002.safetensors, which the repository doesn't have" "$work/out" || fail "missing shard not named"
bf16_repo 1 1; rm "$work/repo/chat_template.jinja"
if prepare someone/Flash-BF16 --as noasset; then fail "a repo without chat_template.jinja was taken"; fi
grep -q 'lacks chat_template.jinja' "$work/out" || fail "missing asset not named"
bf16_repo 1 1
if FAKE_FREE=100 prepare someone/Flash-BF16 --as small; then fail "too little disk was accepted"; fi
grep -q 'free' "$work/out" || fail "disk shortage not said"
mkdir -p "$work/models/flash/taken"
if prepare someone/Flash-BF16 --as taken; then fail "an existing name was reused"; fi
rmdir "$work/models/flash/taken"
ok "convert-prepare refuses another model, one without an MTP head or vision tower, a missing asset, too little disk and a taken name, before any weights download"

run conv --threads 3 || fail "a good conversion failed"
out="$work/models/flash/conv"
{ [ "$(cat "$out/model.hgn")" = converted ] && [ -f "$out/qwen38-flash-next-vision.hgn" ]; } || fail "no output"
grep -q "hf $commit model-00001-of-00002.safetensors model-00002-of-00002.safetensors" "$work/hf.log" || fail "weights not fetched at the commit"
grep -q 'convert --source .* --output .*/flash/.convert/conv/out/conv --profile v2 --threads 3' "$work/b2h.log" || fail "converter args: $(cat "$work/b2h.log")"
grep -q '^b2h verify' "$work/b2h.log" || fail "bf16-to-hgn's verify didn't run"
# Both runs in their own unit: no network, no sockets (the user manager's would reach out), the
# settings and halogen's home hidden, only the work folder writable.
[ "$(grep -c -- '-p PrivateNetwork=yes -p SystemCallFilter=~socket socketpair -p SystemCallErrorNumber=EAFNOSUPPORT' "$work/sdrun.log")" = 2 ] || fail "the converter ran with network: $(cat "$work/sdrun.log")"
grep -q -- '-p InaccessiblePaths=-[^ ]*configs -' "$work/sdrun.log" || fail "the settings were visible: $(cat "$work/sdrun.log")"
grep -q -- "-p ReadWritePaths=$(readlink -f "$work/models/flash/.convert/conv") " "$work/sdrun.log" || fail "wrong writable folder"
grep -q -- '-p BindsTo=halogen-flash-convert.service' "$work/sdrun.log" || fail "the sandbox outlives the job"
[ ! -e "$work/models/flash/.convert/conv/out" ] || fail "the staging folder stayed"
{ [ "$(info conv checkpoint)" = model.hgn ] && [ "$(info conv verified)" = pass ] && [ "$(info conv commit)" = "$commit" ]; } || fail "halos.info: $(cat "$out/halos.info")"
info conv converted_with | grep -q '^bf16-to-hgn ' || fail "no converted_with"
grep -q 'model.hgn' "$work/verify.log" || fail "Halogen's verify skipped model.hgn"
grep -q 'vision' "$work/verify.log" || fail "Halogen's verify skipped the vision tower"
if grep -q ngram "$work/verify.log"; then fail "the table went to Halogen's verify"; fi
[ ! -e "$work/models/flash/.convert/conv" ] || fail "the downloaded weights stayed"
grep -q 'flash check conv' "$work/out" || fail "no pointer to flash check"
ok "convert-run downloads the weights at the commit, converts and verifies without network, checks with Halogen's verify, records it and frees the weights"

rm -rf "$out"; prepare someone/Flash-BF16 --as conv > /dev/null
run conv --keep-source || fail "--keep-source failed"
[ -f "$work/models/flash/.convert/conv/source/model-00001-of-00002.safetensors" ] || fail "--keep-source didn't keep the weights"
rm -rf "$out" "$work/models/flash/.convert"; prepare someone/Flash-BF16 --as conv > /dev/null
if FAKE_CORRUPT=model-00002-of-00002.safetensors run conv; then fail "a corrupt download was converted"; fi
grep -q "does not match" "$work/out" || fail "corruption not named"; [ ! -e "$out" ] || fail "output from a corrupt download"
rm -rf "$work/models/flash/.convert"; prepare someone/Flash-BF16 --as conv > /dev/null
if FAKE_CONVERT_FAIL=1 run conv; then fail "a failed conversion passed"; fi
grep -q 'unsupported tensor' "$work/out" || fail "the converter's error wasn't shown"
grep -q 'start it again to retry' "$work/out" || fail "the retry wasn't explained"
[ ! -e "$out" ] || fail "output from a failed conversion"
if run conv --threads 99; then fail "took 99 threads"; fi
ok "convert-run keeps the weights when asked, and refuses a corrupt download, a failed conversion and bad options"

