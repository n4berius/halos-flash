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
    case "$f" in *.hgn|*.safetensors|*.gguf) sha="$(sha256sum "$work/repo/$f" | cut -d' ' -f1)" ;; *) sha=- ;; esac
    printf 'file\t%s\t%s\t%s\t%s\n' "$f" "$size" "$sha" "$blob"
  done
}
reset_repo() {
  rm -rf "$work/repo"; mkdir -p "$work/repo"
  put model.hgn checkpoint; put qwen38-flash-next-ngram.hgn table; put qwen38-flash-next-vision.hgn eyes
  put qwen38-flash-next-drafter-r2.hgn drafter   # Peonist's layout since Halogen 0.20.6: not a checkpoint
  put tokenizer/tokenizer.json '{"custom": true}'; put tokenizer/chat_template.jinja '{{ x }}'
  put tokenizer/evil.py 'import os'; put README.md hello; put model.safetensors.bin pickle
}

cat > "$work/bin/podman" <<'S'
#!/bin/bash
# Plays the pinned image: /models is the test's folder, and the entrypoint picks the tool.
echo "podman $*" >> "$FAKE/podman.log"
# The pull lock (fd 9) must not reach podman: its conmon would hold it after a hard kill.
[ ! -e /proc/self/fd/9 ] || echo "podman $*" >> "$FAKE/fd9.log"
# Removing the container ends a "container" that ignores SIGTERM (FAKE_HANG below).
if [ "$1" = rm ] && [ -s "$FAKE/hang.pid" ]; then kill -9 "$(cat "$FAKE/hang.pid")" 2> /dev/null; fi
[ "$1" = run ] || exit 0
shift; entry=""; vols=()
while [ $# -gt 0 ]; do
  case "$1" in
    --entrypoint) entry="$2"; shift 2 ;;
    -v) vols+=("$2"); shift 2 ;;
    -e) case "$2" in HALOGEN_MTP_HEAD=*) HALOGEN_MTP_HEAD_SEEN="${2#*=}" ;; esac; shift 2 ;;
    --tmpfs|--security-opt|--cap-drop|--device|--group-add|--ulimit|--name) shift 2 ;;
    -*) shift ;;
    *) shift; break ;;
  esac
