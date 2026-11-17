#!/usr/bin/python3
"""Check a kernel's Secure Boot signature the way shim does, with openssl only.

Usage: authenticode-check.py <vmlinuz> <shimx64.efi> [<baseline vmlinuz>]

Run at image build time (kernel-next, versions.env) on the test kernel, against the CA Fedora's
own shim trusts (its .vendor_cert section). It fails unless:
  - vmlinuz holds one Authenticode signature (SHA-256) whose signed hash equals the file's own
    Authenticode hash, whose messageDigest matches, and whose RSA signature over the signed
    attributes verifies with the signer's certificate;
  - that certificate chains to shim's vendor CA (times not checked: firmware has no clock to trust)
    and is for code signing;
  - its .sbat section's kernel.fedora generation is at least the baseline kernel's (shim refuses
    a kernel whose generation a newer SBAT revocation has raised past).
Prints one line per check. Nothing here signs anything.
"""
import hashlib
import os
import struct
import subprocess
import sys
import tempfile


class Bad(Exception):
    pass


# --- PE ---------------------------------------------------------------------------------------
def pe_layout(d):
    if d[:2] != b"MZ":
        raise Bad("not a PE file")
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe:pe + 4] != b"PE\0\0":
        raise Bad("not a PE file")
    nsec, = struct.unpack_from("<H", d, pe + 6)
    symp, nsym = struct.unpack_from("<II", d, pe + 12)
    optsz, = struct.unpack_from("<H", d, pe + 20)
    opt = pe + 24
    magic, = struct.unpack_from("<H", d, opt)
    if magic == 0x20B:
        dirs = opt + 112
    elif magic == 0x10B:
        dirs = opt + 96
    else:
        raise Bad("unknown PE optional header")
    hdrsize, = struct.unpack_from("<I", d, opt + 60)
    checksum_off = opt + 64
    certdir_off = dirs + 4 * 8
    cert_off, cert_size = struct.unpack_from("<II", d, certdir_off)
    strtab = symp + nsym * 18
    secs = []
    st = opt + optsz
    for i in range(nsec):
        s = st + 40 * i
        name = d[s:s + 8].rstrip(b"\0").decode("ascii", "replace")
        if name.startswith("/") and name[1:].isdigit():
            o = strtab + int(name[1:])
            name = d[o:d.index(b"\0", o)].decode("ascii", "replace")
        vsz, _va, rsz, rptr = struct.unpack_from("<IIII", d, s + 8)
        secs.append((name, vsz, rsz, rptr))
    return {"checksum": checksum_off, "certdir": certdir_off, "hdrsize": hdrsize,
            "cert_off": cert_off, "cert_size": cert_size, "sections": secs}


def section(d, lay, name):
    for n, vsz, rsz, rptr in lay["sections"]:
        if n == name:
            return d[rptr:rptr + (min(vsz, rsz) if vsz else rsz)]
    return None


def authenticode_hash(d, lay):
    h = hashlib.sha256()
    h.update(d[:lay["checksum"]])
    h.update(d[lay["checksum"] + 4:lay["certdir"]])
    h.update(d[lay["certdir"] + 8:lay["hdrsize"]])
    end = lay["hdrsize"]
    for _n, _vsz, rsz, rptr in sorted(lay["sections"], key=lambda s: s[3]):
        if rsz == 0:
            continue
        h.update(d[rptr:rptr + rsz])
        end = max(end, rptr + rsz)
    tail = len(d) - (lay["cert_size"] if lay["cert_off"] else 0)
    if tail > end:
        h.update(d[end:tail])
    return h.digest()


# --- DER --------------------------------------------------------------------------------------
def tlv(b, i):
    """(tag, header start, value start, end) of the element at i."""
    tag = b[i]
    ln = b[i + 1]
    j = i + 2
    if ln & 0x80:
        n = ln & 0x7F
        if n == 0 or n > 4:
            raise Bad("unsupported DER length")
        ln = int.from_bytes(b[j:j + n], "big")
        j += n
    if j + ln > len(b):
        raise Bad("truncated DER")
    return tag, i, j, j + ln


def children(b, start, end):
    out = []
    i = start
    while i < end:
        t = tlv(b, i)
        out.append(t)
        i = t[3]
    return out


