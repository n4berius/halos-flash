ARG FEDORA_BOOTC_IMAGE

FROM ${FEDORA_BOOTC_IMAGE} AS os
ARG HALOGEN_VARIANT
ARG HALOGEN_IMAGE
ARG HALOGEN_VERSION
ARG HALOGEN_SOURCE_COMMIT
ARG HALOGEN_CLOCK_SHA256
ARG HALOGEN_LICENSE_SHA256
ARG HALOGEN_NOTICES_SHA256
ARG HALOGEN_WEIGHTS_REPO
ARG HALOGEN_WEIGHTS_REVISION

# A headless AMD server: AMD GPU, NPU and CPU firmware, the network firmware Strix Halo boards
# use (Realtek, MediaTek, Qualcomm), the Wi-Fi channel rules (wireless-regdb, small, with iw;
# the Wi-Fi driver asks for them at boot) and a few admin tools. fwupd stays for firmware updates,
# with udisks2: fwupd finds the EFI partition only through it (EspLocation only picks among what it
# lists), so without it the Secure Boot revocation list (dbx) can't be updated. It starts on demand.
# auditd (#107): Fedora's default rules file turns syscall auditing, and file watches with it, off,
# so it goes and halOS's rules (files/etc/audit/rules.d) take its place. The audit log rotates at
# 50 MB, 20 files (1 GB, so it fits the 2 GiB a custom install may give /var/log/audit), and a full disk never stops the machine: logging pauses (SUSPEND), after
# a note in the journal.
# fail2ban (#92): shuts out addresses that keep failing SSH logins or API keys, through its own
# nftables table (nft comes with firewalld; named here so it stays); its settings are in files/etc/fail2ban.
# clevis (#44): unlocks the disk from a tang server on the network; its dracut and systemd parts put
# the password agent into the initramfs, which halOS's own module starts only where it's set up.
RUN dnf -y --setopt=install_weak_deps=False install \
      amd-gpu-firmware firewalld linux-firmware tpm2-tss tpm2-tools clevis clevis-luks clevis-dracut clevis-systemd \
      amdsmi nvtop htop pciutils usbutils tmux wireless-regdb nano bash-completion audit audit-rules fail2ban-server nftables && \
    dnf -y remove \
      nvidia-gpu-firmware intel-gpu-firmware intel-npu-firmware intel-audio-firmware \
      cirrus-audio-firmware brcmfmac-firmware tiwilink-firmware nxpwireless-firmware \
      qcom-wwan-firmware microcode_ctl \
      'qemu-user-static*' toolbox sos python3-boto3 python3-botocore python3-s3transfer \
      'sssd*' adcli libsmbclient 'samba-*' nfs-utils \
      btrfs-progs nilfs-utils f2fs-tools ntfsprogs ntfs-3g exfatprogs udftools \
      fwupd-plugin-modem-manager ModemManager-glib libqmi libmbim && \
    dnf clean all && \
    rm -rf /var/log/dnf5.log /var/lib/dnf /var/cache/libdnf5 /run/dnf && \
    rpm -q bash-completion fwupd udisks2 skopeo jq clevis-dracut clevis-systemd amd-ucode-firmware realtek-firmware mt7xxx-firmware atheros-firmware && \
    systemctl disable udisks2.service && ls /usr/share/dbus-1/system-services/org.freedesktop.UDisks2.service && \
    ls -d /usr/lib/firmware/amdgpu /usr/lib/firmware/amdnpu && \
    for c in runuser setpriv prlimit nano auditctl augenrules ausearch aureport clevis jose curl; do command -v "$c" > /dev/null || { echo "missing: $c" >&2; exit 1; }; done && \
    rm -f /etc/audit/rules.d/audit.rules && \
    sed -i -E -e 's/^max_log_file *=.*/max_log_file = 50/' -e 's/^num_logs *=.*/num_logs = 20/' \
      -e 's/^max_log_file_action *=.*/max_log_file_action = ROTATE/' \
      -e 's/^space_left *=.*/space_left = 500/' -e 's/^space_left_action *=.*/space_left_action = SYSLOG/' \
      -e 's/^admin_space_left *=.*/admin_space_left = 200/' -e 's/^admin_space_left_action *=.*/admin_space_left_action = SUSPEND/' \
      -e 's/^disk_full_action *=.*/disk_full_action = SUSPEND/' -e 's/^disk_error_action *=.*/disk_error_action = SUSPEND/' \
      /etc/audit/auditd.conf && \
    for kv in 'max_log_file = 50' 'num_logs = 20' 'max_log_file_action = ROTATE' 'space_left = 500' 'space_left_action = SYSLOG' 'admin_space_left = 200' \
      'admin_space_left_action = SUSPEND' 'disk_full_action = SUSPEND' 'disk_error_action = SUSPEND'; do \
      grep -qx "$kv" /etc/audit/auditd.conf || { echo "auditd.conf lacks: $kv" >&2; exit 1; }; done && \
    if grep -qiE '^[a-z_]*_action *= *(HALT|SINGLE)' /etc/audit/auditd.conf; then echo "auditd.conf could stop the machine" >&2; exit 1; fi

