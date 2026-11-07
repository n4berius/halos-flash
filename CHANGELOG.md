# Changelog

What changed in each halOS release, newest version first, in plain language. Dates are UTC. The numbers link to the
pull requests with the details. Halogen's own changes are in its
[changelog](https://github.com/peonist-ai/halogen-flash-server/blob/main/CHANGELOG.md).

Each pull request adds its lines under **Unreleased**. After a release, they move under its
version. A beta, RC or stable release that promotes an earlier one lists only what was
promoted.

## Unreleased

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
