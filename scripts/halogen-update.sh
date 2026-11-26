#!/bin/bash
# shellcheck disable=SC2016 # Backticks here are Markdown, not shell.
# Move versions.env to a new halogen-flash-server release and regenerate the option lists.
# Writes a pull request description to the given file. Exit 0 with nothing changed when
# the release is not newer than the current pin.
# Usage: scripts/halogen-update.sh path/to/halogen-flash-server-clone pr-body.md [version]
# The clone needs its tags. HALOGEN_UPDATE_DIGEST skips the registry lookup (for tests).
set -euo pipefail
upstream="$(cd "$1" && pwd)"; body="$2"; want="${3:-}"
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env
old_version="$HALOGEN_VERSION"
source_repo=peonist-ai/halogen-flash-server

up() { git -C "$upstream" "$@"; }
if [ -z "$want" ]; then
  want="$(up tag --list 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)"
  want="${want#v}"
fi
[[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a release version: $want" >&2; exit 1; }
if [ "$(printf '%s\n%s\n' "$want" "$old_version" | sort -V | tail -n 1)" = "$old_version" ]; then
  echo "Halogen $want is not newer than $old_version; nothing to do"
  exit 0
fi

commit="$(up rev-parse "v$want^{commit}")"
show() { up show "$commit:$1"; }
hash_of() { show "$1" | sha256sum | cut -d' ' -f1; }
clock="$(hash_of deploy/host/halogen-fabric-clock)"
license="$(hash_of LICENSE.md)"
notices="$(hash_of THIRD-PARTY-NOTICES.md)"
digest="${HALOGEN_UPDATE_DIGEST:-$(skopeo inspect --format '{{.Digest}}' "docker://ghcr.io/$source_repo:$want")}"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad digest for $want: $digest" >&2; exit 1; }

set_pin() { sed -i "s|^$1=.*|$1=$2|" versions.env; grep -qx "$1=$2" versions.env; }
set_pin HALOGEN_VERSION "$want"
set_pin HALOGEN_DIGEST "$digest"
set_pin HALOGEN_SOURCE_COMMIT "$commit"
set_pin HALOGEN_CLOCK_SHA256 "$clock"
set_pin HALOGEN_LICENSE_SHA256 "$license"
set_pin HALOGEN_NOTICES_SHA256 "$notices"
# Peonist's Qwen3.8-27B (flash pull 27b) moves to its repository's newest commit with every
# Halogen update, with fresh hashes of its files (scripts/pin-27b.sh, which needs the network).
old_27b="$HALOGEN_27B_REVISION"; work_27b="$(mktemp)"
# A failure (Hugging Face down, the repository gone) keeps the old pin (pin-27b.sh writes
# versions.env only at its end) and doesn't stop the Halogen update: the description says so.
if ! scripts/pin-27b.sh > "$work_27b" 2>&1; then
  row_27b="**not moved**: scripts/pin-27b.sh failed ($(tail -n 1 "$work_27b" | tr -cd '[:print:]' | tr '|`' '  ' | cut -c1-200)). Still \`${old_27b:0:12}\`: run it by hand on this branch"
elif new_27b="$(sed -n 's/^HALOGEN_27B_REVISION=//p' versions.env)"; [ "$new_27b" = "$old_27b" ]; then
  row_27b="unchanged ([\`${old_27b:0:12}\`](https://huggingface.co/$HALOGEN_27B_REPO/tree/$old_27b)): the repository has no newer commit"
else
  row_27b="[\`${new_27b:0:12}\`](https://huggingface.co/$HALOGEN_27B_REPO/tree/$new_27b) (was \`${old_27b:0:12}\`; [its commits](https://huggingface.co/$HALOGEN_27B_REPO/commits/main)), with \`HALOGEN_27B_SHA256\` written again: check the 27B's notes say it suits Halogen $want"
fi
rm -f "$work_27b"
# Our notices name the Halogen version and commit we ship, as Peonist's trademark policy asks.
if [ -f THIRD-PARTY-NOTICES.md ]; then
  sed -i -E "s/^(\| \[halogen-flash-server\][^|]*\| )[0-9.]+, commit \`[0-9a-f]+\`/\1$want, commit \`${commit:0:7}\`/" THIRD-PARTY-NOTICES.md
  grep -qF "| $want, commit \`${commit:0:7}\`" THIRD-PARTY-NOTICES.md || { echo "could not update THIRD-PARTY-NOTICES.md" >&2; exit 1; }
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
for e in npu no-npu; do cp "variants/$e/usr/share/halogen/options.allowed" "$work/$e.old"; done
show docs/FLAGS.md > "$work/FLAGS.md"
python3 scripts/gen-options.py "$work/FLAGS.md"

# The changelog sections newer than the old version, as upstream wrote them.
# Headings move down a level so they sit under this description's own.
# Read from a file: awk stops at the old version, which would cut off a pipe from git show.
show CHANGELOG.md > "$work/CHANGELOG.md"
awk -v old="$old_version" '
  /^## / { if ($2 == old) exit; keep = 1; print "### Halogen " $2; next }
  keep { sub(/^### /, "#### "); print }' "$work/CHANGELOG.md" |
  # Upstream's @names and #numbers would notify people and link to this repository's issues.
  sed -E -e 's/(^|[^[:alnum:]_`])@([[:alnum:]-]+)/\1`@\2`/g' \
    -e "s@(^|[^[:alnum:]_/])#([0-9]+)@\\1$source_repo#\\2@g" > "$work/notes.md"

changed_options() {
  local e="$1" added removed
  added="$(comm -13 "$work/$e.old" "variants/$e/usr/share/halogen/options.allowed" | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')"
  removed="$(comm -23 "$work/$e.old" "variants/$e/usr/share/halogen/options.allowed" | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')"
  echo "- **$e edition**: added ${added:-none}; removed ${removed:-none}"
}

old_commit="$(git show HEAD:versions.env | sed -n 's/^HALOGEN_SOURCE_COMMIT=//p')"
compare="https://github.com/$source_repo/compare/$old_commit...$commit"
cat > "$body" <<EOF
## Summary

Moves Halogen from **$old_version** to **$want**. Opened by the Halogen update workflow
(\`.github/workflows/halogen-update.yml\`), which found a newer release upstream.

| Pin | New value |
|---|---|
| \`HALOGEN_VERSION\` | \`$want\` |
| \`HALOGEN_DIGEST\` | \`$digest\` |
| \`HALOGEN_SOURCE_COMMIT\` | [\`${commit:0:12}\`](https://github.com/$source_repo/tree/$commit) ([changes since $old_version]($compare)) |
| Clock script, license, notices | hashes updated from that commit |
| \`HALOGEN_27B_REVISION\` | $row_27b |
| \`HALOGEN_WEIGHTS_REVISION\` | unchanged (\`$HALOGEN_WEIGHTS_REVISION\`): check the notes below say the Flash checkpoints are unchanged (if they changed, set the new revision and run \`scripts/weights-sums.sh\`) |

### Settings

The option lists were regenerated from upstream's [\`docs/FLAGS.md\`](https://github.com/$source_repo/blob/$commit/docs/FLAGS.md).
New settings are allowed but not turned on. Review each one before merging.

$(changed_options npu)
$(changed_options no-npu)

## Upstream release notes

From [\`CHANGELOG.md\`](https://github.com/$source_repo/blob/$commit/CHANGELOG.md):

$(cat "$work/notes.md")

## Test plan

- [ ] Build OS image passes for both editions
- [ ] Build USB installer passes (LUKS + TPM install test) for both editions
- [ ] Release notes read for host, NPU or setting changes that need work here
- [ ] Tried on real hardware before release (not done by this workflow)

Merging and releasing stay a person's decision. After merging, start again at alpha.
EOF
echo "Updated to Halogen $want ($digest)"
