ARG FEDORA_BOOTC_IMAGE

# bf16-to-hgn, built from its pinned commit on the same base, so its C++ and OpenMP libraries are
# the ones the OS image has (libstdc++, libgomp). The compilers stay in this stage. /root links to
# /var/roothome, which the base image lacks, and cargo keeps its downloads in ~/.cargo.
FROM ${FEDORA_BOOTC_IMAGE} AS bf16-to-hgn
ARG BF16_TO_HGN_COMMIT
RUN set -eu; \
    dnf -y --setopt=install_weak_deps=False install cargo rust gcc-c++ git-core; \
    git clone -q https://github.com/Quat3rnion/bf16-to-hgn /src; \
    cd /src; git checkout -q "$BF16_TO_HGN_COMMIT"; \
    [ "$(git rev-parse HEAD)" = "$BF16_TO_HGN_COMMIT" ]; \
    mkdir -p "$(realpath /root)"; \
    cargo build --release --locked; \
    ./target/release/bf16-to-hgn --version

# halogen-dashboard (Quaternion's live page of Halogen's load), built from its pinned commit: the
# web page first (the binary embeds it), then the collector. Node and Rust stay in this stage.
# Also gathers the licences of what the binary carries: the embedded web page's font (IBM Plex
# Sans, SIL OFL 1.1), uPlot and Svelte, and the Rust crates it is built from.
FROM ${FEDORA_BOOTC_IMAGE} AS dashboard
ARG HALOGEN_DASHBOARD_COMMIT
RUN set -eu; \
    dnf -y --setopt=install_weak_deps=False install cargo rust gcc nodejs pnpm git-core jq; \
    git clone -q https://github.com/Quat3rnion/halogen-dashboard /src; \
    cd /src; git checkout -q "$HALOGEN_DASHBOARD_COMMIT"; \
    [ "$(git rev-parse HEAD)" = "$HALOGEN_DASHBOARD_COMMIT" ]; \
    mkdir -p "$(realpath /root)"; \
    (cd web && pnpm install --frozen-lockfile && pnpm build); \
    cargo build --release --locked --bin halogen-dashboard; \
    ./target/release/halogen-dashboard --version; \
    lic=/out/licenses; mkdir -p "$lic/web"; \
    cp LICENSE-MIT LICENSE-APACHE "$lic/"; \
    for p in @fontsource-variable/ibm-plex-sans uplot svelte; do \
      f="$(find "web/node_modules/$p/" -maxdepth 1 -iname 'licen[cs]e*' | head -n 1)"; \
      [ -n "$f" ] || { echo "no licence file for $p" >&2; exit 1; }; \
      cp "$f" "$lic/web/$(echo "$p" | tr / _ | tr -d @)-LICENSE"; \
    done; \
    { echo "Rust crates halogen-dashboard is built from (name, version, licence), from Cargo.lock at $HALOGEN_DASHBOARD_COMMIT."; \
      echo "Their licence texts are at https://crates.io/crates/<name>/<version>."; echo; \
      cargo metadata --format-version 1 --locked | jq -r '.packages[] | select(.name != "halogen-dashboard") | "\(.name) \(.version) \(.license // "see crates.io")"' | sort -u; \
    } > "$lic/crates.txt"

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
# the Wi-Fi driver asks for them at boot) and a few admin tools. fwupd stays for firmware updates.
RUN dnf -y --setopt=install_weak_deps=False install \
      amd-gpu-firmware firewalld linux-firmware tpm2-tss \
      amdsmi nvtop htop pciutils usbutils tmux wireless-regdb nano bash-completion && \
    dnf -y remove \
      nvidia-gpu-firmware intel-gpu-firmware intel-npu-firmware intel-audio-firmware \
      cirrus-audio-firmware brcmfmac-firmware tiwilink-firmware nxpwireless-firmware \
      qcom-wwan-firmware microcode_ctl \
      'qemu-user-static*' toolbox sos python3-boto3 python3-botocore python3-s3transfer \
      'sssd*' adcli libsmbclient 'samba-*' nfs-utils udisks2 libudisks2 \
      btrfs-progs nilfs-utils f2fs-tools ntfsprogs ntfs-3g exfatprogs udftools \
      fwupd-plugin-modem-manager ModemManager-glib libqmi libmbim && \
    dnf clean all && \
    rm -rf /var/log/dnf5.log /var/lib/dnf /var/cache/libdnf5 /run/dnf && \
    rpm -q bash-completion fwupd skopeo jq amd-ucode-firmware realtek-firmware mt7xxx-firmware atheros-firmware && \
    ls -d /usr/lib/firmware/amdgpu /usr/lib/firmware/amdnpu && \
    command -v runuser setpriv nano

