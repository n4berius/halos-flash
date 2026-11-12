#!/bin/bash
# Install the ISO to a blank disk unattended, boot it with Secure Boot on, and report on it.
# Usage: tests/iso-install.sh path/to.iso os-image-reference output-dir variant
# It takes the guided installer's unattended boot entry, with its answers on a volume labelled
# HALOS_ANSWERS instead of typed. The NPU edition installs on LUKS to a 512 GB disk, no-NPU without
# LUKS to a 2 TB one, so both encrypted and plain installs and both ends of the sizing are tested.
# The VM has an emulated TPM: the LUKS install is bound to it with halogen-enroll-tpm, then
# rebooted to prove the disk unlocks with no passphrase. Before that, the stale binding's boot
# asks for the passphrase, which this test answers over SSH (unlock over SSH, #13).
set -euo pipefail
iso="$1"; target="$2"; out="$3"; variant="$4"; mkdir -p "$out/answers"
here="$(cd "$(dirname "$0")" && pwd)"
code=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$out/vars.fd"
# Sizes as sold: 512 GB and 2 TB, in bytes.
if [ "$variant" = npu ]; then disk_bytes=512110190592; else disk_bytes=2000398934016; fi
qemu-img create -f qcow2 "$out/disk.qcow2" "$disk_bytes" >/dev/null

# Test-only passwords, in a throwaway VM. Each is different, so a leak can be told apart.
luks=""
[ "$variant" != npu ] || luks=halogentest
# Unlock over SSH (#13): the installer takes this key (TPM and SSH), and the admin user gets it too.
unlock=none; key=""
if [ -n "$luks" ]; then
  ssh-keygen -q -t ed25519 -N '' -C halostest -f "$out/unlock-key"
  unlock=both; key="$(cat "$out/unlock-key.pub")"
fi
cat > "$out/answers/answers" <<S
disk=vda
hostname=halostest
luks_passphrase=$luks
root_password=rootsecret
admin_user=admin
admin_password=adminsecret
finish=poweroff
allow_root_ssh=yes
unlock=$unlock
ssh_key=$key
admin_ssh=yes
S
genisoimage -quiet -V HALOS_ANSWERS -o "$out/answers.iso" "$out/answers/answers"

vm() {
  # A fresh swtpm per run; its state in $out/tpm lasts across the install and every boot.
  mkdir -p "$out/tpm"
  swtpm socket --tpm2 --daemon --terminate --tpmstate "dir=$out/tpm" \
    --ctrl "type=unixio,path=$out/tpm/sock"
  qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 4 -machine q35,smm=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code" \
    -drive "if=pflash,format=raw,unit=1,file=$out/vars.fd" \
    -drive "file=$out/disk.qcow2,if=virtio" \
    -chardev "socket,id=chrtpm,path=$out/tpm/sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -vga virtio -display none -monitor "unix:$out/monitor.sock,server,nowait" "$@"
}

echo "=== installing ==="
timeout 1500 bash -c "$(declare -f vm); code=$code out=$out; vm -cdrom '$iso' -boot d \
  -drive file=$out/answers.iso,format=raw,if=virtio,readonly=on -serial file:$out/install.log" &
install=$!
# Answers are used only from the unattended menu entry, which the test picks like a person would.
python3 "$here/grub-pick.py" "$out/monitor.sock" "$out/install.log" || { kill "$install"; exit 1; }
wait "$install" || { echo "the install did not finish (see install.log)" >&2; exit 1; }
echo "install finished"

# vm-login.py reads the unlock state on the first boot.
[ -z "$luks" ] || export HALOS_TEST_SSH_UNLOCK=1

