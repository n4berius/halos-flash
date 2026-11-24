#!/bin/bash
# halogen-enroll-tpm: on a disk that isn't encrypted it says so, before anything else; otherwise
# it binds the first volume crypttab names (comments skipped) or the device given.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
printf '#!/bin/sh\necho "cryptenroll $*" >> "%s/log"\n' "$work" > "$work/bin/systemd-cryptenroll"; chmod +x "$work/bin/systemd-cryptenroll"
# No tang binding (#44): the helper reads none.
printf '#!/bin/sh\nexit 0\n' > "$work/bin/tang-unlock"; chmod +x "$work/bin/tang-unlock"
run() { PATH="$work/bin:$PATH" HALOS_CRYPTTAB="$work/crypttab" HALOS_TANG_UNLOCK="$work/bin/tang-unlock" "$repo/files/usr/bin/halogen-enroll-tpm" "$@" > "$work/out" 2>&1; }
for tab in missing empty comments; do
  case "$tab" in missing) rm -f "$work/crypttab" ;; empty) : > "$work/crypttab" ;; comments) printf '# none\n\n' > "$work/crypttab" ;; esac
  if run; then echo "enrolled with a $tab crypttab" >&2; exit 1; fi
  grep -q "This disk isn't encrypted" "$work/out" || { cat "$work/out" >&2; echo "no plain message with a $tab crypttab" >&2; exit 1; }
done
[ ! -e "$work/log" ] || { echo "cryptenroll ran on an unencrypted disk" >&2; exit 1; }
echo "ok: on a disk that isn't encrypted, halogen-enroll-tpm says so and enrolls nothing"
printf '# comment\nluks-abc UUID=1234-abcd none discard\n' > "$work/crypttab"
run || { cat "$work/out" >&2; exit 1; }
grep -q 'cryptenroll .*/dev/disk/by-uuid/1234-abcd$' "$work/log" || { cat "$work/log" >&2; echo "the volume after a comment wasn't used" >&2; exit 1; }
: > "$work/crypttab"; run /dev/sdz2 || { cat "$work/out" >&2; exit 1; }
grep -q 'cryptenroll .*/dev/sdz2$' "$work/log" || { echo "the device given wasn't used" >&2; exit 1; }
echo "ok: halogen-enroll-tpm binds crypttab's first volume, or the device given"
if [ "$(id -u)" != 0 ]; then
  printf 'luks-abc UUID=1234-abcd none\n' > "$work/crypttab"; chmod 000 "$work/crypttab"
  if run; then echo "enrolled from an unreadable crypttab" >&2; exit 1; fi
  grep -q "run it with sudo" "$work/out" || { cat "$work/out" >&2; echo "an unreadable crypttab passed for an unencrypted disk" >&2; exit 1; }
  chmod 600 "$work/crypttab"
  echo "ok: an unreadable crypttab asks for sudo rather than saying the disk isn't encrypted"
fi
