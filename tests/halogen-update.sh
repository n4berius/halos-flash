#!/bin/bash
# shellcheck disable=SC2016 # Backticks here are Markdown, not shell.
# The Halogen update script against a made-up upstream, with no network.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

up="$work/upstream"
mkdir -p "$up/deploy/host" "$up/docs"
echo clock > "$up/deploy/host/halogen-fabric-clock"
echo license > "$up/LICENSE.md"
echo notices > "$up/THIRD-PARTY-NOTICES.md"
cat > "$up/docs/FLAGS.md" <<'F'
## Sampling

| Name | Default | What it does |
|---|---|---|
| `HALOGEN_TEMPERATURE` | `0.7` | Sampling temperature. |
| `HALOGEN_AGENT_GUARD` | `off` | A preview: reads tool results on the NPU. |
F
printf '# Changelog\n\n## 9.1.0\n\nNew things.\n\n### Fixed\n\n- A fix. Thanks @someone (#12).\n\n## 9.0.0\n\nOld things.\n' > "$up/CHANGELOG.md"
# A long history after the old version, as upstream's has: reading stops early, which must not fail.
for i in $(seq 1 20000); do echo "- an old change, number $i, with enough text to fill the pipe"; done >> "$up/CHANGELOG.md"
g -C "$up" init -q && g -C "$up" add -A && g -C "$up" commit -qm one && g -C "$up" tag v9.0.0
echo notices2 > "$up/THIRD-PARTY-NOTICES.md"
g -C "$up" commit -qam two && g -C "$up" tag v9.1.0 && g -C "$up" tag v9.2.0-rc.1

here="$work/here"
mkdir -p "$here"
cp -r "$repo/scripts" "$repo/variants" "$repo/versions.env" "$repo/THIRD-PARTY-NOTICES.md" "$here/"
# Its own starting option lists, so the result does not depend on this checkout's (the update
# workflow runs this test after it has already regenerated them).
for e in npu no-npu; do echo HALOGEN_TEMPERATURE > "$here/variants/$e/usr/share/halogen/options.allowed"; done
sed -i -e 's/^HALOGEN_VERSION=.*/HALOGEN_VERSION=9.0.0/' \
  -e "s/^HALOGEN_SOURCE_COMMIT=.*/HALOGEN_SOURCE_COMMIT=$(g -C "$up" rev-parse v9.0.0)/" "$here/versions.env"
g -C "$here" init -q && g -C "$here" add -A && g -C "$here" commit -qm base

# A fake Hugging Face (curl) for scripts/pin-27b.sh: the 27B repository at a newer commit.
mkdir -p "$work/bin"; export FAKE="$work" PATH="$work/bin:$PATH"
printf 'tok' > "$work/small"
new27="$(printf '%040d' 27)"; lfs27="$(printf '%064d' 5)"
blob27="$( { printf 'blob 3\0'; printf tok; } | sha1sum | cut -d' ' -f1)"
printf '{"sha":"%s","siblings":[{"rfilename":"README.md","blobId":"x"},{"rfilename":"q27.hgn","lfs":{"sha256":"%s"},"blobId":"y"},{"rfilename":"tokenizer/tokenizer.json","blobId":"%s"}]}' \
  "$new27" "$lfs27" "$blob27" > "$work/hf27.json"