echo "=== first boot from disk ==="
# No network: the fetch must not start a 125 GB download in CI.
vm -nic none -serial "file:$out/firstboot.log" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
python3 "$here/vm-login.py" "$out/monitor.sock" "$out/firstboot.log" "$out" "$([ -n "$luks" ] && echo luks-stale)"
cat "$out/report.txt"
grep -q 'amdgpu.gttsize=126976' "$out/report.txt"
if [ "$variant" = npu ]; then grep -q 'iommu=pt' "$out/report.txt"; else grep -q 'amd_iommu=off' "$out/report.txt"; fi
grep -qi 'secure boot.*enabled\|Secure Boot: enabled' "$out/report.txt"
grep -q 'Linger=yes' "$out/report.txt"
# bootc mounts the root volume at /sysroot; / itself is the read-only image.
for m in /sysroot /var /var/log /var/log/audit /var/home /var/srv/configs /var/srv/models; do
  grep -qE "^$m " "$out/report.txt" || { echo "no separate volume for $m" >&2; exit 1; }
done
# The guided install's fixed names (#42), whatever the hostname.
for v in /sysroot:root /var:var /var/log:log /var/log/audit:audit /var/home:home \
         /var/srv/configs:configs /var/srv/models:models; do
  grep -qx "${v%%:*} /dev/mapper/halos-${v#*:}" "$out/report.txt" || { echo "${v%%:*} is not on halos-${v#*:}" >&2; exit 1; }
done
# The models volume takes the rest: about 308 GiB of a 512 GB disk, 1690 GiB of a 2 TB one.
models_gib="$(awk '$1 == "models" { printf "%d", $2 }' "$out/report.txt")"
if [ "$variant" = npu ]; then want=290; else want=1650; fi
[ "${models_gib:-0}" -ge "$want" ] || { echo "the models volume is ${models_gib:-missing} GiB, expected $want or more" >&2; exit 1; }
grep -qF "$target" "$out/report.txt" || { echo "the installed system doesn't follow $target" >&2; exit 1; }
grep -qx halostest "$out/report.txt" || { echo "the hostname was not set" >&2; exit 1; }
grep -qE '^uid=[0-9]+\(admin\).*\(wheel\)' "$out/report.txt" || { echo "the admin user is missing or not in wheel" >&2; exit 1; }
# No password or passphrase in a file or the journal on the installed system.
if grep -q '^PWLEAK ' "$out/report.txt"; then grep '^PWLEAK ' "$out/report.txt" >&2; echo "a password was written to disk" >&2; exit 1; fi
grep -qx 'PWJOURNAL 0' "$out/report.txt" || { echo "a password is in the journal" >&2; exit 1; }
# fwupd finds the EFI partition through udisks2 (#106), which starts only when asked; both editions.
grep -qE '^ESPRC 0 [1-9][0-9]* disabled' "$out/report.txt" \
  || { echo "fwupd did not find the EFI partition at /boot/efi, or udisks2 is enabled:" >&2; grep '^ESPRC' "$out/report.txt" >&2; exit 1; }
# Only root may use udisks2: the admin gets polkit's flat no (NotAuthorized:, not NotAuthorizedCanObtain,
# the default's "needs a password"), and halogen's call is refused by the bus while the same call
# from the admin gets an answer, so the refusal is halogen's own.
grep -qE '^UDLOOP [1-9]' "$out/report.txt" || { echo "the admin wasn't refused udisks2 by halOS's rule:" >&2; grep '^UDLOOP' "$out/report.txt" >&2; exit 1; }
# busctl says "Access denied"; dbus-broker's own log names the policy, so it was this refusal.
if ! grep -qE '^UDBUS [1-9]' "$out/report.txt" || ! grep -q '^UDBUSLOG .*security policy denied' "$out/report.txt"; then
  echo "the halogen user could call udisks2:" >&2; grep '^UDBUS' "$out/report.txt" >&2; exit 1
fi
grep -qE '^UDBUSADMIN [1-9]' "$out/report.txt" || { echo "the control call to udisks2 got no answer, so the halogen check proves nothing:" >&2; grep '^UDBUS' "$out/report.txt" >&2; exit 1; }
# The serial login prompt has the port check and still starts where the port answers (ttyS0).
grep -qx 'SERIALGETTY active 1' "$out/report.txt" \
  || { grep SERIALGETTY "$out/report.txt" >&2; echo "the serial getty check is wrong" >&2; exit 1; }
