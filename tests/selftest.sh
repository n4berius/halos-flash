#!/bin/bash
# shellcheck disable=SC2016 # The fake commands expand their variables when they run.
# halogenctl selftest against fake hardware and fake system tools.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fake="$work/fake"; sysbin="$work/sysbin"
mkdir -p "$fake" "$sysbin" "$work/sys/class/dmi/id" "$work/sys/class/net/enp1s0/device" \
  "$work/dev/dri" "$work/dev/accel" "$work/models/npu/qwen3.5-2b" "$work/configs" "$work/logs/halogen"
export FAKE="$work"

# Only basic tools, so a tool missing from the image really is missing here.
for t in bash sh cat head tail sed awk grep find df date paste wc sort uname basename readlink \
  mktemp chmod rm stat tr cut printf python3 timeout id ls env mkdir jq cmp du findmnt; do
  p="$(command -v "$t")" && ln -sf "$p" "$sysbin/$t"
done
ln -sf /usr/bin/test "$sysbin/test"   # as_owner test -e runs the program, not the shell builtin

echo "ASUS" > "$work/sys/class/dmi/id/board_vendor"; echo "board" > "$work/sys/class/dmi/id/board_name"
echo "1.02" > "$work/sys/class/dmi/id/bios_version"
echo up > "$work/sys/class/net/enp1s0/operstate"; echo 5000 > "$work/sys/class/net/enp1s0/speed"
touch "$work/dev/kfd" "$work/dev/dri/renderD128" "$work/dev/accel/accel0" "$work/dev/tpmrm0"
mkdir -p "$work/models/flash" "$work/models/decider" "$work/models/LFM" "$work/models/custom"; touch "$work/models/.fetch-stamp"
echo 'SECRET-KEY-MARKER' > "$work/configs/api-key"; echo 'hf_SECRET-TOKEN-MARKER' > "$work/configs/hf-token"
printf 'MemTotal: 130000000 kB\n' > "$work/meminfo"
echo 'BOOT_IMAGE=x amdgpu.gttsize=126976 ttm.pages_limit=32505856 iommu=pt' > "$work/cmdline"
printf 'HALOGEN_VARIANT=npu\nHALOGEN_VERSION=9.9.9\nHALOGEN_WEIGHTS_REVISION=abc\n' > "$work/release.env"

f() { printf '#!/bin/bash\n%s\n' "$2" > "$fake/$1"; chmod +x "$fake/$1"; }
# prlimit: run what follows --.
f prlimit 'case "$*" in *--memlock=unlimited*) export FAKE_MEMLOCK=1 ;; esac; while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift; exec "$@"'
# setpriv as halogen: run what follows env (the fake systemctl, or podman).
f setpriv 'while [ $# -gt 0 ] && [ "$1" != env ]; do shift; done; exec "$@"'
f podman 'case "$*" in *"exec halogen stat"*) [ "$PWD" = / ] || { echo "cannot chdir to $PWD: Permission denied"; exit 125; }
    [ -n "${FAKE_MEMLOCK:-}" ] || { echo "crun: setrlimit RLIMIT_MEMLOCK: Operation not permitted"; exit 126; } ;; esac; case "$*" in *"exec halogen stat"*) printf "/tmp xfs\n/var/tmp %s\n/root xfs\n" "${FAKE_VARTMP:-xfs}" ;; *) exit 1 ;; esac'
f mokutil 'echo "SecureBoot ${FAKE_SB:-enabled}"'
f getenforce 'echo "${FAKE_SELINUX:-Enforcing}"'
f journalctl 'case "$*" in *--disk-usage*) echo "Archived and active journals take up 1.2G in the file system." ;; *) cat "$FAKE/kernel.log" 2>/dev/null ;; esac; true'
# auditd's loaded rules: halOS's watches unless FAKE_AUDIT says otherwise.
f auditctl 'if [ "$1" = -s ]; then echo "enabled ${FAKE_AUDIT_ENABLED:-2}"; echo "lost ${FAKE_AUDIT_LOST:-0}"; exit 0; fi
ex="-a never,task -F uid=970 -F auid=970"; w="-w /etc/passwd -p wa -k accounts"; x="-a always,exit -S all -F path=/usr/bin/env -F perm=x -F auid!=-1 -F key=halosctl"
case "${FAKE_AUDIT:-halos}" in
  halos) printf "%s\n" "$ex" "$w" "$x" ;;
  wide) printf "%s\n" "$ex" "-a never,task -F uid=0" "$w" "$x" ;;
  exclude) printf "%s\n" "$ex" "-a always,exclude -F msgtype=USER_CMD" "$w" "$x" ;;
  noexempt) printf "%s\n" "-a never,task -F uid=970" "$w" "$x" ;;
  fedora) echo "-a never,task" ;;
  few) printf "%s\n" "$ex" "$w" ;; esac'