# crun held at the version that starts Halogen (versions.env says why), checked by its sha256.
ARG CRUN_PIN_URL
ARG CRUN_PIN_SHA256
RUN set -eu; \
    curl -fsSL --retry 3 -o /tmp/crun.rpm "$CRUN_PIN_URL"; \
    echo "$CRUN_PIN_SHA256  /tmp/crun.rpm" | sha256sum -c -; \
    rpmkeys --import /usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-45-x86_64; \
    rpmkeys -K /tmp/crun.rpm | grep -q 'digests signatures OK'; \
    want="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' /tmp/crun.rpm)"; \
    echo "crun in Fedora's base today: $(rpm -q crun); held at: $want"; \
    case "$(rpm -q --qf '%{VERSION}' crun)" in 1.30*|1.31) ;; *) echo "WARNING: Fedora now ships $(rpm -q crun): check whether it fixes crun#2480, and remove the hold (versions.env)";; esac; \
    if [ "$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}' crun)" != "$want" ]; then dnf -y --setopt=install_weak_deps=False downgrade /tmp/crun.rpm || dnf -y --setopt=install_weak_deps=False install /tmp/crun.rpm; fi; \
    [ "$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}' crun)" = "$want" ]; \
    rpmkeys --delete f577861e; \
    if rpmkeys --list | grep -qi f577861e; then echo "Fedora 45's key is still in the rpm keyring" >&2; exit 1; fi; \
    rm -f /tmp/crun.rpm; dnf clean all; rm -rf /var/log/dnf5.log /var/lib/dnf /var/cache/libdnf5 /run/dnf

