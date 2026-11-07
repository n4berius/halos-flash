#!/bin/bash
set -euo pipefail
scripts=(scripts/*.sh tests/*.sh files/usr/bin/* files/usr/libexec/halogen/* installer/guided/plan-install)
for f in "${scripts[@]}"; do
  bash -n "$f"
  [ -x "$f" ] || { echo "$f is not executable" >&2; exit 1; }
done
if command -v shellcheck >/dev/null; then shellcheck -x "${scripts[@]}"; else echo "shellcheck not installed, skipped"; fi

python3 - <<'P'
import configparser, glob, os, re, tomllib, xml.dom.minidom, yaml

kargs = tomllib.load(open("variants/npu/usr/lib/bootc/kargs.d/10-halogen.toml", "rb"))["kargs"]
no_npu = tomllib.load(open("variants/no-npu/usr/lib/bootc/kargs.d/10-halogen.toml", "rb"))["kargs"]
assert "amd_iommu=off" in no_npu and [k for k in kargs if "=" in k and "iommu" not in k] == [k for k in no_npu if "iommu" not in k]
assert "iommu=pt" in kargs and not any(k.startswith("amd_iommu") for k in kargs)
gtt = next(int(k.split("=")[1]) for k in kargs if k.startswith("amdgpu.gttsize="))
pages = next(int(k.split("=")[1]) for k in kargs if k.startswith("ttm.pages_limit="))
assert gtt * 1024 == pages * 4, "GTT and TTM limits disagree"

class Multi(dict):
    def __setitem__(self, k, v):
        if isinstance(v, list) and k in self: self[k].extend(v)
        else: super().__setitem__(k, v)
units = glob.glob("variants/npu/usr/lib/systemd/system/*.d/*.conf") + glob.glob("variants/npu/etc/containers/systemd/users/970/*.d/*") + glob.glob("files/usr/lib/systemd/system/*.service") + glob.glob("files/usr/lib/systemd/user/*.service") \
      + glob.glob("files/usr/lib/systemd/system/*.d/*.conf") + glob.glob("files/etc/containers/systemd/users/970/*")
for path in units:
    c = configparser.RawConfigParser(dict_type=Multi, strict=False, interpolation=None)
    c.optionxform = str
    c.read(path)
    assert c.sections(), path

q = open("files/etc/containers/systemd/users/970/halogen.container").read()
n = open("variants/npu/etc/containers/systemd/users/970/halogen.container.d/10-npu.conf").read()
assert "accel" not in q
locked = {l.split("=")[0] for l in open("files/usr/share/halogen/locked.env") if l.startswith("HALOGEN_")}
for edition in ("npu", "no-npu"):
    allowed = set(open(f"variants/{edition}/usr/share/halogen/options.allowed").read().split())
    assert allowed and not allowed & locked, allowed & locked
    assert "HALOGEN_DOWNLOAD" not in allowed
    assert (edition == "npu") == ("HALOGEN_NPU_MODELS" in allowed)
assert "HALOGEN_DOWNLOAD" not in q.replace("# No download settings here", "")
assert "@sha256" not in q and "Image=@HALOGEN_IMAGE@" in q
# Halogen carries XRT from 0.19.1. A partial host XRT is refused, so mount none at all.
for unit in (q, n):
    assert not re.search(r"^Volume=.*(xilinx|libxrt)", unit, re.M | re.I), "no XRT mounts: Halogen's image has its own"
xml.dom.minidom.parse("files/usr/lib/firewalld/services/halogen.xml")
pins = dict(l.strip().split("=", 1) for l in open("versions.env") if "=" in l and not l.startswith("#"))
assert re.fullmatch(r"[0-9a-f]{40}", pins["HALOGEN_WEIGHTS_REVISION"]), "HALOGEN_WEIGHTS_REVISION must be a commit, not a branch"
# Older Halogen images have no XRT of their own and need the host's.
assert tuple(map(int, re.match(r"(\d+)\.(\d+)\.(\d+)", pins["HALOGEN_VERSION"]).groups())) >= (0, 19, 1), "Halogen before 0.19.1 needs the host's XRT"
assert "DEBIAN_IMAGE" not in pins and "XRT_MIN_VERSION" not in pins
# The public key machines get is the one the signing script checks with (#46).
sign = open("scripts/sign-image.sh").read()
embedded = re.search(r"PUBLIC_KEY='(-----BEGIN PUBLIC KEY-----.*?-----END PUBLIC KEY-----)'", sign, re.S).group(1)
assert embedded + "\n" == open("files/etc/pki/containers/halos-flash.pub").read(), "the image's public key differs from sign-image.sh's"
for wf in ("build", "release", "refresh"):
    w = open(f".github/workflows/{wf}.yml").read()
    assert "COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}" in w, f"{wf}.yml doesn't pass the signing key"
    # Every job that signs runs in the protected "signing" environment.
    for job in yaml.safe_load(w)["jobs"].values():
        if any(any(k.startswith("COSIGN_") for k in (st.get("env") or {})) for st in job.get("steps", [])):
            assert "signing" in str(job.get("environment", "")), f"{wf}.yml signs outside the signing environment"
    # Only a step named Sign gets the key, and it runs nothing but the signing script.
    for job in yaml.safe_load(w)["jobs"].values():
        for step in job.get("steps", []):
            if any(k.startswith("COSIGN_") for k in (step.get("env") or {})):
                assert step.get("name") == "Sign" and "sign-image.sh" in step["run"] and "\n" not in step["run"].strip(), (wf, step.get("name"))
print("static checks ok")
P
python3 -c "import glob, yaml; [yaml.safe_load(open(f)) for f in glob.glob('.github/**/*.yml', recursive=True)]"

# Root never logs in over SSH. The 00- name keeps it before the installer's 01-permitrootlogin.conf.
f=files/etc/ssh/sshd_config.d/00-halos.conf
grep -qx 'PermitRootLogin no' "$f" || { echo "$f must say PermitRootLogin no" >&2; exit 1; }
echo "ok: root can't log in over SSH"

# Every workflow that publishes an image also signs it (#46).
for f in .github/workflows/*.yml; do
  code="$(grep -v '^[[:space:]]*#' "$f")"   # commands only, not comments
  if grep -q 'podman push\|push-image.sh' <<< "$code" && ! grep -q 'sign-image.sh' <<< "$code"; then
    echo "$f pushes images but doesn't sign them (scripts/sign-image.sh)" >&2; exit 1
  fi
done
echo "ok: every workflow that pushes an image signs it"

# Halogen's container runs with no capabilities (security audit R2).
q=files/etc/containers/systemd/users/970/halogen.container
if ! grep -qx 'DropCapability=all' "$q" || ! grep -qx 'NoNewPrivileges=true' "$q"; then
  echo "$q must drop all capabilities and set NoNewPrivileges" >&2; exit 1
fi
echo "ok: Halogen's container has no capabilities"

# A serial getty only on a port that answers (freyja's dead ttyS0 respawned agetty every 10 s),
# and only the VM test's boot entry puts a serial console on the installed system.
grep -qxF "ExecCondition=/usr/bin/sh -c 'exec /usr/bin/stty -F \"/dev/\$\$1\" >/dev/null 2>&1' sh %I" \
  files/usr/lib/systemd/system/serial-getty@.service.d/10-halos.conf \
  || { echo "serial-getty has no port check" >&2; exit 1; }
if [ "$(grep -c 'console=ttyS0' installer/iso.yaml)" != 1 ] || ! grep 'console=ttyS0' installer/iso.yaml | grep -q 'halos.unattended=1'; then
  echo "a user-facing boot entry gives installs a serial console" >&2; exit 1
fi
echo "ok: serial consoles"


# Actions run in jobs that can push images or reach the signing key, so each is pinned to a full
# commit (a version tag can be moved). Dependabot keeps the pins current.
if grep -rhE '^\s*-?\s*uses:' .github/workflows | grep -vE 'uses: [^@ ]+@[0-9a-f]{40}( #.*)?$'; then
  echo "an action above is not pinned to a full commit" >&2; exit 1
fi
echo "ok: actions are pinned to commits"