f firewall-cmd 'case "$1" in --state) echo "${FAKE_FIREWALL:-running}" ;; --get-default-zone) echo FedoraServer ;; *) cat "$FAKE/services" ;; esac'
f lsblk 'echo "/dev/nvme0n1p3 crypto_LUKS"'
f cryptsetup 'printf "Tokens:\n  0: systemd-tpm2\n"'
f amd-smi 'if [ -n "${FAKE_NOGPU:-}" ]; then echo "ERROR:root:Unable to detect any GPU devices"; exit 255; fi; printf "GPU: 0\n    BDF: 0000:c3:00.0\n"'
f systemd-run 'case "$*" in *render-config*) printf "%s\n" "${FAKE_RENDER:-HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn}" ;; *) echo "preflight: ok" ;; esac'
f bootc 'case "$*" in *json*) echo "{\"spec\":{\"image\":{\"image\":\"${FAKE_FOLLOWS:-ghcr.io/n4berius/halos-flash:stable}\",\"signature\":\"${FAKE_SIG:-containerPolicy}\"}}}" ;; *) echo "Booted image: ghcr.io/n4berius/halos-flash:9.9.9" ;; esac'
f systemctl 'case "$*" in *--failed*) cat "$FAKE/failed" 2>/dev/null ;; *"show -p Job"*) echo "${FAKE_JOB:-}" ;;
  *"is-enabled halos-dashboard"*) echo "${FAKE_DASH:-enabled}" ;; *"is-active halos-proxy"*) echo "${FAKE_PROXY:-active}" ;;
  *"IPIngressBytes --value halos-dashboard"*) echo "${FAKE_DASH_IPIN-1234}" ;; *"IPAddressDeny --value halos-dashboard"*) echo "${FAKE_DASH_DENY-0.0.0.0/0 ::/0}" ;;
  *"IPAddressAllow --value halos-dashboard"*) echo "127.0.0.0/8 ::1/128" ;; *"MainPID --value halos-dashboard"*) echo "${FAKE_DASH_PID-4242}" ;; *"MainPID --value user@"*) echo "${FAKE_MGR_PID-0}" ;;
  *"--machine"*"cat halogen.service"*) exit 1 ;;  # that route failed on freyja: the selftest must not use it
  *"cat halogen.service"*) echo "${FAKE_UNIT-ExecStart=podman run -v /srv/logs/halogen:/records x}" ;;
  *halogen-fetch*) echo "${FAKE_FETCH:-inactive}" ;; *) echo "${FAKE_STATE:-active}" ;; esac'
f fabric-clock 'exit 0'
f ssh-unlock 'case "$1" in verify) exit "${FAKE_VERIFY:-0}" ;; *) echo "${FAKE_SSHU:-on 2}" ;; esac'
# Group, owner and label as the real image sets them.
f stat 'case "$2" in %G|%U) echo halogen ;; %u) case "$3" in /proc/4242/environ) echo "${FAKE_DASH_DUMP_UID:-0}" ;; *) exec /usr/bin/stat "$@" ;; esac ;; %C) case "$3" in *accel*) echo system_u:object_r:dri_device_t:s0 ;; *) echo system_u:object_r:container_file_t:s0 ;; esac ;; *) exec /usr/bin/stat "$@" ;; esac'
f curl 'echo "curl $*" >> "$FAKE/curl.log"; case "$*" in *-w*) ;; *18731/health*) h="${FAKE_HEALTH:-}"; [ -n "$h" ] || h="{\"status\":\"ok\"}"; echo "$h"; exit 0 ;; esac; case "$*" in *8732/healthz*) printf "${FAKE_DASH_CODE:-200}" ;; *models*) echo "{\"data\":[{\"id\":\"halogen-qwen3.8-flash-next\"},{\"id\":\"qwen3.5-2b\"}]}" ;; *::1*) [ -n "${FAKE_NOIPV6:-}" ] && printf 000 || printf 200 ;; *) printf 200 ;; esac'
echo "halogen" > "$work/services"
# Files halogen owns are read through runuser (security audit P2/P7); log it, then run the command.
f runuser 'echo "runuser $*" >> "$FAKE/runuser.log"; [ "$1 $2 $3" = "-u halogen --" ] || exit 9; shift 3; exec "$@"'
mkdir -p "$work/models/.cache/huggingface/download"
printf '8ef7ad828f7fa715cba0721a8ef9f9ab20d44e50\n' > "$work/models/.cache/huggingface/download/qwen38-flash-next-v2.hgn.metadata"

mkdir -p "$work/models/.prompt-cache"; /usr/bin/chmod 700 "$work/models/.prompt-cache"
mkdir -p "$work/audit"
mkdir -p "$work/audit" "$work/proc/4711" "$work/home/.config"
# The rules halOS ships, as the selftest reads them: two paths that exist, one that doesn't.
printf '%s\n' '-w /etc/passwd -p wa -k accounts' '-w /nonexistent/preload -p wa -k preload' \
  '-a always,exit -F path=/usr/bin/env -F perm=x -F auid!=unset -k halosctl' > "$work/halos.rules"
export PATH="$fake:$sysbin" HALOGEN_RELEASE_FILE="$work/release.env" HALOGEN_SYSFS="$work/sys" \
  HALOGEN_DEV="$work/dev" HALOGEN_CMDLINE="$work/cmdline" HALOGEN_MEMINFO="$work/meminfo" \
  HALOGEN_MODELS_DIR="$work/models" HALOGEN_CONFIGS_DIR="$work/configs" HALOGEN_CLOCK="$fake/fabric-clock" \
  HALOGEN_LOGS_DIR="$work/logs" HALOGEN_RECORDS_DROPIN="$work/20-records.conf" HALOS_LOG_DIR="$work" \
  HALOS_AUDIT_RULES="$work/halos.rules" HALOGEN_PROC="$work/proc" HALOGEN_HOME="$work/home" HALOGEN_RUNTIME_DIR="$work/run-user" \
  HALOS_POLICY="$repo/files/etc/containers/policy.json" HALOS_SSH_UNLOCK="$fake/ssh-unlock" \
  HALOS_ETC="$work/etc" HALOS_USR_ETC="$work/usretc" HALOS_ROOT_POLICY="$work/root-policy.json" \
  HALOS_HTTPS_HELPER="$fake/https" HALOS_HTTPS_RUN="$work/run-halos"
# The https helper: off unless FAKE_HTTPS says otherwise.
f https 'case "$1" in
  describe) case "${FAKE_HTTPS:-off}" in
      self-signed) echo "mode self-signed"; echo "ca ${FAKE_CA-AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89}"; echo "ca_until Jan 1 2036" ;;
      invalid) echo "mode invalid" ;;
      custom) echo "mode custom"; echo "subject CN=box.example"; echo "until Jan 1 2027"; echo "expires ${FAKE_EXPIRES:-later}" ;;
      letsencrypt) echo "mode letsencrypt"; echo "provider cloudflare"; echo "public halos.example.com"; echo "staging ${FAKE_STAGING:-no}"
        echo "names localhost 127.0.0.1"; echo "until ${FAKE_UNTIL:-Feb 1 2027}"; echo "issuer CN=R12,O=Let'"'"'s Encrypt"; echo "expires ${FAKE_EXPIRES:-later}" ;;
      *) echo "mode off" ;; esac ;;
  ca) [ "${FAKE_CA-x}" != none ] && echo "-----BEGIN CERTIFICATE-----" ;;
  uncovered) [ -z "${FAKE_UNCOVERED:-}" ] || echo "$FAKE_UNCOVERED" ;;
  *) exit 1 ;; esac'