done
# FAKE_HANG=<entrypoint>: that step's "container" ignores SIGTERM until it is removed.
if [ -n "${FAKE_HANG:-}" ] && [ "$FAKE_HANG" = "$entry" ]; then trap '' TERM INT HUP; sleep 30 & echo "$!" > "$FAKE/hang.pid"; wait; exit 1; fi
case "$entry" in
  python3) cat > /dev/null
           if [ -n "${FAKE_HUB_ERROR:-}" ]; then echo "error $FAKE_HUB_ERROR"
           elif [ -f "$FAKE/listing-${2//\//_}" ]; then cat "$FAKE/listing-${2//\//_}"; else cat "$FAKE/listing"; fi ;;
  hf) shift; from="$FAKE/repo"; [ "$1" != weights/repo ] || from="$FAKE/weights"; shift; files=(); dir=""; rev=""
      while [ $# -gt 0 ]; do case "$1" in
        --local-dir) dir="${2/\/models/$FAKE/models}"; shift 2 ;; --revision) rev="$2"; shift 2 ;;
        *) files+=("$1"); shift ;; esac; done
      echo "hf $rev ${files[*]}" >> "$FAKE/hf.log"
      echo "Hint: update hf"
      for f in "${files[@]}"; do mkdir -p "$(dirname "$dir/$f")"; cp "$from/$f" "$dir/$f"; done
      [ -z "${FAKE_CORRUPT:-}" ] || printf 'x' >> "$dir/$FAKE_CORRUPT"
      # What a hostile download could leave behind it (a test plants it here).
      [ ! -f "$FAKE/plant" ] || { bash "$FAKE/plant" "$dir"; rm -f "$FAKE/plant"; } ;;
  /usr/local/bin/flash_serve) echo "loading"; echo "${FAKE_FACTS-61.2 0 1}" ;;
  "") if [ "$1" = convert ]; then
        echo "convert $2 $3" >> "$FAKE/convert.log"
        # Container paths through its mounts, the longest destination first (as the kernel sees them).
        host() { local v best="" bl=0 src dst; for v in "${vols[@]}"; do src="${v%%:*}"; dst="${v#*:}"; dst="${dst%%:*}"
                   if [[ "$1" == "$dst"/* ]] && [ "${#dst}" -gt "$bl" ]; then best="$src${1#"$dst"}"; bl="${#dst}"; fi; done; echo "$best"; }
        [ -f "$(host "$2")" ] || exit 1
        [ -f "$(host "$HALOGEN_MTP_HEAD_SEEN")" ] || exit 1
        [ -z "${FAKE_CONVERT_RC:-}" ] || exit "$FAKE_CONVERT_RC"
        o="$(host "$3")"; printf 'HGN1converted' > "$o"; echo junk > "$(dirname "$o")/stray.txt"
        exit 0
      fi
      if [ "$1" = ppl ]; then
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
printf 'HALOGEN_IMAGE=img@sha256:1\nHALOGEN_VERSION=9.9.9\nHALOGEN_VARIANT=no-npu\nHALOGEN_WEIGHTS_REPO=weights/repo\nHALOGEN_WEIGHTS_REVISION=wrev\n' > "$work/release.env"
export HALOGEN_FLASH_FILE="$work/flash-checkpoint"
mkdir -p "$work/state"
export HALOGEN_STATE_DIR="$work/state" PATH="$work/bin:$PATH" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_MODELS_DIR="$work/models" \
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
# A draft head file the repository ships comes too (checked by its hash, not given to verify), and
# is listed for flash drafter; the official one drafts until it is chosen.
grep -qx "hf $commit qwen38-flash-next-drafter-r2.hgn" "$work/hf.log" || fail "the repository's draft head wasn't fetched: $(cat "$work/hf.log")"
{ [ "$(cat "$d/qwen38-flash-next-drafter-r2.hgn")" = drafter ] && [ "$(info mine drafter)" = qwen38-flash-next-drafter-r2.hgn ]; } || fail "the draft head wasn't kept and listed"
if grep -q drafter "$work/verify.log"; then fail "verify was given a draft head file"; fi
[ "$(info mine own_precision)" = 1 ] || fail "whether it carries its own precision wasn't recorded"
# A draft head hard-linked to another file (the official one, say) goes before the container gets
# the folder; a FIFO at its name is removed, never hashed (which would hang).
printf 'official' > "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
rm "$d/qwen38-flash-next-drafter-r2.hgn"; ln "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn" "$d/qwen38-flash-next-drafter-r2.hgn"
mkfifo "$d/old-drafter.hgn"
timeout 60 "$tool" pull someone/My-Flash-HGN --as mine > "$work/out" 2>&1 || fail "the pull with a hard-linked draft head failed"
{ [ "$(stat -c %h "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn")" = 1 ] && [ "$(cat "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn")" = official ] &&
  [ ! -e "$d/old-drafter.hgn" ] && [ "$(cat "$d/qwen38-flash-next-drafter-r2.hgn")" = drafter ]; } || fail "a hard link or FIFO at a draft head's name survived"
rm "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
grep -q 'sudo halogenctl flash drafter mine qwen38-flash-next-drafter-r2.hgn' "$work/out" || fail "the pull doesn't say how to use its draft head"
# A copy of the official draft head is copied (its own file, no link), not downloaded.
printf 'drafter' > "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
pull someone/My-Flash-HGN --as mine2 || fail "a pull with the official draft head failed"
if grep -q 'drafter' "$work/hf.log"; then fail "a copy of the official draft head was downloaded"; fi
{ [ "$(cat "$work/models/flash/mine2/qwen38-flash-next-drafter-r2.hgn")" = drafter ] && [ ! -L "$work/models/flash/mine2/qwen38-flash-next-drafter-r2.hgn" ] &&
  [ "$(stat -c %h "$work/models/flash/mine2/qwen38-flash-next-drafter-r2.hgn")" = 1 ]; } || fail "the official draft head wasn't copied as a file of its own"
rm -rf "$work/models/flash/mine2" "$work/models/qwen38-flash-next-drafter-r2-ht4.hgn"
: > "$work/podman.log"; pull someone/My-Flash-HGN --as mine || fail "the pull again failed"   # the checks below read its logs
{ [ "$(info mine repo)" = someone/My-Flash-HGN ] && [ "$(info mine commit)" = "$commit" ] && [ "$(info mine checkpoint)" = model.hgn ]; } || fail "info wrong"
{ [ "$(info mine verified)" = pass ] && [ "$(info mine verified_with)" = 9.9.9 ]; } || fail "verify not recorded"
grep -qx "verify /models/flash/mine/model.hgn" "$work/verify.log" || fail "the checkpoint was not verified"
if grep -q ngram "$work/verify.log"; then fail "verify was given the lookup table, which it doesn't take"; fi
grep -qx 'name=mine' "$work/out" || fail "no name line"
if grep -q '^Hint' "$work/out"; then fail "hf noise reached the output"; fi
grep 'podman run' "$work/podman.log" | grep ' verify ' | grep -q -- '--network=none --cap-drop=all' || fail "verify was not offline and without capabilities"
grep 'podman run' "$work/podman.log" | grep -- '--entrypoint hf' > "$work/runs"
grep -q -- '--cap-drop=all' "$work/runs" || fail "the download kept capabilities"
# The online containers have the pull's name (a leftover one is replaced); one left by an
# interrupted pull goes first, and the last one when the pull ends.
grep -q -- '--name halogen-pull-flash-mine --replace ' "$work/runs" || fail "the download container wasn't named"
grep -qx 'podman rm -f -i -t 0 halogen-pull-flash-mine' "$work/podman.log" || fail "a leftover pull container isn't removed"
tail -n 1 "$work/podman.log" | grep -qx 'podman rm -f -i -t 0 halogen-pull-flash-mine' || fail "the pull's container isn't removed at the end"
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
# The official tokenizer is copied only as plain files: a link in it (or in its place) stops the pull.
ln -s /etc/hostname "$work/models/tokenizer/extra.json"
reset_repo; rm -r "$work/repo/tokenizer"
if pull someone/No-Tokenizer --as no-tok2; then fail "a pull copied an official tokenizer holding a link"; fi
grep -q "official tokenizer folder holds a link" "$work/out" || fail "the link in the official tokenizer wasn't named"
[ ! -L "$work/models/flash/no-tok2/tokenizer/extra.json" ] || fail "a link was copied into the checkpoint"
rm -f "$work/models/tokenizer/extra.json"; rm -rf "$work/models/flash/no-tok2"
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
if pull someone/Gguf; then fail "an incomplete GGUF build was accepted"; fi
grep -q "no complete model build" "$work/out" || fail "no GGUF explanation"
ok "several checkpoints need --file, and an incomplete GGUF build is explained"

# GGUF repositories (#61): the shards at the exact commit, the official draft head from the
# weights repository, Halogen's convert offline into model.hgn, then verify.
wcommit=fedcba9876543210fedcba9876543210fedcba98
mkdir -p "$work/weights"; printf 'mtphead' > "$work/weights/qwen38-flash-next-mtp.hgn"
{ echo "commit $wcommit"; printf 'file\tqwen38-flash-next-mtp.hgn\t7\t%s\t-\n' "$(printf mtphead | sha256sum | cut -d' ' -f1)"; } > "$work/listing-weights_repo"
gguf_repo() {
  rm -rf "$work/repo"; mkdir -p "$work/repo"
  put UD-IQ4_XS/Flash-UD-IQ4_XS-00001-of-00002.gguf shard1; put UD-IQ4_XS/Flash-UD-IQ4_XS-00002-of-00002.gguf shard2
  put mmproj-F16.gguf proj; put Flash-MTP-draft.gguf draft; put README.md hello
}
gguf_repo; : > "$work/podman.log"; : > "$work/convert.log"
pull someone/Flash-GGUF --as gg || fail "a GGUF pull failed"
g="$work/models/flash/gg"
{ [ "$(cat "$g/model.hgn")" = HGN1converted ] && [ "$(info gg checkpoint)" = model.hgn ] && [ "$(info gg gguf)" = UD-IQ4_XS/Flash-UD-IQ4_XS ] \
  && [ "$(info gg verified)" = pass ] && [ "$(info gg commit)" = "$commit" ]; } || fail "the converted checkpoint isn't in place and recorded"
grep -qx "hf $commit UD-IQ4_XS/Flash-UD-IQ4_XS-00001-of-00002.gguf UD-IQ4_XS/Flash-UD-IQ4_XS-00002-of-00002.gguf" "$work/hf.log" || fail "the shards weren't fetched at the commit: $(cat "$work/hf.log")"
grep -qx "hf $wcommit qwen38-flash-next-mtp.hgn" "$work/hf.log" || fail "the draft head wasn't fetched from the weights repository: $(cat "$work/hf.log")"
if grep -qE 'mmproj|MTP-draft' "$work/hf.log"; then fail "a projector or llama.cpp draft head was downloaded"; fi
grep -qx "convert /models/gguf/UD-IQ4_XS/Flash-UD-IQ4_XS-00001-of-00002.gguf /models/out/gg/model.hgn" "$work/convert.log" || fail "convert wasn't given the first shard: $(cat "$work/convert.log")"
grep ' convert ' "$work/podman.log" > "$work/conv.line"
{ grep -q -- '--network=none' "$work/conv.line" && grep -q -- '--cap-drop=all' "$work/conv.line" && grep -q -- '--oom-score-adj=1000' "$work/conv.line" \
  && grep -q -- '-e HALOGEN_MTP_HEAD=/models/head/qwen38-flash-next-mtp.hgn' "$work/conv.line" \
  && grep -q -- '--read-only' "$work/conv.line" \
  && grep -q -- "-v $work/models/flash/.convert/gg:/models:ro -v $work/models/flash/.convert/gg/out/gg:/models/out/gg " "$work/conv.line" \
  && [ "$(grep -o -- ' -v ' "$work/conv.line" | wc -l)" = 2 ]; } || fail "convert didn't run offline, unprivileged, read-only, seeing only its own work folder, with the head: $(cat "$work/conv.line")"
{ [ ! -e "$g/stray.txt" ] && [ ! -e "$work/models/flash/.convert/gg" ] && grep -q official "$g/tokenizer/tokenizer.json"; } || fail "strays, the download or a missing tokenizer"
grep -qx "verify /models/flash/gg/model.hgn" "$work/verify.log" || fail "verify didn't check the result"
grep -qx 'name=gg' "$work/out" || fail "no name= line for halogenctl"
ok "a GGUF repository is downloaded, converted with the official draft head, verified, and the download removed"

if pull someone/Flash-GGUF --as gg; then fail "a pull over an existing checkpoint was accepted"; fi
put Q8_0/Flash-Q8_0.gguf q8
if pull someone/Flash-GGUF --as g2; then fail "several builds were accepted without --file"; fi
grep -q 'several GGUF builds.*Q8_0/Flash-Q8_0.*UD-IQ4_XS/Flash-UD-IQ4_XS' "$work/out" || fail "the builds weren't listed: $(cat "$work/out")"
pull someone/Flash-GGUF --as g2 --file Q8_0/Flash-Q8_0.gguf --keep-gguf || fail "--file of a GGUF build failed"
{ [ "$(info g2 gguf)" = Q8_0/Flash-Q8_0 ] && [ -f "$work/models/flash/.convert/g2/gguf/Q8_0/Flash-Q8_0.gguf" ] \
  && [ ! -e "$work/models/flash/.convert/g2/head" ] && [ ! -e "$work/models/flash/.convert/g2/out" ]; } || fail "--keep-gguf didn't keep only the GGUF"
if grep -q UD-IQ4_XS "$work/hf.log"; then fail "another build was downloaded"; fi
pull someone/Flash-GGUF --as g2b --file UD-IQ4_XS/Flash-UD-IQ4_XS-00002-of-00002.gguf || fail "--file naming the second shard failed"
[ "$(info g2b gguf)" = UD-IQ4_XS/Flash-UD-IQ4_XS ] || fail "a shard name didn't pick its build"
ok "several builds need --file (a build's name or any of its files), and --keep-gguf keeps the download"

put Q3_K_M/Flash-Q3_K_M.gguf q3
if pull someone/Flash-GGUF --as g3 --file Q3_K_M/Flash-Q3_K_M.gguf; then fail "a quantization Halogen refuses was pulled"; fi
{ grep -q "can't read" "$work/out" && [ ! -s "$work/hf.log" ]; } || fail "the refusal came after a download"
ok "quantizations Halogen refuses are refused before downloading"

# A conversion that fails keeps the download; the next pull doesn't download the shards again.
gguf_repo
if FAKE_CONVERT_RC=1 pull someone/Flash-GGUF --as g4; then fail "a failed conversion was accepted"; fi
{ grep -q 'convert-stop g4' "$work/out" && [ -f "$work/models/flash/.convert/g4/gguf/UD-IQ4_XS/Flash-UD-IQ4_XS-00001-of-00002.gguf" ] \
  && [ ! -e "$work/models/flash/g4" ]; } || fail "a failed conversion lost the download or left a checkpoint"
if FAKE_CONVERT_RC=137 pull someone/Flash-GGUF --as g4; then fail "a conversion out of memory was accepted"; fi
grep -q 'ran out of memory' "$work/out" || fail "running out of memory wasn't explained"
if [ -s "$work/hf.log" ]; then fail "the retry downloaded again: $(cat "$work/hf.log")"; fi
pull someone/Flash-GGUF --as g4 || fail "the retry failed"
ok "a failed conversion keeps the download for the retry"

# What a hostile download could leave: a link to the keys among the shards, a stray file.
gguf_repo; mkdir -p "$work/configs"; echo secret > "$work/configs/api-key"
printf 'ln -s %q "$1/UD-IQ4_XS/evil.gguf"; echo x > "$1/stray.bin"\n' "$work/configs/api-key" > "$work/plant"
pull someone/Flash-GGUF --as g5 --keep-gguf || fail "a pull with a planted link failed"
{ [ ! -L "$work/models/flash/.convert/g5/gguf/UD-IQ4_XS/evil.gguf" ] && [ ! -e "$work/models/flash/.convert/g5/gguf/stray.bin" ] \
  && [ "$(cat "$work/configs/api-key")" = secret ]; } || fail "a planted link or stray file survived"
if FAKE_CORRUPT=UD-IQ4_XS/Flash-UD-IQ4_XS-00002-of-00002.gguf pull someone/Flash-GGUF --as g6; then fail "a shard that differs from its hash was converted"; fi
grep -q 'does not match' "$work/out" || fail "the hash mismatch wasn't said"
if FAKE_FREE=1000 pull someone/Flash-GGUF --as g7; then fail "a GGUF pull without room was accepted"; fi
grep -q 'free' "$work/out" || fail "no space message"
# flash convert's weights and a GGUF pull's never share a name.
mkdir -p "$work/models/flash/.convert/g8"; echo repo=x > "$work/models/flash/.convert/g8/convert.info"
if pull someone/Flash-GGUF --as g8; then fail "a GGUF pull went over flash convert's download"; fi
grep -q 'convert-stop g8' "$work/out" || fail "the clash wasn't explained"
ok "a GGUF pull removes planted links, checks hashes and space, and keeps clear of flash convert"

# A shard tampered with at its right size is deleted when its hash fails, so the next pull fetches
# it again; a folder the download container made unwritable is opened up, not left stuck.
gguf_repo
printf 'ln -s x "$1/UD-IQ4_XS/l"; chmod 0555 "$1/UD-IQ4_XS" "$1"\n' > "$work/plant"
pull someone/Flash-GGUF --as g10 --keep-gguf || fail "a pull whose download folder was made read-only failed"
s2="$work/models/flash/.convert/g10/gguf/UD-IQ4_XS/Flash-UD-IQ4_XS-00002-of-00002.gguf"
rm -rf "$work/models/flash/g10"; printf 'shardX' > "$s2"
if pull someone/Flash-GGUF --as g10; then fail "a same-size tampered shard was converted"; fi
[ ! -e "$s2" ] || fail "the tampered shard was kept"
pull someone/Flash-GGUF --as g10 || fail "the pull after a tampered shard failed"
grep -q 'Flash-UD-IQ4_XS-00002-of-00002.gguf' "$work/hf.log" || fail "the tampered shard wasn't fetched again"
# flash convert-stop <name> deletes under the name's lock.
mkdir -p "$work/models/flash/.convert/g11/gguf/sub"; chmod 0555 "$work/models/flash/.convert/g11/gguf"
( exec 9>> "$work/state/pull-flash-g11.lock"; flock 9; sleep 5 ) & held=$!; sleep 1
if "$tool" convert-clear g11 > "$work/out" 2>&1; then fail "convert-clear ran under a held lock"; fi
wait "$held"
"$tool" convert-clear g11 > "$work/out" 2>&1 || fail "convert-clear failed"
[ ! -e "$work/models/flash/.convert/g11" ] || fail "convert-clear left the folder"
ok "a tampered shard is fetched again, read-only folders are opened up, and convert-clear takes the lock"
# A verify that fails keeps the download; full-precision builds are refused before downloading.
gguf_repo
if FAKE_BAD=model.hgn pull someone/Flash-GGUF --as g12; then fail "a result failing verify was accepted"; fi
[ -f "$work/models/flash/.convert/g12/gguf/UD-IQ4_XS/Flash-UD-IQ4_XS-00001-of-00002.gguf" ] || fail "a failed verify deleted the download"
put BF16/Flash-BF16-00001-of-00001.gguf b
if pull someone/Flash-GGUF --as g13 --file BF16/Flash-BF16; then fail "a full-precision build was pulled"; fi
[ ! -s "$work/hf.log" ] || fail "the full-precision refusal came after a download"
ok "a failed verify keeps the download, and full precision is refused"

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
# verify starts no named container and removes none: a pull of the same name may be running.
: > "$work/podman.log"; "$tool" verify mine > /dev/null 2>&1 || true
if grep -q -e 'podman rm' -e '--name' "$work/podman.log"; then fail "verify touched a pull's container"; fi
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

# One pull or conversion of a name at a time: a second stops before it touches a container.
exec 8>> "$work/state/pull-flash-busy.lock"; flock -n 8
: > "$work/podman.log"
if pull someone/My-Flash-HGN --as busy; then fail "two pulls of one name ran at once"; fi
grep -q "Another pull, check or other command on busy is running" "$work/out" || fail "the lock wasn't named"
if grep -q "halogen-pull-flash-busy" "$work/podman.log"; then fail "the second pull touched the first one's container"; fi
exec 8>&-
ok "a second pull of the same name stops before it touches the first one's container"
# verify, check-prepare and check take the same lock (#119): a pull writing the checkpoint is a
# busy answer (75), not a verify of half-written files or a measurement of them.
exec 8>> "$work/state/pull-flash-mine.lock"; flock -n 8
for c in verify check-prepare check; do
  rc=0; "$tool" "$c" mine > "$work/out" 2>&1 || rc=$?
  if [ "$rc" != 75 ] || ! grep -q "Another pull, check or other command on mine is running" "$work/out"; then
    cat "$work/out" >&2; fail "$c ran beside a pull of the same checkpoint (rc $rc)"
  fi
done
exec 8>&-
ok "verify and check wait their turn behind a pull of the same checkpoint"
# The busy message says how to stop the holder only when it is a live process group of this user's,
# never for 1 or one that is gone.
exec 8>> "$work/state/pull-flash-busy.lock"; flock -n 8
ps -o pgid= -p "$$" | tr -cd 0-9 > "$work/state/pull-flash-busy.lock"
pull someone/My-Flash-HGN --as busy || true
grep -q "to stop it: sudo kill -- -$(ps -o pgid= -p "$$" | tr -cd 0-9)" "$work/out" || fail "the busy message didn't say how to stop the pull"
for g in 999999999 1; do
  echo "$g" > "$work/state/pull-flash-busy.lock"
  pull someone/My-Flash-HGN --as busy || true
  if grep -q "sudo kill" "$work/out"; then fail "the busy message offered to kill $g"; fi
done
exec 8>&-
ok "the busy message says how to stop a live pull, and never offers kill -- -1"

# No podman call gets the lock's descriptor (conmon would keep the name locked after a hard kill),
# and the progress loop lets go of the lock with the command: right after it, the name is free.
rm -f "$work/fd9.log"
reset_repo; HALOGEN_PROGRESS_S=5 pull someone/My-Flash-HGN --as prog || { cat "$work/out" >&2; fail "a pull with progress failed"; }
[ ! -s "$work/fd9.log" ] || fail "podman got the pull lock's descriptor: $(cat "$work/fd9.log")"
flock -n "$work/state/pull-flash-prog.lock" true || fail "the lock outlived the pull (its progress loop held it)"
ok "the pull lock reaches no podman call and is free as soon as the pull ends"

# A stop (TERM to the whole unit) removes the download's container at once, though it ignores
# the signal.
: > "$work/podman.log"; rm -f "$work/hang.pid"; listing > "$work/listing"
FAKE_HANG=hf setsid "$tool" pull someone/My-Flash-HGN --as hang > "$work/out" 2>&1 &
p=$!
for _ in $(seq 100); do [ -s "$work/hang.pid" ] && break; sleep 0.1; done
[ -s "$work/hang.pid" ] || { cat "$work/out" >&2; fail "the fake download never started"; }
kill -TERM -- "-$p"
for _ in $(seq 50); do kill -0 "$p" 2> /dev/null || break; sleep 0.1; done
if kill -0 "$p" 2> /dev/null; then kill -9 -- "-$p"; fail "the pull kept waiting on a container that ignores TERM"; fi
wait "$p" || true
if kill -0 "$(cat "$work/hang.pid")" 2> /dev/null; then fail "the container outlived the stop"; fi
grep -q -x 'podman rm -f -i -t 0 halogen-pull-flash-hang' "$work/podman.log" || fail "the container wasn't removed: $(cat "$work/podman.log")"
rm -f "$work/hang.pid"; rm -rf "$work/models/flash/hang"
ok "a stop during a flash pull removes its container at once"
# The same while the repository is being listed (a container run inside $(...), where only the
# function's own trap can act at once).
: > "$work/podman.log"; rm -f "$work/hang.pid"; listing > "$work/listing"
FAKE_HANG=python3 setsid "$tool" pull someone/My-Flash-HGN --as hang > "$work/out" 2>&1 &
p=$!
for _ in $(seq 100); do [ -s "$work/hang.pid" ] && break; sleep 0.1; done
[ -s "$work/hang.pid" ] || { cat "$work/out" >&2; fail "the fake listing never started"; }
kill -TERM -- "-$p"
for _ in $(seq 50); do kill -0 "$p" 2> /dev/null || break; sleep 0.1; done
if kill -0 "$p" 2> /dev/null; then kill -9 -- "-$p"; fail "the pull kept waiting on a listing that ignores TERM"; fi
wait "$p" || true
if kill -0 "$(cat "$work/hang.pid")" 2> /dev/null; then fail "the listing outlived the stop"; fi
rm -f "$work/hang.pid"; rm -rf "$work/models/flash/hang"
ok "a stop while a flash pull lists its repository ends it at once"

# The pull's container could leave tokenizer/ as a link to a folder holding the right files: the
# hashes pass through it, but nothing is then removed through it.
mkdir -p "$work/victim3"; echo keep > "$work/victim3/keepme"
printf 'cp -r "$1/tokenizer/." "%s/victim3/"; rm -rf "$1/tokenizer"; ln -s "%s/victim3" "$1/tokenizer"\n' "$work" "$work" > "$work/plant"
if pull someone/My-Flash-HGN --as linked-tok; then fail "a pull went on with tokenizer/ a link"; fi
[ "$(cat "$work/victim3/keepme" 2>/dev/null)" = keep ] || fail "a pull removed files through a link at tokenizer/"
grep -qF "sudo rm $work/models/flash/linked-tok/tokenizer" "$work/out" || fail "the refusal didn't give the command that removes the link"
rm -rf "$work/models/flash/linked-tok" "$work/victim3"
ok "a link in place of a pulled checkpoint's tokenizer/ stops the pull, and nothing is removed through it"

# A lookup table identical to the official one is shared, not downloaded again.
reset_repo; cp "$work/repo/qwen38-flash-next-ngram.hgn" "$work/models/qwen38-flash-next-ngram.hgn"
pull someone/Same-Table --as same || fail "pull failed"
cmp -s "$work/models/flash/same/qwen38-flash-next-ngram.hgn" "$work/models/qwen38-flash-next-ngram.hgn" || fail "the table was not shared"
if grep -q ngram "$work/hf.log"; then fail "the shared table was downloaded"; fi
# The checkpoint gets a file of its own, also when an earlier pull had hard-linked it: the
# download container could otherwise write the official table through the link.
if [ "$work/models/flash/same/qwen38-flash-next-ngram.hgn" -ef "$work/models/qwen38-flash-next-ngram.hgn" ]; then fail "the table is a hard link to the official one"; fi
rm -f "$work/models/flash/same/qwen38-flash-next-ngram.hgn"; ln "$work/models/qwen38-flash-next-ngram.hgn" "$work/models/flash/same/qwen38-flash-next-ngram.hgn"
pull someone/Same-Table --as same || fail "pull failed"
if [ "$work/models/flash/same/qwen38-flash-next-ngram.hgn" -ef "$work/models/qwen38-flash-next-ngram.hgn" ]; then fail "an old hard link to the official table was kept"; fi
cmp -s "$work/models/flash/same/qwen38-flash-next-ngram.hgn" "$work/models/qwen38-flash-next-ngram.hgn" || fail "the table's copy differs"
# A link where the checkpoint's folder belongs is refused, and nothing is made through it.
mkdir -p "$work/aside"; ln -s "$work/aside" "$work/models/flash/vialink"
if pull someone/Same-Table --as vialink > "$work/out" 2>&1; then fail "a pull went through a link"; fi
[ -z "$(ls -A "$work/aside")" ] || fail "a pull wrote through a link"
rm "$work/models/flash/vialink"
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
[ "$(grep -c -- '-p PrivateNetwork=yes -p SystemCallFilter=~socket socketpair io_uring_setup io_uring_enter io_uring_register -p SystemCallErrorNumber=EAFNOSUPPORT' "$work/sdrun.log")" = 2 ] || fail "the converter ran with network: $(cat "$work/sdrun.log")"
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
# The conversion's downloads have a name of their own: a pull of the same name never replaces them.
grep 'podman run' "$work/podman.log" | grep -- '--entrypoint hf' | grep -q -- '--name halogen-convert-conv --replace ' || fail "the conversion's download wasn't named"
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

# A conversion holds the name's lock too: a pull or a second conversion of it waits its turn.
exec 8>> "$work/state/pull-flash-conv.lock"; flock -n 8
if prepare someone/Flash-BF16 --as conv; then fail "convert-prepare ran beside a pull of the same name"; fi
grep -q "Another pull, check or other command on conv is running" "$work/out" || fail "convert-prepare didn't name the lock: $(cat "$work/out")"
if run conv; then fail "convert-run ran beside a pull of the same name"; fi
grep -q "Another pull, check or other command on conv is running" "$work/out" || fail "convert-run didn't name the lock: $(cat "$work/out")"
exec 8>&-
# Its progress loop (ten times the pull's interval) lets go of the lock with it.
rm -rf "$out" "$work/models/flash/.convert"; prepare someone/Flash-BF16 --as conv > /dev/null
HALOGEN_PROGRESS_S=3 run conv || fail "a conversion with progress failed"
flock -n "$work/state/pull-flash-conv.lock" true || fail "the lock outlived the conversion (its progress loop held it)"
ok "convert-prepare and convert-run take the name's lock, and let go of it when they end"