# kernel-next images only (KERNEL_TRACK=next): Fedora 46's 7.4 test kernel in place of Fedora
# 45's, from the exact packages versions.env names, each checked by sha256 and Fedora 46's
# signature. Fails unless the base has exactly the four kernel packages it replaces, the new one
# is the only kernel left, has its debug options off and carries the GPU and NPU drivers, and its
# Secure Boot signature checks out the way shim checks it (src/authenticode-check.py: the signed
# hash, the signature, a code-signing certificate under the CA in the base's own shim, and an SBAT
# generation no lower than Fedora 45's kernel). Fedora 46's key leaves the rpm keyring afterwards.
# The initramfs step below rebuilds for it.
ARG KERNEL_TRACK=fedora
ARG KERNEL_NEXT_NVR
ARG KERNEL_NEXT_URL
ARG KERNEL_NEXT_SHA256
RUN --mount=type=bind,source=src/authenticode-check.py,target=/tmp/authenticode-check.py \
    set -eu; \
    case "$KERNEL_TRACK" in fedora) echo "kernel: Fedora 45's own, $(rpm -q kernel-core)"; exit 0 ;; next) ;; \
      *) echo "unknown KERNEL_TRACK: $KERNEL_TRACK" >&2; exit 1 ;; esac; \
    have="$(rpm -qa --qf '%{NAME}\n' 'kernel*' | grep -vxE 'kernel-tools(-libs)?' | sort | paste -sd' ')"; \
    [ "$have" = "kernel kernel-core kernel-modules kernel-modules-core" ] \
      || { echo "the base has other kernel packages than the four replaced: $have" >&2; exit 1; }; \
    mkdir /tmp/k; \
    for pair in $KERNEL_NEXT_SHA256; do \
      n="${pair%%:*}"; f="/tmp/k/$n-$KERNEL_NEXT_NVR.x86_64.rpm"; \
      curl -fsSL --retry 3 -o "$f" "$KERNEL_NEXT_URL/$n-$KERNEL_NEXT_NVR.x86_64.rpm" \
        || { echo "Koji no longer serves $n-$KERNEL_NEXT_NVR: move KERNEL_NEXT_* in versions.env to a current build" >&2; exit 1; }; \
      echo "${pair#*:}  $f" | sha256sum -c -; \
    done; \
    [ "$(ls /tmp/k | wc -l)" = 4 ]; \
    rpmkeys --import /usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-46-x86_64; \
    for f in /tmp/k/*.rpm; do rpmkeys -K "$f" | grep -q 'digests signatures OK' || { echo "bad signature: $f" >&2; exit 1; }; done; \
    old="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"; \
    cp "/usr/lib/modules/$old/vmlinuz" /tmp/k/base-vmlinuz; \
    rpm -U /tmp/k/*.rpm; \
    rpmkeys --delete 91211fce; \
    if rpmkeys --list | grep -qi 91211fce; then echo "Fedora 46's key is still in the rpm keyring" >&2; exit 1; fi; \
    kver="${KERNEL_NEXT_NVR#kernel-}.x86_64"; \
    rm -rf "/usr/lib/modules/$old"; \
    [ "$(ls /usr/lib/modules)" = "$kver" ] || { echo "more than one kernel: $(ls /usr/lib/modules)" >&2; exit 1; }; \
    [ "$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)" = "$kver" ]; \
    m="/usr/lib/modules/$kver"; \
    for want in kernel/drivers/accel/amdxdna/amdxdna.ko.xz kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.xz vmlinuz; do \
      [ -s "$m/$want" ] || { echo "the test kernel lacks $want" >&2; exit 1; }; done; \
    for opt in PROVE_LOCKING LOCKDEP KASAN DEBUG_VM DEBUG_OBJECTS DEBUG_KMEMLEAK DEBUG_PAGEALLOC DEBUG_ATOMIC_SLEEP; do \
      if grep -qx "CONFIG_$opt=y" "$m/config"; then echo "the test kernel is a debug build (CONFIG_$opt)" >&2; exit 1; fi; done; \
    set -- /usr/lib/efi/shim/*/EFI/fedora/shimx64.efi; \
    [ "$#" = 1 ] && [ -f "$1" ] || { echo "expected one Fedora shim in the base, found: $*" >&2; exit 1; }; \
    python3 -I /tmp/authenticode-check.py "$m/vmlinuz" "$1" /tmp/k/base-vmlinuz \
      || { echo "the test kernel's Secure Boot signature doesn't check out against the base's shim" >&2; exit 1; }; \
    echo "kernel: test kernel $kver in place of $old"; \
    rm -rf /tmp/k; dnf clean all; rm -rf /var/log/dnf5.log /var/lib/dnf /var/cache/libdnf5 /run/dnf