f hostname 'echo "192.168.1.20 "'
mkdir -p "$work/run-halos"; printf 'HALOS_API_SITES="https://localhost:8731, https://192.168.1.20:8731"\n' > "$work/run-halos/proxy.env"
# /etc and the image's /usr/etc copy, alike to start with.
for d in etc usretc; do
  mkdir -p "$work/$d/containers/registries.d" "$work/$d/pki/containers"
  /usr/bin/cp "$repo/files/etc/containers/policy.json" "$work/$d/containers/"
  /usr/bin/cp "$repo/files/etc/containers/registries.d/halos-flash.yaml" "$work/$d/containers/registries.d/"
  /usr/bin/cp "$repo/files/etc/pki/containers/halos-flash.pub" "$work/$d/pki/containers/"
done
selftest="$repo/files/usr/libexec/halogen/selftest"
ok() { echo "ok: $*"; }
expect() { grep -qE "$1" "$work/out" || { echo "expected '$1' in:" >&2; cat "$work/out" >&2; exit 1; }; }
refuse() { if grep -qE "$1" "$work/out"; then echo "did not expect '$1' in:" >&2; cat "$work/out" >&2; exit 1; fi; }

"$selftest" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "a healthy machine failed" >&2; exit 1; }
for id in secure-boot image-signatures signature-files ssh-unlock kernel-iommu memory selinux-denials firewall luks-tpm gpu-kfd npu-device npu-label \
  fabric-clock server preflight api-ipv4 api-ipv6 proxy api-models dashboard dashboard-filter dashboard-nodump npu-folder folder-LFM folder-flash folder-logs; do
  expect "^PASS $id:"
done
expect '^Summary: [0-9]+ passed, 0 warnings, 0 failed'
expect 'serving: halogen-qwen3.8-flash-next qwen3.5-2b'
expect '^INFO records: off'
# The prompt cache on disk: on by default, off on request, and a missing folder is a warning.
expect '^PASS prompt-cache: on, '
# Off is two halves: the choice file, and root's drop-in that mounts the folder read-only.
pcoff="$work/etc/containers/systemd/users/halogen.container.d/15-prompt-cache.conf"
echo off > "$work/configs/prompt-cache"; "$selftest" > "$work/out" 2>&1 || true; expect '^WARN prompt-cache: off, but only half'
mkdir -p "${pcoff%/*}"; printf '%s\n' '# Written by sudo halogenctl cache off; removed by cache on.' '[Container]' \
  'Volume=/srv/models/.prompt-cache:/models/.prompt-cache:ro,noexec,nosuid,nodev' > "$pcoff"
FAKE_UNIT='ExecStart=podman run -v /srv/models/.prompt-cache:/models/.prompt-cache:ro,noexec,nosuid,nodev x' "$selftest" > "$work/out" 2>&1 || true
expect '^INFO prompt-cache: off, and Halogen can only read'
/usr/bin/rm "$pcoff"
# Two cache mounts in Halogen's unit (podman refuses them), and a read-only drop-in the unit doesn't follow.
two='ExecStart=podman run -v /srv/models/.prompt-cache:/models/.prompt-cache:ro,noexec -v /srv/models/.prompt-cache:/models/.prompt-cache:noexec x'
FAKE_UNIT="$two" "$selftest" > "$work/out" 2>&1 || true; expect '^FAIL prompt-cache: .* has 2 mounts'
echo off > "$work/configs/prompt-cache"; mkdir -p "${pcoff%/*}"; printf '%s\n' '# Written by sudo halogenctl cache off; removed by cache on.' '[Container]' \
  'Volume=/srv/models/.prompt-cache:/models/.prompt-cache:ro,noexec,nosuid,nodev' > "$pcoff"
FAKE_UNIT='ExecStart=podman run -v /srv/models/.prompt-cache:/models/.prompt-cache:noexec,nosuid,nodev x' "$selftest" > "$work/out" 2>&1 || true
expect "^WARN prompt-cache: off, but Halogen's service doesn't mount the cache folder read-only"; /usr/bin/rm "$pcoff"
# With the off drop-in there, a mount without options or from another source isn't "can only read".
printf '%s\n' '# Written by sudo halogenctl cache off; removed by cache on.' '[Container]' 'Volume=/srv/models/.prompt-cache:/models/.prompt-cache:ro,noexec,nosuid,nodev' > "$pcoff"
for u in 'ExecStart=podman run -v /srv/models/.prompt-cache:/models/.prompt-cache x' 'ExecStart=podman run -v /srv/configs:/models/.prompt-cache:noexec x'; do
  FAKE_UNIT="$u" "$selftest" > "$work/out" 2>&1 || true; expect "^WARN prompt-cache: off, but Halogen's service doesn't mount the cache folder read-only"
