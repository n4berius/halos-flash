#!/bin/bash
set -euo pipefail
scripts=(scripts/*.sh tests/*.sh files/usr/bin/* files/usr/libexec/halogen/* installer/guided/plan-install)
for f in "${scripts[@]}"; do
  bash -n "$f"
  [ -x "$f" ] || { echo "$f is not executable" >&2; exit 1; }
done
if command -v shellcheck >/dev/null; then shellcheck -x "${scripts[@]}"; else echo "shellcheck not installed, skipped"; fi
# Tab completion files are sourced, not run, so they have no #! line and aren't executable.
completions=(files/usr/share/bash-completion/completions/*)
for f in "${completions[@]}"; do bash -n "$f"; done
if command -v shellcheck >/dev/null; then shellcheck -s bash "${completions[@]}"; fi

python3 - <<'P'
import configparser, glob, json, os, re, tomllib, xml.dom.minidom, yaml

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
# bf16-to-hgn is built from an exact commit, and its licenses ship (halogenctl flash convert).
assert re.fullmatch(r"[0-9a-f]{40}", pins["BF16_TO_HGN_COMMIT"]), "BF16_TO_HGN_COMMIT must be a full commit"
cf = open("Containerfile").read()
assert 'git checkout -q "$BF16_TO_HGN_COMMIT"' in cf and "cargo build --release --locked" in cf, "bf16-to-hgn isn't built from its pin"
assert "/usr/share/licenses/bf16-to-hgn/" in cf and "native/NOTICE" in cf, "bf16-to-hgn's licenses aren't shipped"
assert "bf16-to-hgn" in open("THIRD-PARTY-NOTICES.md").read(), "THIRD-PARTY-NOTICES doesn't name bf16-to-hgn"
assert '--build-arg "BF16_TO_HGN_COMMIT=$BF16_TO_HGN_COMMIT"' in open("scripts/build.sh").read(), "build.sh doesn't pass the pin"
# halogen-dashboard (Quaternion's) is built from an exact commit, and its and its parts' licences ship.
assert re.fullmatch(r"[0-9a-f]{40}", pins["HALOGEN_DASHBOARD_COMMIT"]), "HALOGEN_DASHBOARD_COMMIT must be a full commit"
assert 'git checkout -q "$HALOGEN_DASHBOARD_COMMIT"' in cf and "pnpm install --frozen-lockfile" in cf \
  and "cargo build --release --locked --bin halogen-dashboard" in cf and "pnpm install --frozen-lockfile --ignore-scripts && pnpm build" in cf, "halogen-dashboard isn't built from its pin"
assert "COPY src/dashboard-nodump.c" in cf and "COPY --from=dashboard /out/dashboard-nodump.so /usr/lib64/halos/dashboard-nodump.so" in cf \
  and "PR_SET_DUMPABLE, 0" in open("src/dashboard-nodump.c").read(), "the dashboard's not-dumpable library isn't built or shipped"
assert "/usr/share/licenses/halogen-dashboard/" in cf and "ibm-plex-sans" in cf and "crates.txt" in cf, "halogen-dashboard's licences aren't shipped"
notices = open("THIRD-PARTY-NOTICES.md").read()
# Caddy (halos-proxy) is built from src/caddy's pinned modules, with its four DNS providers, and its
# licences ship.
gomod = open("src/caddy/go.mod").read()
gosrc = open("src/caddy/main.go").read() + "".join(open(f).read() for f in glob.glob("src/caddy/dnsproviders/*.go"))
for m in ("github.com/caddyserver/caddy/v2", "github.com/caddy-dns/cloudflare", "github.com/caddy-dns/porkbun",
          "github.com/libdns/duckdns", "github.com/libdns/namecheap"):
    assert re.search(r"^\t" + re.escape(m) + r" v\d+\.\d+\.\d+$", gomod, re.M), f"{m} isn't pinned in src/caddy/go.mod"
    assert f'"{m}' in gosrc, f"src/caddy doesn't link {m}"
    assert m + " " in open("src/caddy/go.sum").read(), f"src/caddy/go.sum has no hash for {m}"
# caddy-dns/duckdns and caddy-dns/namecheap carry no licence, so halOS uses its own modules instead.
assert "caddy-dns/duckdns" not in gomod and "caddy-dns/namecheap" not in gomod, "an unlicensed caddy-dns plugin is back"
for mod in ("duckdns", "namecheap"):
    assert f'ID:  "dns.providers.{mod}"' in gosrc, f"halOS's {mod} module is missing"
assert "GOFLAGS=-mod=readonly" in cf and "COPY --from=caddy /out/caddy /usr/libexec/halogen/caddy" in cf \
  and "COPY --from=caddy /out/licenses/ /usr/share/licenses/halos-caddy/" in cf, "Caddy isn't built from src/caddy or its licences don't ship"
assert "caddy validate --config /usr/share/halos/proxy/Caddyfile" in cf and "systemctl enable halos-proxy.service" in cf, "the proxy isn't checked or enabled"
assert "caddyserver/caddy" in notices and "halos-caddy/modules.txt" in notices, "THIRD-PARTY-NOTICES doesn't credit Caddy"
assert "Quat3rnion/halogen-dashboard" in notices and "IBM Plex" in notices, "THIRD-PARTY-NOTICES doesn't credit halogen-dashboard and its font"
assert '--build-arg "HALOGEN_DASHBOARD_COMMIT=$HALOGEN_DASHBOARD_COMMIT"' in open("scripts/build.sh").read(), "build.sh doesn't pass the dashboard pin"
assert "--add-service=halos-dashboard" in cf and "halos-dashboard.service" in cf, "the dashboard isn't enabled with its port"
# The public key machines get is the one the signing script checks with (#46).
sign = open("scripts/sign-image.sh").read()
embedded = re.search(r"PUBLIC_KEY='(-----BEGIN PUBLIC KEY-----.*?-----END PUBLIC KEY-----)'", sign, re.S).group(1)
assert embedded + "\n" == open("files/etc/pki/containers/halos-flash.pub").read(), "the image's public key differs from sign-image.sh's"
# Machines take halOS's images only with that key's signature (#46 phase 2b). bootc refuses to
# check against a policy whose default accepts anything, so the default rejects; other registries
# and local storage are accepted, as before (the Halogen image is pinned by digest).
pol = json.load(open("files/etc/containers/policy.json"))
assert pol["default"] == [{"type": "reject"}], "the policy's default must reject: bootc refuses an insecure default"
ours = pol["transports"]["docker"]["ghcr.io/n4berius/halos-flash"]
assert ours == [{"type": "sigstoreSigned", "keyPath": "/etc/pki/containers/halos-flash.pub",
                 "signedIdentity": {"type": "matchRepository"}}], ours
assert all(e == [{"type": "insecureAcceptAnything"}] for t, scopes in pol["transports"].items()
           for scope, e in scopes.items() if scope == ""), "only whole transports are accepted unsigned"
assert set(pol["transports"]["docker"]) == {"ghcr.io/n4berius/halos-flash", ""}, "a new docker scope needs a look"
reg = yaml.safe_load(open("files/etc/containers/registries.d/halos-flash.yaml"))
assert reg["docker"]["ghcr.io/n4berius/halos-flash"]["use-sigstore-attachments"] is True, "machines wouldn't find the signatures"
for ks in ("installer/guided/halos-guided.ks", "installer/anaconda/interactive-defaults.ks"):
    k = open(ks).read()
    assert "%post --nochroot --interpreter=/usr/bin/bash\n" in k and 'mount --bind "$physical" "$root/sysroot"' in k \
        and 'chroot "$root" bootc switch --mutate-in-place --enforce-container-sigpolicy @TARGET_IMAGE@ ' in k, f"{ks} doesn't turn the signature check on"
# The guided install hands plan-install's unlock choice and keys to the new system (#13).
ci = open("Containerfile.installer").read()
assert "COPY files/usr/libexec/halogen/ssh-unlock /usr/libexec/halos/ssh-unlock" in ci, "the installer lacks the key helper"
assert "COPY installer/guided/save-unlock /usr/libexec/halos/save-unlock" in ci, "the installer lacks save-unlock"
assert "/usr/libexec/halos/save-unlock $unlock $disk <<'HALOS_KEYS'" in open("installer/guided/plan-install").read(), "plan-install doesn't hand on the unlock choice"
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

# Every workflow that publishes an image also signs it (#46), and gets cosign before its first
# push, so a failed download leaves nothing unsigned (#90). Fetching alone doesn't count as signing.
for f in .github/workflows/*.yml; do
  code="$(grep -v '^[[:space:]]*#' "$f")"   # commands only, not comments
  grep -q 'podman push\|push-image.sh' <<< "$code" || continue
  signs="$(grep -v -- '--fetch' <<< "$code")"
  grep -q 'sign-image.sh' <<< "$signs" || { echo "$f pushes images but doesn't sign them (scripts/sign-image.sh)" >&2; exit 1; }
  fetch_at="$(grep -n 'sign-image.sh.* --fetch' <<< "$code" | head -n 1 | cut -d: -f1)"
  push_at="$(grep -n 'podman push\|push-image.sh' <<< "$code" | head -n 1 | cut -d: -f1)"
  if [ -z "$fetch_at" ] || [ "$fetch_at" -gt "$push_at" ]; then
    echo "$f pushes before it gets cosign (sign-image.sh --fetch)" >&2; exit 1
  fi
done
echo "ok: every workflow that pushes an image gets cosign first and signs it"

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
grep -qx 'dev.tty.legacy_tiocsti = 0' files/usr/lib/sysctl.d/60-halos.conf || { echo "60-halos.conf lost dev.tty.legacy_tiocsti = 0" >&2; exit 1; }
# journalctl escapes control characters unless told not to; halogenctl must never tell it so.
if grep -nE 'journalctl.*( -a\b| --all\b| -o +cat| --output[= ]cat)' files/usr/bin/halogenctl; then echo "halogenctl runs journalctl in a mode that prints control characters" >&2; exit 1; fi
# shellcheck disable=SC2016 # the literal text in build.sh
grep -q -- '--label "io.github.n4berius.halos.edition=$VARIANT"' scripts/build.sh || { echo "build.sh lost the edition label halosctl reads" >&2; exit 1; }
# Every system unit halOS installs to start on its own is enabled in the image.
for unit in files/usr/lib/systemd/system/*.service; do
  grep -q '^\[Install\]' "$unit" || continue
  grep -qE "systemctl enable .*\b$(basename "$unit" .service)\.service" Containerfile \
    || { echo "$unit has an [Install] section but the Containerfile doesn't enable it" >&2; exit 1; }
done
# Every root unit halOS ships keeps its sandbox: a read-only system and no new privileges.
for unit in files/usr/lib/systemd/system/*.service; do
  # systemd takes the last line of a setting, so each appears exactly once.
  if ! grep -qx 'ProtectSystem=strict' "$unit" || ! grep -qx 'NoNewPrivileges=yes' "$unit" \
    || [ "$(grep -cE '^(ProtectSystem|NoNewPrivileges)=' "$unit")" != 2 ]; then
    echo "$unit lost ProtectSystem=strict or NoNewPrivileges=yes" >&2; exit 1
  fi
done
# The power profile's unit may write only its one file in /sys, with no capabilities.
u=files/usr/lib/systemd/system/halos-platform-profile.service
# A later line would widen an earlier one (capabilities add up), so each setting appears once,
# and nothing grants capabilities or binds paths in another way.
if ! grep -qx 'ProtectKernelTunables=yes' "$u" || ! grep -qx 'CapabilityBoundingSet=' "$u" \
  || [ "$(grep -cE '^(ProtectKernelTunables|CapabilityBoundingSet|ReadWritePaths)=' "$u")" != 3 ] \
  || ! grep -qx 'ReadWritePaths=-/sys/firmware/acpi/platform_profile' "$u" \
  || grep -qE '^(AmbientCapabilities|BindPaths|ReadWriteDirectories|PrivilegedExecStart)=' "$u"; then
  echo "$u may write more than the platform profile" >&2; exit 1
fi
# Every bootc switch halosctl runs asks bootc to check the signature (#46).
switches="$(grep -E '\bbootc switch\b' files/usr/bin/halosctl | grep -v '^ *#')"
# shellcheck disable=SC2016 # the literal text in halosctl
unflagged="$(grep -cvF 'bootc switch "$sig_flag"' <<< "$switches" || true)"
if [ -z "$switches" ] || [ "$unflagged" != 0 ] \
  || ! grep -qx 'sig_flag=--enforce-container-sigpolicy' files/usr/bin/halosctl; then
  echo "halosctl has a bootc switch without --enforce-container-sigpolicy" >&2; exit 1
fi
