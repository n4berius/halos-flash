# Only the OS source is preset, so the installer asks about disks, encryption and users.
bootc --source-imgref containers-storage:@TARGET_IMAGE@ --target-imgref @TARGET_IMAGE@

%post --nochroot --interpreter=/usr/bin/bash
# halOS images are signed (#46). The bootc line installs without checking signatures; this turns
# the check on for every update (bootc's in-place switch, made for an installer's %post). It needs
# the disk's top level at /sysroot inside the new system, which Anaconda's bootc install doesn't
# bind (only its OSTree install does), so bind it here. Should it fail, the install still boots,
# the selftest warns, and halosctl upgrade turns it on later.
root="${ANA_INSTALL_PATH:-/mnt/sysroot}"; physical=/mnt/sysimage
[ -d "$physical/ostree/deploy" ] || { echo "halOS: no OSTree deployment at $physical" > /dev/console; exit 1; }
mount --bind "$physical" "$root/sysroot" || exit 1
chroot "$root" bootc switch --mutate-in-place --enforce-container-sigpolicy @TARGET_IMAGE@ 2>&1 | tee /dev/console
rc=${PIPESTATUS[0]}
umount "$root/sysroot"
exit "$rc"
%end