done
FAKE_UNIT='Failed to connect to bus' "$selftest" > "$work/out" 2>&1 || true; expect '^INFO prompt-cache: off, and Halogen can only read'
/usr/bin/rm "$pcoff"
# A --mount form landing on the cache folder is counted like -v.
FAKE_UNIT='ExecStart=podman run -v /srv/models/.prompt-cache:/models/.prompt-cache:noexec --mount type=bind,src=/srv/configs,dst=/models/.prompt-cache x' "$selftest" > "$work/out" 2>&1 || true
expect '^FAIL prompt-cache: .* has 2 mounts'
# A file in place of the NPU models folder.
/usr/bin/mv "$work/models/npu" "$work/models/npu.x"; : > "$work/models/npu"
"$selftest" > "$work/out" 2>&1 || true; expect "^FAIL npu-folder: .* isn't a folder of halogen's"
/usr/bin/rm "$work/models/npu"; /usr/bin/mv "$work/models/npu.x" "$work/models/npu"
# A link in place of the NPU models folder.
/usr/bin/mv "$work/models/npu" "$work/models/npu.x"; /usr/bin/ln -s "$work/configs" "$work/models/npu"
"$selftest" > "$work/out" 2>&1 || true; expect '^FAIL npu-folder: .* is a link'
/usr/bin/rm "$work/models/npu"; /usr/bin/mv "$work/models/npu.x" "$work/models/npu"
# A link in place of an own-checkpoint folder, and a file in halogen's own runtime Quadlet folder.
/usr/bin/mv "$work/models/custom" "$work/models/custom.x"; /usr/bin/ln -s "$work/configs" "$work/models/custom"
"$selftest" > "$work/out" 2>&1 || true; expect '^FAIL folder-custom: .* is a link'
/usr/bin/rm "$work/models/custom"; /usr/bin/mv "$work/models/custom.x" "$work/models/custom"
# A link in place of the folder, or a folder others can read.
/usr/bin/mv "$work/models/.prompt-cache" "$work/models/.pc"; /usr/bin/ln -s "$work/configs" "$work/models/.prompt-cache"
"$selftest" > "$work/out" 2>&1 || true; expect '^FAIL prompt-cache: .* is a link'
/usr/bin/rm "$work/models/.prompt-cache"; /usr/bin/mv "$work/models/.pc" "$work/models/.prompt-cache"; /usr/bin/chmod 755 "$work/models/.prompt-cache"
"$selftest" > "$work/out" 2>&1 || true; expect '^WARN prompt-cache: .* has mode 755'; /usr/bin/chmod 700 "$work/models/.prompt-cache"
rm "$work/configs/prompt-cache"; /usr/bin/mv "$work/models/.prompt-cache" "$work/models/.pc"
"$selftest" > "$work/out" 2>&1 || true; expect '^WARN prompt-cache: .* is missing'; /usr/bin/mv "$work/models/.pc" "$work/models/.prompt-cache"
# Logs (#107): auditd with halOS's watches, the journal's size and room on /var/log.
expect '^PASS audit: auditd keeps .* 2 rules loaded and locked'
expect '^PASS halogen-autostart:'
expect '^INFO logs: journal 1.2G, at most 4 GB'
FAKE_AUDIT=fedora "$selftest" > "$work/out" 2>&1 || true; expect "^WARN audit: .*Fedora's rule"
FAKE_AUDIT=few "$selftest" > "$work/out" 2>&1 || true; expect "^WARN audit: .*aren't loaded: /usr/bin/env \\("
FAKE_AUDIT_ENABLED=0 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN audit: .*switched off in the kernel'
FAKE_AUDIT_ENABLED=1 "$selftest" > "$work/out" 2>&1 || true; expect "^WARN audit: .*aren't locked"
FAKE_AUDIT_LOST=7 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN audit: the kernel dropped 7 audit records since boot'
FAKE_AUDIT=exclude "$selftest" > "$work/out" 2>&1 || true; expect '^WARN audit: a rule keeps some kinds of record out'
FAKE_AUDIT=wide "$selftest" > "$work/out" 2>&1 || true; expect "^WARN audit: more than Halogen's own"
FAKE_AUDIT=noexempt "$selftest" > "$work/out" 2>&1 || true; expect "^WARN audit: .*leaves Halogen's own processes out"
# Halogen's service manager without Halogen's own login uid: the exemption wouldn't match it.
echo 4294967295 > "$work/proc/4711/loginuid"
FAKE_MGR_PID=4711 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN audit: .*login uid 4294967295, not 970'
echo 970 > "$work/proc/4711/loginuid"
FAKE_MGR_PID=4711 "$selftest" > "$work/out" 2>&1 || true; expect '^PASS audit:'
mkdir -p "$work/home/.config/systemd/user"; : > "$work/home/.config/systemd/user/evil.service"
"$selftest" > "$work/out" 2>&1 || true; expect '^WARN halogen-autostart: .*evil.service'; rm -r "$work/home/.config/systemd"
mkdir -p "$work/run-user/containers/systemd/halogen.container.d"; : > "$work/run-user/containers/systemd/halogen.container.d/15-prompt-cache.conf"
"$selftest" > "$work/out" 2>&1 || true; expect '^WARN halogen-autostart: .*run-user/containers/systemd/halogen.container.d/15-prompt-cache.conf'; rm -r "$work/run-user/containers"
mkdir -p "$work/run-user/systemd/user.control"; : > "$work/run-user/systemd/user.control/x.conf"
"$selftest" > "$work/out" 2>&1 || true; expect '^WARN halogen-autostart: .*run-user/systemd/user.control/x.conf'; rm -r "$work/run-user/systemd"
# The audit rules and Halogen's container definition compared with the image's copies.
expect '^SKIP config-files:'
for d in etc usretc; do mkdir -p "$work/$d/audit/rules.d" "$work/$d/containers/systemd/users/970/halogen.container.d"
  echo rules > "$work/$d/audit/rules.d/50-halos.rules"; echo unit > "$work/$d/containers/systemd/users/970/halogen.container"; done
printf '%s\n' '# Written by sudo halogenctl records on; removed by records off.' '[Container]' 'Volume=/srv/logs/halogen:/records:noexec,nosuid,nodev' \
  > "$work/etc/containers/systemd/users/970/halogen.container.d/20-records.conf"
