#!/bin/bash
# Pins the Qwen3.8-27B download (halogenctl flash pull 27b, and the fetch on a machine short of
# memory) to one commit of HALOGEN_27B_REPO, with the sha256 of every file the pull can take: the
# .hgn files in the top folder and the tokenizer/ files. Writes HALOGEN_27B_REVISION and
# HALOGEN_27B_SHA256 in versions.env. Needs the network.
# Usage: scripts/pin-27b.sh [<branch, tag or commit>]   (default main)
# scripts/halogen-update.sh runs it, so every Halogen update moves the pin to the newest commit.
# Large files: Hugging Face's LFS sha256. Small ones: downloaded at that commit, checked against
# their git blob id from the same listing, then hashed here.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./versions.env
repo="$HALOGEN_27B_REPO" rev="${1:-main}"
hub=https://huggingface.co
[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "odd HALOGEN_27B_REPO: $repo" >&2; exit 1; }
[[ "$rev" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "odd revision: $rev" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# One request: the commit the revision names and every file at it, with LFS hashes and blob ids.
curl -sSf -m 60 --proto =https --proto-redir =https "$hub/api/models/$repo/revision/$rev?blobs=true" > "$tmp/info.json"
python3 -I - "$tmp/info.json" > "$tmp/list" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
sha = d.get("sha", "")
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    sys.exit("no commit in Hugging Face's answer")
print("commit", sha)
for s in d.get("siblings") or []:
    p = s.get("rfilename", "")
    if not (re.fullmatch(r"[A-Za-z0-9._-]+\.hgn", p) or p.startswith("tokenizer/")):
        continue
    if not re.fullmatch(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?", p):
        sys.exit(f"{p!r}: a file name the pull doesn't take")
    lfs = (s.get("lfs") or {}).get("sha256", "")
    print(p, lfs or "-", s.get("blobId") or "-")
PY
commit="$(sed -n 's/^commit //p' "$tmp/list")"
sed -i '/^commit /d' "$tmp/list"
grep -q '^tokenizer/tokenizer\.json ' "$tmp/list" || { echo "$repo at $commit has no tokenizer/tokenizer.json" >&2; exit 1; }
grep -E '^[A-Za-z0-9._-]+\.hgn ' "$tmp/list" | grep -qvE 'vision|ngram|mtp|overlay|drafter' || { echo "$repo at $commit has no checkpoint" >&2; exit 1; }
sums=()
while read -r path lfs blob; do
  if [ "$lfs" != - ]; then
    [[ "$lfs" =~ ^[0-9a-f]{64}$ ]] || { echo "odd LFS hash for $path" >&2; exit 1; }
    sums+=("$path:$lfs")
  else
    [[ "$blob" =~ ^[0-9a-f]{40}$ ]] || { echo "no blob id for $path" >&2; exit 1; }
    curl -sSfL -m 300 --proto =https --proto-redir =https -o "$tmp/f" "$hub/$repo/resolve/$commit/$path"
    got="$( { printf 'blob %s\0' "$(stat -c %s "$tmp/f")"; cat "$tmp/f"; } | sha1sum | cut -d' ' -f1)"
    [ "$got" = "$blob" ] || { echo "$path doesn't match its git blob id at $commit" >&2; exit 1; }
    sums+=("$path:$(sha256sum < "$tmp/f" | cut -d' ' -f1)")
  fi
done < "$tmp/list"
line="HALOGEN_27B_SHA256=\"${sums[*]}\""
sed -i -e "s|^HALOGEN_27B_REVISION=.*|HALOGEN_27B_REVISION=$commit|" -e "s|^HALOGEN_27B_SHA256=.*|$line|" versions.env
if ! grep -qx "HALOGEN_27B_REVISION=$commit" versions.env || ! grep -qxF "$line" versions.env; then
  echo "versions.env has no HALOGEN_27B_REVISION or HALOGEN_27B_SHA256 line to set" >&2; exit 1
fi
echo "pinned $repo at $commit (${#sums[@]} files)"
