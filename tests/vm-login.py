"""Log in at a VM console through the QEMU monitor and capture a report on serial.

Usage: vm-login.py monitor.sock serial.log out-dir [plain|luks|luks-stale|luks-enroll|ssh-enroll|tpm]
With HALOS_TEST_SSH_UNLOCK=1, luks-stale also reports unlocking over SSH, which the installer set up.
  luks         type the disk passphrase, which must be asked for
  luks-stale   as luks, then enroll the TPM against a changed PCR 7 (as if the Secure Boot
               state later changed) and power off, leaving a binding that won't unlock
  luks-enroll  as luks, then bind the disk to the TPM with halogen-enroll-tpm and power off
  ssh-enroll   as luks-enroll, but the passphrase comes over SSH (tests/iso-install.sh), not typed
  tpm          fail if the passphrase is asked for: the TPM must unlock the disk by itself
"""
import os, pathlib, re, socket, subprocess, sys, time

sock_path, serial, out = sys.argv[1:4]
mode = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else "plain"
luks = mode in ("luks", "luks-stale", "luks-enroll")
asked = False
serial, out = pathlib.Path(serial), pathlib.Path(out)
KEYS = {" ": "spc", "-": "minus", "=": "equal", ".": "dot", "/": "slash", ";": "semicolon",
        ",": "comma", "'": "apostrophe", "\n": "ret",
        "[": "bracket_left", "]": "bracket_right", "\\": "backslash"}
SHIFT = {"_": "minus", "|": "backslash", ">": "dot", "{": "bracket_left", "}": "bracket_right",
         "&": "7", "*": "8", "(": "9", ")": "0", "$": "4", "?": "slash", '"': "apostrophe", "!": "1",
         "@": "2", "#": "3", ":": "semicolon", "+": "equal", "<": "comma", "%": "5"}

time.sleep(5)
mon = socket.socket(socket.AF_UNIX)
mon.connect(sock_path)

def cmd(text):
    mon.send((text + "\n").encode())
    time.sleep(0.05)

def typed(text):
    for ch in text:
        if ch in SHIFT: key = "shift-" + SHIFT[ch]
        elif ch in KEYS: key = KEYS[ch]
        elif ch.isupper(): key = "shift-" + ch.lower()
        else: key = ch
        cmd("sendkey " + key)

deadline = time.time() + 600
while time.time() < deadline:
    time.sleep(15)
    shot = out / "console.png"
    cmd(f"screendump {shot} -f png")
    time.sleep(2)
    text = subprocess.run(["tesseract", shot, "-"], capture_output=True, text=True).stdout
    if mode == "tpm" and "passphrase" in text.lower():
        print(text)
        sys.exit("the disk asked for its passphrase: the TPM did not unlock it")
    if luks and "passphrase" in text.lower():
        typed("halogentest\n")
        luks = False
        asked = True
        continue
    if "login:" in text:
        break
else:
    print(text)
    sys.exit("no login prompt appeared")
if mode in ("luks", "luks-stale", "luks-enroll") and not asked:
    sys.exit("the disk was expected to ask for its passphrase, but it did not")