"$selftest" > "$work/out" 2>&1 || true; expect '^PASS config-files:'
echo Privileged > "$work/etc/containers/systemd/users/970/halogen.container"
"$selftest" > "$work/out" 2>&1 || true; expect '^WARN config-files: changed .*/etc/containers/systemd/users/970/halogen.container '
echo unit > "$work/etc/containers/systemd/users/970/halogen.container"; : > "$work/etc/audit/rules.d/99-off.rules"
"$selftest" > "$work/out" 2>&1 || true; expect "^WARN config-files: files halOS didn't put there .*99-off.rules"
/usr/bin/rm "$work/etc/audit/rules.d/99-off.rules"; echo 'Volume=/:/host' >> "$work/etc/containers/systemd/users/970/halogen.container.d/20-records.conf"
"$selftest" > "$work/out" 2>&1 || true; expect "^WARN config-files: .*20-records.conf \\(not what halogenctl records on writes now"
# The drop-in cache off writes is excused with exactly its content, and flagged with any other.
mkdir -p "$work/etc/containers/systemd/users/halogen.container.d"
printf '%s\n' '# Written by sudo halogenctl cache off; removed by cache on.' '[Container]' 'Volume=/srv/models/.prompt-cache:/models/.prompt-cache:ro,noexec,nosuid,nodev' \
  > "$work/etc/containers/systemd/users/halogen.container.d/15-prompt-cache.conf"
echo off > "$work/configs/prompt-cache"
/usr/bin/rm -f "$work/etc/containers/systemd/users/970/halogen.container.d/20-records.conf"
"$selftest" > "$work/out" 2>&1 || true; expect '^PASS config-files:'
echo 'Volume=/srv/configs:/models/.prompt-cache' > "$work/etc/containers/systemd/users/halogen.container.d/15-prompt-cache.conf"
"$selftest" > "$work/out" 2>&1 || true; expect "^WARN config-files: .*15-prompt-cache.conf \\(not what halogenctl cache off writes\\)"
/usr/bin/rm "$work/etc/containers/systemd/users/halogen.container.d/15-prompt-cache.conf" "$work/configs/prompt-cache"
# A file is excused by its full path only: the same name elsewhere, and auditd plugins, are flagged.
/usr/bin/rm -f "$work/etc/containers/systemd/users/970/halogen.container.d/20-records.conf"
mkdir -p "$work/etc/containers/systemd/users/halogen.container.d" "$work/etc/audit/plugins.d"
echo 'Volume=/:/host' > "$work/etc/containers/systemd/users/halogen.container.d/20-records.conf"
"$selftest" > "$work/out" 2>&1 || true; expect "^WARN config-files: files halOS didn't put there .*/etc/containers/systemd/users/halogen.container.d/20-records.conf"
/usr/bin/rm "$work/etc/containers/systemd/users/halogen.container.d/20-records.conf"; echo 'path = /tmp/x' > "$work/etc/audit/plugins.d/x.conf"
"$selftest" > "$work/out" 2>&1 || true; expect "^WARN config-files: files halOS didn't put there .*/etc/audit/plugins.d/x.conf"
rm -r "$work/etc/audit" "$work/usretc/audit" "$work/etc/containers/systemd" "$work/usretc/containers/systemd"
HALOS_AUDIT_MIN_FREE_MB=99999999 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN audit: only [0-9]+ MB free'
HALOS_LOG_MIN_FREE_MB=999999999 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN logs: only'
"$selftest" > "$work/out" 2>&1 || true
expect '^PASS scratch: '
FAKE_VARTMP=tmpfs "$selftest" > "$work/out" 2>&1 || true; expect '^FAIL scratch: .*in memory'
FAKE_STATE=inactive "$selftest" > "$work/out" 2>&1 || true; refuse '^(PASS|FAIL|WARN) scratch:'
# Request records on (#107): Halogen's own counts from /health, or a warning when it has none.
: > "$work/20-records.conf"
FAKE_HEALTH='{"request_records":{"written":3,"dropped_cap":0}}' "$selftest" > "$work/out" 2>&1 || true
expect '^PASS records: on, .* Halogen reports \{"written":3,"dropped_cap":0\}'
"$selftest" > "$work/out" 2>&1 || true; expect '^WARN records: on, but Halogen.s /health'
FAKE_UNIT='ExecStart=podman run x' FAKE_HEALTH='{"request_records":{"written":3}}' "$selftest" > "$work/out" 2>&1 || true
expect "^WARN records: on, but Halogen's service doesn't mount"
rm "$work/20-records.conf"
# Off, but Halogen still records (an off cut short before the restart).
FAKE_HEALTH='{"request_records":{"written":3}}' "$selftest" > "$work/out" 2>&1 || true; expect '^WARN records: off, but Halogen still keeps records'
ok "request records: off, on with Halogen's counts, and a mount or state that doesn't match"
FAKE_DASH=disabled "$selftest" > "$work/out" 2>&1 || true; expect '^INFO dashboard: off; .*halosctl dashboard on'
FAKE_DASH_CODE=000 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN dashboard: .*journalctl -u halos-dashboard'
refuse '^(PASS|WARN) dashboard-(filter|nodump)'
for ipin in '' 0 '[not set]' 18446744073709551615; do
  FAKE_DASH_IPIN="$ipin" "$selftest" > "$work/out" 2>&1 || true; expect '^WARN dashboard-filter: .*from anywhere'
