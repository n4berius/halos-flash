#!/bin/bash
set -euo pipefail
scripts=(scripts/*.sh tests/*.sh files/usr/bin/* files/usr/libexec/halogen/* installer/guided/plan-install)
for f in "${scripts[@]}"; do
  bash -n "$f"
  [ -x "$f" ] || { echo "$f is not executable" >&2; exit 1; }
done
# The initramfs's own scripts (dracut modules) too; they are run, not sourced, but module-setup.sh.
scripts+=(files/usr/lib/dracut/modules.d/*/*.sh)
if command -v shellcheck >/dev/null; then shellcheck -x "${scripts[@]}"; else echo "shellcheck not installed, skipped"; fi
# Tab completion files are sourced, not run, so they have no #! line and aren't executable.
completions=(files/usr/share/bash-completion/completions/*)
for f in "${completions[@]}"; do bash -n "$f"; done
if command -v shellcheck >/dev/null; then shellcheck -s bash "${completions[@]}"; fi
# The VM test's long checks are written out by vm-login.py and run with bash in the VM: a quoting
# slip should fail here, not 30 minutes into the ISO install test.
probe="$(mktemp -d)"
python3 tests/vm-login.py --scripts "$probe"
for f in report selftest https sshu; do bash -n "$probe/$f.sh"; done
rm -r "$probe"

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
      + glob.glob("files/usr/lib/systemd/system/*.d/*.conf") + glob.glob("files/etc/containers/systemd/users/970/*.container") + glob.glob("files/etc/containers/systemd/users/970/*.network") + glob.glob("files/etc/containers/systemd/users/970/*.d/*.conf")
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
    # The key settings left locked.env (render-config sets them, api-key on|off): still never allowed.
    assert not allowed & {"HALOGEN_API_KEY", "HALOGEN_API_KEY_FILE"}, edition
    assert (edition == "npu") == ("HALOGEN_NPU_MODELS" in allowed)
assert "HALOGEN_DOWNLOAD" not in q.replace("# No download settings here", "")
assert "@sha256" not in q and "Image=@HALOGEN_IMAGE@" in q
# Halogen carries XRT from 0.19.1. A partial host XRT is refused, so mount none at all.
for unit in (q, n):
    assert not re.search(r"^Volume=.*(xilinx|libxrt)", unit, re.M | re.I), "no XRT mounts: Halogen's image has its own"
xml.dom.minidom.parse("files/usr/lib/firewalld/services/halogen.xml")
pins = dict(l.strip().split("=", 1) for l in open("versions.env") if "=" in l and not l.startswith("#"))
assert re.fullmatch(r"[0-9a-f]{40}", pins["HALOGEN_WEIGHTS_REVISION"]), "HALOGEN_WEIGHTS_REVISION must be a commit, not a branch"
# The hashes fetch-models checks the official files against belong to that same revision.
sums = open("files/usr/share/halogen/weights.sha256").read()
assert f"from {pins['HALOGEN_WEIGHTS_REPO']}\n" in sums, "weights.sha256 is for another weights repository: run scripts/weights-sums.sh"
assert f"\n# revision {pins['HALOGEN_WEIGHTS_REVISION']}\n" in sums, "weights.sha256 is for another weights revision: run scripts/weights-sums.sh"
for f in ("qwen38-flash-next-v2.hgn", "qwen38-flash-next-ngram.hgn", "qwen38-flash-next-drafter-r2-ht4.hgn", "qwen38-flash-next-drafter-r2.hgn", "qwen38-flash-next-vision.hgn", "tokenizer/tokenizer.json"):
    assert re.search(r"^[0-9a-f]{64}  " + re.escape(f) + "$", sums, re.M), f"weights.sha256 has no hash for {f}"
# Older Halogen images have no XRT of their own and need the host's.
assert tuple(map(int, re.match(r"(\d+)\.(\d+)\.(\d+)", pins["HALOGEN_VERSION"]).groups())) >= (0, 19, 1), "Halogen before 0.19.1 needs the host's XRT"
assert "DEBIAN_IMAGE" not in pins and "XRT_MIN_VERSION" not in pins
# bf16-to-hgn is built from an exact commit, and its licenses ship (halogenctl flash convert).
assert re.fullmatch(r"[0-9a-f]{40}", pins["BF16_TO_HGN_COMMIT"]), "BF16_TO_HGN_COMMIT must be a full commit"
cf = open("Containerfile").read()
# The helper programs are built in Containerfile.helpers, once per CI run, and reach the OS image
# through the "helpers" build context on the same base by digest (#122).
hf = open("Containerfile.helpers").read()
bs = open("scripts/build.sh").read()
assert '--build-context "helpers=$HALOS_HELPERS/tree"' in bs and 'scripts/build-helpers.sh --check "$HALOS_HELPERS"' in bs \
  and '--build-arg "FEDORA_BOOTC_IMAGE=$BASE_IMAGE"' in bs, "build.sh doesn't build on the helpers' base, or doesn't check them"
for stage in ("bf16-to-hgn", "dashboard", "caddy"):
    assert f"FROM ${{FEDORA_BOOTC_IMAGE}} AS {stage}\n" in hf, f"Containerfile.helpers has no {stage} stage"
    assert f" AS {stage}\n" not in cf and f"--from={stage} " not in cf, f"the Containerfile builds {stage} itself again"
assert 'git checkout -q "$BF16_TO_HGN_COMMIT"' in hf and "cargo build --release --locked" in hf, "bf16-to-hgn isn't built from its pin"
assert "COPY --from=helpers bf16-to-hgn/licenses/ /usr/share/licenses/bf16-to-hgn/" in cf and "native/NOTICE" in hf, "bf16-to-hgn's licenses aren't shipped"
assert "bf16-to-hgn" in open("THIRD-PARTY-NOTICES.md").read(), "THIRD-PARTY-NOTICES doesn't name bf16-to-hgn"
assert '--build-arg "BF16_TO_HGN_COMMIT=$BF16_TO_HGN_COMMIT"' in open("scripts/build.sh").read(), "build.sh doesn't pass the pin"
# halogen-dashboard (Quaternion's) is built from an exact commit, and its and its parts' licences ship.
assert re.fullmatch(r"[0-9a-f]{40}", pins["HALOGEN_DASHBOARD_COMMIT"]), "HALOGEN_DASHBOARD_COMMIT must be a full commit"
assert 'git checkout -q "$HALOGEN_DASHBOARD_COMMIT"' in hf and "pnpm install --frozen-lockfile" in hf \
  and "cargo build --release --locked --bin halogen-dashboard" in hf and "pnpm install --frozen-lockfile --ignore-scripts && pnpm build" in hf, "halogen-dashboard isn't built from its pin"
assert "COPY src/dashboard-nodump.c" in hf and "COPY --from=helpers dashboard/dashboard-nodump.so /usr/lib64/halos/dashboard-nodump.so" in cf \
  and "PR_SET_DUMPABLE, 0" in open("src/dashboard-nodump.c").read(), "the dashboard's not-dumpable library isn't built or shipped"
assert "/usr/share/licenses/halogen-dashboard/" in cf and "ibm-plex-sans" in hf and "crates.txt" in hf, "halogen-dashboard's licences aren't shipped"
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
assert "export GOPROXY=off GOCACHE=/go-build" in hf and "go test -c -o" in hf and "COPY src/caddy/go.mod src/caddy/go.sum /src/caddy/" in hf, "the caddy stage must build offline from the checked modules and always run its tests (#122)"
assert "GOFLAGS=-mod=readonly" in hf and "COPY --from=helpers caddy/caddy /usr/libexec/halogen/caddy" in cf \
  and "COPY --from=helpers caddy/licenses/ /usr/share/licenses/halos-caddy/" in cf and "-iname 'notice*'" in hf \
  and 'cp "$goli" "$lic/go-LICENSE"' in hf, "Caddy isn't built from src/caddy or its licences don't ship"
# Halogen's container runs read-only, with only /tmp, /var/tmp and /root writable, on disk.
quadlet = open("files/etc/containers/systemd/users/970/halogen.container").read()
# podman's own read-only tmpfs would race the volumes on /tmp and /var/tmp, so it is off.
for line in ("ReadOnly=true", "ReadOnlyTmpfs=false", "Tmpfs=/run", "Volume=/dev/shm:/dev/shm", "Volume=/tmp",
             "Volume=/var/tmp", "Volume=/root", "ExecStartPre=-/usr/bin/podman rm -v -f -i halogen"):
    assert "\n" + line + "\n" in quadlet, f"halogen.container lacks {line}"
assert not re.search(r"^Tmpfs=/(var/)?tmp", quadlet, re.M), "Halogen's scratch folders must stay on disk, not in memory"
# Halogen's network has no route out and no DNS (#120); the download containers don't use it.
assert "\nNetwork=halogen-internal.network\n" in quadlet and len(re.findall(r"^Network=", quadlet, re.M)) == 1, "Halogen's container isn't on halogen-internal alone"
hnet = open("files/etc/containers/systemd/users/970/halogen-internal.network").read()
for line in ("[Network]", "NetworkName=halogen-internal", "Internal=true", "DisableDNS=true"):
    assert "\n" + line + "\n" in "\n" + hnet, f"halogen-internal.network lacks {line}"
assert not re.search(r"^(IPv6|Gateway|Options|Subnet|IPRange)=", hnet, re.M), "halogen-internal.network sets more than it needs"
for f in glob.glob("variants/*/etc/containers/systemd/users/970/halogen.container.d/*.conf") + glob.glob("files/etc/containers/systemd/users/970/halogen.container.d/*.conf"):
    assert not re.search(r"^Network=|^PodmanArgs=.*--net", open(f).read(), re.M), f"{f} changes Halogen's network"
assert not re.search(r"^PodmanArgs=.*--net", quadlet, re.M), "halogen.container's PodmanArgs change its network"
# The https helper lets through exactly the Cloudflare token shapes the plugin accepts (it prints a
# token it refuses), and the build checks the plugin still uses those two (H1).
helper = open("files/usr/libexec/halogen/https").read()
for rx in ("^[A-Za-z0-9_-]{35,50}$", "^cf(ut|at)_[A-Za-z0-9_-]{32,256}$"):
    assert f"grep -qF 'regexp.MustCompile(`{rx}`)'" in hf, f"the build doesn't check caddy-dns/cloudflare still uses {rx}"
    assert f'"$3" =~ {rx}' in helper, f"dns_value_ok doesn't use the Cloudflare shape {rx}"
# DNS credentials reach Caddy through systemd's credentials, read from root's folder (H5), never
# copied into Caddy's own runtime folder.
proxy = open("files/usr/lib/systemd/system/halos-proxy.service").read()
assert "\nLoadCredential=dns:/etc/halos/https/dns\n" in proxy, "halos-proxy doesn't load the DNS credentials as credentials"
for f in glob.glob("files/usr/share/halos/proxy/acme/dns-*.caddy"):
    body = open(f).read()
    assert "{file.{$CREDENTIALS_DIRECTORY}/dns_" in body and "RUNTIME_DIRECTORY" not in body, f"{f} doesn't read the credentials from CREDENTIALS_DIRECTORY"
assert ".dns_$f." not in helper, "the https helper still copies DNS credentials into Caddy's runtime folder"
assert re.search(r"^d /etc/halos/https/dns 0700 root root", open("files/usr/lib/tmpfiles.d/halos.conf").read(), re.M), "/etc/halos/https/dns isn't made at boot"
# Logs (#107): halOS's audit rules replace Fedora's (which turn file watches off), Halogen's own
# processes stay out of syscall auditing, and nothing in auditd.conf can stop the machine.
rules = open("files/etc/audit/rules.d/50-halos.rules").read()
assert "\n-a task,never -F uid=970 -F auid=970\n" in rules and len(re.findall(r"^-a task,never", rules, re.M)) == 1 and rules.rstrip().endswith("\n-e 2") and not re.search(r"^-a task,never$", rules, re.M), "the audit rules don't leave out only Halogen"
assert "rm -f /etc/audit/rules.d/audit.rules" in cf and "systemctl enable auditd.service audit-rules.service" in cf, "Fedora's audit rules stay, or auditd isn't enabled"
assert "(HALT|SINGLE)" in cf and "disk_full_action = SUSPEND" in cf, "auditd.conf isn't checked against stopping the machine"
# 20 files of 50 MB fit the 2 GiB a custom install may give /var/log/audit, above admin_space_left.
assert "'max_log_file = 50' 'num_logs = 20'" in cf, "the audit log may outgrow a 2 GiB volume, where auditd then stops recording"
# set -e ignores failures inside "a && b" and "! cmd": the build's rule checks are plain statements.
assert "augenrules &&" not in cf and "&& ! grep" not in cf, "the build's audit rule check can't fail"
assert len(re.findall(r"^-a always,exit -F path=\S+ -F perm=x -F auid!=unset -k \S+$", rules, re.M)) == 6 and not re.search(r"^-w .* -p x ", rules, re.M), "program rules must leave out the system's own runs (the status timer)"
# Hardening: the paths that decide how Halogen and the machine start are watched, the specific
# signature-policy rules come before the wider /etc/containers one, and the rules are locked.
for w in ("/etc/environment", "/etc/fstab", "/etc/nsswitch.conf", "/etc/authselect", "/etc/ld.so.conf", "/etc/ld.so.conf.d", "/etc/ld.so.cache", "/etc/sysctl.conf", "/etc/containers/systemd", "/etc/audit", "/etc/systemd", "/etc/ssh", "/etc/pam.d", "/etc/crypttab", "/etc/ld.so.preload"):
    assert re.search(rf"^-w {re.escape(w)} -p wa -k ", rules, re.M), f"no audit watch on {w}"
assert rules.index("-w /etc/containers/policy.json") < rules.index("-w /etc/containers/systemd") < rules.index("-w /etc/containers -p"), "the wider /etc/containers watch must come last"
assert "\n-a always,exit -F path=/usr/bin/kmod -F perm=x -k modules\n" in rules, "runs of modprobe/insmod aren't recorded"
ctl = open("files/usr/bin/halogenctl").read()
assert ctl.startswith("#!/bin/bash -p\n") and "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin LANG=C.UTF-8 /usr/libexec/halogen/selftest" in ctl, "the selftest's test variables work for root in production"
# Cache hardening: the cache mount lives in a drop-in (so cache off can replace it), and every
# container that mounts all of /srv/models hides the cache folder behind an empty tmpfs.
assert ".prompt-cache" not in "\n".join(l for l in open("files/etc/containers/systemd/users/970/halogen.container").read().splitlines() if not l.startswith("#")), "the cache mount is back in halogen.container: cache off can't make it read-only"
assert "\nVolume=/srv/models/.prompt-cache:/models/.prompt-cache:noexec,nosuid,nodev\n" in open("files/etc/containers/systemd/users/970/halogen.container.d/15-prompt-cache.conf").read()
for path in glob.glob("files/usr/libexec/halogen/*"):
    body = open(path).read()
    for line in body.splitlines():
        # Any spelling of a mount whose destination is all of /models (-v, --volume, ${models}, :rw, dst=).
        if not line.lstrip().startswith("#") and re.search(r'[:=]/models(:[a-z,]+)?["\s)]|dst=/models\b', line):
            assert '"${hide_cache[@]}"' in line, f"{path} mounts all of /srv/models without hiding the prompt cache: {line.strip()}"
    if "hide_cache" in body:
        assert 'hide_cache=(--tmpfs "/models/.prompt-cache:ro,size=4k,notmpcopyup")' in body, f"{path}: the tmpfs must not copy the folder's files up"
# Whatever root runs as halogen through setpriv reaching halogen-controlled programs goes in a
# session of its own: halogen's podman and systemd settings decide what those run, and code that
# shares root's terminal could read keystrokes or fake a prompt (security audit of #137). In the
# selftest through run_alone (setsid before timeout, so the time limit reaches what it starts).
for path, ok in (("files/usr/libexec/halogen/selftest", r"\brun_alone\s+(\S+\s+)*setpriv\b"),
                 ("files/usr/bin/halogenctl", r"\bsetpriv\b.*\benv\b.*\bsetsid\s+-w\s+(podman|systemctl)\b")):
    text = open(path).read().replace("\\\n", " ")
    for line in text.splitlines():
        code = line.split(" #", 1)[0]
        if re.search(r"\bsetpriv\b", code) and re.search(r"\b(podman|systemctl|container-check)\b", code) and not code.lstrip().startswith("#"):
            assert re.search(ok, code), f"{path} runs something as halogen outside a session of its own: {code.strip()[:120]}"
# A container set up like Halogen's is started by the selftest (and so by the VM test), since the
# VM never starts Halogen: crun 1.31 broke every start of it unseen by CI.
assert re.fullmatch(r"[0-9a-f]{64}", pins["CRUN_PIN_SHA256"]) and pins["CRUN_PIN_URL"].startswith("https://kojipkgs.fedoraproject.org/packages/crun/") and "/data/signed/" in pins["CRUN_PIN_URL"] and "rpmkeys -K /tmp/crun.rpm" in cf, "crun's hold needs an exact package and its sha256"
assert 'curl -fsSL --retry 3 -o /tmp/crun.rpm "$CRUN_PIN_URL"' in cf and 'echo "$CRUN_PIN_SHA256  /tmp/crun.rpm" | sha256sum -c -' in cf and "downgrade /tmp/crun.rpm" in cf, "crun's hold is gone from the Containerfile"
assert cf.index("RUN dnf -y --setopt=install_weak_deps=False install") < cf.index("downgrade /tmp/crun.rpm") < cf.index("COPY files/ /"), "crun's hold must come after the main dnf install (which would bring 1.31 back) and before the files"
assert '"CRUN_PIN_SHA256=$CRUN_PIN_SHA256"' in open("scripts/build.sh").read(), "crun's hold isn't passed to the build"
assert '[[ "$tag" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+-[1-9][0-9]{0,3}-(alpha|rc|stable)$ ]] ||' in open(".github/workflows/release.yml").read(), "release.yml must refuse a beta or old-style tag pushed by hand (#141)"
assert "rpmkeys --delete f577861e" in cf, "Fedora 45's key must leave the image's rpm keyring after crun's check"
assert "RUN --mount=type=bind,source=src/authenticode-check.py,target=/tmp/authenticode-check.py" in cf, "the kernel-next step must check the kernel's Secure Boot signature"
assert "HALOS_KERNEL_BUILT=" in cf, "release.env must record when the kernel was built (the selftest's kernel-next age check)"
# The Fedora base is a tag, resolved once per build to the digest every stage and the installer
# use, and recorded with the packages and toolchains (#121).
b = open("scripts/build.sh").read()
bh = open("scripts/build-helpers.sh").read()
assert "--format '{{.Digest}} " in bh and 'FEDORA_BOOTC_IMAGE=$base"' in bh, "build-helpers.sh must resolve the base to a digest and build on it"
assert '--build-arg "FEDORA_BOOTC_IMAGE=$BASE_IMAGE"' in b and '--label "io.github.n4berius.halos.base=$BASE_IMAGE"' in b, "build.sh must resolve the base to a digest, build on it and label it"
assert "scripts/build-info.sh" in b, "build.sh must write the build record"
froms = re.findall(r"^FROM\s+(\S+)", cf + hf, re.M)
assert all(f in ("${FEDORA_BOOTC_IMAGE}", "scratch") for f in froms) and froms.count("${FEDORA_BOOTC_IMAGE}") >= 4, f"every stage must start from the resolved base: {froms}"
for want in ('echo "HALOS_BASE_IMAGE=${FEDORA_BOOTC_IMAGE}"', "/usr/share/halogen/packages.txt", "/usr/share/halogen/toolchains.txt", "*@sha256:*) ;;"):
    assert want in cf, f"the image's build record is gone from the Containerfile: {want}"
assert 'io.github.n4berius.halos.base' in open("scripts/build-iso.sh").read(), "the installer must use the OS image's base"
rel = open(".github/workflows/release.yml").read()
assert "git show origin/main:scripts/build-info.sh" in rel and "pattern: info-*" in rel, "releases must attach each edition's build record"
# kernel-next: exact Fedora packages, each with a sha256, from Koji's signed copies, checked in the
# build (sha256, signature, one kernel left, not a debug build, signed for Secure Boot); only
# builds asked for with KERNEL_TRACK=next get it, and only main pushes them, as kernel-next.
nvr = pins["KERNEL_NEXT_NVR"]
sums = dict(p.split(":", 1) for p in pins["KERNEL_NEXT_SHA256"].strip('"').split())
assert sorted(sums) == ["kernel", "kernel-core", "kernel-modules", "kernel-modules-core"] and all(re.fullmatch(r"[0-9a-f]{64}", v) for v in sums.values()), "kernel-next needs the four packages, each with a sha256"
assert pins["KERNEL_NEXT_URL"].startswith("https://kojipkgs.fedoraproject.org/packages/kernel/") and "/data/signed/" in pins["KERNEL_NEXT_URL"] and nvr.replace("-", "/", 1) in pins["KERNEL_NEXT_URL"], "kernel-next must come from Koji's signed copies of that exact build"
for want in ('echo "${pair#*:}  $f" | sha256sum -c -', "rpmkeys -K", 'python3 -I /tmp/authenticode-check.py "$m/vmlinuz" "$1" /tmp/k/base-vmlinuz', "rpmkeys --delete 91211fce", 'grep -qx "CONFIG_$opt=y"', 'case "$KERNEL_TRACK" in fedora)'):
    assert want in cf, f"kernel-next's checks are gone from the Containerfile: {want}"
assert cf.index('downgrade /tmp/crun.rpm') < cf.index('rpm -U /tmp/k/*.rpm') < cf.index('dracut --no-hostonly'), "the test kernel must go in before the initramfs is built"
b = open("scripts/build.sh").read()
assert '"KERNEL_TRACK=$KERNEL_TRACK"' in b and '"KERNEL_NEXT_SHA256=$KERNEL_NEXT_SHA256"' in b, "build.sh doesn't pass kernel-next's pins"
assert "kernel-next" in open(".github/workflows/build.yml").read() and "HALOS_EXPECT_KERNEL" in open(".github/workflows/iso.yml").read(), "kernel-next isn't built or install-tested"
# main's ruleset requires "build (npu)" and "build (no-npu)": the Fedora-kernel jobs must keep those names.
ruleset = json.load(open(".github/rulesets/protect-main.json"))
required = {c["context"] for r in ruleset["rules"] if r["type"] == "required_status_checks" for c in r["parameters"]["required_status_checks"]}
assert {"build (npu)", "build (no-npu)"} <= required and "name: build (${{ matrix.variant }}${{ matrix.kernel == 'next' && ', kernel-next' || '' }})" in open(".github/workflows/build.yml").read(), "the build jobs no longer report the check names main requires"
for wf in (".github/workflows/build.yml", ".github/workflows/iso.yml"):
    assert "IMAGE_TAG: ${{ matrix.kernel == 'next' && 'kernel-next' || '' }}" in open(wf).read(), f"{wf}: the test-kernel image must be tagged kernel-next, the tag that is pushed"
assert "container-check" in open("files/usr/libexec/halogen/selftest").read() and "'PASS container-start:'" in open("tests/iso-install.sh").read(), "the selftest or the VM test no longer starts a container set up like Halogen's"
fc = open("files/usr/libexec/halogen/flash-checkpoint").read()
# Download path: the shared lookup table is a reflink copy first (a hard link lets the next pull's
# container write the official file), and no folder is mounted through a link.
assert 'cp --reflink=auto -- "$models/$table" "$dir/$table"' in fc and 'ln "$models/$table"' not in fc, "the shared lookup table is hard-linked, not copied"
for script in ("flash-checkpoint", "model-pull"):
    assert "plain_dir() {" in open(f"files/usr/libexec/halogen/{script}").read(), f"{script} mounts folders without checking for links in their path"
fm = open("files/usr/libexec/halogen/fetch-models").read()
assert '"${pin[@]}"' in fm and "--name halogen-fetch-download --replace" in fm and "for f in npu decider LFM custom flash; do\n  if [ -L" in fm
assert "-$m/.prompt-cache -$l -/dev/shm -/sysroot -/var/log\"" in fc and "-p PrivateUsers=yes -p PrivateDevices=yes" in fc and "-p RestrictAddressFamilies=none" not in fc and '-p "SystemCallFilter=~socket socketpair io_uring_setup io_uring_enter io_uring_register"' in fc and "-p SystemCallArchitectures=native" in fc, "the convert sandbox can read the prompt cache, the request records, devices, shared memory or the journal"
# The folders Halogen's container can write and find again hold no programs; halogen never logs in.
npuconf = open("variants/npu/etc/containers/systemd/users/970/halogen.container.d/10-npu.conf").read()
for f in ("decider", "LFM", "custom"):
    assert f"\nVolume=/srv/models/{f}:/models/{f}:noexec,nosuid,nodev\n" in npuconf, f"{f} is mounted without noexec,nosuid,nodev"
assert "\nVolume=/srv/models/npu:/models/npu:ro,noexec,nosuid,nodev\n" in npuconf
assert re.search(r"^DenyUsers halogen$", open("files/etc/ssh/sshd_config.d/00-halos.conf").read(), re.M), "the halogen service user could log in over SSH"
assert "-$m/.prompt-cache" in open("files/usr/libexec/halogen/flash-checkpoint").read(), "the convert sandbox can read the prompt cache"
# fail2ban (#92): installed with its nftables action, both jails on and reading the journal, this
# machine and private networks never shut out, checked at build, sandboxed, and its folder watched.
jail = open("files/etc/fail2ban/jail.d/50-halos.conf").read()
assert "fail2ban-server nftables" in cf and "fail2ban-firewalld" not in cf and 'banaction = nftables[type=multiport, blocktype="reject with tcp reset"]' in jail and "systemctl enable fail2ban.service" in cf and "fail2ban-client -t" in cf and "fail2ban-regex" in cf
assert "\nbackend = systemd\n" in jail and re.search(r"\[sshd\]\nenabled = true", jail) and re.search(r"\[halos-api\]\nenabled = true\nfilter = halos-api\nport = 8731\nmaxretry = 10\nfindtime = 10m\nbantime = 10m", jail)
for net in ("127.0.0.0/8", "::1", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7"):
    assert net in re.search(r"^ignoreip = (.*)$", jail, re.M).group(1).split(), f"fail2ban could shut out {net}"
flt = open("files/etc/fail2ban/filter.d/halos-api.conf").read()
assert '\nfailregex = ^\\S+ caddy\\[\\d+\\]: \\{"level"' in flt and '"remote_ip":"<ADDR>"' in flt and "journalmatch = _SYSTEMD_UNIT=halos-proxy.service" in flt, "the API filter must start at the journal line's beginning (host, program, then Caddy's JSON) and read only the front door's log"
assert "\nusedns = no\n" in jail and "loglevel = NOTICE" in open("files/etc/fail2ban/fail2ban.d/50-halos.conf").read()
sb = open("files/usr/lib/systemd/system/fail2ban.service.d/10-halos.conf").read()
for opt in ("CPUQuota=", "TasksMax=", "StateDirectory=fail2ban", "ProtectSystem=strict", "ProtectHome=yes", "MemoryMax=", "CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_NET_ADMIN\n",
            "IPAddressDeny=any", "SystemCallFilter=@system-service", "ProtectProc=invisible", "PrivateIPC=yes", "UMask=0077",
            "ExecStartPre=-/usr/sbin/nft delete table inet f2b-table", "SystemCallFilter=~@privileged @resources\n",
            "InaccessiblePaths=/run/dbus\n"):
    assert opt in sb, f"fail2ban's sandbox lacks {opt}"
# Access-log lines stay whole for fail2ban: the header cap in every Caddyfile, and journald's LineMax above 6 x (cap + 4 KB).
for c in ("Caddyfile", "Caddyfile.https", "Caddyfile.letsencrypt"):
    assert "\t\tmax_header_size 32KB\n" in open(f"files/usr/share/halos/proxy/{c}").read(), f"{c} has no header size limit"
assert "\t\t\tresp_headers delete\n" in open("files/usr/share/halos/proxy/sites.caddy").read(), "Halogen's reply headers reach the access log"
assert "s/^StrictForwardPorts=no$/StrictForwardPorts=yes/" in cf, "firewalld lets through ports others DNAT"
assert "request>tls>server_name delete" in open("files/usr/share/halos/proxy/sites.caddy").read(), "the TLS name can make an access-log line too long for the journal"
for c in ("Caddyfile.https", "Caddyfile.letsencrypt"):
    assert "log default {\n\t\texclude http.log.access\n\t}" in open(f"files/usr/share/halos/proxy/{c}").read(), f"{c}: Caddy's default logger would write API keys of requests no site matches"
assert "\nLineMax=256K\n" in open("files/usr/lib/systemd/journald.conf.d/60-halos.conf").read()
assert not re.search(r"^NoNewPrivileges=", sb, re.M), "NoNewPrivileges keeps fail2ban out of its own SELinux domain (fail2ban_t)"
assert "/run/systemd/private" not in re.sub(r"^#.*$", "", sb, flags=re.M), "masking systemd's private socket stopped fail2ban from starting (VM test)"
assert "SystemCallErrorNumber" not in sb, "a refused call must kill fail2ban (audited, restarted), not fail quietly"
assert re.search(r"^-w /etc/fail2ban -p wa -k fail2ban$", rules, re.M), "fail2ban's settings aren't watched"
assert "= '-e 2' ]" in cf, "the build doesn't check the audit rules end locked"
assert "SystemMaxUse=4G" in open("files/usr/lib/systemd/journald.conf.d/60-halos.conf").read(), "the journal has no cap"
assert "systemctl enable halos-https-refresh.timer" in cf, "the HTTPS address refresh isn't enabled"
assert "caddy adapt --config /usr/share/halos/proxy/Caddyfile.https" in cf and "for tls in internal custom" in cf, "the HTTPS Caddyfile isn't checked at build"
assert "caddy adapt --config /usr/share/halos/proxy/Caddyfile.letsencrypt" in cf and "for dns in cloudflare duckdns porkbun namecheap" in cf, "the Let's Encrypt Caddyfile isn't checked at build for every DNS provider"
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
# The quick checks run once, before both edition builds, in a job that can only read (#123).
bj = yaml.safe_load(open(".github/workflows/build.yml").read())["jobs"]
assert "check" in bj["build"]["needs"] and "environment" not in bj["check"] and bj["check"]["permissions"] == {"contents": "read"}, "build.yml's check job must gate the builds and hold no rights"
# The helper programs are built once per run, by a job that can only read and never signs (#122).
assert "helpers" in bj["build"]["needs"] and "environment" not in bj["helpers"] and bj["helpers"]["permissions"] == {"contents": "read"}, "build.yml's helpers job must feed the builds and hold no rights"
assert 'HALOS_HELPERS="$RUNNER_TEMP/helpers" scripts/build.sh' in str(bj["build"]["steps"]), "build.yml's image jobs don't use the helpers job's programs"
assert '{"context": "check"}' in open(".github/rulesets/protect-main.json").read(), "the check job isn't a required check in the ruleset"
# udisks2 (kept for fwupd, #106) is root's alone: a polkit rule refuses everyone else, and halogen
# can't reach it on the bus.
rules = open("files/usr/share/polkit-1/rules.d/10-halos-udisks2.rules").read()
assert 'org.freedesktop.udisks2.' in rules and 'subject.user != "root"' in rules and "polkit.Result.NO" in rules, "the udisks2 polkit rule is missing"
bus = open("files/usr/share/dbus-1/system.d/halos-udisks2.conf").read()
assert '<policy user="halogen">' in bus and '<deny send_destination="org.freedesktop.UDisks2"/>' in bus, "the udisks2 D-Bus policy for halogen is missing"
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