COPY files/ /
COPY variants/${HALOGEN_VARIANT}/ /
COPY LICENSE THIRD-PARTY-NOTICES.md /usr/share/licenses/halos-flash/
COPY --from=bf16-to-hgn /src/target/release/bf16-to-hgn /usr/libexec/halogen/bf16-to-hgn
COPY --from=bf16-to-hgn /src/LICENSE-MIT /src/LICENSE-APACHE /usr/share/licenses/bf16-to-hgn/
COPY --from=bf16-to-hgn /src/native/LICENSE /usr/share/licenses/bf16-to-hgn/native/LICENSE
COPY --from=bf16-to-hgn /src/native/NOTICE /usr/share/licenses/bf16-to-hgn/native/NOTICE
COPY --from=dashboard /src/target/release/halogen-dashboard /usr/libexec/halogen/halogen-dashboard
COPY --from=dashboard /out/licenses/ /usr/share/licenses/halogen-dashboard/

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
RUN set -eu; \
    /usr/libexec/halogen/bf16-to-hgn --version; \
    /usr/libexec/halogen/halogen-dashboard --version; \
    chmod 0755 /usr/bin/halosctl /usr/bin/halogenctl /usr/bin/halogen-enroll-tpm /usr/libexec/halogen/*; \
    find /etc/containers/systemd/users/970 -type f -exec sed -i \
      -e "s|@HALOGEN_IMAGE@|${HALOGEN_IMAGE}|g" -e "s|@HALOGEN_VERSION@|${HALOGEN_VERSION}|g" {} +; \
    if grep -rq '@HALOGEN_' /etc/containers/systemd/users/970; then exit 1; fi; \
    { echo "HALOGEN_IMAGE=${HALOGEN_IMAGE}"; \
      echo "HALOGEN_VERSION=${HALOGEN_VERSION}"; \
      echo "HALOGEN_VARIANT=${HALOGEN_VARIANT}"; \
      echo "HALOS_RELEASE=${HALOS_RELEASE}"; \
      echo "HALOGEN_WEIGHTS_REPO=${HALOGEN_WEIGHTS_REPO}"; \
      echo "HALOGEN_WEIGHTS_REVISION=${HALOGEN_WEIGHTS_REVISION}"; \
      echo "BF16_TO_HGN_COMMIT=${BF16_TO_HGN_COMMIT}"; \
      echo "HALOGEN_DASHBOARD_COMMIT=${HALOGEN_DASHBOARD_COMMIT}"; } > /usr/share/halogen/release.env; \
    echo 'halogen:524288:65536' >> /etc/subuid; \
    echo 'halogen:524288:65536' >> /etc/subgid; \
    firewall-offline-cmd --add-service=halogen; \
    firewall-offline-cmd --add-service=halos-dashboard; \
    systemctl enable firewalld.service halogen-prepare.service halos-status.timer halos-platform-profile.service; \
    systemctl enable halos-dashboard.service; \
    if [ "$HALOGEN_VARIANT" = npu ]; then \
      systemctl enable halogen-fabric-clock.service; \
    else \
      rm -rf /usr/lib/systemd/system/halogen-fabric-clock.service /usr/libexec/halogen/halogen-fabric-clock; \
    fi; \
    systemctl mask bootc-fetch-apply-updates.timer; \
    systemctl disable systemd-homed.service systemd-homed-activate.service

# Rebuild the initramfs with LUKS, TPM2 and LVM support, and fail the build without them.
RUN set -eu; \
    mkdir -p "$(realpath /root)"; \
    kver="$(ls /usr/lib/modules)"; \
    img="/usr/lib/modules/${kver}/initramfs.img"; \
    env DRACUT_NO_XATTR=1 dracut --no-hostonly -f "$img" "$kver"; \
    contents="$(lsinitrd "$img")"; \
    echo "$contents" | grep -E 'cryptsetup|bin/lvm|tpm2' | awk '{print $NF}' | sort -u; \
    for want in '/systemd-cryptsetup$' '/systemd-cryptsetup-generator$' 'libcryptsetup' 'bin/lvm$' \
                '/halos-ssh-unlock$' 'bin/sshd$' '/sshd-session$' '/sshd-auth$' '/nm-initrd-generator$' 'fs/fat/vfat'; do \
      echo "$contents" | awk '{print $NF}' | grep -qE "$want" || { echo "initramfs is missing $want" >&2; exit 1; }; \
    done; \
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
