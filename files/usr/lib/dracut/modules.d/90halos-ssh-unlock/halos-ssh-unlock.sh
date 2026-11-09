#!/bin/bash
# Runs in the initramfs. When the EFI system partition holds /halos/ssh-unlock/ (put there by
# halosctl ssh-unlock), brings up wired network with DHCP and starts an SSH server whose only
# command answers the disk passphrase prompt. Otherwise it does nothing.
set -u
esp_type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
run=/run/halos-ssh-unlock mnt=/run/halos-esp
mkdir -p "$run" "$mnt" && chmod 0700 "$run" "$mnt"

# The disk's partitions appear within seconds; give them up to 30.
found="" esps=""
for _ in $(seq 30); do
  esps="$(lsblk -rno PATH,PARTTYPE 2> /dev/null | while read -r p t; do [ "$t" = "$esp_type" ] && echo "$p"; done)"
  [ -z "$esps" ] || break
  sleep 1
done
for dev in $esps; do
  mount -t vfat -o ro,nodev,nosuid,noexec,umask=0077 "$dev" "$mnt" 2> /dev/null || continue
  src="$mnt/halos/ssh-unlock"
  if [ -s "$src/authorized_keys" ] && [ -s "$src/ssh_host_ed25519_key" ]; then
    cp "$src/authorized_keys" "$src/ssh_host_ed25519_key" "$run/" && found=1
  fi
  umount "$mnt"
  [ -z "$found" ] || break
done
if [ -z "$found" ]; then echo "halos-ssh-unlock: not set up on this machine"; exit 0; fi
chmod 0600 "$run"/*

# Wired network, DHCP, through the initramfs's NetworkManager; the system's own takes it over
# after the disk is unlocked.
if [ -x /usr/libexec/nm-initrd-generator ]; then
  /usr/libexec/nm-initrd-generator -- ip=dhcp rd.neednet=1
  systemctl start --no-block nm-initrd.service || true
fi
echo "halos-ssh-unlock: waiting for the disk passphrase over SSH (port 22)"
# sshd re-executes itself, so it needs its absolute path.
exec "$(command -v sshd)" -D -e -f /etc/ssh/halos-unlock.conf
