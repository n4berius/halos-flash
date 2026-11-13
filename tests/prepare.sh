#!/bin/bash
# halogen-prepare (root, every boot): inside the halogen-owned folders everything is done as
# halogen (security audit P1), and a link planted where a file should be is never followed.
# The VM install test checks the real privilege drop; this checks the routing and the links.
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/outside"
export FAKE="$work"
f() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
f runuser 'echo "runuser $*" >> "$FAKE/log"; [ "$1 $2 $3" = "-u halogen --" ] || exit 9; shift 3; FAKE_AS=halogen exec "$@"'
# Root's own install -o halogen: log it and drop the owner options this test can't use.
f install 'echo "${FAKE_AS:-root} install $*" >> "$FAKE/log"; a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done; exec /usr/bin/install "${a[@]}"'
f selinuxenabled 'exit 1'
printf 'HALOGEN_VARIANT=npu\n' > "$work/release.env"; echo 'HALOGEN_FLASH_CTX=1' > "$work/default.env"
export PATH="$work/bin:$PATH" HALOGEN_MODELS_DIR="$work/models" HALOGEN_CONFIGS_DIR="$work/configs" HALOGEN_LOGS_DIR="$work/logs" \
  HALOGEN_STATE_DIR="$work/state" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_ENV_DEFAULT="$work/default.env"
prepare="$repo/files/usr/libexec/halogen/prepare"
ok() { echo "ok: $*"; }

"$prepare"
for d in flash npu decider LFM custom; do [ -d "$work/models/$d" ] || { echo "missing $d" >&2; exit 1; }; done
[ "$(stat -c %a "$work/configs/api-key")" = 600 ] && [ "$(wc -c < "$work/configs/api-key")" = 64 ]
grep -qx 'HALOGEN_FLASH_CTX=1' "$work/configs/halogen.env"
# Root itself only creates the three top folders; everything inside goes through runuser.
grep '^root install' "$work/log" | grep -q "$work/models/npu" && { echo "root created a folder inside /srv/models" >&2; exit 1; }
grep -q "runuser -u halogen -- install -d -m 0750 $work/models/npu" "$work/log"
grep -q "runuser -u halogen -- install -d -m 0750 $work/models/flash" "$work/log"
grep -q "runuser -u halogen -- install -d -m 0700 $work/logs/halogen" "$work/log"
[ "$(stat -c %a "$work/logs/halogen")" = 700 ] || { echo "the records folder isn't private" >&2; exit 1; }
grep -q "runuser -u halogen -- install -d -m 0700 $work/models/.prompt-cache" "$work/log"
[ "$(stat -c %a "$work/models/.prompt-cache")" = 700 ] || { echo "the prompt cache folder isn't private" >&2; exit 1; }
grep -q "runuser -u halogen -- sh -c .* $work/configs/api-key" "$work/log"
if ! grep -q '^# Reference only' "$work/configs/halogen.env.example" || ! grep -qx 'HALOGEN_FLASH_CTX=1' "$work/configs/halogen.env.example" ||
   ! grep -q "sh $work/configs/halogen.env.example " "$work/log"; then
  echo "halogen.env.example was not written as halogen" >&2; exit 1
fi
ok "root creates only the top folders; the model folders, settings and API key are made as halogen"

key="$(cat "$work/configs/api-key")"; "$prepare"
[ "$(cat "$work/configs/api-key")" = "$key" ] || { echo "a second boot replaced the API key" >&2; exit 1; }
rm "$work/configs/api-key" "$work/configs/halogen.env"
ln -s "$work/outside/stolen-key" "$work/configs/api-key"; ln -s "$work/outside/stolen-env" "$work/configs/halogen.env"
"$prepare"
if [ -e "$work/outside/stolen-key" ] || [ -e "$work/outside/stolen-env" ]; then
  echo "prepare followed a link planted in /srv/configs" >&2; exit 1
fi
# A newer release's template replaces the reference; halogen.env itself stays as it was.
echo 'HALOGEN_FLASH_CTX=2' > "$work/default.env"; echo 'HALOGEN_FLASH_CTX=1' > "$work/configs/halogen.env.keep"
rm "$work/configs/halogen.env"; cp "$work/configs/halogen.env.keep" "$work/configs/halogen.env"; "$prepare"
grep -qx 'HALOGEN_FLASH_CTX=2' "$work/configs/halogen.env.example" || { echo "the reference was not refreshed" >&2; exit 1; }
cmp -s "$work/configs/halogen.env" "$work/configs/halogen.env.keep" || { echo "halogen.env changed" >&2; exit 1; }
ok "it keeps the API key on later boots and never follows a link where a file should be; the reference is refreshed and halogen.env left alone"

# A link planted where one of halogen's folders belongs is removed (as halogen) and the folder
# made, instead of install -d following it: the target keeps its mode, and a dangling link
# doesn't fail the unit.
mkdir -p "$work/target"; chmod 755 "$work/target"
rmdir "$work/models/.prompt-cache"; ln -s "$work/target" "$work/models/.prompt-cache"
rm -rf "$work/models/custom"; ln -s "$work/nowhere" "$work/models/custom"
: > "$work/log"; "$prepare" 2> "$work/err"
if [ -L "$work/models/.prompt-cache" ] || [ ! -d "$work/models/.prompt-cache" ]; then echo "a link in place of the prompt cache folder was kept" >&2; exit 1; fi
if [ -L "$work/models/custom" ] || [ ! -d "$work/models/custom" ]; then echo "a dangling link in place of a checkpoint folder was kept" >&2; exit 1; fi
[ "$(stat -c %a "$work/target")" = 755 ] || { echo "prepare changed the mode of a link's target" >&2; exit 1; }
grep -q "runuser -u halogen -- rm -f -- $work/models/.prompt-cache" "$work/log" || { echo "the link wasn't removed as halogen" >&2; exit 1; }
grep -q 'removing the link' "$work/err" || { echo "removing a link wasn't said" >&2; exit 1; }
ok "a link in place of one of halogen's folders is removed and the folder made"
