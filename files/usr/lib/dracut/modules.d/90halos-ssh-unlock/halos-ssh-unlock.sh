#!/bin/bash
# Runs in the initramfs. When the EFI system partition holds /halos/ssh-unlock/ (put there by
# halosctl ssh-unlock), brings up wired network with DHCP (halos-initrd-net, which also drops it
# before the real system starts) and starts an SSH server whose only command answers the disk
# passphrase prompt. Otherwise it does nothing.
set -u
esp_type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
run=/run/halos-ssh-unlock mnt=/run/halos-esp

mkdir -p "$run" "$mnt" && chmod 0700 "$run" "$mnt"
# The machine's own disks only: an EFI partition on a USB stick could otherwise turn this on.
# lsblk gives a partition no transport (TRAN is read from the disk's "device" link, which a
# partition lacks), so ask for the device and every device under it (-s) and refuse any on USB.
on_usb() { [[ $'\n'"$(lsblk -rsno TRAN "$1" 2> /dev/null)"$'\n' == *$'\n'usb$'\n'* ]]; }
internal_esps() {
  lsblk -rno PATH,PARTTYPE,RM 2> /dev/null | while read -r p t rm; do
    [ "$t" = "$esp_type" ] && [ "$rm" = 0 ] && ! on_usb "$p" && echo "$p"
  done
}
# The disk's partitions appear within seconds; give them up to 30.
found="" esps=""
for _ in {1..30}; do
  esps="$(internal_esps)"
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

# Wired network, DHCP, through the initramfs's NetworkManager.
/usr/libexec/halos-initrd-net up || true
echo "halos-ssh-unlock: waiting for the disk passphrase over SSH (port 22)"
# sshd re-executes itself, so it needs its absolute path.
exec "$(command -v sshd)" -D -e -f /etc/ssh/halos-unlock.conf