done
FAKE_DASH_DENY='' "$selftest" > "$work/out" 2>&1 || true; expect '^WARN dashboard-filter: .*from anywhere'
FAKE_DASH_DUMP_UID=61234 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN dashboard-nodump: .*dumpable.*restart halos-dashboard.*systemctl cat halos-dashboard'
FAKE_DASH_PID=0 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN dashboard-nodump:'
ok "the selftest checks the dashboard's address filter is on and that it isn't dumpable"
FAKE_PROXY=failed "$selftest" > "$work/out" 2>&1 || true; expect '^FAIL proxy: .*nothing answers on 8731 or 8732'
ok "the selftest fails when Caddy (halos-proxy) isn't running"
"$selftest" > "$work/out" 2>&1 || true; expect '^INFO https: off'
FAKE_HTTPS=self-signed "$selftest" > "$work/out" 2>&1 || true; expect '^PASS https: on, self-signed; authority.s fingerprint AB:CD:EF'
refuse 'https-names'; expect '^PASS dashboard:'; grep -q 'curl .*-k .*https://127.0.0.1:8732/healthz' "$work/curl.log" || { echo "the dashboard check didn't use https" >&2; exit 1; }
FAKE_HTTPS=self-signed FAKE_CA=none "$selftest" > "$work/out" 2>&1 || true; expect '^WARN https: .*hasn.t made its authority'
FAKE_HTTPS=self-signed FAKE_UNCOVERED=192.168.1.20 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN https-names: not covered by the certificate yet: 192.168.1.20'
FAKE_HTTPS=custom "$selftest" > "$work/out" 2>&1 || true; expect '^PASS https: on, with your certificate for CN=box.example'
FAKE_HTTPS=custom FAKE_EXPIRES=soon "$selftest" > "$work/out" 2>&1 || true; expect '^WARN https: your certificate .* within 14 days'
FAKE_HTTPS=custom FAKE_EXPIRES=ended "$selftest" > "$work/out" 2>&1 || true; expect '^FAIL https: your certificate .* ended'
FAKE_HTTPS=invalid "$selftest" > "$work/out" 2>&1 || true; expect '^FAIL https: .*isn.t off, self-signed, custom or letsencrypt'
# Let's Encrypt: checked by name, against the system's trust store (no -k, no --cacert).
: > "$work/curl.log"
FAKE_HTTPS=letsencrypt "$selftest" > "$work/out" 2>&1 || true; expect '^PASS https: on, Let.s Encrypt for halos.example.com \(DNS: cloudflare\)'
grep -q -- '--resolve halos.example.com:8731:127.0.0.1 .*https://halos.example.com:8731/health' "$work/curl.log" || { echo "the Let's Encrypt check didn't ask by name" >&2; exit 1; }
if grep 'https://halos.example.com:8731/health' "$work/curl.log" | grep -q -e ' -k ' -e cacert; then echo "the Let's Encrypt check didn't use the system's trust store" >&2; exit 1; fi
FAKE_HTTPS=letsencrypt FAKE_STAGING=yes "$selftest" > "$work/out" 2>&1 || true; expect '^WARN https: .*staging'
FAKE_HTTPS=letsencrypt FAKE_UNTIL=none "$selftest" > "$work/out" 2>&1 || true; expect '^FAIL https: .*serves no certificate'
FAKE_HTTPS=letsencrypt FAKE_EXPIRES=soon "$selftest" > "$work/out" 2>&1 || true; expect '^WARN https: .*renewing is failing'
FAKE_HTTPS=letsencrypt FAKE_EXPIRES=ended "$selftest" > "$work/out" 2>&1 || true; expect '^FAIL https: .*renewing failed'
ok "the selftest names the HTTPS mode, checks Caddy answers in it, and warns of a missing authority, an uncovered address or an ending certificate"
"$selftest" > "$work/out" 2>&1 || true
expect '^INFO weights: downloaded from weights commit 8ef7ad828f7f'
if ! { grep -q "runuser -u halogen -- cat $work/configs/api-key" "$work/runuser.log" &&
       grep -q "runuser -u halogen -- head -n 1 $work/models/.cache" "$work/runuser.log"; }; then
  echo "the API key or weights record was read as root" >&2; exit 1
fi
ok "a healthy NPU machine passes every check, reading the halogen user's files as halogen"

refuse 'SECRET-KEY-MARKER|SECRET-TOKEN-MARKER'
if grep -q 'SECRET-KEY-MARKER' "$work/curl.log"; then echo "the API key was on a command line" >&2; exit 1; fi
ok "the API key and HF token never appear in the report or on a command line"

FAKE_SIG=insecure "$selftest" > "$work/out" 2>&1 || true
expect "^WARN image-signatures: updates aren't checked.*halosctl upgrade"
FAKE_FOLLOWS=ghcr.io/someone/halos-flash:stable "$selftest" > "$work/out" 2>&1 || true
expect "^WARN image-signatures: this machine follows an image that isn't halOS's"
echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$work/policy.json"
HALOS_POLICY="$work/policy.json" "$selftest" > "$work/out" 2>&1 || true
expect '^WARN image-signatures:.*/usr/etc/containers/policy.json'
echo '# changed' >> "$work/etc/pki/containers/halos-flash.pub"
"$selftest" > "$work/out" 2>&1 || true
expect '^WARN signature-files: changed .*/etc/pki/containers/halos-flash.pub'
/usr/bin/cp "$work/usretc/pki/containers/halos-flash.pub" "$work/etc/pki/containers/"; echo '{}' > "$work/root-policy.json"
"$selftest" > "$work/out" 2>&1 || true
expect '^WARN signature-files: .*root-policy.json replaces'; rm "$work/root-policy.json"
HALOS_USR_ETC="$work/none" "$selftest" > "$work/out" 2>&1 || true; expect '^SKIP signature-files:'
FAKE_VERIFY=124 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN ssh-unlock: reading the EFI partition took too long'
ok "an install that doesn't check signatures yet, follows another image, has a changed policy, key or registry file, or a root policy is a warning"
FAKE_SSHU=off "$selftest" > "$work/out" 2>&1 || true
expect '^INFO ssh-unlock: not set up.*halosctl ssh-unlock on'; refuse '^(WARN|FAIL) ssh-unlock'
FAKE_SSHU='ssh-unlock: no EFI system partition found' "$selftest" > "$work/out" 2>&1 || true
expect '^WARN ssh-unlock:.*no EFI system partition'
FAKE_VERIFY=1 "$selftest" > "$work/out" 2>&1 || true; expect '^WARN ssh-unlock:.*differ from the record'
FAKE_VERIFY=2 "$selftest" > "$work/out" 2>&1 || true; expect '^INFO ssh-unlock:.*ssh-unlock record'
ok "unlocking over SSH is shown when set up, offered when not, and a warning when unreadable"

