#!/bin/bash
# src/authenticode-check.py (the kernel-next build's Secure Boot check) against made-up PE files
# signed with throwaway keys: what it accepts and each thing it refuses. Checked by hand against
# Fedora's real 7.3 and 7.4-rc2 kernels and shim (#142's follow-up PR).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/../src/authenticode-check.py"
fixture="$here/authenticode-fixture.py"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$work"

# A CA, a code-signing key it signs, and another CA nobody trusts.
ca() {
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.pem" -days 2 -subj "/CN=$1" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2> /dev/null
  openssl x509 -in "$1.pem" -outform DER -out "$1.der"
}
leaf() {  # leaf <name> <ca> <eku>
  openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$1" 2> /dev/null
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\n' "$3" > "$1.ext"
  openssl x509 -req -in "$1.csr" -CA "$2.pem" -CAkey "$2.key" -CAcreateserial -days 2 -out "$1.pem" -extfile "$1.ext" 2> /dev/null
}
ca trusted; ca stranger
leaf signer trusted codeSigning
leaf webserver trusted serverAuth
leaf outsider stranger codeSigning
python3 -I "$fixture" shim shim.efi trusted.der
python3 -I "$fixture" pe base.efi signer.pem signer.key 2

ok() { echo "ok: $*"; }
pass() { python3 -I "$check" "$@" > out 2>&1 || { cat out >&2; echo "refused a good kernel" >&2; exit 1; }; }
refuse() {  # refuse <expected words> <args...>
  local want="$1"; shift
  if python3 -I "$check" "$@" > out 2>&1; then cat out >&2; echo "accepted: $want" >&2; exit 1; fi
  grep -q -- "$want" out || { cat out >&2; echo "refused, but not for: $want" >&2; exit 1; }
}

python3 -I "$fixture" pe good.efi signer.pem signer.key 2
pass good.efi shim.efi base.efi
grep -q 'SBAT kernel.fedora generation 2 (base kernel: 2)' out
ok "a kernel signed by a code-signing key under shim's CA, at the base's SBAT generation, passes"

cp good.efi changed.efi; printf 'Y' | dd of=changed.efi bs=1 seek=$((0x210)) conv=notrunc 2> /dev/null
refuse "changed after signing" changed.efi shim.efi
python3 -I "$fixture" pe wrongkey.efi signer.pem outsider.key 2
refuse "doesn't verify" wrongkey.efi shim.efi
python3 -I "$fixture" pe other.efi outsider.pem outsider.key 2
refuse "doesn't chain to the CA shim trusts" other.efi shim.efi
python3 -I "$fixture" pe web.efi webserver.pem webserver.key 2
refuse "isn't for code signing" web.efi shim.efi
python3 -I "$fixture" pe digest.efi signer.pem signer.key 2 bad-digest
refuse "message digest doesn't match" digest.efi shim.efi
python3 -I "$fixture" pe old.efi signer.pem signer.key 1
refuse "below the base kernel's" old.efi shim.efi base.efi
head -c $(( $(stat -c %s good.efi) - 4 )) good.efi > cut.efi
refuse "" cut.efi shim.efi
python3 -I "$fixture" pe plain.efi signer.pem signer.key 2
python3 - plain.efi <<'EOF'
import struct, sys
d = bytearray(open(sys.argv[1], "rb").read())
struct.pack_into("<II", d, 0x58 + 112 + 32, 0, 0)
open(sys.argv[1], "wb").write(d)
EOF
refuse "no signature" plain.efi shim.efi
ok "a changed kernel, a signature by another key, another CA, a key not for code signing, a wrong digest, a lower SBAT generation, a cut file and no signature are refused"