COPY files/ /
COPY variants/${HALOGEN_VARIANT}/ /
COPY LICENSE THIRD-PARTY-NOTICES.md /usr/share/licenses/halos-flash/
# bf16-to-hgn, halogen-dashboard and Caddy, built by Containerfile.helpers on this same base:
# "helpers" is the build context scripts/build.sh passes (--build-context helpers=<tree>).
COPY --from=helpers bf16-to-hgn/bf16-to-hgn /usr/libexec/halogen/bf16-to-hgn
COPY --from=helpers bf16-to-hgn/licenses/ /usr/share/licenses/bf16-to-hgn/
COPY --from=helpers dashboard/halogen-dashboard /usr/libexec/halogen/halogen-dashboard
COPY --from=helpers dashboard/licenses/ /usr/share/licenses/halogen-dashboard/
COPY --from=helpers dashboard/dashboard-nodump.so /usr/lib64/halos/dashboard-nodump.so
COPY --from=helpers caddy/caddy /usr/libexec/halogen/caddy
COPY --from=helpers caddy/licenses/ /usr/share/licenses/halos-caddy/
# The compilers each helper stage used, for the build record (scripts/build-info.sh, #121).
COPY --from=helpers bf16-to-hgn/toolchain.txt /tmp/toolchain-1.txt
COPY --from=helpers dashboard/toolchain.txt /tmp/toolchain-2.txt
COPY --from=helpers caddy/toolchain.txt /tmp/toolchain-3.txt

# Upstream's clock script and terms, unmodified and checked by hash.
RUN set -eu; \
    base="https://raw.githubusercontent.com/peonist-ai/halogen-flash-server/${HALOGEN_SOURCE_COMMIT}"; \
    mkdir -p /usr/share/licenses/halogen; \
    curl -fsSL "$base/deploy/host/halogen-fabric-clock" -o /usr/libexec/halogen/halogen-fabric-clock; \
    curl -fsSL "$base/LICENSE.md" -o /usr/share/licenses/halogen/LICENSE.md; \
    curl -fsSL "$base/THIRD-PARTY-NOTICES.md" -o /usr/share/licenses/halogen/THIRD-PARTY-NOTICES.md; \
    { echo "$HALOGEN_CLOCK_SHA256  /usr/libexec/halogen/halogen-fabric-clock"; \
      echo "$HALOGEN_LICENSE_SHA256  /usr/share/licenses/halogen/LICENSE.md"; \
      echo "$HALOGEN_NOTICES_SHA256  /usr/share/licenses/halogen/THIRD-PARTY-NOTICES.md"; } | sha256sum -c -