def oid(b, t):
    if t[0] != 0x06:
        raise Bad("expected an OID")
    v = b[t[2]:t[3]]
    parts = [v[0] // 40, v[0] % 40]
    n = 0
    for x in v[1:]:
        n = (n << 7) | (x & 0x7F)
        if not x & 0x80:
            parts.append(n)
            n = 0
    return ".".join(map(str, parts))


OID_SIGNED_DATA = "1.2.840.113549.1.7.2"
OID_SPC_INDIRECT = "1.3.6.1.4.1.311.2.1.4"
OID_SHA256 = "2.16.840.1.101.3.4.2.1"
OID_MESSAGE_DIGEST = "1.2.840.113549.1.9.4"
OID_CONTENT_TYPE = "1.2.840.113549.1.9.3"


def parse_signature(sig):
    _, _, cv, ce = tlv(sig, 0)                       # ContentInfo
    ci = children(sig, cv, ce)
    if oid(sig, ci[0]) != OID_SIGNED_DATA:
        raise Bad("the signature isn't PKCS#7 SignedData")
    _, _, sv, se = tlv(sig, ci[1][2])                # [0] EXPLICIT -> SignedData SEQUENCE
    sd = children(sig, sv, se)
    # version, digestAlgorithms, contentInfo, [0] certificates?, [1] crls?, signerInfos
    content = children(sig, sd[2][2], sd[2][3])
    if oid(sig, content[0]) != OID_SPC_INDIRECT:
        raise Bad("the signature doesn't sign a PE image (no SpcIndirectDataContent)")
    spc = tlv(sig, content[1][2])                    # the SpcIndirectDataContent SEQUENCE
    spc_kids = children(sig, spc[2], spc[3])
    dinfo = children(sig, spc_kids[1][2], spc_kids[1][3])
    alg = children(sig, dinfo[0][2], dinfo[0][3])
    if oid(sig, alg[0]) != OID_SHA256:
        raise Bad("the signed image hash isn't SHA-256")
    signed_hash = sig[dinfo[1][2]:dinfo[1][3]]
    certs = []
    signer_infos = None
    for t in sd[3:]:
        if t[0] == 0xA0:
            certs = [sig[c[1]:c[3]] for c in children(sig, t[2], t[3])]
        elif t[0] == 0x31:
            signer_infos = children(sig, t[2], t[3])
    if not signer_infos or len(signer_infos) != 1:
        raise Bad("expected exactly one signer")
    si = children(sig, signer_infos[0][2], signer_infos[0][3])
    ias = si[1]
    issuer_serial = children(sig, ias[2], ias[3])
    serial = sig[issuer_serial[1][2]:issuer_serial[1][3]]
    issuer = sig[issuer_serial[0][1]:issuer_serial[0][3]]
    if oid(sig, children(sig, si[2][2], si[2][3])[0]) != OID_SHA256:
        raise Bad("the signer's digest isn't SHA-256")
    attrs = si[3]
    if attrs[0] != 0xA0:
        raise Bad("the signer has no signed attributes")
    msg_digest = None
    ctype = None
    for a in children(sig, attrs[2], attrs[3]):
        k = children(sig, a[2], a[3])
        name = oid(sig, k[0])
        vals = children(sig, k[1][2], k[1][3])
        if name == OID_MESSAGE_DIGEST:
            msg_digest = sig[vals[0][2]:vals[0][3]]
        elif name == OID_CONTENT_TYPE:
            ctype = oid(sig, vals[0])
    if ctype != OID_SPC_INDIRECT:
        raise Bad("the signed attributes don't name a PE image")
    signed_attrs = b"\x31" + sig[attrs[1] + 1:attrs[3]]
    encrypted = si[5]
    signature = sig[encrypted[2]:encrypted[3]]
    # Authenticode: the message digest covers the content's value, without its tag and length.
    content_hash = hashlib.sha256(sig[spc[2]:spc[3]]).digest()
    return {"signed_hash": signed_hash, "certs": certs, "serial": serial, "issuer": issuer,
            "msg_digest": msg_digest, "content_hash": content_hash,
            "signed_attrs": signed_attrs, "signature": signature}


def cert_issuer_serial(cert):
    tbs = children(cert, *tlv(cert, 0)[2:4])[0]
    k = children(cert, tbs[2], tbs[3])
    i = 1 if k[0][0] == 0xA0 else 0                  # optional [0] version
    return cert[k[i + 2][1]:k[i + 2][3]], cert[k[i][2]:k[i][3]]


def certs_in_signature(d, lay):
    off, size = lay["cert_off"], lay["cert_size"]
    if not off or not size or off + size > len(d):
        raise Bad("no signature (the PE certificate table is empty)")
    out = []
    i = off
    while i + 8 <= off + size:
        length, rev, ctype = struct.unpack_from("<IHH", d, i)
        if length < 8:
            break
        if ctype == 0x0002:                           # WIN_CERT_TYPE_PKCS_SIGNED_DATA
            out.append(d[i + 8:i + length])
        i += (length + 7) & ~7
    return out


# --- shim -------------------------------------------------------------------------------------
def vendor_ca(shim):
    d = open(shim, "rb").read()
    lay = pe_layout(d)
    vc = section(d, lay, ".vendor_cert")
    if not vc or len(vc) < 16:
        raise Bad("shim has no .vendor_cert")
    size, _dsize, off, _doff = struct.unpack_from("<IIII", vc, 0)
    cert = vc[off:off + size]
    if not cert.startswith(b"\x30\x82"):
        raise Bad("shim's vendor certificate isn't a single DER certificate")
    return cert


def sbat_generation(d, lay, component="kernel.fedora"):
    s = section(d, lay, ".sbat")
    if s is None:
        raise Bad("no .sbat section")
    for line in s.split(b"\0", 1)[0].decode("ascii", "replace").splitlines():
        f = line.split(",")
        if len(f) >= 2 and f[0] == component and f[1].isdigit():
            return int(f[1])
    raise Bad(f"no {component} line in .sbat")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    pe, shim = argv[1], argv[2]
    d = open(pe, "rb").read()
    lay = pe_layout(d)
    sigs = certs_in_signature(d, lay)
    if len(sigs) != 1:
        raise Bad(f"expected one signature, found {len(sigs)}")
    p = parse_signature(sigs[0])
    if p["signed_hash"] != authenticode_hash(d, lay):
        raise Bad("the signed hash doesn't match this file (it was changed after signing)")
    print("ok: the signed hash matches the file")
    if p["msg_digest"] != p["content_hash"]:
        raise Bad("the signature's message digest doesn't match what it signs")
    signer = None
    for c in p["certs"]:
        iss, ser = cert_issuer_serial(c)
        if iss == p["issuer"] and ser == p["serial"]:
            signer = c
    if signer is None:
        raise Bad("the signer's certificate isn't in the signature")
    with tempfile.TemporaryDirectory() as t:
        def put(name, data):
            path = os.path.join(t, name)
            with open(path, "wb") as f:
                f.write(data)
            return path
        signer_der = put("signer.der", signer)
        run(["openssl", "x509", "-inform", "DER", "-in", signer_der, "-out", put("signer.pem", b"")], check=True)
        r = run(["openssl", "x509", "-in", os.path.join(t, "signer.pem"), "-noout", "-pubkey"], check=True)
        pub = put("pub.pem", r.stdout.encode())
        r = run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", put("sig.bin", p["signature"]),
                 put("attrs.der", p["signed_attrs"])])
        if r.returncode != 0 or "Verified OK" not in r.stdout:
            raise Bad("the RSA signature over the signed attributes doesn't verify")
        print("ok: the signature verifies with the signer's certificate")
        ca_der = put("ca.der", vendor_ca(shim))
        run(["openssl", "x509", "-inform", "DER", "-in", ca_der, "-out", put("ca.pem", b"")], check=True)
        chain = b""
        for i, c in enumerate(p["certs"]):
            if c != signer:
                cp = put(f"c{i}.der", c)
                chain += run(["openssl", "x509", "-inform", "DER", "-in", cp], check=True).stdout.encode()
        # shim's CA alone: -CAfile adds to openssl's default trust (the system's public roots in its
        # folder and store), which -no-CApath and -no-CAstore turn off (security audit).
        args = ["openssl", "verify", "-no_check_time", "-purpose", "any", "-no-CApath", "-no-CAstore",
                "-CAfile", os.path.join(t, "ca.pem")]
        if chain:
            args += ["-untrusted", put("chain.pem", chain)]
        r = run(args + [os.path.join(t, "signer.pem")])
        if r.returncode != 0:
            raise Bad("the signer doesn't chain to the CA shim trusts: " + (r.stdout + r.stderr).strip())
        r = run(["openssl", "x509", "-in", os.path.join(t, "signer.pem"), "-noout", "-ext", "extendedKeyUsage"])
        # The exact item (openssl prints 1.3.6.1.5.5.7.3.3 as "Code Signing"), not a substring:
        # Microsoft's "Individual/Commercial Code Signing" uses aren't it.
        lines = r.stdout.splitlines()[1:]
        if "Code Signing" not in [u.strip() for line in lines for u in line.split(",")]:
            raise Bad("the signer's certificate isn't for code signing")
        r = run(["openssl", "x509", "-in", os.path.join(t, "ca.pem"), "-noout", "-subject"], check=True)
        print("ok: the signer chains to shim's CA (" + r.stdout.strip() + ")")
    if len(argv) == 4:
        b = open(argv[3], "rb").read()
        new, old = sbat_generation(d, lay), sbat_generation(b, pe_layout(b))
        if new < old:
            raise Bad(f"its SBAT generation (kernel.fedora,{new}) is below the base kernel's ({old})")
        print(f"ok: SBAT kernel.fedora generation {new} (base kernel: {old})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (Bad, OSError, IndexError, ValueError, struct.error, subprocess.CalledProcessError) as e:
        print(f"authenticode-check: {e}", file=sys.stderr)
        sys.exit(1)
