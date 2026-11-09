# Only the OS source is preset, so the installer asks about disks, encryption and users.
bootc --source-imgref containers-storage:@TARGET_IMAGE@ --target-imgref @TARGET_IMAGE@

%post
# halOS images are signed (#46). The line above installs without checking signatures; this turns
# the check on for every update (bootc's in-place switch, made for an installer's %post). Should it
# fail, the install still boots, the selftest warns, and halosctl upgrade turns it on later.
bootc switch --mutate-in-place --enforce-container-sigpolicy @TARGET_IMAGE@
%end