if [ -n "$luks" ]; then grep -q 'crypto_LUKS' "$out/report.txt"; fi
grep -q 'halogen-fetch:' "$out/report.txt"
# halosctl reads bootc's status and the image's release file on a real install.
grep -qE "^halOS [0-9]+\.[0-9]+\.[0-9]+.*, $variant edition" "$out/report.txt" || { echo "halosctl version failed" >&2; exit 1; }
grep -qE '^Image: +[a-z]' "$out/report.txt" || { echo "halosctl did not read bootc status" >&2; exit 1; }
# Root never logs in over SSH (files/etc/ssh/sshd_config.d/00-halos.conf), as sshd itself reports,
# even with the installer's "allow root SSH" (rootpw --allow-ssh above) also written.
grep -q '01-permitrootlogin.conf' "$out/report.txt" || { echo "the installer did not write its allow-root file" >&2; exit 1; }
grep -qix 'permitrootlogin no' "$out/report.txt" || { echo "sshd allows root logins" >&2; exit 1; }
# Security audit P1: root's prepare must not chown or chmod a root folder through a planted link.
grep -qE '^drwxr-xr-x\.? +[0-9]+ root +root .*/var/tmp/victim' "$out/report.txt" \
  || { echo "halogen-prepare changed a root-owned folder through a link" >&2; grep victim "$out/report.txt" >&2; exit 1; }
# No-cost hardening (security audit R5, R7) is active on the installed system.
for want in 'kernel.dmesg_restrict = 1' 'kernel.kptr_restrict = 1' 'kernel.yama.ptrace_scope = 1'; do
  grep -qx "$want" "$out/report.txt" || { echo "sysctl not applied: $want" >&2; exit 1; }
done
grep -qix 'x11forwarding no' "$out/report.txt" || { echo "sshd still allows X11 forwarding" >&2; exit 1; }
echo "installed system verified"

# halogenctl selftest, as people run it on hardware. Only what a VM can pass is required.
cat "$out/selftest.txt"
selftest_has() { grep -qE "^$1" "$out/selftest.txt" || { echo "selftest: expected '$1'" >&2; exit 1; }; }
selftest_has 'Summary: '
selftest_has 'PASS secure-boot:'
selftest_has 'PASS image-signatures:'   # the installer's %post turned bootc's signature check on (#46)
selftest_has 'PASS kernel-amdgpu.gttsize:'
selftest_has 'PASS kernel-iommu:'
selftest_has 'PASS firewall:'
# The dashboard (halos-dashboard.service) runs sandboxed, its start found a key to hand over, and it
# answers on 8732, though Halogen itself isn't up in the VM (so the key itself isn't tried).
selftest_has 'PASS proxy:'
selftest_has 'PASS dashboard:'
selftest_has 'PASS dashboard-filter:'
selftest_has 'PASS dashboard-nodump:'
selftest_has 'PASS prepare:'
# HTTPS (#102): switched on with halOS's own authority, a client trusting it got an answer
# (Caddy's 503 note, since Halogen isn't up), plain http:// was redirected, the selftest passed
# it, and off went back to plain HTTP.
https_has() { grep -qE "$1" "$out/https.txt" || { echo "https: expected '$1'" >&2; cat "$out/https.txt" >&2; exit 1; }; }
https_has '^HTTPS-RC=0'; https_has '^CURL 503'; https_has '^REDIRECT 308'; https_has '^PASS https: on, self-signed'
https_has '^PASS proxy:'; https_has '^PASS dashboard:'; https_has '^OFF-RC=0'; https_has '^BACK 503'
# The DNS credential: loaded by systemd (root's file, read-only, Caddy's user by ACL: no "other"
# bits), none in Caddy's runtime folder, gone after forget-dns, and Caddy starts with the folder empty.
https_has '^CRED [0-7][0-7]0 [a-z-]+ 0$'; https_has '^CREDGONE 0 active$'
selftest_has '(PASS|SKIP) power-profile:'   # QEMU likely has no ACPI platform profile
selftest_has 'PASS folder-flash:'
selftest_has 'INFO flash: serving the official Flash checkpoint'
if [ "$variant" = npu ]; then
  selftest_has 'PASS npu-folder:'
  for f in decider LFM custom; do selftest_has "PASS folder-$f:"; done