# The guided install's test answers (tests/iso-install.sh): the root password is not the disk's.
typed("root\n"); time.sleep(3)
typed("rootsecret\n"); time.sleep(5)
# The user services start after the fabric clock, which waits about a minute for a GPU
# that a VM does not have. Give them time before reporting.
typed("timeout 180 sh -c 'until journalctl -o cat _SYSTEMD_USER_UNIT=halogen-fetch.service | grep -q halogen-fetch; do sleep 5; done'\n")
time.sleep(5)
typed("{ echo RESULT-START; cat /proc/cmdline; dmesg | grep -i secure; bootctl status | grep -i secure; "
      "bootc status | head -12; udevadm verify /usr/lib/udev/rules.d/70-halogen-devices.rules; "
      "lsblk -f | grep -i crypto; sysctl kernel.dmesg_restrict kernel.kptr_restrict kernel.yama.ptrace_scope; sshd -T | grep -i x11forwarding; "
      "for d in $(lsblk -rno PATH,FSTYPE | awk '$2==\"crypto_LUKS\"{print $1}'); do cryptsetup luksDump $d | grep -i systemd-tpm2; done; vgs --noheadings -o vg_name; findmnt -rn -o TARGET,SOURCE -t xfs; sestatus | head -3; id halogen; loginctl show-user halogen -p Linger; "
      "systemctl status user@970.service --no-pager | head -4; journalctl --no-pager -n 8 -o cat _SYSTEMD_USER_UNIT=halogen-fetch.service; systemctl --failed --no-legend --no-pager; "
      "systemctl is-active firewalld halogen-prepare; halosctl version; ls /etc/ssh/sshd_config.d; sshd -T | grep -i permitrootlogin; journalctl -b -o cat -u bootc-fstab-edit; echo FSTABMARK $(grep -c Updated.by.bootc-fstab-edit /etc/fstab); fwupdtool esp-list --json > /tmp/esp 2>&1; echo ESPRC $? $(grep -c /boot/efi /tmp/esp) $(systemctl is-enabled udisks2); echo UDLOOP $(runuser -u admin -- udisksctl loop-setup -r --no-user-interaction -f /etc/os-release 2>&1 | grep -c Error.NotAuthorized:); runuser -u halogen -- busctl call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager org.freedesktop.DBus.Properties GetAll s org.freedesktop.UDisks2.Manager > /tmp/udbus 2>&1; echo UDBUS $(grep -c -i access.denied /tmp/udbus); echo UDBUSOUT $(head -c 200 /tmp/udbus | tr -cd [:print:]); echo UDBUSLOG $(journalctl -b -u dbus-broker --no-pager -o cat | grep -i -e halogen -e udisks | tail -n 3 | tr -cd [:print:]); echo UDBUSADMIN $(runuser -u admin -- busctl call org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager org.freedesktop.DBus.Properties GetAll s org.freedesktop.UDisks2.Manager 2>&1 | grep -c -F a{sv}); "
      # Security audit P1: a link planted in /srv/models must not let root hand its target to halogen.
      # Only the NPU edition makes model folders, so on no-NPU this passes without testing much.
      "mkdir -p -m 755 /var/tmp/victim; mv /var/srv/models/custom /var/srv/models/custom.x; ln -s /var/tmp/victim /var/srv/models/custom; "
      "systemctl restart halogen-prepare; ls -ld /var/tmp/victim; rm /var/srv/models/custom; mv /var/srv/models/custom.x /var/srv/models/custom; "
      "systemctl restart halogen-prepare; "
      # Request records (#107): on adds the mount and counts only reach Halogen; off removes it.
      # Halogen doesn't run in the VM, so nothing is recorded: that part is checked on freyja.
      "halogenctl records on --yes 2>&1 | cat > /tmp/rec; "
      "echo RECCONF $(halogenctl config 2>/dev/null | grep -c -x -e HALOGEN_RECORD_DIR=/records -e HALOGEN_RECORD_TEXT=none) "
      "$(setpriv --reuid=halogen --regid=halogen --init-groups env XDG_RUNTIME_DIR=/run/user/970 systemctl --user cat halogen.service 2>/dev/null | grep -c -F srv/logs/halogen:/records); "
      "halogenctl records off --yes 2>&1 | cat >> /tmp/rec; echo RECOFF $(ls /etc/containers/systemd/users/970/halogen.container.d | grep -c records); "
      "stat -c 'RECDIR %U %a' /var/srv/logs/halogen; cat /tmp/rec; "
      # Hardening: the logs volume can't hold programs, and Halogen's container is read-only.
      "echo RECMNT $(findmnt -n -o OPTIONS /var/srv/logs | tr , ' ' | xargs -n 1 | grep -c -x -e nodev -e nosuid -e noexec) "
      "$(setpriv --reuid=halogen --regid=halogen --init-groups env XDG_RUNTIME_DIR=/run/user/970 systemctl --user cat halogen.service 2>/dev/null | grep -c -e --read-only); "
      # The guided install (#42): volume sizes, hostname, admin user, and no password left behind.
      "lvs --noheadings --units g --nosuffix -o lv_name,lv_size halos; cat /etc/hostname; id admin; "
      "grep -rIlsE 'halogentest|rootsecret|adminsecret' /etc /var/roothome /var/log /boot | sed 's/.*/PWLEAK &/'; "
      "echo PWJOURNAL $(journalctl -o cat | grep -cE 'halogentest|rootsecret|adminsecret'); "
      # The serial getty has halOS's port check and still runs on a port that answers (QEMU's
      # ttyS0). QEMU's other ports don't fail like freyja's dead ttyS0, so the skip is checked there.
      "echo SERIALGETTY $(systemctl is-active serial-getty@ttyS0.service) "
      "$(systemctl show serial-getty@ttyS0.service -p ExecCondition --value | grep -c stty); "
      # Unlock over SSH (#13): no early-boot network settings may stay in the running system.
      "for f in /run/NetworkManager/system-connections/*; do [ -e \"$f\" ] && echo NMRUN $f; done; "
      "echo RESULT-END; } > /dev/ttyS0 2>&1\n")