cat > "$work/bin/curl" <<'C'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -m|--proto|--proto-redir) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
echo "$url" >> "$FAKE/curl.log"
case "$url" in
  */api/models/*/revision/main*) cat "$FAKE/hf27.json" ;;
  */resolve/*/tokenizer/tokenizer.json) cat "$FAKE/small" > "${out:-/dev/stdout}" ;;
  *) exit 22 ;;
esac
C
chmod +x "$work/bin/curl"
digest="sha256:$(printf '%064d' 7)"
HALOGEN_UPDATE_DIGEST="$digest" "$here/scripts/halogen-update.sh" "$up" "$work/body.md" > /dev/null
# shellcheck source=/dev/null
. "$here/versions.env"
[ "$HALOGEN_VERSION" = 9.1.0 ] || { echo "picked $HALOGEN_VERSION, not the newest release" >&2; exit 1; }
[ "$HALOGEN_DIGEST" = "$digest" ] && [ "$HALOGEN_SOURCE_COMMIT" = "$(g -C "$up" rev-parse v9.1.0)" ]
[ "$HALOGEN_NOTICES_SHA256" = "$(echo notices2 | sha256sum | cut -d' ' -f1)" ]
[ "$HALOGEN_CLOCK_SHA256" = "$(echo clock | sha256sum | cut -d' ' -f1)" ]
[ "$HALOGEN_WEIGHTS_REVISION" = "$(sed -n 's/^HALOGEN_WEIGHTS_REVISION=//p' "$repo/versions.env")" ]
grep -qF "| 9.1.0, commit \`$(g -C "$up" rev-parse --short=7 v9.1.0)\`" "$here/THIRD-PARTY-NOTICES.md" \
  || { echo "the notices still name the old Halogen version" >&2; exit 1; }
if [ "$HALOGEN_27B_REVISION" != "$new27" ] || [ "$HALOGEN_27B_SHA256" != "q27.hgn:$lfs27 tokenizer/tokenizer.json:$(printf tok | sha256sum | cut -d' ' -f1)" ]; then
  echo "the 27B pin didn't move to the repository's newest commit with its hashes: $HALOGEN_27B_REVISION $HALOGEN_27B_SHA256" >&2; exit 1
fi
grep -q "/resolve/$new27/tokenizer/tokenizer.json" "$work/curl.log" || { echo "a small 27B file wasn't read at the pinned commit" >&2; exit 1; }
grep -qF "| \`HALOGEN_27B_REVISION\` | [\`${new27:0:12}\`]" "$work/body.md" || { echo "the description doesn't name the new 27B pin" >&2; exit 1; }
echo "ok: the newest release's pins and hashes are written, the 27B pin moves, and the weights stay pinned"

[ "$(cat "$here/variants/npu/usr/share/halogen/options.allowed")" = "$(printf 'HALOGEN_AGENT_GUARD\nHALOGEN_TEMPERATURE')" ]
[ "$(cat "$here/variants/no-npu/usr/share/halogen/options.allowed")" = HALOGEN_TEMPERATURE ]
echo "ok: options come from the new FLAGS.md, and NPU-only ones stay out of the no-NPU edition"

grep -q '^### Halogen 9.1.0$' "$work/body.md" && grep -q '^#### Fixed$' "$work/body.md"
! grep -q 'Old things' "$work/body.md" || { echo "notes include the old version" >&2; exit 1; }
grep -qF 'Thanks `@someone` (peonist-ai/halogen-flash-server#12)' "$work/body.md" \
  || { echo "upstream @names or #numbers would notify or mislink" >&2; exit 1; }
grep -qF 'added `HALOGEN_AGENT_GUARD`' "$work/body.md"
echo "ok: the description has only the new notes, with mentions and issue numbers made safe"

g -C "$here" commit -qam update
before="$(cat "$here/versions.env")"
HALOGEN_UPDATE_DIGEST="$digest" "$here/scripts/halogen-update.sh" "$up" "$work/again.md" > /dev/null
[ "$before" = "$(cat "$here/versions.env")" ] && [ ! -e "$work/again.md" ]
# A small 27B file that doesn't match its blob id stops the update.
printf 'bad' > "$work/small"
if (cd "$here" && scripts/pin-27b.sh) > /dev/null 2>&1; then echo "pin-27b took a file that doesn't match its blob id" >&2; exit 1; fi
[ "$before" = "$(cat "$here/versions.env")" ] || { echo "a failed pin-27b changed versions.env" >&2; exit 1; }
if HALOGEN_UPDATE_DIGEST=bad "$here/scripts/halogen-update.sh" "$up" "$work/x.md" 9.9.9 >/dev/null 2>&1; then
  echo "accepted a version upstream does not have" >&2; exit 1
fi
echo "ok: nothing changes when already up to date, and an unknown version fails"

# Hugging Face failing doesn't stop a Halogen update: the 27B pin stays and the description says so.
git -C "$here" reset -q --hard HEAD~1
pin_before="$(grep '^HALOGEN_27B_' "$here/versions.env")"
mv "$work/hf27.json" "$work/hf27.off"
HALOGEN_UPDATE_DIGEST="$digest" "$here/scripts/halogen-update.sh" "$up" "$work/down.md" > /dev/null \
  || { echo "a failing Hugging Face stopped the Halogen update" >&2; exit 1; }
[ "$(sed -n 's/^HALOGEN_VERSION=//p' "$here/versions.env")" = 9.1.0 ] && [ "$pin_before" = "$(grep '^HALOGEN_27B_' "$here/versions.env")" ] \
  || { echo "with Hugging Face down, the Halogen pins weren't written or the 27B pin changed" >&2; exit 1; }
grep -qF '| `HALOGEN_27B_REVISION` | **not moved**' "$work/down.md" || { echo "the description doesn't say the 27B pin didn't move" >&2; exit 1; }
echo "ok: a failing Hugging Face keeps the 27B pin and the update goes on"
