#!/bin/bash
# scripts/weights-sums.sh against a fake Hugging Face (curl): it writes the hashes, and refuses a
# listing that comes in pages or has a tokenizer file in a subfolder.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export FAKE="$work" WEIGHTS_SUMS_OUT="$work/sums" PATH="$work/bin:$PATH"
printf 'hello' > "$work/small"
blob="$( { printf 'blob 5\0'; printf hello; } | sha1sum | cut -d' ' -f1)"
lfs="$(printf '%064d' 1)"
cat > "$work/bin/curl" <<'S'
#!/bin/bash
# Writes headers (-D) and the body (-o or stdout) for the two kinds of request the script makes.
hdr=""; out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -D) hdr="$2"; shift 2 ;; -o) out="$2"; shift 2 ;; -m) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
[ -z "$hdr" ] || printf 'HTTP/2 200\r\n%s' "${FAKE_LINK:-}" > "$hdr"
case "$url" in
  */api/models/*) cat "$FAKE/tree.json" ;;
  *) cat "$FAKE/small" > "${out:-/dev/stdout}" ;;
esac
S
chmod +x "$work/bin/curl"
tree() {
  printf '[{"type":"file","path":"qwen38-flash-next-v2.hgn","oid":"a","lfs":{"oid":"%s"}},' "$lfs"
  printf '{"type":"file","path":"qwen38-flash-next-ngram.hgn","oid":"b","lfs":{"oid":"%s"}},' "$lfs"
  printf '{"type":"file","path":"qwen38-flash-next-drafter-r2.hgn","oid":"e","lfs":{"oid":"%s"}},' "$lfs"
  printf '{"type":"file","path":"qwen38-flash-next-vision.hgn","oid":"c","lfs":{"oid":"%s"}},' "$lfs"
  printf '{"type":"file","path":"tokenizer/tokenizer.json","oid":"%s"}%s]' "$blob" "${1:-}"
}
tree > "$work/tree.json"
"$repo/scripts/weights-sums.sh" > /dev/null
grep -qx "$(printf hello | sha256sum | cut -d' ' -f1)  tokenizer/tokenizer.json" "$work/sums" && grep -qx "$lfs  qwen38-flash-next-v2.hgn" "$work/sums"
echo "ok: weights-sums writes the LFS hashes and hashes the small files it checked"
rm "$work/sums"
if FAKE_LINK=$'link: <https://huggingface.co/api/models/x/tree/y?cursor=z>; rel="next"\r\n' "$repo/scripts/weights-sums.sh" > /dev/null 2>&1 || [ -e "$work/sums" ]; then
  echo "a listing in pages was taken as whole" >&2; exit 1
fi
tree ',{"type":"file","path":"tokenizer/sub/extra.json","oid":"d"}' > "$work/tree.json"
if "$repo/scripts/weights-sums.sh" > /dev/null 2>&1 || [ -e "$work/sums" ]; then
  echo "a tokenizer file in a subfolder was accepted" >&2; exit 1
fi
echo "ok: weights-sums refuses a listing in pages and tokenizer files in subfolders"