fi
if grep -qE 'SELFTEST-LEAK|Bearer' "$out/selftest.txt"; then echo "selftest printed the API key" >&2; exit 1; fi
# The login status (halos-status.timer): the console line and the SSH message's version lines.
# A new install first waits for setup; halosctl setup --skip then starts the download.
grep -q 'waiting for setup: sudo halosctl setup' "$out/setup.txt" || { cat "$out/setup.txt" >&2; echo "the line didn't say setup is pending" >&2; exit 1; }
# --skip's own message is saved in the VM and printed later, with the selftest: the login prompt
# on the serial console is redrawn when the status changes (agetty --reload), which can swallow
# output written at that moment.
grep -q 'The first download (about 130 GB) starts now' "$out/selftest.txt" || { echo "setup --skip didn't release the download" >&2; exit 1; }
# The VM has no network, so the first download keeps retrying: the line must say so, which also
# proves the sandboxed service can ask the halogen user's service manager.
# Through a file, not a pipe: grep -q stops reading early, sed dies of SIGPIPE, and pipefail fails.
sed -n '/ISSUE-END/q;p' "$out/selftest.txt" > "$out/issue.txt"
grep -qE '^halOS [^ ]+ \((npu|no-npu) edition\) - downloading models [0-9]+%' "$out/issue.txt" \
  || { echo "the login status line is missing or wrong" >&2; exit 1; }
grep -qE '^  Halogen: ' "$out/selftest.txt" || { echo "no version lines in the SSH message" >&2; exit 1; }
echo "selftest verified"

