# Notes for Claude Code

halOS (formerly halogen-bootc) is a Fedora 45 bootc OS image, plus an Anaconda USB installer, for one job:
running [halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) ("Halogen")
on a dedicated AMD Strix Halo 128 GB server. It configures and deploys Halogen. It never
modifies Halogen itself, which is closed source under Peonist's EULA.

The owner, n4berius, is not a programmer. Explain changes in plain language, keep pull
requests focused, and say what was and wasn't tested. Halogen's
[official docs](https://github.com/peonist-ai/halogen-flash-server/tree/main/docs) are the
authority on its settings and behaviour. Read them instead of guessing, and link to them in
our docs.

Naming: the project is **halOS** in prose and the installer, and `halos-flash` where a name
must be lowercase (the image `ghcr.io/n4berius/halos-flash`, ISO and asset names). Names that
refer to Halogen the server stay: `halogenctl`, the `halogen` user, `/srv/models`, the
`HALOGEN_*` settings. Peonist's trademark policy doesn't allow "halogen" in our product's
name, but allows saying halOS runs Halogen.

## Ground rules

- `main` is protected. Work on a branch and open a PR. Never push to `main`, force-push it,
  or move release tags.
- Never commit secrets. The API key and the HF token live only on the machine, under
  `/srv/configs`.
- Releases are cut by the owner (Actions > Release > Run workflow, picking alpha, beta, rc or
  stable; `scripts/next-tag.sh` numbers it, and beta/rc/stable promote the newest published
  release one step below). Don't create tags or releases yourself.
- If GitHub or a registry refuses an action (403 from the session proxy), stop and tell the
  owner. Don't work around it.
- Run `tests/run.sh` before every push. CI also runs shellcheck, which may not be installed
  locally.

## Layout

| Path | What it is |
|---|---|
| `versions.env` | Every pinned input: Fedora base, Halogen version, digest and source commit, upstream file hashes, weights repo and revision, ISO builder |
| `Containerfile` | The OS image. XRT is not in it: Halogen's image carries its own since 0.19.1 |
| `Containerfile.installer`, `installer/` | The live installer image, Anaconda defaults (storage layout for custom partitioning), branding and boot menu. `installer/guided/`: the guided install's kickstart and `plan-install` (#42) |
| `files/` | Copied into both editions: systemd units, `halosctl`, `halogenctl`, `halogen-enroll-tpm` (bash completion for all three in `usr/share/bash-completion/completions/`; `tests/completion.sh` fails when a tool gains a top-level command, or a `flash`/`model` subcommand, its completion doesn't offer; checkpoint folder names are written by halogen and its containers, so they are never passed to `compgen -W`, which expands `$(...)`: only plain names, matched by hand), `/usr/libexec/halogen/*` (`flash-checkpoint` and `model-pull` download your own checkpoints) |
| `variants/npu`, `variants/no-npu` | Per-edition kernel arguments, Quadlet drop-ins, the allowed-options list and default `halogen.env` |
| `scripts/` | `build.sh`, `build-iso.sh`, `package-iso.sh` (single-file release ISO), `release-info.sh`, `gen-options.py` (options from upstream `FLAGS.md`), `halogen-update.sh` (pins a new Halogen release), `size-report.sh`, `channels.sh` (which channel tags a release moves), `next-tag.sh` (the next release tag), `push-image.sh`, `sign-image.sh` (cosign signing) |
| `CHANGELOG.md`, `ROADMAP.md` | What each release changed (PRs add to Unreleased), and the order of the work ahead |
| `tests/` | `run.sh` (fast checks, no GPU or network), `iso-install.sh` + `vm-login.py` (QEMU install test) |
| `.claude/agents/` | Subagents: `code-reviewer` (QA review before merge) and `security-auditor` (audit, zero-cost hardening ideas). Both only read and report |
| `.github/workflows/` | `build.yml` (image, edge tag; also weekly, Thursday 05:37 UTC), `iso.yml` (ISO + VM install test), `release.yml`, `refresh.yml` (weekly rebuild of stable), `halogen-update.yml` (daily: opens a PR for a new Halogen release) |

## How the running system works

- Halogen runs as the rootless `halogen` user (UID 970) through a Quadlet in
  `/etc/containers/systemd/users/970/`, with linger on. `halogenctl` wraps it, so run it with
  `sudo`. `halogenctl model pull|list|remove` manages your own NPU checkpoints. `halogenctl selftest`
  (`/usr/libexec/halogen/selftest`, root) runs the beta hardware checklist read-only; the VM
  install test runs it too and checks what a VM can pass.
- First boot: `halogen-prepare` (root) creates `/srv/models`, `/srv/configs`, `halogen.env`
  and the API key. `halogen-fetch` (user) pulls the pinned image, downloads models with `hf`
  inside that image, and runs Halogen's `verify`. Then `halogen.service` starts with the models
  read-only and never downloads (its container still has network: "offline" was wrong, audit F). Each restart of `halogen.service` reruns the fetch, which only downloads what's
  missing or changed.
- `halos-status.timer` runs `login-status` (root, sandboxed, writes only under `/run`) every 30 s:
  one line in `/run/issue.d/50-halos.issue` for the console login screen (agetty's `\4` fills
  in the IPv4 address; `agetty --reload` redraws on a change), the same with the hostname plus
  `halosctl version`'s channel/staged/rollback lines (cached 10 min) in `/run/motd.d/50-halos`
  for SSH, and one `wall` per boot when `/health` first answers. It reads as halogen with
  `setpriv` and `systemctl --user` on `/run/user/970`, not `runuser` or `--machine=halogen@.host`:
  both of those open a full PAM login (logind session, lastlog write, journal lines), far too much
  every 30 s. When `/health` answers it asks nothing else. Before setup it says "waiting for setup".
- First-boot setup (#43): `prepare` touches `/var/lib/halogen/setup-pending` only when
  `halogen.env` doesn't exist yet (a new install, never an upgrade). `fetch-models` waits while it
  exists, up to `HALOGEN_SETUP_WAIT_S` (1800 s, counted with `$SECONDS`, not the marker's mtime:
  the wall clock jumps at first boot), then removes it and starts with the defaults. `sudo halosctl
  setup` asks TPM unlock (`halogen-enroll-tpm`), HF token (`halogenctl hf-token`), and editing
  `halogen.env` the sudoedit way (root edits a private copy, written back as halogen; never an
  editor as halogen on root's tty), then removes the marker; `--skip` removes it at once. The VM
  test checks the pending line, then skips. On the serial console, `agetty --reload` can swallow
  output written while the status changes, so the VM test saves such output to a file and prints
  it later.
- Settings: users edit `/srv/configs/halogen.env`. `render-config` keeps only the names in
  `options.allowed`, and `locked.env` wins over it. `halogenctl config` shows the result.
  `halogen.env` is copied once and never changed by halOS. `prepare` rewrites
  `/srv/configs/halogen.env.example` (the edition's template) at every boot, `halogenctl options
  [--new]` lists every option as set, commented or new, and each release attaches both editions'
  templates as `halos-flash-<tag>-<edition>-halogen.env.example`.
- NPU models live in `/srv/models/npu/<model>`, with no version folder. Their files are
  checked against the hashes in the pinned image's `/opt/halogen/npu/models.txt`, so an
  upgrade downloads only what changed. Old `npu/<version>/` folders are moved across by
  `fetch-models`.
- Own NPU checkpoints live in `/srv/models/{decider,LFM,custom}/<name>`, put there by
  `halogenctl model pull` (`model-pull`, which uses Halogen's `halogen-npu probe` to pick the
  folder; each of its containers mounts only that checkpoint's folder, the probe read-only). The
  fetch probes each path in `HALOGEN_NPU_MODELS` first in an offline container (`FETCH_MODE=probe`,
  models read-only, no token) and passes the answers to the download container as `OWN_BASES`,
  which never probes; then it fetches their NPU programs.
  These folders are mounted writable, because Halogen keeps a conversion beside the
  checkpoint only on a writable folder (on a read-only one it converts into /tmp at every start).
- Own Flash checkpoints (#56) live in `/srv/models/flash/<name>/`, put there by `halogenctl flash
  pull` (`flash-checkpoint`). It lists the repo with the image's Python `huggingface_hub` at an
  exact commit, and downloads only the checkpoint `.hgn`, its overlay, the vision tower and
  `tokenizer/`. The lookup table (`qwen38-flash-next-ngram.hgn`) comes only when
  `flash_serve --resident-gib` says the checkpoint doesn't carry one. Then it checks the
  files against HF's hashes (LFS sha256, or the git blob id for small files), runs Halogen's
  `verify` on the `.hgn` files except the table (verify doesn't list the table as a file it
  takes), removes files an older pull left, and records everything in `halos.info`. A table
  identical to the official one is hard-linked, not downloaded. `fetch-models` re-verifies the
  chosen checkpoint when `verified_with` differs from `HALOGEN_VERSION`, and renders with
  `HALOGEN_FLASH_FILE=/dev/null` so the choice never changes what is fetched.
  `status`, `flash list` and the selftest read `render-config --show` to say what is served.
  `flash use` writes `/srv/configs/flash-checkpoint`; `render-config` turns it into
  `HALOGEN_CHECKPOINT` (no longer in `locked.env`), falling back to the official file for
  anything unexpected, and drops `HALOGEN_VISION_TOWER` when the custom folder has no tower. The
  official checkpoint is always kept and fetched (owner decision). `flash check <name>` (#56):
  halogenctl runs `flash-checkpoint check-prepare` (name, verify, corpus) while Halogen still
  serves, arms an EXIT trap (with `set +e`; it stops the named unit `halogen-flash-check` first,
  then starts Halogen only if it was running, before printing, since a dead terminal fails echo),
  stops Halogen (ppl needs the GPU), then `flash-checkpoint check` (that unit, `RuntimeMaxSec=3h`,
  output through a pipe with control characters removed; `--pipe` doesn't stop the unit on
  Ctrl-C, hence the named unit) runs Halogen's `ppl --json` with the official tokenizer on wikitext-2's test split
  (`/srv/models/flash/.check/`, fetched from HF's dataset viewer rows API and checked against the
  sha256 of the text Halogen's docs build from the parquet file, `bbf94c53…`), first `--ref-out`
  for the official checkpoint once per Halogen version, then `--ref --worst 5` for the custom one;
  results go to `halos.info` (`checked_*`) and `check.json`. GGUF conversion is a later step.
- `halosctl power [low-power|balanced|performance]` (#83) saves the firmware's ACPI platform profile in
  `/etc/halos/platform-profile` and sets it at once; `halos-platform-profile.service` (root, oneshot,
  at boot and after resume, skipped without `/sys/firmware/acpi/platform_profile`) runs
  `/usr/libexec/halogen/platform-profile apply`, `performance` when nothing is saved (Halogen's
  troubleshooting.md: about 70 W at balanced against 127 W at performance). Only the three names,
  and only those the firmware lists in `platform_profile_choices`. The image has no
  power-profiles-daemon or tuned to fight it. freyja ships at `balanced`; `performance` read
  prompts about 22% faster (pp2048 1876 against about 1530 tok/s).
- `halogenctl bench [--quick]` (#15, `/usr/libexec/halogen/bench`, as halogen) runs Halogen's own
  `sweep` (`/halogen/tools/halogen-bench.py --json`, an HTTP client) in the pinned image against the
  running server: `--network=host` only, read-only, no mounts, devices or capabilities, the API key
  through the environment. Halogen's `bench`/`sweep` image modes start their own engine, which
  would need Halogen stopped, so they aren't used. Reports (text + JSON, with versions, BIOS, kargs,
  fabric clock, platform profile, checkpoint and settings minus keys) go to `/srv/configs/bench/`.
- `/srv` is `/var/srv` on bootc. The installer makes LVM volumes for `/`, `/var`, `/var/log`,
  `/var/log/audit`, `/var/home`, `/var/srv/configs` and `/var/srv/models`. The guided install
  names them `halos-root`, `-var`, `-log`, `-audit`, `-home`, `-configs`, `-models` (VG `halos`);
  older installs keep Anaconda's `<product>_<hostname>` names (freyja: `halogen_freyja`).
- Updates are manual, since a reboot stops inference. `halosctl` (`files/usr/bin/halosctl`)
  handles the OS: `version`, `switch <channel>`, `upgrade`, `rollback [--to]`, `history`
  (`/var/lib/halos/history`), `npu on|off` (the other edition's tag on the same channel, or the
  same exact release pinned by digest; switch and `rollback --to` take the edition from what boots
  next, so a staged edition change survives; a staged digest's edition is read from the image label
  `io.github.n4berius.halos.edition` (set by `build.sh`), and they refuse when it has none, as
  images built before the label; `switch_to` refuses a tag whose image's label names the other
  edition; NPU presence is read from PCI, 1022:1502/17f0, since
  the no-NPU edition's `amd_iommu=off` hides `/dev/accel`; bootc applies the kargs.d difference,
  to confirm on freyja). `halogenctl` handles the engine and models. Exact release tags
  never move. Channel tags (`alpha`, `beta`, `rc`, `stable`, `edge`) do, and each one points to
  the newest release at least that stable (`scripts/channels.sh`), so a channel never moves
  backwards. The Halogen version tag (such as `0.19.1`) moves with stable releases and weekly rebuilds. The
  image's release name is `HALOS_RELEASE` in `release.env` and its version label (#40).
- Root never works inside halogen's folders: `prepare`, `halogenctl` and `selftest` read and write
  there through `runuser -u halogen` (security audit P1/P2/P7). halogenctl runs halOS's scripts as
  halogen only through `halogen_run` (`systemd-run --pipe` with stdin `/dev/null`, output piped
  through `sed` that drops control characters but tab), so they never hold root's terminal, and
  `dev.tty.legacy_tiocsti = 0` keeps keystroke injection off (Fedora's kernel already ships it
  off). `clean` also filters `status` (halogen's service manager writes its descriptions and
  status lines), and selftest's `say` drops control characters from every message. journalctl
  escapes control characters itself unless given `-a` or `-o cat`, which halogenctl never uses. The two root boot units are
  sandboxed (`ProtectSystem=strict`, no network); verify and the model probe run with no network
  or capabilities; `sysctl.d/60-halos.conf` and `sshd_config.d/00-halos.conf` hold the no-cost
  hardening. The ISO builder is pinned by digest (`IMAGE_BUILDER` in `versions.env`).
- Every pushed image is signed with cosign by `scripts/sign-image.sh` (from main's copy, also when
  promoting old code), twice: keyless (public audit) and with halOS's key (`COSIGN_PRIVATE_KEY`
  and `COSIGN_PASSWORD` in the `signing` environment, open only to `main` and `v*` tags; only a
  job with `environment: signing` and only its step named Sign get them; public half in `files/etc/pki/containers/halos-flash.pub`
  and embedded in the script, `tests/static.sh` checks they match). containers/image can match a
  keyless signer only by email, not GitHub's workflow URI, so machines will check the key. Both
  are checked in the same job, including the classic `.sig` tag. Machines don't enforce it yet:
  the policy (#46 phase 2b) ships once every channel points to a key-signed image.

## Lessons already learned

- The initramfs must be built with `--no-hostonly` and the `crypt systemd-cryptsetup tpm2-tss
  lvm` modules, or LUKS fails at boot on real hardware. The Containerfile checks this.
- The root volume is mounted at `/sysroot`, not `/`.
- The Anaconda `.buildstamp` product name becomes the volume group name of automatic
  partitioning (custom entry only). Keep it short.
- Guided install (#42): the default boot entry has `inst.ks=file:/halos-guided.ks`, a path inside
  the initramfs (`dracut --include` in `Containerfile.installer`). Its `%pre` runs `plan-install`
  on tty8 (`chvt`; ttys 2 to 6 get Anaconda's root shell from logind), which writes `/tmp/halos-plan.ks` (mode 600) for `%include`: storage
  (`ignoredisk`, `reqpart --add-boot`, VG `halos`, fixed LV names), users, hostname, reboot.
  Kickstart values are single-quoted for pykickstart's shlex; `tests/guided.sh` parses them with
  pykickstart when installed. The VM test answers from a volume labelled `HALOS_ANSWERS` (file
  `answers`, read as data, never sourced), used only from the third boot entry
  (`halos.unattended=1`; `tests/grub-pick.py` selects it within grub's 5 s by watching the serial log, where GRUB draws its menu too: OCR was once too slow), so a stick
  left plugged in never starts a wipe; there `lsblk` reports no transport, so fields are
  split on `\x1f`, since `read` merges empty tab-separated ones.
- Anaconda copies the installer's `console=` boot arguments to the installed system, so every
  install from before the serial-getty fix has `console=ttyS0 console=tty0`, and systemd's getty
  generator starts `serial-getty@ttyS0`. On freyja ttyS0 exists but has no working UART, and agetty
  respawned every 10 s with an EIO. `serial-getty@.service.d/10-halos.conf` adds an `ExecCondition` running
  `stty -F /dev/%I` with its output thrown away (a skipped condition isn't restarted; systemd gives
  the condition the tty, so stty's settings line would otherwise print before every login prompt), and only the VM test's boot entry passes
  `console=ttyS0`. The VM test checks ttyS0's getty is active with the check loaded. QEMU's ttyS1 does not fail
  like freyja's ttyS0 (the getty ran there), so the skip itself can only be checked on freyja.
- `halogen.service` has `StartLimitBurst=3` in 900 s against GPU crash loops. halogenctl's
  `start_halogen` runs `reset-failed` first, so a start or restart you ask for (also `flash use`
  and `model pull`'s offer) is never refused; only automatic restarts count.
- `halogen-enroll-tpm` uses PCR 7 and `--wipe-slot=tpm2`, so re-enrolling replaces the old
  binding. Enrolling twice on the same boot is a no-op ("already enrolled").
- In the VM test, `systemd-pcrextend` needs `SYSTEMD_FORCE_MEASURE=1` on non-UKI boots.
- `vm-login.py` types through QEMU `sendkey`. Any new character in a typed command needs a
  key mapping, or it is silently dropped.
- Until 0.19.0 Halogen needed the host's XRT, which halOS took from Debian trixie-backports
  and mounted at three paths. From 0.19.1 its image carries XRT 2.25, so halOS mounts none (a
  host mount must be all three libraries or none). `tests/static.sh` keeps it that way.
- Halogen 0.18.x listened on IPv4 only, so we published `0.0.0.0:8731`. From 0.19.0 it listens
  on IPv6 too, and the port is published dual-stack.
- `HALOGEN_AGENT_GUARD=watch|hold` makes Halogen add `halogen-spotter-0.6b` and `decider-4b`
  at start. The server never downloads, so `fetch-models` adds them to the fetch.
- `hf` is noisy and shows no progress in the journal. `fetch-in-container` filters it, and
  `fetch-models` logs the size downloaded every minute.
- Own NPU checkpoints (`d1-2B`, `LFM3-*`) are named by path, need NPU programs fetched, and
  are converted at first start. `halogen-npu probe` links XRT (in Halogen's image since 0.19.1), but it
  needs no NPU device (so neither the fetch nor `model pull` passes one) and only the checkpoint's config and tokenizer (checked against 0.19.0's
  image). Some of Halogen's models have no download of their own and reuse others' programs
  (`lfm3-omni-2b`, the `-fast` VL and Audio): check the model is known, not that it has a repo.
- GitHub actions are pinned to full commit SHAs with the version in a comment (`tests/static.sh`
  checks it; Dependabot updates them). Look SHAs up with `git ls-remote --tags
  https://github.com/actions/<name>`, which the session's git proxy serves for public repos.
- `cmd | grep -q` under `set -o pipefail` fails at random on long output: `grep -q` stops reading,
  the writer dies of SIGPIPE, and the pipe fails. In tests, write to a file and grep that.
- ISO install tests take about 25 to 40 minutes, and a new push cancels the previous run.
  Don't push mid-run unless you mean to.
- The OS image is flattened (`FROM scratch` + `COPY --from=os / /`) after its `dnf remove`
  step, with `/sysroot/ostree` deleted first, as Fedora's rechunker does. Otherwise the removed
  files still ship in the base image's layers inside the ISO. File capabilities survive the copy.
- GitHub release assets must be under 2 GiB. Since the trimmed, flattened image (#22, #26) the
  ISO ships as a plain `.iso` of about 1370 MiB; `package-iso.sh` falls back to `.iso.xz` if not.

## Where the work stands

Open issues are the source of truth, prioritised with the `priority: high/medium/low` labels
and tracked on the owner's project board. [ROADMAP.md](ROADMAP.md) holds the order and
[CHANGELOG.md](CHANGELOG.md) what each release changed. When this file was last updated (after
#78, the move to Halogen 0.20.0):

- Released: `v0.19.1-alpha.6`, the last release on Halogen 0.19.1. It carries the guided installer
  (#66), the serial-getty fix (#67), the TPM wording (#68), the full security audit's fixes (#69),
  the restart fix (#70) and the duplicate-settings note (#71), all first in alpha.4; `npu on|off`
  (#72), `bench` (#73), `flash check` (#74), tab completion (#75) and the hardening from their
  reviews (#76 terminal, #77 edition label), first in alpha.5. On edge since: Halogen 0.20.0 (#78).
  Next: the owner checks alpha.6 on freyja and does one real guided install from its ISO, then
  edge on 0.20.0, then an alpha with 0.20.0. Freyja serves `swift-15fn-heretic-coder` with
  `flash use`.
- Before RC: machines refuse unsigned images (#46 phase 2b; ships once every channel points to a
  key-signed image). Done: first-boot setup and "API ready" (#43), the guided installer (#42, one
  real install still to do), the full `security-auditor` pass (#69).
- Built for stable, still to check on freyja: benchmark (#15), `flash check` (#56), `halosctl npu
  on|off` (#40), tab completion (#14).
- **Stable waits for Halogen 0.20** (owner decision): halOS is aligned with 0.20.0 first, then
  released as stable. 0.20.0 (ROCm 10.1 in its image, OvisOCR3 document parsing on the NPU as your
  own checkpoint, faster prefill, a strict-tool-call crash fixed; the Flash checkpoints and weights
  revision unchanged) is pinned by #78 (merged; on edge, in no release yet). Between source commits 47ceb43 and 8242b15, FLAGS.md,
  `deploy/entrypoint.sh` and host-setup's requirements are unchanged (only image tags in examples),
  so `options.allowed`, `halogen.env.default`, the Quadlet and kernel arguments stay as they are.
  OvisOCR3 (`ATH-MaaS/OvisOCR3`, 1.7 GB safetensors) goes through `model pull` into `custom` (the
  probe's base, almost certainly `ovisocr3` by the image's `models.txt` and the probe binary, isn't
  LFM or decider; freyja confirms; its NPU programs in `models.txt` have no pinned revision, like
  `halogen-spotter-0.6b`, so an upstream push to them breaks the fetch's hash check), served as
  `OvisOCR3` from `/models/custom/OvisOCR3`; INSTALL mentions `HALOGEN_WEIGHTS_LOCK=1` (already
  allowed) beside it. Still to do: test 0.20.0 on freyja, then stable.
- After stable: unlock over SSH (#13), clevis/tang (#44), GGUF in `flash pull` (#61).
- The ISO install test also runs when `versions.env` changes (#78), so every Halogen update PR
  gets the LUKS + TPM install in a VM, about 30 minutes for both editions.
- Known upstream: bootc 1.17.1 rewrites `/etc/fstab` at every boot on Anaconda installs
  (bootc-dev/bootc#2592); `bootc-fstab-edit.service.d/10-halos.conf` skips it. `bootc switch` to
  the ref a machine already follows does nothing; use `bootc upgrade`.

The owner's test machine is "freyja": an AMD Ryzen AI Halo Developer Platform (128 GB,
2 TB NVMe), NPU edition, Secure Boot on.

## Commits and pull requests

Use plain, specific messages that explain why. PR descriptions have a summary and a test plan
with checkboxes, and say whether real hardware was involved.

Every PR that changes what users get adds a plain-language line under **Unreleased** in
`CHANGELOG.md`, with its PR number. After the owner releases, the next PR moves those lines under
the new version's heading (the release workflow numbers releases, so the version isn't known
before). Keep `ROADMAP.md` in step when an issue is done, added or reordered.

Before asking the owner to merge a PR, run the `code-reviewer` subagent on it and fix or answer
what it finds. Run `security-auditor` too when the change touches services, permissions, the
firewall, containers, secrets, the installer or LUKS/TPM. Hardening it suggests goes in its own
PR, only once the owner agrees.