rm "$fake/mokutil" "$fake/amd-smi"
"$selftest" > "$work/out" 2>&1 || true
expect '^SKIP secure-boot:'; expect '^Summary:'
ok "a missing tool is skipped, and the rest still runs"

echo "public" > "$work/services"
cat > "$work/kernel.log" <<'L'
audit: type=1400 audit(1.2:3): avc:  denied  { map } for  pid=9 comm="halogen" path="/dev/kfd" dev="devtmpfs" scontext=system_u:system_r:container_t:s0 tcontext=system_u:object_r:kfd_device_t:s0 tclass=chr_file
audit: type=1400 audit(1.2:4): avc:  denied  { map } for  pid=9 comm="halogen" path="/dev/kfd" dev="devtmpfs" scontext=system_u:system_r:container_t:s0 tcontext=system_u:object_r:kfd_device_t:s0 tclass=chr_file
audit: type=1400 audit(1.2:5): avc:  denied  { recv } for  saddr=192.168.1.50 src=51234 daddr=192.168.1.10 dest=8731 netif=enp1s0 scontext=system_u:system_r:container_t:s0 tcontext=system_u:object_r:unlabeled_t:s0 tclass=packet
L
if "$selftest" > "$work/out" 2>&1; then echo "failures still exited 0" >&2; exit 1; fi
expect '^FAIL firewall:'; expect '^FAIL selinux-denials: 2 different'; expect 'kfd_device_t'; expect 'tclass=packet'
refuse '192\.168|saddr|path=|pid='
ok "a closed port and SELinux denials fail, each denial once, with no paths or addresses"
echo "halogen" > "$work/services"
# bootc's own SELinux check, as freyja logs it (both transports), is not a denial to report.
cat > "$work/kernel.log" <<'L'
AVC avc:  denied  { mac_admin } for  pid=7684 comm="chcon" capability=33  scontext=system_u:system_r:unconfined_service_t:s0 tcontext=system_u:system_r:unconfined_service_t:s0 tclass=capability2 permissive=0
SELINUX_ERR op=setxattr invalid_context="system_u:object_r:invalid_bootcinstall_testlabel_t:s0"
SYSCALL arch=c000003e syscall=188 success=no exit=-22 comm="chcon" exe="/usr/bin/chcon"
audit: type=1400 audit(1794150732.406:355): avc:  denied  { mac_admin } for  pid=7684 comm="chcon" capability=33  scontext=system_u:system_r:unconfined_service_t:s0 tcontext=system_u:system_r:unconfined_service_t:s0 tclass=capability2 permissive=0
audit: type=1401 audit(1794150732.406:355): op=setxattr invalid_context="system_u:object_r:invalid_bootcinstall_testlabel_t:s0"
L
"$selftest" > "$work/out" 2>&1 || { cat "$work/out" >&2; echo "bootc's SELinux check failed the selftest" >&2; exit 1; }
expect '^PASS selinux-denials'
# The same denial with any other label, or none, still counts.
cat > "$work/kernel.log" <<'L'
AVC avc:  denied  { mac_admin } for  pid=7684 comm="chcon" capability=33  scontext=system_u:system_r:unconfined_service_t:s0 tcontext=system_u:system_r:unconfined_service_t:s0 tclass=capability2 permissive=0
SELINUX_ERR op=setxattr invalid_context="system_u:object_r:something_else_t:s0"
SYSCALL arch=c000003e syscall=188 success=no exit=-22 comm="chcon" exe="/usr/bin/chcon"
PROCTITLE proctitle=x
audit: type=1400 audit(1.2:9): avc:  denied  { mac_admin } for  pid=9 comm="chcon" capability=33  scontext=system_u:system_r:unconfined_service_t:s0 tcontext=system_u:system_r:unconfined_service_t:s0 tclass=capability2 permissive=0
L
if "$selftest" > "$work/out" 2>&1; then echo "a chcon denial without bootc's label passed" >&2; exit 1; fi
expect '^FAIL selinux-denials: 1 different'
# Another chcon denial is still reported when bootc's check follows it, right away or later on.
real='AVC avc:  denied  { mac_admin } for  pid=5 comm="chcon" capability=33  scontext=unconfined_u:unconfined_r:unconfined_t:s0 tcontext=unconfined_u:unconfined_r:unconfined_t:s0 tclass=capability2 permissive=0'
probe='AVC avc:  denied  { mac_admin } for  pid=7684 comm="chcon" capability=33  scontext=system_u:system_r:unconfined_service_t:s0 tcontext=system_u:system_r:unconfined_service_t:s0 tclass=capability2 permissive=0'
err='SELINUX_ERR op=setxattr invalid_context="system_u:object_r:invalid_bootcinstall_testlabel_t:s0"'
printf '%s\n' "$real" 'SYSCALL x' "$probe" "$err" > "$work/kernel.log"
if "$selftest" > "$work/out" 2>&1; then echo "a chcon denial right before bootc's check was hidden" >&2; exit 1; fi
expect '^FAIL selinux-denials: 1 different'; expect 'unconfined_t'
# Past 4 records it is reported, even when a second copy of bootc's error line (the kernel's) follows.
printf '%s\n' "$real" 'SYSCALL x' 'PROCTITLE x' 'BPF x' 'BPF y' 'BPF z' "$probe" "$err" "audit: type=1401 audit(1.2:9): $err" > "$work/kernel.log"
if "$selftest" > "$work/out" 2>&1; then echo "a chcon denial before bootc's check was hidden" >&2; exit 1; fi
expect '^FAIL selinux-denials: 1 different'; expect 'unconfined_t'
ok "bootc's own SELinux check is not reported, other chcon denials are"
rm "$work/kernel.log"

