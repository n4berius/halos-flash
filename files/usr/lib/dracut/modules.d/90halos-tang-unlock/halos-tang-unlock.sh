#!/bin/bash
# Runs in the initramfs. When an encrypted volume has a clevis binding that names a tang server
# (put there by halosctl tang-unlock), brings up wired network with DHCP (halos-initrd-net, which
# also drops it before the real system starts) and starts clevis's password agent. The agent
# answers the passphrase prompt once the server (and, in "and" mode, the TPM) gives the key back,
# trying again every half second while the prompt waits; the passphrase still works meanwhile, at
# the keyboard or over SSH. Otherwise it does nothing. Never ordered before the unlock, so a
# machine without it doesn't wait.
set -u
# The disk's volumes appear within seconds; give them up to 60. A machine without encryption
# just finds none.
# The machine's own disks only, as halos-ssh-unlock: a USB stick with a tang binding must not start
# the network. lsblk gives a partition no transport, so the devices under it (-s) are asked too.
on_usb() { [[ $'\n'"$(lsblk -rsno TRAN "$1" 2> /dev/null)"$'\n' == *$'\n'usb$'\n'* ]]; }
devs=""
for _ in {1..60}; do
  devs=""
  for d in $(lsblk -rno PATH,FSTYPE,RM 2> /dev/null | awk '$2 == "crypto_LUKS" && $3 == "0" { print $1 }'); do
    on_usb "$d" || devs="$devs $d"
  done
  [ -z "$devs" ] || break
  sleep 1
done
found=""
for d in $devs; do
  if clevis luks list -d "$d" 2> /dev/null | grep -qw tang; then found="$d"; break; fi
done
if [ -z "$found" ]; then echo "halos-tang-unlock: not set up on this machine"; exit 0; fi
/usr/libexec/halos-initrd-net up || true
echo "halos-tang-unlock: asking the tang server to unlock $found"
systemctl start --no-block clevis-luks-askpass.path
