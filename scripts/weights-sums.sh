#!/bin/bash
# Writes files/usr/share/halogen/weights.sha256: the sha256 of each official file the fetch
# downloads (the Flash checkpoint, its lookup table and vision tower, and tokenizer/), at the
# weights revision versions.env pins. fetch-models checks the files against it after a download.
# Needs the network. Run it whenever HALOGEN_WEIGHTS_REVISION changes (tests/static.sh fails
# until then). Large files: Hugging Face's LFS sha256. Small ones: downloaded at that commit,
# checked against their git blob id from the same listing, then hashed here.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. versions.env
repo="$HALOGEN_WEIGHTS_REPO" rev="$HALOGEN_WEIGHTS_REVISION"
out=files/usr/share/halogen/weights.sha256
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -sSf -m 60 "https://huggingface.co/api/models/$repo/tree/$rev?recursive=1" > "$tmp/tree.json"
python3 - "$tmp/tree.json" > "$tmp/list" <<'PY'
import json, sys
want = {"qwen38-flash-next-v2.hgn", "qwen38-flash-next-ngram.hgn", "qwen38-flash-next-vision.hgn"}
for e in json.load(open(sys.argv[1])):
    p = e.get("path", "")
    if e.get("type") != "file" or not (p in want or p.startswith("tokenizer/")):
        continue
    lfs = (e.get("lfs") or {}).get("oid", "")
    print(p, lfs or "-", e["oid"])
PY
for f in qwen38-flash-next-v2.hgn qwen38-flash-next-ngram.hgn qwen38-flash-next-vision.hgn tokenizer/tokenizer.json; do
  grep -q "^$f " "$tmp/list" || { echo "$repo at $rev has no $f" >&2; exit 1; }
done
{
  echo "# sha256 of the official files fetch-models downloads, from $repo"
  echo "# revision $rev"
  echo "# Written by scripts/weights-sums.sh; don't edit by hand."
  while read -r path lfs blob; do
    [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "odd file name in the listing" >&2; exit 1; }
    if [ "$lfs" != - ]; then
      [[ "$lfs" =~ ^[0-9a-f]{64}$ ]] || { echo "odd LFS hash for $path" >&2; exit 1; }
      echo "$lfs  $path"
    else
      curl -sSfL -m 300 -o "$tmp/f" "https://huggingface.co/$repo/resolve/$rev/$path"
      got="$( { printf 'blob %s\0' "$(stat -c %s "$tmp/f")"; cat "$tmp/f"; } | sha1sum | cut -d' ' -f1)"
      [ "$got" = "$blob" ] || { echo "$path doesn't match its git blob id at $rev" >&2; exit 1; }
      echo "$(sha256sum < "$tmp/f" | cut -d' ' -f1)  $path"
    fi
  done < "$tmp/list"
} > "$tmp/out"
mv "$tmp/out" "$out"
echo "wrote $out"
