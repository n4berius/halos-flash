# Changelog

What changed in each halOS release, newest version first, in plain language. Dates are UTC. The numbers link to the
pull requests with the details. Halogen's own changes are in its
[changelog](https://github.com/peonist-ai/halogen-flash-server/blob/main/CHANGELOG.md).

Each pull request adds its lines under **Unreleased**. After a release, they move under its
version. A beta, RC or stable release that promotes an earlier one lists only what was
promoted.

## Unreleased

- Firmware updates: `sudo fwupdmgr update` can now also update the Secure Boot revocation list
  (dbx), instead of saying "UEFI ESP partition not detected". On a machine that unlocks its disk
  with the TPM, such an update asks for the disk passphrase at the next boot; then run
  `sudo halogen-enroll-tpm` once. (#106)
- The dashboard moved from port 8790 to **8732**, next to the API on 8731: `http://<machine>:8732`.
  The firewall follows by itself on upgrade; only a bookmark changes. (#103)
- [Caddy](https://caddyserver.com) now answers on ports 8731 (API) and 8732 (dashboard) and passes
  requests on to Halogen and the dashboard, which listen on the machine only: the first step to
  HTTPS (#102). Nothing changes for apps: same address, same key, replies still stream. While
  Halogen starts, the API answers with a short note instead of refusing the connection. If you let
  other networks see the dashboard with `systemctl edit halos-dashboard` (`IPAddressAllow=`), put
  those ranges in `/etc/halos/proxy.env` as `HALOS_DASHBOARD_ALLOW=` instead: the old setting no
  longer lets them in. (#104)

## v0.20.1-alpha.2 (2026-11-11)

- The dashboard can no longer leak the API key in a crash report, may listen only on its own port,
  and the selftest checks that its private-networks rule is really on. (#101)

## v0.20.1-alpha.1 (2026-11-10)

- A live dashboard of Halogen at `http://<machine>:8790`: whether it is up, speed, busy slots,
  queue, KV pool, prompt cache and NPU, with charts up to 30 days. It is
  [halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) by Quaternion, built in
  unchanged; about 12 MB of memory and 430 MB of disk once it holds 30 days. It is on by default,
  also after upgrading, with no login: anyone on your network can view it, nobody can change
  anything. `sudo halosctl dashboard off` stops it, `on` brings it back. (#98)
- The dashboard is locked down further: it answers only this machine and private networks (home,
  office, Tailscale), uses at most one CPU core, writes no core files, and its web page is built
  without running packages' install scripts. (#99)
- Halogen 0.20.1: follow-up turns start faster (the end of each reply is cached, on by default,
  about 0.4 GiB more RAM at 4 slots), a turn that ended inside its reasoning now gets its answer,
  and a routine `kv pool` line no longer shows red in the logs. The Flash checkpoints and
  the NPU model files are unchanged, so nothing new downloads. The setting
  `HALOGEN_FORK_AUTO_KEEPS` is gone (Halogen no longer reads it) and `HALOGEN_FORK_MAP=auto` is
  ignored with one line at start; a `halogen.env` that still has either keeps working. (#95)
- Hardening from the security reviews of #91, #93 and #94 (#96):
  - `halosctl version` says whether updates are signature-checked, and the SSH login message warns
    when they aren't; the selftest's new `signature-files` line warns if the policy, registry
    setting or halOS's key differ from the image's copies, or root has a policy of its own.
  - `halosctl upgrade` doesn't reboot by itself when the name it follows points to an older build,
    and switching refuses a changed halOS public key file.
  - SSH unlock keeps the keys' and early-boot host key's fingerprints on the encrypted disk; the
    selftest and `halosctl ssh-unlock` warn when the EFI partition's copies change, and setting
    them up again then makes a new host key.
  - `sudo halosctl ssh-passwords off` allows SSH logins with keys only, once your account has a
    key; setup offers it.
- `sudo halogenctl flash convert <repo>` converts full-precision (BF16 safetensors) Qwen3.8 Flash
  Next weights into your own Flash checkpoint on the machine, with bf16-to-hgn (built into the
  image, CPU only). It checks the model before the 360 GB download, runs as its own service (many
  hours, likely a day or more), checks the result twice and deletes the downloaded weights
  (`--keep-source` keeps them). `convert-logs` follows it, `convert-stop` stops it. (#97)
- The guided installer asks how an encrypted disk unlocks: TPM and SSH (recommended), TPM only,
  SSH only, or the passphrase at the keyboard. For SSH it takes your public keys from GitHub,
  GitLab or Codeberg, or a pasted key, and can let the same keys log the admin user in. First-boot
  setup then defaults to that choice. (#13, #94)
- Unlock the disk over SSH at boot (#13): when the TPM can't unlock it, type the passphrase from
  another computer with `ssh root@<machine>`. Turn it on with `sudo halosctl ssh-unlock on
  --github <user>` (or `--gitlab`, `--codeberg`, `--key`), or in `sudo halosctl setup`. The
  selftest shows it as `ssh-unlock`. (#93)
- Machines take only images signed with halOS's key (#46). New installs check from the start;
  older ones turn the check on with their next `sudo halosctl upgrade` after this release, which
  says so and asks. Releases before `0.19.1-alpha.3` aren't signed, so `rollback --to` can't reach
  them. Images from other registries (Halogen's own, your own podman containers) are taken as
  before. The selftest reports it as `image-signatures`. (#91)
- Building images: the signing tool is downloaded before anything is pushed, and its download
  retries for up to five minutes. A GitHub outage during the weekly stable refresh had left the
  `0.20.0` tag pointing to an unsigned rebuild. (#90)
- `flash pull` and `flash verify` add the official tokenizer's vocabulary to a checkpoint whose
  `tokenizer/` folder has no `tokenizer.json` (Signal-3.8-Flash-Next-HGN-v2 ships only its chat
  template and settings), keeping its own chat template. Halogen couldn't start on such a checkpoint
  and restarted every 30 seconds; a checkpoint still without one, or with a vocabulary of its own,
  now fails verify, so `flash use` refuses it. For one pulled before: `sudo halogenctl flash verify
  <name>`, then `sudo halogenctl restart` if Halogen serves it. (#88)

## v0.20.0 (2026-11-09)

The first stable release on Halogen 0.20.0, promoted from `v0.20.0-rc.2`: everything since
`v0.19.0-beta.1`, listed under the releases below. freyja was also reinstalled with
the guided installer, and passed restarts, tab completion and a `model pull` of OvisOCR3.

## v0.20.0-rc.2 (2026-11-08)

Built from main, so it carries one change beside the beta's notes (#86):

- `halogenctl model list` shows an NPU model as in use when one of your own checkpoints runs on it
  ("yes, for OvisOCR3") or the agent guard adds it, where it used to say "no". (#87)

## v0.20.0-rc.1 (2026-11-08)

Promoted from `v0.20.0-beta.1`, with no change.

## v0.20.0-beta.1 (2026-11-08)

Promoted from `v0.20.0-alpha.3`: the first beta on Halogen 0.20.0, with everything since
`v0.19.0-beta.1`. On freyja it passed the selftest, the power profile at `performance` and the
fabric clock held in `bench`, and earlier `bench`, `flash check` and `halosctl npu off`/`on`.

## v0.20.0-alpha.3 (2026-11-08)

No change to what users get: the release notes for alpha.1 (#85). The same code as alpha.2.

## v0.20.0-alpha.2 (2026-11-08)

- The power profile's boot service can now write only the one file it sets, with no special
  rights, as the security review of #83 suggested. Nothing changes in use. (#84)

## v0.20.0-alpha.1 (2026-11-08)

- `halogenctl bench` reported the GPU fabric clock as not held when it was: it now asks the clock
  the way the selftest does. `flash check` prints its numbers rounded, no longer shows a passing
  download hiccup as an error, and gives the time it took on the test machine. (#81)
- **Halogen 0.20.0** ([its changelog](https://github.com/peonist-ai/halogen-flash-server/blob/8242b157ce78fd720f5b3da18d398d2fb8cebce5/CHANGELOG.md)):
  its image moves to ROCm 10.1 (less power while generating, same speed), prompts read a few
  percent faster, and a crash with strict tool calls under load is fixed. New: document parsing on
  the NPU with your own OvisOCR3 (`sudo halogenctl model pull ATH-MaaS/OvisOCR3`; INSTALL.md says
  how to serve it). The Flash checkpoint and every setting stay the same; at temperature 0 replies
  can differ from 0.19.1's in the last bits. (#78)
- `halogenctl selftest` no longer reports a `chcon` SELinux denial: that is bootc checking its own
  rights (it expects the refusal) each time halOS asks it for status. Other denials still fail. (#82)
- **Power profile:** halOS now sets the firmware's power profile to `performance` at every boot,
  where some machines, freyja among them, ship at `balanced`. On freyja that read prompts about 22% faster.
  `sudo halosctl power balanced` (or `low-power`) picks a cooler, quieter one, at once and for
  every boot; `sudo halosctl power` shows it, and the selftest warns when it isn't as chosen. (#83)

## v0.19.1-alpha.6 (2026-11-08)

No change to what users get: the project notes and roadmap were brought up to date (#79).

## v0.19.1-alpha.5 (2026-11-08)

- **Hardening:** programs running as the `halogen` user (Halogen's helpers, and anything that
  might break out of its container) can no longer type into an admin's root terminal or send it
  escape codes. `halogenctl` gives the scripts it runs as `halogen` no access to your terminal,
  and `status`, `selftest`, `api-key` and `model pull` strip control characters from anything the
  `halogen` user could have written. The kernel's terminal-injection call (`TIOCSTI`), already
  off in Fedora's kernel, is kept off by a setting. (#76)
- Images now say which edition they are (NPU or no-NPU) in a label. `halosctl` checks it before
  switching, and reads it to tell the edition of a build a pinned machine has waiting for the next
  boot, where it used to ask you to reboot first. Images from before this change have no label,
  so for those it still asks. (#77)
- Tab completion for `halogenctl`, `halosctl` and `halogen-enroll-tpm`: commands, options,
  channels and LUKS devices. (#75)
- `sudo halogenctl flash check <name>` measures your own Flash checkpoint against the official
  one with Halogen's `ppl`, on the same public text Halogen's docs use: perplexity, how often both
  pick the same next word, and how far apart their predictions are. Halogen stops while it runs
  and starts again afterwards. `flash list` shows the result. (#74)
- `sudo halogenctl bench` measures how fast the server reads prompts and writes answers, with
  Halogen's own benchmark tool, without restarting it. The report lists what the numbers depend
  on (versions, BIOS, kernel settings, power profile, checkpoint, settings) and is saved in
  `/srv/configs/bench/` to compare later runs. `--quick` takes under a minute. It uses the prompt
  cache as your server does, so its prompts can push long cached conversations out once. (#73)
- `sudo halosctl npu off` moves a machine to the no-NPU edition, and `npu on` back, keeping its
  channel (or exact release) and everything in `/srv`. It warns when turning the NPU on for a
  machine that has none, and says plainly what turning the IOMMU off costs. A channel switch or
  `rollback --to` now keeps an edition change that is waiting for the next boot, or, when that
  can't be told (a machine pinned to one release), asks you to reboot first instead of guessing.
  (#72)

## v0.19.1-alpha.4 (2026-11-07)

- A setting written twice in `halogen.env` (easy to do when pasting from the example file) is
  now pointed out: `halogenctl status`, `config` and `options` name it, and Halogen's log says
  which line is used (the last one). Nothing changes in what Halogen receives. (#71)
- Restarting Halogen yourself (`sudo halogenctl restart`, `flash use`, or after a settings
  change) always works now. A few restarts in a row used to hit Halogen's crash-loop guard ("start
  of the service was attempted too often"), which only automatic restarts should count towards.
  (#70)
- **Security fixes from the full audit:**
  - Your own NPU checkpoints are checked offline, with no access to your Hugging Face token,
    before the download step, which no longer reads them itself.
  - `model pull`'s download and check see only that checkpoint's folder, the check read-only.
    `--revision` or `--as` with nothing after it no longer hangs.
  - `model list` prints no folder name that holds terminal control codes.
  - The docs no longer say Halogen serves "offline": it never downloads, but its container can
    reach the network.
  - The download log no longer claims more than the estimate was downloaded when your own
    checkpoints are counted in.
  - The build and release workflows use GitHub's actions pinned to exact commits, so a moved
    version tag can't change what runs beside the signing key. (#69)
- The installer, `halosctl setup` and the docs now say plainly what TPM unlock protects: a disk
  taken out of the machine, not the machine taken whole. INSTALL.md section 8 explains how to
  protect the machine too (BIOS password, USB boot off, a boot menu password). (#68)
- No more serial login prompt restarting every 10 seconds on machines whose first serial port
  doesn't work (freyja logged "failed to get terminal attributes" from boot on). A serial login
  prompt now starts only on a port that answers, and new installs no longer get a serial
  console at all. (#67)
- **Guided installer.** The first boot menu entry asks only for the disk, the machine's name,
  encryption, root and the admin user, on a text screen, then installs by itself. It never
  offers USB drives, and a disk with data on it, or a choice of disks, needs its name typed. Every
  machine gets the same volume names (`halos-root`, `halos-models` and so on). The full graphical
  installer stays as "custom partitioning". (#66)

## v0.19.1-alpha.3 (2026-11-07)

- Images are also signed with halOS's own key, and every image carries its public key at
  `/etc/pki/containers/halos-flash.pub`. A later release makes machines refuse images without
  that signature. (#65)
- This changelog, and [ROADMAP.md](ROADMAP.md): what comes next on the way to a stable release.
  (#62)
- **"API ready" at a glance.** The login screen shows Halogen's state: downloading with a
  percentage, checking, starting, or `ready` with the address. The SSH login message shows the
  same, with the release, channel and any staged update. Logged-in users get a one-time notice
  when Halogen first answers after a boot. (#63)
- **First-boot setup.** `sudo halosctl setup` asks how the disk unlocks (TPM or passphrase), for
  an optional Hugging Face token, and whether to edit the settings. On a new install the first
  download waits for it, up to 30 minutes, so the token and settings count from the start;
  `--skip` starts it at once. Upgraded machines never wait. (#64)

## v0.19.1-alpha.2 (2026-11-06)

- **Your own Flash checkpoint.** `sudo halogenctl flash pull|list|use|verify|remove` runs a
  community or self-trained `.hgn` build of the Flash model in place of the official one, which
  always stays downloaded. A pull fetches only what Halogen loads, at an exact commit, checks
  every file against the repository's hashes and with Halogen's `verify`, and is checked again
  after each Halogen update. See [INSTALL.md](INSTALL.md#your-own-flash-checkpoint). (#60)
- The model download and `model pull` no longer get the NPU device. (#60)

## v0.19.1-alpha.1 (2026-11-06)

- **Halogen 0.19.1.** Its image now carries AMD's XRT, so halOS no longer ships or mounts its own.
  (#58, #59)
- **New Halogen options are easy to find.** `sudo halogenctl options --new` lists the ones your
  `halogen.env` doesn't mention yet. `/srv/configs/halogen.env.example` holds every option and is
  refreshed at each boot. Each release attaches both editions' lists. `halogen.env` itself is never
  changed. (#57)
- **Security hardening** from a full audit:
  - Root never reads or writes in the `halogen` user's folders. (#51)
  - The root boot services are sandboxed.
  - Halogen's checks run without network.
  - Kernel settings that cost nothing are tightened.
  - SSH X11 forwarding is off.
  - The installer builder is pinned. (#52)
  - Halogen's container runs with no capabilities. (#53)
- `sudo halogenctl model list` is readable. (#55)
- Edge is rebuilt weekly, so machines get Fedora fixes in quiet weeks. (#54)

## v0.19.0-beta.1 (2026-11-06)

Promoted from `v0.19.0-alpha.4`. Freyja passed the beta hardware checklist:
- TPM unlock
- `halosctl` switch, upgrade and rollback, each keeping `/srv`
- selftest 30 of 30

## v0.19.0-alpha.5 (2026-11-06)

- Every pushed image is signed with cosign, keyless. Machines don't check it yet. (#50)

## v0.19.0-alpha.4 (2026-11-06)

- No more fstab warning at every boot. `halosctl upgrade` says "Already up to date" instead of
  asking when there is nothing new. (#49)

## v0.19.0-alpha.3 (2026-11-05)

- Releases are cut by picking alpha, beta, rc or stable. The number is worked out, and beta, RC
  and stable promote the newest release one step below. (#48)
- Fixes the failed `v0.19.0-alpha.2` release run. That tag exists, but has no release. (#47)

## v0.19.0-alpha.2 (2026-11-05, tag only)

- **`halosctl`**, one command for the OS: `version`, `switch <channel>`, `upgrade`, `rollback
  [--to]` and `history`. Channels follow newer, more stable releases. (#41)
- Root can never log in over SSH. (#45)
- The selftest treats Halogen waiting at boot as a warning. Adds `wireless-regdb`. (#39)

## v0.19.0-alpha.1 (2026-11-05)

- **Renamed to halOS** (image `ghcr.io/n4berius/halos-flash`). (#37, #38)
- **Halogen 0.19.0.** (#32)
- `sudo halogenctl selftest`: the beta hardware checklist in one command. (#36)
- **NPU models:**
  - one folder for all NPU models
  - `sudo halogenctl model` for your own NPU checkpoints (#29, #35)
- The Flash weights are pinned to a commit. (#34)
- A smaller installer and OS image. (#22)
- A daily check opens a pull request for each new Halogen release. (#28, #30, #31)
- Review agents and CLAUDE.md for development. (#27, #33)

## v0.18.23-alpha.3 (2026-11-05)

- **Install fixes:**
  - single-file installer ISOs
  - download progress at first boot
  - docs from the first hardware install (#17)
- Enrolling the TPM again replaces the old binding. (#21)

## v0.18.23-alpha.2 (2026-11-05)

- **Boot and install fixes:**
  - LUKS boots on real hardware
  - better default partitioning
  - TPM unlock is tested (#12)

## v0.18.23-alpha.1 (2026-11-04)

- First release, with Halogen 0.18.23. (#6, #9, #10, #11)