# The halOS release (0.19.0-alpha.2, or 0.19.0-dev.<commit> for builds of main), for halosctl.
ARG HALOS_RELEASE
ARG BF16_TO_HGN_COMMIT
ARG HALOGEN_DASHBOARD_COMMIT
# What this build was made from (#121): the Fedora base as build.sh resolved it (repository@digest,
# used by every stage), the base's own version label and the halOS source commit.
ARG FEDORA_BOOTC_IMAGE
ARG HALOS_BASE_VERSION=unknown
ARG HALOS_SOURCE_COMMIT=unknown
RUN set -eu; \
    /usr/libexec/halogen/bf16-to-hgn --version; \
    /usr/libexec/halogen/halogen-dashboard --version; \
    [ -z "$(LD_PRELOAD=/usr/lib64/halos/dashboard-nodump.so /usr/bin/true 2>&1)" ]; \
    HOME=/tmp XDG_DATA_HOME=/tmp XDG_CONFIG_HOME=/tmp /usr/libexec/halogen/caddy validate --config /usr/share/halos/proxy/Caddyfile --adapter caddyfile; \
    for tls in internal custom; do \
      HOME=/tmp XDG_DATA_HOME=/tmp XDG_CONFIG_HOME=/tmp HALOS_TLS=$tls RUNTIME_DIRECTORY=/tmp/halos-tls \
        HALOS_API_SITES="https://localhost:8731, https://127.0.0.1:8731" HALOS_DASH_SITES="https://localhost:8732" \
        /usr/libexec/halogen/caddy adapt --config /usr/share/halos/proxy/Caddyfile.https --adapter caddyfile > /dev/null; \
    done; \
    for dns in cloudflare duckdns porkbun namecheap; do for mail in yes no; do \
      HOME=/tmp XDG_DATA_HOME=/tmp XDG_CONFIG_HOME=/tmp CREDENTIALS_DIRECTORY=/tmp/halos-creds HALOS_ACME_DNS=$dns \
        HALOS_ACME_EMAIL_SET=$mail HALOS_ACME_EMAIL=admin@example.com HALOS_ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory \
        HALOS_ACME_API_SITES="https://halos.example.com:8731" HALOS_ACME_DASH_SITES="https://halos.example.com:8732" \
        HALOS_API_SITES="https://localhost:8731, https://127.0.0.1:8731" HALOS_DASH_SITES="https://localhost:8732" \
        /usr/libexec/halogen/caddy adapt --config /usr/share/halos/proxy/Caddyfile.letsencrypt --adapter caddyfile > /dev/null; \
    done; done; \
    chmod 0755 /usr/bin/halosctl /usr/bin/halogenctl /usr/bin/halogen-enroll-tpm /usr/libexec/halogen/*; \
    find /etc/containers/systemd/users/970 -type f -exec sed -i \
      -e "s|@HALOGEN_IMAGE@|${HALOGEN_IMAGE}|g" -e "s|@HALOGEN_VERSION@|${HALOGEN_VERSION}|g" {} +; \
    if grep -rq '@HALOGEN_' /etc/containers/systemd/users/970; then exit 1; fi; \
    # Halogen's container is on its own network with no route out and no DNS (#120): netavark makes it,
    # and Quadlet must still turn the files into exactly that.
    rpm -q netavark; \
    QUADLET_UNIT_DIRS=/etc/containers/systemd/users/970 /usr/libexec/podman/quadlet -dryrun -user > /tmp/quadlet.txt 2>&1 || { cat /tmp/quadlet.txt; exit 1; }; \
    netline="$(grep -E '^ExecStart=/usr/bin/podman network create ' /tmp/quadlet.txt)"; \
    case "$netline" in *' --internal '*) ;; *) echo "Halogen's network isn't internal: $netline" >&2; exit 1 ;; esac; \
    case "$netline" in *' --disable-dns '*) ;; *) echo "Halogen's network has DNS: $netline" >&2; exit 1 ;; esac; \
    case "$netline" in *' halogen-internal') ;; *) echo "Halogen's network has another name: $netline" >&2; exit 1 ;; esac; \
    grep -E '^ExecStart=/usr/bin/podman run ' /tmp/quadlet.txt | grep -qE ' --network[= ]halogen-internal( |$)' \
      || { echo "Halogen's container isn't on halogen-internal" >&2; exit 1; }; \
    rm -f /tmp/quadlet.txt; \
    { echo "HALOGEN_IMAGE=${HALOGEN_IMAGE}"; \
      echo "HALOGEN_VERSION=${HALOGEN_VERSION}"; \
      echo "HALOGEN_VARIANT=${HALOGEN_VARIANT}"; \
      echo "HALOS_RELEASE=${HALOS_RELEASE}"; \
      echo "HALOGEN_WEIGHTS_REPO=${HALOGEN_WEIGHTS_REPO}"; \
      echo "HALOGEN_WEIGHTS_REVISION=${HALOGEN_WEIGHTS_REVISION}"; \
      echo "BF16_TO_HGN_COMMIT=${BF16_TO_HGN_COMMIT}"; \
      echo "HALOGEN_DASHBOARD_COMMIT=${HALOGEN_DASHBOARD_COMMIT}"; \
      echo "HALOS_KERNEL=${KERNEL_TRACK}"; \
      echo "HALOS_KERNEL_BUILT=$(rpm -q --qf '%{BUILDTIME}' kernel-core)"; \
      echo "HALOS_BASE_IMAGE=${FEDORA_BOOTC_IMAGE}"; \
      echo "HALOS_BASE_VERSION=${HALOS_BASE_VERSION}"; \
      echo "HALOS_SOURCE_COMMIT=${HALOS_SOURCE_COMMIT}"; } > /usr/share/halogen/release.env; \
    case "$FEDORA_BOOTC_IMAGE" in *@sha256:*) ;; *) echo "the base must come by digest (scripts/build.sh resolves it)" >&2; exit 1 ;; esac; \
    cat /tmp/toolchain-1.txt /tmp/toolchain-2.txt /tmp/toolchain-3.txt > /usr/share/halogen/toolchains.txt; \
    rm -f /tmp/toolchain-*.txt; \
    rpm -qa --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > /usr/share/halogen/packages.txt; \
    grep -q '^kernel-core-' /usr/share/halogen/packages.txt; \
    echo 'halogen:524288:65536' >> /etc/subuid; \
    echo 'halogen:524288:65536' >> /etc/subgid; \
    firewall-offline-cmd --add-service=halogen; \
    firewall-offline-cmd --add-service=halos-dashboard; \
    # Only ports firewalld itself opens are reachable: by default it also lets through any port a
    # rootful container publishes (traffic DNAT'd by others), which something with CAP_NET_ADMIN
    # could use to open one with a NAT rule of its own. halOS publishes none that way (Halogen is
    # rootless, on 127.0.0.1); the security audit of #132.
    grep -qx 'StrictForwardPorts=no' /etc/firewalld/firewalld.conf; \
    sed -i 's/^StrictForwardPorts=no$/StrictForwardPorts=yes/' /etc/firewalld/firewalld.conf; \
    grep -qx 'StrictForwardPorts=yes' /etc/firewalld/firewalld.conf; \
    systemctl enable firewalld.service halogen-prepare.service halos-status.timer halos-platform-profile.service; \
    systemctl enable halos-dashboard.service; \
    systemctl enable halos-proxy.service; \
    systemctl enable halos-https-refresh.timer; \
    systemctl enable auditd.service audit-rules.service; \
    systemctl enable fail2ban.service; \
    fail2ban-client -t; \
    fail2ban-client -d > /tmp/f2b.conf; \
    grep -q "'add', 'sshd', 'systemd'" /tmp/f2b.conf; grep -q "'add', 'halos-api', 'systemd'" /tmp/f2b.conf; \
    grep -q "'halos-api', 'addaction', 'nftables'" /tmp/f2b.conf; grep -q "'sshd', 'addaction', 'nftables'" /tmp/f2b.conf; \
    grep -q "'blocktype', 'reject with tcp reset'" /tmp/f2b.conf; command -v nft > /dev/null; \
    grep -q "'halos-api', 'addjournalmatch', '_SYSTEMD_UNIT=halos-proxy.service'" /tmp/f2b.conf; \
    grep -q "'halos-api', 'usedns', 'no'" /tmp/f2b.conf; grep -q "'set', 'loglevel', 'NOTICE'" /tmp/f2b.conf; \
    grep -q "'set', 'logtarget', 'SYSTEMD-JOURNAL'" /tmp/f2b.conf; rm -f /tmp/f2b.conf; \
    printf '%s\n' 'host caddy[1]: {"level":"info","ts":1.5,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"203.0.113.7","remote_port":"1","uri":"/v1/models"},"status":401,"resp_headers":{}}' \
      'host caddy[1]: {"level":"info","ts":1.5,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"203.0.113.8","remote_port":"1","uri":"/x\"remote_ip\":\"198.51.100.1\",\"status\":401,"},"status":404,"resp_headers":{}}' \
      '{"level":"info","ts":1.5,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"203.0.113.9","remote_port":"1","uri":"/v1/models"},"status":401,"resp_headers":{}}' \
      'host caddy[1]: {"level":"info","ts":1.5,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"203.0.113.6","remote_port":"1","uri":"/v1/models"},"duration":0.1,"size":9,"status":401}' > /tmp/f2b.log; \
    fail2ban-regex /tmp/f2b.log /etc/fail2ban/filter.d/halos-api.conf > /tmp/f2b.out; grep -q '^Lines: 4 lines, 0 ignored, 2 matched, 2 missed' /tmp/f2b.out; rm -f /tmp/f2b.log /tmp/f2b.out; \
    augenrules; \
    grep -q -- '-w /etc/halos -p wa -k halos-config' /etc/audit/audit.rules; \
    grep -qx -- '-a task,never -F uid=970 -F auid=970' /etc/audit/audit.rules; \
    [ "$(grep -c -- '^-a task,never' /etc/audit/audit.rules)" = 1 ]; \
    [ "$(grep -v -e '^#' -e '^$' /etc/audit/audit.rules | tail -n 1)" = '-e 2' ]; \
    if grep -qx -- '-a task,never' /etc/audit/audit.rules; then echo "Fedora's audit rule that turns auditing off is back" >&2; exit 1; fi; \
    if [ "$HALOGEN_VARIANT" = npu ]; then \
      systemctl enable halogen-fabric-clock.service; \
    else \
      rm -rf /usr/lib/systemd/system/halogen-fabric-clock.service /usr/libexec/halogen/halogen-fabric-clock; \
    fi; \
    systemctl mask bootc-fetch-apply-updates.timer; \
    systemctl disable systemd-homed.service systemd-homed-activate.service

# Rebuild the initramfs with LUKS, TPM2 and LVM support, SSH and tang unlock, and fail the build
# without them.
RUN set -eu; \
    mkdir -p "$(realpath /root)"; \
    kver="$(ls /usr/lib/modules)"; \
    img="/usr/lib/modules/${kver}/initramfs.img"; \
    env DRACUT_NO_XATTR=1 dracut --no-hostonly -f "$img" "$kver"; \
    contents="$(lsinitrd "$img")"; \
    echo "$contents" | grep -E 'cryptsetup|bin/lvm|tpm2' | awk '{print $NF}' | sort -u; \
    for want in '/systemd-cryptsetup$' '/systemd-cryptsetup-generator$' 'libcryptsetup' 'bin/lvm$' \
                '/halos-ssh-unlock$' 'bin/sshd$' '/sshd-session$' '/sshd-auth$' '/nm-initrd-generator$' 'fs/fat/vfat' \
                '/halos-initrd-net$' '/halos-tang-unlock$' '/halos-tang-unlock.service$' '/clevis-luks-askpass$' \
                '/clevis-luks-askpass.path$' '/clevis-decrypt-tang$' '/clevis-decrypt-sss$' '/clevis-decrypt-tpm2$' \
                '/clevis-luks-list$' 'bin/jose$' 'bin/curl$' 'libtss2-tcti-device'; do \
      echo "$contents" | awk '{print $NF}' | grep -qE "$want" || { echo "initramfs is missing $want" >&2; exit 1; }; \
    done; \
    echo "$contents" | awk '{print $NF}' | grep -qE '/(tpm2_unseal|clevis-pin-tpm2)$' \
      || { echo "the initramfs has no TPM tool for clevis's tpm2 pin (TPM and tang)" >&2; exit 1; }; \
    if echo "$contents" | grep -q 'cryptsetup.target.wants/clevis-luks-askpass.path'; then \
      echo "clevis's password agent starts on every machine; halos-tang-unlock should start it" >&2; exit 1; fi; \
    case "$contents" in *'nm-wait-online-initrd.service -> /dev/null'*) ;; \
      *) echo "the initramfs could wait for the network at boot (halos-ssh-unlock)" >&2; exit 1 ;; esac; \
    lsinitrd -f etc/shadow "$img" | grep -q '^root:' \
      || { echo "the initramfs has no shadow line for root, so its sshd would refuse root" >&2; exit 1; }

# The base image's own OSTree copy of its files, which still holds everything removed above.
# A flattened image does not use it; Fedora's rechunker drops it the same way.
RUN rm -rf /sysroot/ostree && bootc container lint

# One layer, so the files removed above are not shipped in the base image's layers
# underneath. This keeps the installer ISO small. Labels and start-up as in the base image.
FROM scratch
COPY --from=os / /
LABEL containers.bootc=1 ostree.bootable=true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
RUN bootc container lint