mkdir -p "$work/models/npu/0.18.23"
echo 'ath11k_pci: Direct firmware load for ath11k/WCN6855 failed with error -2' > "$work/kernel.log"
"$selftest" > "$work/out" 2>&1 || true
expect '^WARN npu-folder:.*0\.18\.23'; expect '^WARN firmware:'; expect '^ +ath11k/WCN6855$'
ok "leftover version folders and missing firmware are reported"
rm -r "$work/models/npu/0.18.23" "$work/kernel.log"

printf 'HALOGEN_VARIANT=no-npu\n' > "$work/release.env"
echo 'BOOT_IMAGE=x amdgpu.gttsize=126976 ttm.pages_limit=32505856 amd_iommu=off' > "$work/cmdline"
rm "$work/dev/accel/accel0"
"$selftest" > "$work/out" 2>&1 || { cat "$work/out" >&2; exit 1; }
expect '^PASS kernel-iommu:.*amd_iommu=off'
refuse 'npu-device|fabric-clock|folder-LFM'
ok "the no-NPU edition expects amd_iommu=off and skips the NPU checks"

f mokutil 'echo "SecureBoot ${FAKE_SB:-enabled}"'
f amd-smi 'if [ -n "${FAKE_NOGPU:-}" ]; then echo "ERROR:root:Unable to detect any GPU devices"; exit 255; fi; echo "GPU: 0"'
printf 'HALOGEN_VARIANT=npu\n' > "$work/release.env"
echo 'BOOT_IMAGE=x ttm.pages_limit=32505856 iommu=pt amd_iommu=off' > "$work/cmdline"
printf 'MemTotal: 60000000 kB\n' > "$work/meminfo"
echo 'halogen-fabric-clock.service loaded failed failed Hold the clock' > "$work/failed"
if FAKE_SB=disabled FAKE_SELINUX=Permissive FAKE_STATE=inactive FAKE_NOGPU=1 FAKE_NOIPV6=1 FAKE_FIREWALL=not-running \
    "$selftest" > "$work/out" 2>&1; then echo "an unhealthy machine passed" >&2; exit 1; fi
for line in 'WARN secure-boot' 'FAIL kernel-amdgpu.gttsize' 'FAIL kernel-iommu-off' 'FAIL memory' \
  'FAIL failed-units:.*halogen-fabric-clock' 'WARN selinux' 'FAIL firewall: firewalld is not running' \
  'WARN amd-smi' 'FAIL npu-device' 'FAIL prepare' 'FAIL server' 'WARN api-ipv6'; do
  expect "^$line"
done
ok "an unhealthy machine gets a FAIL or WARN for each problem"

rm "$work/failed"
for wait in FAKE_JOB=42 FAKE_FETCH=activating; do
  env FAKE_STATE=inactive "$wait" "$selftest" > "$work/out" 2>&1 || true
  expect '^WARN server:.*waiting.*fetch-logs'; refuse '^FAIL (server|api-)'
done
FAKE_STATE=inactive FAKE_JOB='Failed to connect to bus' "$selftest" > "$work/out" 2>&1 || true
expect '^FAIL server:.*halogenctl start'
FAKE_STATE=inactive FAKE_FETCH=failed "$selftest" > "$work/out" 2>&1 || true
expect '^FAIL server:.*download and check step failed.*fetch-logs'
FAKE_STATE=deactivating "$selftest" > "$work/out" 2>&1 || true
expect '^WARN server:.*deactivating'
ok "Halogen waiting for the fetch, or stopping, is a warning; a failed fetch or a stopped Halogen says what to do"

# The Flash checkpoint: named when it is your own, with the way back when Halogen isn't running.
"$selftest" > "$work/out" 2>&1 || true
expect '^INFO flash: serving the official Flash checkpoint'
mkdir -p "$work/models/flash/mine"; printf 'repo=someone/Mine-HGN\n' > "$work/models/flash/mine/halos.info"
echo mine > "$work/configs/flash-checkpoint"
export FAKE_RENDER=HALOGEN_CHECKPOINT=/models/flash/mine/model.hgn
"$selftest" > "$work/out" 2>&1 || true
expect '^INFO flash: serving your own Flash checkpoint mine \(someone/Mine-HGN\)'
FAKE_STATE=failed "$selftest" > "$work/out" 2>&1 || true
expect '^WARN flash: .*mine.*sudo halogenctl flash use official'
FAKE_RENDER=$'halogen-config: mine has not passed the check; using the official one\nHALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn' "$selftest" > "$work/out" 2>&1 || true
expect '^WARN flash: you chose your own Flash checkpoint mine, but Halogen serves the official one: mine has not passed'
grep -q "runuser -u halogen -- head -n 1 $work/configs/flash-checkpoint" "$work/runuser.log" || { echo "the choice was read as root" >&2; exit 1; }
rm -r "$work/models/flash" "$work/configs/flash-checkpoint"
"$selftest" > "$work/out" 2>&1 || true
expect '^FAIL folder-flash: '
ok "the Flash folder is checked, and the served checkpoint is named, with the way back when Halogen is down"

# A new install waiting for first-boot setup says so, instead of "waiting for the download".
mkdir -p "$work/state"; : > "$work/state/setup-pending"
FAKE_STATE=inactive HALOGEN_STATE_DIR="$work/state" "$selftest" > "$work/out" 2>&1 || true
expect '^WARN server: Halogen waits for first-boot setup: sudo halosctl setup'
ok "a new install waiting for setup is named in the selftest"

# The firmware power profile: skipped without one, a warning when it differs from the choice.
"$selftest" > "$work/out" 2>&1 || true; expect '^SKIP power-profile'
mkdir -p "$work/sys/firmware/acpi"; echo balanced > "$work/sys/firmware/acpi/platform_profile"
export HALOS_PROFILE_FILE="$work/platform-profile"
"$selftest" > "$work/out" 2>&1 || true; expect '^WARN power-profile: .*balanced, not performance'
echo balanced > "$HALOS_PROFILE_FILE"
"$selftest" > "$work/out" 2>&1 || true; expect '^PASS power-profile'
ok "the power profile is checked against the choice, and skipped where the firmware has none"
