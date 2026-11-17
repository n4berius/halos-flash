#!/usr/bin/python3
"""Test fixtures for src/authenticode-check.py: a tiny PE signed like a kernel, and a shim.

  authenticode-fixture.py pe <out> <signer.pem> <signer.key> <sbat-generation> [bad-digest]
  authenticode-fixture.py shim <out> <ca.der>

Only for tests/authenticode.sh: the keys are throwaway ones it makes with openssl.
"""
import hashlib
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ac", os.path.join(here, "..", "src", "authenticode-check.py"))
ac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ac)


def der(tag, body):
    n = len(body)
    if n < 0x80:
        ln = bytes([n])
    else:
        b = n.to_bytes((n.bit_length() + 7) // 8, "big")
        ln = bytes([0x80 | len(b)]) + b
    return bytes([tag]) + ln + body


def seq(*parts):
    return der(0x30, b"".join(parts))


def oid(dotted):
    p = [int(x) for x in dotted.split(".")]
    out = bytes([p[0] * 40 + p[1]])
    for n in p[2:]:
        enc = [n & 0x7F]
        n >>= 7
        while n:
            enc.append(0x80 | (n & 0x7F))
            n >>= 7
        out += bytes(reversed(enc))
    return der(0x06, out)


NULL = b"\x05\x00"


def pe_image(sections):
    """MZ + PE32+ headers (SizeOfHeaders 0x200) and the given (name, data) sections."""
    nsec = len(sections)
    hdr = bytearray(0x200)
    hdr[0:2] = b"MZ"
    struct.pack_into("<I", hdr, 0x3C, 0x40)
    hdr[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", hdr, 0x44, 0x8664, nsec, 0, 0, 0, 240, 0x22)
    opt = 0x58
    struct.pack_into("<H", hdr, opt, 0x20B)
    struct.pack_into("<I", hdr, opt + 32, 0x200)      # SectionAlignment
    struct.pack_into("<I", hdr, opt + 36, 0x200)      # FileAlignment
    struct.pack_into("<I", hdr, opt + 60, 0x200)      # SizeOfHeaders
    struct.pack_into("<I", hdr, opt + 108, 16)        # NumberOfRvaAndSizes
    body = b""
    st = opt + 240
    off = 0x200
    strtab = b""                                      # names longer than 8 go here, as "/<offset>"
    for i, (name, data) in enumerate(sections):
        data = data + b"\0" * (-len(data) % 0x200)
        s = st + 40 * i
        if len(name) > 8:
            hdr[s:s + 8] = f"/{4 + len(strtab)}".encode().ljust(8, b"\0")
            strtab += name.encode() + b"\0"
        else:
            hdr[s:s + 8] = name.encode().ljust(8, b"\0")
        struct.pack_into("<IIII", hdr, s + 8, len(data), off, len(data), off)
        body += data
        off += len(data)
    if strtab:
        struct.pack_into("<I", hdr, 0x4C, off)        # PointerToSymbolTable; no symbols, then the strings
        body += struct.pack("<I", 4 + len(strtab)) + strtab
    return bytes(hdr) + body


def sign(image, signer_pem, signer_key, bad_digest=False):
    d = bytearray(image)
    lay = ac.pe_layout(bytes(d))
    h = ac.authenticode_hash(bytes(d), lay)
    spc = seq(seq(oid("1.3.6.1.4.1.311.2.1.15"), seq()),
              seq(seq(oid(ac.OID_SHA256), NULL), der(0x04, h)))
    _, _, sv, se = ac.tlv(spc, 0)
    md = hashlib.sha256(spc[sv:se]).digest()
    if bad_digest:
        md = bytes(32)
    attrs = (seq(oid(ac.OID_CONTENT_TYPE), der(0x31, oid(ac.OID_SPC_INDIRECT)))
             + seq(oid(ac.OID_MESSAGE_DIGEST), der(0x31, der(0x04, md))))
    with tempfile.TemporaryDirectory() as t:
        a = os.path.join(t, "attrs")
        open(a, "wb").write(der(0x31, attrs))
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", signer_key, a],
                             capture_output=True, check=True).stdout
        cert = subprocess.run(["openssl", "x509", "-in", signer_pem, "-outform", "DER"],
                              capture_output=True, check=True).stdout
    issuer, serial = ac.cert_issuer_serial(cert)
    signer_info = seq(der(0x02, b"\x01"), seq(issuer, der(0x02, serial)), seq(oid(ac.OID_SHA256), NULL),
                      der(0xA0, attrs), seq(oid("1.2.840.113549.1.1.1"), NULL), der(0x04, sig))
    signed = seq(der(0x02, b"\x01"), der(0x31, seq(oid(ac.OID_SHA256), NULL)),
                 seq(oid(ac.OID_SPC_INDIRECT), der(0xA0, spc)), der(0xA0, cert), der(0x31, signer_info))
    p7 = seq(oid(ac.OID_SIGNED_DATA), der(0xA0, signed))
    win = struct.pack("<IHH", 8 + len(p7), 0x0200, 0x0002) + p7
    win += b"\0" * (-len(win) % 8)
    d += b"\0" * (-len(d) % 8)
    struct.pack_into("<II", d, lay["certdir"], len(d), len(win))
    return bytes(d) + win


def main(a):
    if a[1] == "pe":
        sbat = ("sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md\n"
                f"kernel.fedora,{a[5]},Red Hat,kernel-core,test,mailto:x@example.com\n").encode()
        img = pe_image([(".text", b"\x90" * 300 + b"kernel text"), (".sbat", sbat)])
        open(a[2], "wb").write(sign(img, a[3], a[4], bad_digest=len(a) > 6))
    elif a[1] == "shim":
        ca = open(a[3], "rb").read()
        vc = struct.pack("<IIII", len(ca), 0, 16, 16 + len(ca)) + ca
        open(a[2], "wb").write(pe_image([(".text", b"\xc3"), (".vendor_cert", vc)]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