def wait_serial(marker, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        time.sleep(5)
        log = serial.read_text(errors="replace")
        if marker in log:
            return log
    sys.exit(f"{marker} never reached the serial log")

log = wait_serial("RESULT-END", 300)
report = log.split("RESULT-START")[-1].split("RESULT-END")[0]
(out / "report.txt").write_text(re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", report))
# The same self-check people run on hardware. A VM has no GPU, so some checks fail here;
# iso-install.sh checks the ones a VM can pass.
# The real API key is compared inside the VM (grep -f never prints it); only a marker leaves.
# A new install waits for first-boot setup: the login line says so, then --skip starts the download.
typed("cat /run/issue.d/50-halos.issue > /dev/ttyS0; echo SETUP-WAIT-END > /dev/ttyS0; "
      "halosctl setup --skip > /tmp/skip 2>&1; sleep 45; echo SETUP-SKIPPED > /dev/ttyS0\n")
log = wait_serial("SETUP-SKIPPED", 180)
(out / "setup.txt").write_text(log.split("RESULT-END")[-1].split("SETUP-SKIPPED")[0])
typed("halogenctl selftest > /tmp/st 2>&1; rc=$?; cat /tmp/st > /dev/ttyS0; "
      "grep -qF -f /srv/configs/api-key /tmp/st && echo SELFTEST-LEAK > /dev/ttyS0; "
      "cat /tmp/skip > /dev/ttyS0; echo SKIP-END > /dev/ttyS0; "
      "cat /run/issue.d/50-halos.issue > /dev/ttyS0; echo ISSUE-END > /dev/ttyS0; "
      "cat /run/motd.d/50-halos > /dev/ttyS0; "
      "echo SELFTEST-RC=$rc > /dev/ttyS0\n")
log = wait_serial("SELFTEST-RC=", 300)
selftest = log.split("RESULT-END")[-1].split("SELFTEST-RC=")[0]
(out / "selftest.txt").write_text(re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", selftest))

# HTTPS (#102): self-signed, then back to plain HTTP. Halogen isn't up in the VM, so Caddy's own
# 503 note answers /health: CURL 503 means the TLS handshake passed with halOS's authority.
if mode in ("plain", "luks-stale"):   # the first boot only
    # Each step says when it starts on the serial console, so a slow step shows; what Caddy was
    # given, what listens, its status and log come at the end.
    step = lambda n: "echo HTTPS-STEP-" + n + " $(date +%s) > /dev/ttyS0; "
    # No --retry: curl retries a 503 and obeys its Retry-After (30 s), and a 503 is the answer
    # expected here; halosctl has already waited for Caddy to answer.
    c = "curl -sS -m 10 -o /dev/null "
    typed(step("on") + "halosctl https self-signed --yes > /tmp/https 2>&1; echo HTTPS-RC=$? >> /tmp/https; "
          + step("ca") + "/usr/libexec/halogen/https ca > /tmp/ca.pem; "
          # What Caddy was given and what listens, before any request.
          + "{ cat /run/halos-https/proxy.env; ss -tlnp; systemctl show halos-proxy -p ActiveState -p SubState -p NRestarts; } > /tmp/https-diag 2>&1; "
          + step("curl") + c + "-w 'CURL %{http_code}' --cacert /tmp/ca.pem https://127.0.0.1:8731/health >> /tmp/https 2>&1; echo >> /tmp/https; "
          + c + "-w 'REDIRECT %{http_code}' http://127.0.0.1:8731/health >> /tmp/https 2>&1; echo >> /tmp/https; "
          + step("selftest") + "halogenctl selftest 2>&1 | grep -E 'https|proxy:|dashboard:|api-ipv6' >> /tmp/https; "
          + "systemctl status halos-proxy --no-pager -n 0 >> /tmp/https-diag 2>&1; journalctl -b -u halos-proxy --no-pager -o cat -n 25 >> /tmp/https-diag 2>&1; "
          + step("off") + "halosctl https off --yes >> /tmp/https 2>&1; echo OFF-RC=$? >> /tmp/https; "
          + step("back") + c + "-w 'BACK %{http_code}' http://127.0.0.1:8731/health >> /tmp/https 2>&1; echo >> /tmp/https; "
          # DNS credentials reach Caddy as systemd credentials (LoadCredential=), readable by its user,
          # and gone after forget-dns. (The runtime-folder count is only a smoke check: the copy
          # happened in letsencrypt mode, which tests/https.sh covers.) A made-up DuckDNS token:
          # the mode stays off, so nothing is asked of DuckDNS.
          + step("cred") + "printf 'api_token=0123abcd-0123-abcd-0123-0123456789ab' | /usr/libexec/halogen/https dns-stage duckdns >> /tmp/https 2>&1; "
          + "/usr/libexec/halogen/https dns-commit; systemctl restart halos-proxy; sleep 3; "
          + "echo CRED $(stat -c '%a %U' /run/credentials/halos-proxy.service/dns_api_token) $(ls -A /run/halos-proxy | grep -c dns) >> /tmp/https 2>&1; "
          + "u=$(ps -o uid= -p $(systemctl show -P MainPID halos-proxy)); "
          + "echo CREDREAD $(setpriv --reuid=$u --regid=$u --clear-groups head -c 4 /run/credentials/halos-proxy.service/dns_api_token | wc -c) >> /tmp/https 2>&1; "
          # forget-dns restarts Caddy itself, so the token it had loaded goes too.
          + "halosctl https forget-dns --yes >> /tmp/https 2>&1; sleep 3; "
          + "echo CREDGONE $(ls -A /run/credentials/halos-proxy.service | grep -c api_token) $(systemctl is-active halos-proxy) >> /tmp/https 2>&1; "
          # Each switch changes the login screen's line, and agetty's reload on the serial console
          # can swallow what is written meanwhile (login-status runs every 30 s): wait it out.
          + step("print") + "sleep 35; cat /tmp/https /tmp/https-diag > /dev/ttyS0; echo HTTPS-END > /dev/ttyS0\n")
    log = wait_serial("HTTPS-END", 600)
    (out / "https.txt").write_text(re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", log.split("SELFTEST-RC=")[-1].split("HTTPS-END")[0]))

if mode == "luks-stale" and os.environ.get("HALOS_TEST_SSH_UNLOCK"):
    # Unlock over SSH (#13), set up by the installer (TPM and SSH): the next boot asks over SSH too.
    typed("halosctl ssh-unlock > /tmp/sshu 2>&1; echo SSHU-RC=$? >> /tmp/sshu; "
          "echo CHOICE $(/usr/libexec/halogen/ssh-unlock choice) >> /tmp/sshu; "
          "echo ADMINKEYS $(grep -c halostest /var/home/admin/.ssh/authorized_keys) >> /tmp/sshu; "
          "halogenctl selftest 2>&1 | grep ssh-unlock >> /tmp/sshu; "
          # What the installer's save-unlock said (/var/log/anaconda keeps the %post output).
          "grep -h halOS /var/log/anaconda/ks-script-*.log >> /tmp/sshu; "
          "cat /tmp/sshu > /dev/ttyS0; echo SSHU-END > /dev/ttyS0\n")
    log = wait_serial("SSHU-END", 120)
    (out / "ssh-unlock.txt").write_text(log.split("SELFTEST-RC=")[-1].split("SSHU-END")[0])

if mode in ("luks-stale", "luks-enroll", "ssh-enroll"):
    # Exactly what INSTALL.md tells people to run; PASSWORD answers the passphrase prompt.
    # For a stale binding, PCR 7 is first extended so the TPM records a value the next boot
    # won't reproduce, like a BIOS or Secure Boot change after enrolling.
    # pcrextend skips non-UKI boots unless told to measure; then check PCR 7 really moved.
    stale = ("before=$(cat /sys/class/tpm/tpm0/pcr-sha256/7) && "
             "SYSTEMD_FORCE_MEASURE=1 /usr/lib/systemd/systemd-pcrextend --pcr=7 halogen-test-stale && "
             "[ \"$(cat /sys/class/tpm/tpm0/pcr-sha256/7)\" != \"$before\" ] && echo PCR7-CHANGED && "
             if mode == "luks-stale" else "")
    typed("{ " + stale + "PASSWORD=halogentest halogen-enroll-tpm; } "
          "> /dev/ttyS0 2>&1; echo ENROLL-RC=$? > /dev/ttyS0\n")
    log = wait_serial("ENROLL-RC=", 120)
    tail = log.split("RESULT-END")[-1]
    print(tail)
    if mode == "luks-stale" and "PCR7-CHANGED" not in tail:
        sys.exit("PCR 7 could not be changed, so the stale-binding test would prove nothing")
    if "ENROLL-RC=0" not in tail:
        sys.exit("halogen-enroll-tpm failed")
    typed("systemctl poweroff\n")
sys.exit(0)