if [ -n "$luks" ]; then
  # First boot left a TPM binding for a Secure Boot state this machine no longer has.
  cat "$out/ssh-unlock.txt"
  grep -q '^SSHU-RC=0' "$out/ssh-unlock.txt" || { echo "halosctl ssh-unlock failed" >&2; exit 1; }
  grep -q '^on, 1 key' "$out/ssh-unlock.txt" || { echo "the installer didn't set up unlocking over SSH" >&2; exit 1; }
  grep -q '^CHOICE both$' "$out/ssh-unlock.txt" || { echo "the installer's unlock choice wasn't kept" >&2; exit 1; }
  grep -q '^ADMINKEYS 1$' "$out/ssh-unlock.txt" || { echo "the admin user didn't get the key" >&2; exit 1; }
  # A new install has no record of the keys on the encrypted disk yet, so the selftest says so
  # rather than PASS (sudo halosctl ssh-unlock record makes one).
  grep -q '^INFO ssh-unlock: unlocks over SSH at boot (1 key' "$out/ssh-unlock.txt" || { echo "the selftest doesn't see unlocking over SSH" >&2; exit 1; }
  grep -q '^Record: none on the encrypted disk yet' "$out/ssh-unlock.txt" || { echo "status doesn't say there is no record yet" >&2; exit 1; }
  # The known_hosts line halosctl prints, as people add it: under the unlock name (HostKeyAlias).
  sed -n 's/^ *known_hosts line: //p' "$out/ssh-unlock.txt" | tr -d '\r' | head -n 1 > "$out/known_hosts"
  grep -q '^halostest-unlock ssh-ed25519 ' "$out/known_hosts" || { echo "no known_hosts line for halostest-unlock" >&2; exit 1; }

  echo "=== second boot: stale binding, so the passphrase is asked; answered over SSH; re-enroll ==="
  timeout 180 tail --pid="$pid" -f /dev/null || { echo "the VM did not power off after enrolling" >&2; exit 1; }
  # Network for the initramfs's SSH server only: restrict=on lets nothing out of the VM.
  vm -nic "user,restrict=on,hostfwd=tcp:127.0.0.1:2222-:22" -serial "file:$out/secondboot.log" &
  pid=$!
  # As a person would: ssh in, type the passphrase. Until the prompt is there, the server isn't up
  # yet or has nothing to ask; it counts only once the passphrase prompt was answered.
  (
    deadline=$((SECONDS + 600))
    while [ "$SECONDS" -lt "$deadline" ]; do
      # The passphrase once the prompt is up; the session stays open until the unlock ends it.
      { sleep 3; printf 'halogentest\n'; sleep 30; } | timeout 60 ssh -tt -p 2222 -i "$out/unlock-key" -o BatchMode=yes \
        -o UserKnownHostsFile="$out/known_hosts" -o HostKeyAlias=halostest-unlock \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
        root@127.0.0.1 > "$out/ssh-session.log" 2>&1 || true
      if grep -qi 'passphrase' "$out/ssh-session.log"; then touch "$out/ssh-unlocked"; exit 0; fi
      sleep 5
    done
  ) &
  sshpid=$!
  python3 "$here/vm-login.py" "$out/monitor.sock" "$out/secondboot.log" "$out" ssh-enroll
  wait "$sshpid" || true
  cat "$out/ssh-session.log" || true
  [ -e "$out/ssh-unlocked" ] || { echo "the disk was not unlocked over SSH" >&2; exit 1; }
  # The early-boot network is gone once the system runs: its own NetworkManager settings apply.
  # The system keeps its own runtime profiles there too ("Wired connection 1", lo); only the
  # generator's default_connection is the early boot's.
  grep '^NMRUN ' "$out/report.txt" || true
  if grep -q '^NMRUN .*/default_connection\.nmconnection' "$out/report.txt"; then echo "the early-boot network settings stayed" >&2; exit 1; fi
  echo "unlock over SSH verified"

  echo "=== third boot: the TPM must unlock the disk ==="
  timeout 180 tail --pid="$pid" -f /dev/null || { echo "the VM did not power off after re-enrolling" >&2; exit 1; }
  vm -nic none -serial "file:$out/thirdboot.log" &
  pid=$!
  python3 "$here/vm-login.py" "$out/monitor.sock" "$out/thirdboot.log" "$out" tpm
  cat "$out/report.txt"
  tokens="$(grep -cE '^[[:space:]]*[0-9]+: systemd-tpm2' "$out/report.txt" || true)"
  # One token means the re-enroll replaced the stale binding instead of adding a second.
  [ "$tokens" = 1 ] || { echo "expected one TPM token on the LUKS volume, found $tokens" >&2; exit 1; }
  echo "TPM unlock verified"
  cat "$out/selftest.txt"
  grep -q '^PASS luks-tpm:' "$out/selftest.txt" || { echo "selftest did not see the TPM unlock" >&2; exit 1; }
  # Anaconda writes ro for / without bootc's marker, so bootc 1.17.1 creates its fstab edit unit at
  # every boot; ours must skip it (bootc-dev/bootc#2592). What counts is that fstab is never
  # rewritten: the unit skipped or never made (some base images don't make it), and no marker.
  if grep -qiE '(Finished|Started|Starting).*bootc-fstab-edit|Updated by bootc-fstab-edit' "$out/report.txt" \
    || ! grep -q '^FSTABMARK 0' "$out/report.txt"; then
    echo "bootc-fstab-edit still rewrote fstab" >&2; exit 1
  fi
  grep -qi "skipped due to 'exec-condition'" "$out/report.txt" || echo "note: bootc-fstab-edit wasn't made at this boot; fstab unchanged"
fi
