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
| `versions.env` | Every pinned input: Fedora base, Halogen version, digest and source commit, upstream file hashes, weights repo and revision, ISO builder, bf16-to-hgn and halogen-dashboard commits |
| `Containerfile` | The OS image. XRT is not in it: Halogen's image carries its own since 0.19.1 |
| `Containerfile.installer`, `installer/` | The live installer image, Anaconda defaults (storage layout for custom partitioning), branding and boot menu. `installer/guided/`: the guided install's kickstart and `plan-install` (#42) |
| `files/` | Copied into both editions: systemd units, `halosctl`, `halogenctl`, `halogen-enroll-tpm` (bash completion for all three in `usr/share/bash-completion/completions/`; `tests/completion.sh` fails when a tool gains a top-level command, or a `flash`/`model` subcommand, its completion doesn't offer; checkpoint folder names are written by halogen and its containers, so they are never passed to `compgen -W`, which expands `$(...)`: only plain names, matched by hand), `/usr/libexec/halogen/*` (`flash-checkpoint` and `model-pull` download your own checkpoints) |
| `variants/npu`, `variants/no-npu` | Per-edition kernel arguments, Quadlet drop-ins, the allowed-options list and default `halogen.env` |
| `scripts/` | `build.sh`, `build-iso.sh`, `package-iso.sh` (single-file release ISO), `release-info.sh`, `gen-options.py` (options from upstream `FLAGS.md`), `halogen-update.sh` (pins a new Halogen release), `size-report.sh`, `channels.sh` (which channel tags a release moves), `next-tag.sh` (the next release tag), `push-image.sh`, `sign-image.sh` (cosign signing) |
| `docs/` | `CLI.md` (every command; update it with a command or option), `CLIENTS.md` (connecting apps and coding agents, and trusting the certificate per agent, from each project's docs and source) |
| `CHANGELOG.md`, `ROADMAP.md` | What each release changed (PRs add to Unreleased), and the order of the work ahead |
| `src/` | halOS's own source: `dashboard-nodump.c` (built in the Containerfile's dashboard stage) and `caddy/` (`main.go`, `go.mod`, `go.sum`: Caddy with the DNS providers, built in the caddy stage; Dependabot `gomod`) |
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
  troubleshooting.md: its numbers at about 85 W; one owner's machine about 70 W at balanced against
  127 W at performance). `70-halos-platform-profile.rules` starts it again when the kernel's
  `platform-profile` class device appears, in case the driver (likely `amd_pmf`) loads after the
  unit ran (its condition then skips it; freyja has `platform-profile-0`). The unit may write only
  that file (`ProtectKernelTunables` + `ReadWritePaths`, no capabilities; checked on freyja). Only the three names,
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
  `/var/log/audit`, `/var/home`, `/var/srv/configs`, `/var/srv/logs` (4 GiB, #107) and `/var/srv/models`. The guided install
  names them `halos-root`, `-var`, `-log`, `-audit`, `-home`, `-configs`, `-logs`, `-models` (VG `halos`);
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
  are checked in the same job, including the classic `.sig` tag. Machines enforce it (#46 phase 2b):
  `/etc/containers/policy.json` defaults to reject (bootc refuses `--enforce-container-sigpolicy`
  when the global default is `insecureAcceptAnything`; it checks only that default), requires the
  key for `ghcr.io/n4berius/halos-flash` (`matchRepository`, so tags and digests both pass), and
  accepts every other registry and local storage through the transports' `""` scopes, as before.
  `registries.d/halos-flash.yaml` turns on `use-sigstore-attachments`, without which no signature
  is found. Every `bootc switch` in halosctl passes the flag; the installers' `%post --nochroot` binds the
  disk's top level (`/mnt/sysimage`) onto the new system's `/sysroot` (Anaconda's bootc install,
  unlike its OSTree one, doesn't) and runs `bootc switch --mutate-in-place
  --enforce-container-sigpolicy` chrooted there; an install whose spec is still
  `insecure` turns it on at its next `halosctl upgrade` (a switch to the same name, which also
  fetches the newest image). Oldest key-signed release: `0.19.1-alpha.3`.

- Unlock over SSH (#13): `files/usr/lib/dracut/modules.d/90halos-ssh-unlock` (added in
  `dracut.conf.d/10-halogen-tpm2.conf`) puts sshd (with `sshd-session`/`sshd-auth`, its privsep
  user and `/usr/share/empty.sshd`), `halos-ssh-unlock.service` (wanted by `initrd.target`,
  conflicts with `initrd-switch-root.target`) and `halos-ssh-unlock-teardown.service` in every
  initramfs. dracut's `network-manager`, `dbus` and network modules were already there. The image is
  the same for every machine, so keys can't be built in: at boot the service looks for an EFI
  system partition (type c12a7328-…) on a non-removable, non-USB disk (`{1..30}`, not `seq`, which
  the initramfs lacks), mounts it read-only and copies `/halos/ssh-unlock/{authorized_keys,
  ssh_host_ed25519_key}` to `/run`. Without them it exits: no network, no server. With them it runs
  `nm-initrd-generator -- ip=dhcp rd.neednet=1`, writes `/run/NetworkManager/initrd/neednet` itself
  (the generator doesn't; dracut's `nm-lib.sh` does only for kernel arguments, and
  `nm-initrd.service` needs it), starts `nm-initrd.service` and execs sshd on port 22
  (`/etc/ssh/halos-unlock.conf`: root only, `AuthenticationMethods publickey`, `UsePAM no`,
  `DisableForwarding`, `PerSourceMaxStartups 2`, `ForceCommand systemd-tty-ask-password-agent
  --watch`, which waits for the prompt and asks again after a wrong passphrase). Root needs a
  shadow line (`root:*`): without one nss-systemd reports `!*` and sshd refuses a locked account.
  `nm-wait-online-initrd.service` is masked, so boot never waits for a cable; the Containerfile
  checks the mask, the binaries and the shadow line. Before switch-root the teardown unit stops
  `nm-initrd`, deletes the generated connection, carrier-timeout and `neednet` files from `/run`
  and flushes the links, so the system's own profiles (static address, firewall zone) apply; the
  VM test checks the generator's `default_connection.nmconnection` is gone afterwards (the
  system's NetworkManager keeps its own runtime "Wired connection 1" and `lo` profiles there too).
  `/usr/libexec/halogen/ssh-unlock` (`LC_ALL=C`; fetch `<user>.keys` from github.com, gitlab.com or
  codeberg.org with curl run as nobody; check with ssh-keygen: plain keys, no options, RSA at least
  2048 bits, each once, comments cut to plain characters; install with `restrict,pty`, the host key
  kept across key changes, a remount back to read-only, a warning if the private key's mode isn't
  private; status reads the ESP read-only and drops control characters) is driven by `halosctl
  ssh-unlock on|off` and `setup` (where a failure doesn't stop setup). The early-boot host key is
  trusted under its own name: `halosctl` prints an ssh config entry with `HostKeyAlias
  <host>-unlock` and a known_hosts line for that name. A second key under the system's own name
  would be deleted by OpenSSH's default `UpdateHostKeys` at the next normal login, and would let
  the early-boot key pass for the running system.

  The guided installer (part 2): after the admin user, with encryption, `plan-install` asks
  both/tpm/ssh/none (Enter: both) and, for SSH, GitHub/GitLab/Codeberg (`nm-online` first) or a
  pasted key, through the same helper copied into the installer image as
  `/usr/libexec/halos/ssh-unlock`; "back" returns to the choice; the keys can go on the admin user
  too (`sshkey --username=`). With encryption it writes a `%post --nochroot` into its own kickstart
  lines, with the choice and keys in a here-document, running `/usr/libexec/halos/save-unlock`
  (`installer/guided/save-unlock`); a static `%post` reading files `%pre` left in `/tmp` saved
  nothing in the VM test. save-unlock (`save-unlock <choice> <disk>`) runs the helper's `install-choice` with `HALOS_ESP`
  set to the new system's ESP: at that point of Anaconda's bootc install neither
  `$ANA_INSTALL_PATH/boot/efi` nor `/mnt/sysimage/boot/efi` is a mount point (VM test), so it finds
  the EFI partition on the disk installed to (lsblk PARTTYPE, else `blkid -p`, since udev's database
  may lag) and mounts it itself. The helper installs the keys and writes `/halos/unlock-choice`; its output is in
  the installed system's `/var/log/anaconda/ks-script-*.log`, which the VM test prints. `halosctl setup` reads it (`ssh-unlock choice`) for its defaults.
  Unattended answers: `unlock`, `ssh_key`, `admin_ssh`; the VM test installs with `unlock=both`
  and its key, so the first boot only reads the state.

- Hardening (#96): `need_policy` also requires the rule's `keyPath`; `halosctl version` prints
  `Signatures:` (login-status shows only the "not checked" line in the motd); `need_policy` also
  `cmp`s the public key with `/usr/etc`'s copy when there; `switch_to` warns about an older staged
  build only for `upgrade` (the first signed upgrade, same name; build times of other channels and
  of the other edition, built in a parallel job, differ normally) and then drops `--reboot`; the
  selftest's `signature-files` (SKIP without `/usr/etc` copies)
  compares `/etc/{containers/policy.json,containers/registries.d/halos-flash.yaml,
  pki/containers/halos-flash.pub}` with `/usr/etc` and warns about
  `/root/.config/containers/policy.json`. SSH unlock: `ssh-unlock record` keeps sha256 of the ESP's
  `authorized_keys` and the host key, private (what boot serves) and public, in
  `/var/lib/halos/ssh-unlock.sums`; `record` only makes a first record (`on` replaces it with
  `HALOS_RECORD_REPLACE=1`, after `install` made a new host key if the ESP had changed since the
  record); `setup` records an installer's keys and says so; `remove` drops it; `verify` returns
  0/1/2 (match, differ, none) for the selftest. `halosctl ssh-passwords on|off` writes or removes
  `/etc/ssh/sshd_config.d/20-halos-keys-only.conf` (`PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`; sshd takes the first value, so 20 beats Fedora's 50), only when
  `$SUDO_USER` has a key sshd accepts (read as that user, checked with ssh-keygen; home and .ssh not
  group/world-writable), checked with `sshd -t` and `sshd -T` (the setting sshd will use); in
  setup a failure doesn't stop setup. A second signing key isn't shipped: it needs a
  key pair the owner makes offline (RELEASING.md).

- Converting full-precision weights (`halogenctl flash convert`, #97): bf16-to-hgn
  (Quat3rnion, MIT/Apache-2.0, `native/` Apache-2.0) is built in the Containerfile's
  `bf16-to-hgn` stage from `BF16_TO_HGN_COMMIT` (same Fedora base, so libstdc++/libgomp match;
  `cargo build --release --locked`, CPU only, about a minute) and copied to
  `/usr/libexec/halogen/bf16-to-hgn` with its licenses; `release.env` records the commit. Its HF
  input must be complete Qwen3.8 Flash Next (`model_type` `qwen4_exp`,
  `Qwen4ExpForConditionalGeneration`, `mtp.*` and `model.visual.*` tensors (HF names; shards are those the index names), config/tokenizer/
  chat_template/merges/generation_config); it reads every shard's header, so `flash-checkpoint
  convert-prepare` checks config.json and the index's keys itself before the weights download
  (about 360 GB), then the space (weights + about 119 GB out). `convert-run` (halogenctl starts it
  as `halogen-flash-convert.service` under halogen's user manager, detached, Nice 10, idle I/O)
  downloads the shards into `flash/.convert/<name>/source`, checks HF's sha256, runs `convert
  --profile v2 --threads N` and `verify` into `flash/.convert/<name>/out/<name>` (emptied first,
  never resumed), each in its own transient unit (`sandboxed`: `PrivateNetwork`,
  `RestrictAddressFamilies=none`, read-only system and models, writable only the work folder,
  `/srv/configs`, halogen's home and `/run/user/970` hidden, `BindsTo` the job; `unshare --net` was
  not enough, since a socket of the user manager reaches out), then `mv -T -n` to `flash/<name>`,
  writes `halos.info` (`checkpoint=model.hgn`, `converted_with`), runs Halogen's verify, and
  deletes the source unless `--keep-source`. Progress is `du` of the staging folder every 10 minutes (its payload files are
  written at preplanned offsets, and the image has no `script` for its pty-only progress display).
  No full-size conversion has run anywhere yet; no CPU timing exists.

- Dashboard (#98): Quaternion's [halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard)
  (MIT/Apache-2.0; Rust collector + Svelte page embedded with rust-embed), built in the
  Containerfile's `dashboard` stage from `HALOGEN_DASHBOARD_COMMIT` with Fedora's rust (1.99), nodejs
  22 and pnpm 10 (reads its v9 lockfile; upstream says pnpm 11), `--bin halogen-dashboard` only (not
  `fake-halogen`), into `/usr/libexec/halogen/halogen-dashboard`. Licences in
  `/usr/share/licenses/halogen-dashboard/`: its own, `web/` (IBM Plex Sans OFL 1.1, uPlot, Svelte, the
  bundled parts) and `crates.txt` (`cargo metadata`). `halos-dashboard.service` (enabled, firewalld
  service `halos-dashboard`, 8732/tcp open by default (8790 in v0.20.1-alpha.1 and alpha.2, until #103; the firewalld service file
  moves the port on upgrade, since zones name the service), no login, GET routes only): `DynamicUser`,
  `StateDirectory=halos-dashboard` (SQLite: raw samples 48 h, one-minute rollups and events 30 d; about 430 MB full, from upstream's `seed --days 30`),
  `MemoryMax=256M` (measured 12 MB RSS against the simulator), `HALOGEN_URL=http://127.0.0.1:8731`
  (the binary's defaults are upstream's LAN address and 0.0.0.0). `/metrics`, `/cache` and
  `/v1/models` need the API key, so `ExecStartPre=+dashboard-key` reads `/srv/configs/api-key` as
  halogen with `setpriv` (never `LoadCredential`/`EnvironmentFile`, which PID 1 would read as root
  through a link halogen could plant), keeps the first key's printable characters in the runtime
  folder (0600, the dynamic user's), and `dashboard-run` exports it as `HALOGEN_API_KEY`. Its ADR
  0001: it must be Halogen's only `/metrics` reader (two gauges reset per read); nothing in halOS reads
  `/metrics` (`halogen-bench.py` doesn't). `halosctl dashboard [on|off]` enables/disables the unit
  only: the firewalld service stays as the image sets it (open), since `firewall-cmd --permanent`
  would make the zone file a local change later images couldn't update; off means nothing listens.
  `dashboard-key` writes through `mktemp` and `chown -h` (the runtime folder is the dynamic user's).
  Upstream's `/api/series` keeps every row in range in memory: the page's 30-day view peaks at about
  104 MB, a crafted 1-second-step request at about 590 MB, which `MemoryMax=256M` turns into an OOM
  restart (Halogen unaffected). The selftest says PASS when `/healthz` answers, INFO when off.
  Hardening (#99, the audit's zero-cost ideas, agreed by the owner): `CPUQuota=100%`, `IPAddressDeny=any`
  with `IPAddressAllow=localhost link-local 10/8 172.16/12 192.168/16 100.64/10 fc00::/7` (outgoing
  traffic too, to the same ranges; it needs only Halogen on localhost; `fc00::/7` is moot while it
  listens on 0.0.0.0), `LimitCORE=0` (no core file; systemd-coredump still journals the environment,
  key included),
  `PrivateUsers=yes`, and `pnpm install --ignore-scripts` in the build stage (the page builds
  without them, checked on Fedora 45).
  Then (#101): `dashboard-run` preloads `/usr/lib64/halos/dashboard-nodump.so` (`src/dashboard-nodump.c`,
  built with gcc in the dashboard stage: a constructor calling `prctl(PR_SET_DUMPABLE, 0)`, exit 70 if
  it fails; a wrapper can't, since execve makes a process dumpable again), so the kernel never hands
  a crash to systemd-coredump (which journals `COREDUMP_ENVIRON`, the key) and gives its `/proc` files
  to root; dashboard-run refuses to start unless the library loads (ld.so skips a broken one with a
  warning), and the dashboard stage checks a nobody process with it can't read its own environ.
  `SocketBindAllow=tcp:8732` + `SocketBindDeny=any` (skipped quietly without systemd's BPF framework
  or libbpf; not checked by the selftest). `IPAccounting=yes` uses the same cgroup BPF program as
  `IPAddressDeny`, which systemd skips quietly when it can't load or attach it: the selftest's
  `dashboard-filter` passes only when `IPIngressBytes` is above 0 after its own curl and
  `IPAddressDeny` holds `0.0.0.0/0`, and prints the allow list; `dashboard-nodump` passes when
  `/proc/<MainPID>/environ` belongs to uid 0. `iso.yml` also runs for `src/**`.

- Front door (#102 step 2, #104): `halos-proxy.service` runs Caddy (`/usr/libexec/halogen/caddy`, built
  in the Containerfile's `caddy` stage from `src/caddy` with Fedora's Go, `GOTOOLCHAIN=local`,
  `-mod=readonly`, `CGO_ENABLED=0`; Fedora's caddy package has no DNS providers). DNS providers: caddy-dns
  cloudflare and porkbun; DuckDNS and Namecheap through halOS's own modules in `src/caddy/dnsproviders`
  on the MIT libdns libraries, because caddy-dns/duckdns and /namecheap carry no licence (owner's call;
  `tests/static.sh` keeps them out). Their values take placeholders (`{file.…}` for credentials). It is the only
  listener on 8731 and 8732, on HTTP or (later) HTTPS: Halogen is published on `127.0.0.1:18731`
  only (Quadlet), the dashboard listens on `127.0.0.1:18732` with `IPAddressAllow=localhost` and
  reads Halogen at 18731. Caddyfile `/usr/share/halos/proxy/Caddyfile` (`caddy validate` at build):
  `admin off`, `persist_config off`, `auto_https off`, `protocols h1 h2`, `grace_period 10s`,
  `flush_interval -1` (SSE, checked unbuffered), 503 notes from `handle_errors` when an upstream
  is down, an access log for 8731 only (journal; `format filter` deletes request headers and the query,
  since Caddy redacts only `Authorization` and `x-api-key`/`?api_key=` would be kept: security audit;
  fail2ban #92 will read it), `bind 0.0.0.0` on 8732 (IPv4 only as before), and the dashboard's private-ranges rule (`remote_ip` + `abort`, plus `{$HALOS_DASHBOARD_ALLOW}`
  from root's optional `/etc/halos/proxy.env`). The unit: `DynamicUser`, `StateDirectory=halos-proxy`
  (HOME/XDG there), `GOMEMLIMIT=192MiB` under `MemoryMax=256M` (no `MemoryHigh`: Caddy's automemlimit
  would aim above it), no capabilities (ports above 1024), the dashboard's sandbox, `SocketBindAllow`
  8731 and 8732. Prototype (Fedora 45 container, as nobody): only TCP 8731/8732 listen (no 2019,
  no :80, no UDP). `login-status`, `bench` and the selftest's `api-ipv4`/`api-models` ask Halogen at
  18731 directly (Halogen's own numbers, no access-log lines, no TLS later); the selftest's `proxy`
  curls 8731 (any HTTP code: Caddy answers) and `api-ipv6` goes through Caddy on `[::1]:8731`.
  `ExecStartPre` runs `caddy validate`, so a bad `proxy.env` range fails once with a reason.
  The 8731 503 note is JSON with `Retry-After`. Licences:
  `/usr/share/licenses/halos-caddy/` (`modules.txt` from `go list -deps`, each module's licence and
  NOTICE files, and Go's own `go-LICENSE` for the standard library).

- HTTPS (#102 step 3, #105): `/usr/libexec/halogen/https` (root, `set -f`) reads `/etc/halos/https.env`
  as data (`HALOS_HTTPS=off|self-signed|custom`, `HALOS_HTTPS_NAMES`; no file or empty = off, also on
  upgrades; any other value = `invalid`, which stops Caddy's start, never plain HTTP) and is
  halos-proxy's `ExecStartPre=+`: it writes `/run/halos-https/proxy.env` (a folder only root writes,
  since PID 1 reads `EnvironmentFile`s as root and Caddy's runtime folder is Caddy's; the unit's own
  default `HALOS_PROXY_CONFIG` is a missing file, so no env file fails closed) with
  `HALOS_PROXY_CONFIG` (`Caddyfile` or `Caddyfile.https`), `HALOS_TLS` (`internal|custom`, imported
  as `tls_<mode>` from `sites.caddy`) and quoted `HALOS_API_SITES`/`HALOS_DASH_SITES` (self-signed:
  `https://<name>:port` for localhost, 127.0.0.1, ::1, the host name, short name, `.local`, every
  global address (`ip -o addr show scope global`, minus temporary/deprecated/tentative IPv6, else
  `hostname -I`) and the extra names (`set self-signed` alone keeps them), IPv6 bracketed, the
  dashboard IPv4 only; custom:
  `https://:port`). systemd re-reads `EnvironmentFile` for each command, so `caddy validate --config
  ${HALOS_PROXY_CONFIG}` and `run` see it. Custom: `stage <cert> <key>` reads each file once (1 MiB
  at most) into `/etc/halos/https/.pending/`, checks the copies (key matches, not expired, no
  passphrase) and re-encodes them (`crl2pkcs7 | pkcs7 -print_certs`, `pkey`); `commit` moves them in,
  keeping `.prev-*`; `discard`, `restore`. `env` copies them into `$RUNTIME_DIRECTORY` (`mktemp` +
  `chown -h --reference`) and fails closed without them. Names are validated (host-name characters or
  an IP) before reaching the Caddyfile. `Caddyfile.https`: `auto_https disable_redirects`,
  `skip_install_trust`, `listener_wrappers { http_redirect tls }` (308 on the same port, no :80).
  Caddy's authority (`/var/lib/private/halos-proxy/caddy/pki/authorities/local/root.crt`, key beside
  it in Caddy's state) is checked by root to lie inside Caddy's state (realpath, a regular file), then read from inside that folder as Caddy's own user with `setpriv` (relative path, so a link swapped in later is followed only with Caddy's rights), `timeout 5` and `head -c 64K`,
  then re-encoded by openssl (a link, FIFO or endless file can't make root print or hang). Checked in
  a container as nobody: certs per name and address, unknown SNI refused, custom cert for any SNI,
  the redirect. `halosctl https [self-signed [<name>...]|custom <cert> <key>|off|ca]`: custom stages,
  shows the subject, asks (no: `discard`, nothing in use changes), commits; every switch restarts the
  proxy and then needs `is-active` plus an HTTP answer on 8731 within 10 s (systemd counts the start
  as done before Caddy binds), else puts back `https.env` and with custom the previous certificate.
  The selftest's `https` (INFO off; FAIL invalid; PASS when `--cacert` the authority, or `-k` for
  custom, gets an answer; WARN within 14 days of a custom certificate's end) and `https-names` (an
  address not in the sites: `https uncovered`); `halos-https-refresh.timer` (every minute, root,
  sandboxed) runs `https refresh`, which in self-signed mode try-restarts halos-proxy only when an
  address isn't covered (Caddy now waits for `network-online.target`, but Tailscale and new leases
  come later: code review found IP clients without SNI failed after a reboot); its API-over-Caddy and dashboard checks use the mode's scheme
  with `-k`; login-status and `halosctl dashboard` show `https://`. INSTALL advises trusting the
  authority per app, not system-wide (it isn't name-constrained). The VM test turns self-signed on,
  curls with the authority (Caddy's 503 note, Halogen being down), checks the 308, the selftest
  lines, and `off`. Not done, for the owner to agree (security audit): a name-constrained root kept
  by root with Caddy holding only an intermediate, and the selftest comparing the served
  certificate in custom mode.
  Let's Encrypt (#102 step 4): `HALOS_HTTPS=letsencrypt` with `HALOS_ACME_DNS` (cloudflare, duckdns,
  porkbun, namecheap), `HALOS_HTTPS_NAMES` (public names only: two labels or more, no address,
  no `.local`/`.lan`/`.home`/`.internal`), `HALOS_ACME_EMAIL`, `HALOS_ACME_STAGING`. Config
  `Caddyfile.letsencrypt`: global `acme_ca`, `cert_issuer acme` and `import acme/dns-<provider>.caddy`
  plus `acme/email-<yes|no>.caddy` (one policy for both ports: two `tls` blocks for the same name on
  8731 and 8732 are refused as ambiguous); the public names' sites get ACME, the local names
  (`names` minus the public ones) keep `tls internal`, so IP clients, the selftest and `proxy_up`
  still work. Credentials: `https dns-stage <provider>` reads `field=value` lines from stdin only
  (4 KiB, one printable word each, a Cloudflare token in the shape caddy-dns/cloudflare accepts,
  since its refusal prints the token; DuckDNS 36 characters; Namecheap's `client_ip` an IPv4), into
  `/etc/halos/https/dns/.pending` (root, 0700/0600); `dns-commit` keeps `.prev`, `dns-restore`; `env`
  checks them and fails closed without them. Caddy gets them as systemd credentials
  (`LoadCredential=dns:/etc/halos/https/dns`: a folder loads each regular file as `dns_<name>`,
  skipping dot entries (`.pending`, `.prev`) and links; the folder must exist: Fedora 45's systemd 262 fails the start
  with 243/CREDENTIALS "No such file or directory" without it, `SetCredential=dns:` as a fallback
  or not (VM test), so tmpfiles makes it at boot and `dns-forget` only empties it) and reads them through
  `{file.{$CREDENTIALS_DIRECTORY}/dns_<field>}`; they're loaded in every mode until `forget-dns`, which also try-restarts halos-proxy, since a running Caddy keeps what it loaded; `env` checks what Caddy's `{file.…}` passes on (the file less one trailing newline; `$(...)` alone drops them all).
  The build stops if caddy-dns/cloudflare's two token regexes change (`dns_value_ok` copies them). halOS's DuckDNS and Namecheap modules check the values after
  replacement in `Provision` and wrap the four record methods to replace the secret (raw and
  URL-encoded) with `REDACTED` in errors (`go test ./dnsproviders/` runs in the caddy stage).
  `halosctl https letsencrypt <provider> <name>... [--email] [--staging]` prompts (hidden) on a
  terminal or reads stdin with `--yes`, offers to reuse the saved credential, waits up to
  `HALOS_ACME_WAIT` (300 s) for each name to answer by SNI (`curl --resolve`, no `--retry`),
  and otherwise prints Caddy's last errors and restores the mode and credentials. The selftest
  checks the name against the system trust store (WARN staging or within 10 days, FAIL none or
  ended). Namecheap's API replaces a domain's whole record list (libdns/namecheap `SetHosts`):
  INSTALL warns. Review and audit fixes: `dns_value_ok` (provider shapes) runs in `dns-stage` and
  again in `env` (a hand-edited token never reaches Caddy); `dns-stage` never echoes a line without
  `field=`; `halosctl` runs `https set --check` (names, email) before asking for any secret, puts
  back the credentials if `set` refuses, traps INT/TERM/HUP during the wait to revert, reads
  Caddy's errors with `jq` (escaped quotes), and drops `.prev` once the new credentials work
  (`https forget-dns` removes them all, refused while in use); `set self-signed` alone doesn't keep
  the Let's Encrypt names. A new credential is first used at Caddy's next renewal when the name
  already has a valid certificate (INSTALL says so). Real issuance can't run in CI; first checked
  on freyja.

- udisks2 (kept for fwupd's EFI partition lookup, #106; disabled, D-Bus activated) is root's alone
  (security audit, owner agreed): `/usr/share/polkit-1/rules.d/10-halos-udisks2.rules` returns NO for
  every `org.freedesktop.udisks2.*` action to a non-root subject (polkit allows uid 0 before rules,
  so fwupd works), and `/usr/share/dbus-1/system.d/halos-udisks2.conf` denies the `halogen` user
  any send to `org.freedesktop.UDisks2` (no call, no properties; dbus-broker still activates the
  service for the message, then refuses it at delivery). The VM test checks the admin gets polkit's
  `Error.NotAuthorized:` from `udisksctl loop-setup -r` (without `-r` udisksctl opens the file
  read-write itself and fails before asking), halogen's `busctl call` (through `runuser -u halogen`: `systemd-run --pipe` with its output in a file in /tmp fails under SELinux, since PID 1 may not write user_tmp_t) gets "Access denied" (busctl's words; dbus-broker logs "A security policy denied … to send")
  while the admin's same call answers (`a{sv}`), besides fwupd's ESPRC.

- Request records (#107 part A): Halogen's own feature (`HALOGEN_RECORD_*`, configuration.md
  "Request records"). `halogenctl records on|off` writes or removes root's Quadlet drop-in
  `/etc/containers/systemd/users/970/halogen.container.d/20-records.conf` (`Volume=/srv/logs/halogen:/records`),
  reloads halogen's manager (as halogen with `setpriv` and `systemctl --user` on its private socket,
  as login-status does; through `--machine=halogen@.host` the VM test's reload and `is-active` failed
  with "Transport endpoint is not connected", cause not established; its output then went to a file
  in /tmp, now a pipe), treats any `is-active` answer but running or stopped as an error (never as
  "stopped", which would skip the restart), checks the generated `halogen.service` gained or lost the
  mount, and restarts Halogen if running; a Quadlet volume can't be conditional
  otherwise, and off means nothing is mounted. `render-config` sets `HALOGEN_RECORD_DIR=/records` only
  while that drop-in exists (`HALOGEN_RECORD_DIR` stays in gen-options' BLOCKED), defaults
  `HALOGEN_RECORD_TEXT` to `none` (owner's decision; Halogen's own default is `all`), checks TEXT
  (Halogen refuses to start on an unknown field), GIB and DAYS, and drops all three while off.
  `prepare` makes `/srv/logs` (halogen, 0750, `container_file_t`) and `logs/halogen` (0700, as
  halogen); `halogen-prepare.service` may write there. `records stats|prune` run Halogen's
  `request_records.py <cmd> /records` through `halogen_run` (the output carries client names):
  `podman exec` while on and running (one writer), else a one-off `podman run --rm --network=none
  --read-only --cap-drop=all` of the pinned image with only the folder (so records kept before
  `off` can still be pruned); prune only with `--days/--gib/--session/--unit/--all` and plain
  values, after asking; on/off/prune need root; `off` restarts Halogen when its `/health` still
  shows `request_records` (an off cut short); the drop-in folder is `install -d -m 0755` (no-NPU
  doesn't ship it). The selftest's `folder-logs` (own volume or /var) and `records`
  (INFO off; PASS with `/health`'s `request_records`; WARN when on but /health has none or
  halogen's generated unit lacks the mount, and when off but /health still has them). The selftest
  reads the generated unit with `setpriv` over halogen's own socket too: `systemctl cat` refuses any
  remote transport, `--machine` included ("Cannot remotely cat units"), so the first version always
  warned about a mount that was there (freyja); the VM test runs the selftest with
  records on (`RECST`). Earlier
  installs keep `/srv/logs` on `/var`: the guided install leaves no free extents (models `--grow`,
  XFS can't shrink). The VM test checks the volume, the folder, on/off, the mount in the generated
  unit and the rendered settings; recording itself needs Halogen running, so freyja checks it.

- Records hardening (owner agreed): the records drop-in mounts `/srv/logs/halogen:/records:noexec,nosuid,nodev`;
  the guided install's `logs` LV has `--fsoptions=nodev,nosuid,noexec` (custom partitioning's
  Anaconda defaults can't set options). `halogen.container` has `ReadOnly=true` with anonymous
  volumes (on disk, removed with the container) for `/tmp`, `/var/tmp` (the entrypoint's only write
  places: the tuning-plan copy, NPU output, `HALOGEN_CACHE_FILE`'s default snapshot, up to 26.6 GiB)
  and `/root` (the image runs as root, HOME unset; ROCm may cache there), never tmpfs, so memory use
  stays as before. `ReadOnlyTmpfs=false`: podman's `addReadWriteTmpfsMounts` skips only binds and
  tmpfs already at a destination, not volumes, so it mounted a tmpfs beside the volume on /tmp and
  /var/tmp and the winner varied per start (code review: about half in memory over 30 runs);
  `Tmpfs=/run` and `Volume=/dev/shm:/dev/shm` (`--read-only` alone remounts the host's shm
  read-only, even with `--ipc=host`) replace it. `ExecStartPre=-podman rm -v -f -i halogen`: the
  generated `--replace` drops a leftover container (hard reboot) without its anonymous volumes.
  Checked with Fedora 45's podman 6.1.3 and its quadlet (rootful harness, busybox, no SELinux):
  35 of 35 starts had all three on disk, `/run` a writable tmpfs with the API key readable,
  `/dev/shm` the host's and writable, device nodes writable though `/dev` is mounted read-only, and
  no dangling volumes after a leftover container. The selftest's `scratch` line asks the running
  container (`podman exec halogen stat -f`) and FAILs on tmpfs. Checked in the VM only as the
  generated unit's `--read-only`; Halogen's start and speed under it need freyja.

- Prompt cache on disk (owner asked; Halogen's `HALOGEN_CACHE_DIR`, configuration.md "Prompt cache
  on disk"): `halogen.container` always mounts `/srv/models/.prompt-cache:/models/.prompt-cache:noexec,nosuid,nodev` (over its own place: at a second path such as `/cache` the read-only `/models` mount shows the same folder without `noexec`, security audit)
  (the one writable folder under the read-only models; `prepare` makes it as halogen, 0700, at every
  boot, so an upgrade has it before Halogen starts; a missing source folder would fail the start).
  `render-config` sets `HALOGEN_CACHE_DIR=/models/.prompt-cache` and `HALOGEN_CACHE_PRUNE_OLD=1` (halOS's default:
  each build/checkpoint/setting keeps its own subtree and never reads another's, so an upgrade would
  leave them; `0` in `halogen.env` keeps them for a rollback) unless `/srv/configs/prompt-cache`
  says `off` (`halogenctl cache off`; the mount stays, Halogen just isn't told) or the folder is
  missing; `HALOGEN_CACHE_DISK_GIB` (whole number, Halogen's 64) and `_PRUNE_OLD` are now in
  `options.allowed`, `CACHE_DIR`/`CACHE_FILE` stay blocked. `halogenctl cache [status|on|off|clear]`:
  all need root (without it runuser fails quietly and the state would always read "on"); on/off
  ask `is-active` over halogen's own socket (setpriv, as records) before writing the choice as
  halogen, then restart only a running Halogen; clear refuses a link in place of the folder, stops
  Halogen (a `deactivating` one counts as running: it flushes its last turn), opens up and empties
  the folder as halogen, and an EXIT trap starts Halogen again whatever happened (halogenctl runs
  under `set -e`, so a bare failing command would have left it stopped); an `is-active` answer that
  is neither running nor stopped is an error before anything changes. `PRUNE_OLD=1` also empties
  the cache when `flash use` switches checkpoint (each checkpoint has its own subtree). The
  fetch's and login-status's `du` of `/srv/models` exclude the folder. Selftest `prompt-cache` (INFO off, WARN folder missing or on tmpfs/overlay, which
  Halogen refuses). About 27 KiB per token; writes happen behind the request. The VM checks the
  folder, the mount and the rendered settings; that Halogen accepts the folder (direct I/O), the
  restore after a restart and the speed need freyja.
- Logs (#107 part B): `audit` and `audit-rules` are installed, auditd and audit-rules.service
  enabled. Fedora's `/etc/audit/rules.d/audit.rules` (`-a task,never`: no syscall auditing, so no
  file watches) is deleted; `files/etc/audit/rules.d/50-halos.rules` (`-D -i -b 8192
  --backlog_wait_time 60000 -f 1`, `-a task,never -F uid=970` so Halogen's processes carry no audit
  cost, then `-w` watches with keys halos-config, halogen-config, signature-policy, sshd-config,
  sudoers, accounts, and exit rules `-F path=… -F perm=x -F auid!=unset` with keys luks-tpm, os-update, halosctl, halogenctl
  (only runs from a login: `halos-status.timer` runs `halosctl version` and so `bootc` every 10 minutes; `auditctl -l` prints these as `-a always,exit … -F key=`); logins/sudo come from PAM) is
  compiled by `augenrules` at build (it says "You must be root" without CAP_AUDIT_CONTROL and still
  writes `audit.rules`, exit 0). `auditd.conf` (sed + checked at build): 50 MB × 20 (1 GB: 100 MB × 20 plus `admin_space_left` wouldn't fit the 2 GiB a custom install may give `/var/log/audit`, and SUSPEND lasts until a restart with more room), ROTATE,
  `space_left` 500 SYSLOG, `admin_space_left` 200 / disk full / disk error SUSPEND; never HALT or
  SINGLE (the build refuses them). journald stays on the audit socket (the selftest's
  selinux-denials reads `_TRANSPORT=audit`), so audit lines also go to the journal, which
  `journald.conf.d/60-halos.conf` caps at 4G, 1G kept free, 128M files, 90 days. logrotate (base
  image) handles btmp/wtmp. The selftest's `audit` (PASS with ≥15 watches; WARN on Fedora's rule,
  few watches, `auditctl -s` saying `enabled 0`, a second `never` rule, the uid 970 rule missing (`-i` makes `auditctl -R` return 0 past a refused rule), under 250 MB free on the audit volume, or auditd down) and `logs` (journal size; WARN under 512 MB free on /var/log, below `SystemKeepFree`). Task rules are checked at fork against the parent, so everything halogen's user manager starts is exempt (its writes in /srv/configs aren't recorded), while `runuser`/`setpriv` from root stay audited; Caddy and the dashboard (DynamicUser) are audited. In the Containerfile the rule checks are separate statements: `set -e` ignores `a && b` (but the last) and `! cmd`. The VM
  test checks auditd active with its watches, a touch in /etc/halos found by `ausearch -k
  halos-config`, a `halosctl version` found by `-k halosctl`, the uid 970 rule, and the journal cap. Speed under auditing, freyja, engine only (`bench` bypasses Caddy): unchanged, pp2048 1878 before and 1889 after #118, tg128 68.1 and 69.4 (2026-11-13); the cost on Caddy's path is unmeasured.

- Audit hardening (security audit of #118, owner agreed): the exemption is `-a task,never -F uid=970
  -F auid=970` (Halogen's own login session: `systemd-user`'s PAM stack has `pam_loginuid`, so
  `user@970` and what it starts carry login uid 970; root acting as uid 970 from an admin's login or
  a system service, `prepare` and the status timer included, is audited, so prepare's boot writes
  in `/srv/configs` appear under `halogen-config`). If the manager's login uid weren't 970 the rule
  would match nothing and Halogen would be audited: the selftest's `audit` WARNs on that, and the VM
  test prints it (`HLOGIN`) and proves both sides with the `/var/srv/configs` watch (`AUDITEX`: a
  `systemd-run --user` touch leaves no record, a `runuser` touch does). More `-w` watches (keys
  quadlet, containers, audit-config, systemd-config, pam, preload, modules, udev, firewall, sysctl;
  `/etc/ssh` whole; crypttab, gshadow, subuid/subgid), the specific signature-policy lines before
  the wider `/etc/containers`; `/usr/bin/kmod` as an exit rule with no auid filter (runs of
  modprobe/insmod/rmmod by any process; the kernel's own modprobe is a `kernel_execve` with no
  syscall and libkmod loads run no program, so neither is seen; a syscall rule on `finit_module`
  would be, at a cost on every audited syscall). A file that doesn't exist yet
  (`/etc/ld.so.preload`) is still watched through its folder (the VM loaded all 34 rules), so the
  selftest requires every shipped rule whose folder exists (read from `rules.d/50-halos.rules`).
  `auditctl -l` prints the kmod rule as `-w … -p x`. VM test lessons: `systemd-run --user --wait`
  uses the D-Bus user bus and takes `DBUS_SESSION_BUS_ADDRESS` (root's, from the login) before
  `XDG_RUNTIME_DIR`, so name halogen's bus; and root's `rm` of a probe file is itself recorded
  under the file's name, so count `nametype=CREATE` lines. `-e 2` last (the build checks): no rule change or
  `auditctl -e 0` until reboot, so no ad hoc `auditctl -w` probes, and selftest hints say reboot.
  Selftest: `audit` also WARNs on `enabled 1` (unlocked) and `lost` above 0 (since boot);
  `audit` also WARNs on any `exclude`-filter rule; `config-files` compares every file under
  `/usr/etc/audit` and `/usr/etc/containers/systemd` with `/etc`'s and WARNs on any file `/etc` has
  there that the image doesn't (auditd `plugins.d` included), excusing by full path only
  `users/970/halogen.container.d/20-records.conf`, which must hold exactly the mount `records on`
  writes (the audit proved a PASS with the same file name in another drop-in folder); `halogen-autostart` WARNs on anything in halogen's
  `.config/{systemd/user,containers/systemd,environment.d,autostart}`.

- Audit follow-up (#126, from the audit of #125, owner agreed): halogenctl is `#!/bin/bash -p` (no `BASH_ENV`, no imported
  functions, which would run before any line of it) and runs the selftest with
  `/usr/bin/env -i PATH=/usr/sbin:/usr/bin LANG=C.UTF-8`; the selftest's curl calls take `-q` (no `/root/.curlrc`) (its `HALOS_*`/`HALOGEN_*` test hooks worked in
  production: `HALOS_USR_ETC=/etc` compared `/etc` with itself); watches on `/etc/environment`
  (key environment), `/etc/fstab` (mounts), `/etc/nsswitch.conf` (accounts), `/etc/sysctl.conf`
  (sysctl), `/etc/ld.so.conf`, `.d` and `ld.so.cache` (preload), `/etc/authselect` (accounts: `nsswitch.conf` and PAM's `system-auth` are links into it, and a watch on a link doesn't cover its target). Not done, to measure on freyja first: `audit=1`
  as a kernel argument (PID 1 has no audit context without it, so `systemctl enable|disable|mask`
  leaves no record under the `/etc/systemd` watch), program rules on `systemctl`/`systemd-run`/
  `runuser`/`setpriv` (noisy: halogenctl runs them), and the cost of folder watches on Caddy's
  path (`bench` talks to 18731 and can't see it).

- Prompt cache hardening (#127, security audit of #124, owner agreed): the cache `Volume=` moved from
  `halogen.container` into the shipped drop-in `users/970/halogen.container.d/15-prompt-cache.conf`
  (a drop-in can add a mount but not change one, and podman refuses two at one place; a locally
  edited `halogen.container` that still has the line would fail to start). `cache off` writes
  root's same-named file in the all-users folder `users/halogen.container.d/` with `:ro,`: Quadlet
  takes the all-users folder's file over the uid folder's (checked with podman 6.1.3's generator
  `--user --dryrun`, both directions), so nothing shipped is edited and `cache on` just removes it.
  Invariant: Halogen is told `HALOGEN_CACHE_DIR` only while the mount is writable: `render-config`
  needs both the choice file not `off` and no off drop-in; both directions save `off` first (a stale choice file saying `on` beside the off drop-in must not survive a failed
  `on`) and `on` saves `on` last, after a daemon-reload and a check of the generated unit's mount;
  a failed reload or check is said out loud, leaves the cache off, and still restarts a running
  Halogen (it keeps the settings it started with); "already off/on" also needs the unit's mount
  to agree, so a half-done switch (or an `off` from before #127: choice file only) is finished
  by running the command again. Two cache mounts in the generated unit count as a wrong answer (the all-users-over-uid
  precedence is Quadlet behaviour, not a documented promise; the VM test counts exactly one).
  `cmount` ends in `|| true`: under `set -e` and pipefail a grep
  without a match killed the script before its own error message. The unit is read whole
  into a variable before matching: `cat | grep -q` under pipefail died of SIGPIPE and read as "not
  mounted" (that was records' wrong "isn't in Halogen's service after the reload" in the VM; fixed
  there too). The selftest's `config-files` excuses the off drop-in by exact path and content, and
  `prompt-cache` FAILs on a link or a foreign owner, WARNs on a mode other than 700 and on a half
  off. `preflight` refuses a link, a missing folder or a foreign owner (mode only warns: prepare
  resets it at boot only). Hidden from other containers: `--tmpfs
  /models/.prompt-cache:ro,size=4k,notmpcopyup` on every podman run that mounts all of
  `/srv/models` (the fetch's probe, download and verify, flash-checkpoint's `offline` and `ppl`),
  always: those scripts run as halogen and first refuse a link in the folder's place and make a
  missing folder (podman can't make the mount point on a read-only `/models`, and a folder that
  appeared during a long download would be seen by the networked container);
  without `notmpcopyup` podman copies the folder's files into the tmpfs (seen with 4.9.3; 6.1.3's
  podman-run(1) says the same); the convert sandbox gets `InaccessiblePaths`. Podman 6 can't run
  in this session's sandbox (cgroups v1), so those flags first run for real on freyja's next fetch.
  Not done yet: `noexec,nosuid,nodev` on the NPU edition's own-checkpoint folders, which needs a
  look at freyja first (whether Halogen maps anything executable from them).

- fail2ban (#92, #129; owner: on by default, private networks exempt, API lenient): Fedora's
  `fail2ban-server` + `fail2ban-firewalld` (1.1.0; the second sets `banaction =
  firewallcmd-rich-rules`, runtime rules only), enabled. `jail.d/50-halos.conf`: `backend = systemd`,
  `ignoreip` = localhost and the dashboard's private ranges, `[sshd]` with Fedora's 5 in 10 min /
  10 min (its filter matches `sshd-session` too), `[halos-api]` 10 in 10 min / 10 min on port 8731.
  `filter.d/halos-api.conf` reads halos-proxy's journal (Caddy's JSON access log): anchored at the
  line's start, the address is the first field of `request` (`"remote_ip":"<ADDR>"`), status 401
  (Halogen's answer to a missing or wrong key, api.md; Caddy passes it through). The pattern
  begins `^\S+ caddy\[\d+\]: \{`: fail2ban's systemd backend hands a filter `<host>
  <program>[<pid>]: <message>` (`formatJournalEntry`), not the bare message; the first version
  began `^\{` and matched every test fed from a file (`journalctl -o cat`, the build's sample
  lines) and nothing from the journal (security audit, which ran Caddy and a real journal file).
  The build's sample lines carry the prefix (a bare-JSON line must not match), and the VM test
  feeds `journalctl -o short-iso` less its date (with the date on, fail2ban-regex's own date
  handling leaves a leading space) and also runs `fail2ban-regex systemd-journal` (`F2BJ`).
  `usedns = no`, `maxmatches = 1`, `dbmaxmatches = 0`, `loglevel = NOTICE` (the audit measured
  about 5 KB per failing address and 17 KB per ban with the defaults, and one journal line per
  401), and `CPUQuota=50%`, `Nice=10`, `TasksMax=64` in the drop-in. Known limits, in INSTALL:
  rich rules sit after firewalld's established-accept, so an open connection survives a ban;
  bans are per address (IPv6 /64); shared addresses and proxies; `firewall-cmd --reload` drops
  the rules unnoticed; with hundreds of bans `off` can leave rules (halosctl counts them).
  Code review fixes: no `NoNewPrivileges` in the drop-in (selinux-policy 45.23 gives `init_t`
  no `nnp_transition` to `fail2ban_t`, unlike `sshd_t`/`firewalld_t`, so the daemon would stay in
  `init_t` and couldn't write its database; the VM prints its domain, `F2BDOM`); Caddy logs a
  status of 500 or more at level `error`, so the VM's 503 line starts `{"level":"error"`: the VM
  runs the shipped pattern with `info`/`401` swapped for `error`/`503` through the real journal
  backend (`fail2ban-regex -m … systemd-journal "<pattern>"`); the access log cuts the uri at 300
  characters (`multi_regexp`; a padded one made a line past journald's 48K `LineMax`, which split
  it and hid the 401); `halosctl fail2ban` survives a failing client (set -e) and `unban` needs
  dots or a colon (hex letters alone would be looked up as a name). Whether a wrong key (not only
  a missing one) gets 401 is not in Halogen's docs: to confirm on freyja.
  Not done, for the owner: the `nftables` action (cuts open connections, cheaper bans, needs
  `CAP_NET_ADMIN` and a bench), `LineMax`/`max_header_size` against 48K line splits, more sandbox. Client text (the
  uri) comes later with its quotes escaped, so it can't forge that field; the Containerfile runs
  `fail2ban-client -t`, checks both jails in `-d`'s output and runs `fail2ban-regex` on a 401 line
  and a forged one. `fail2ban.d/50-halos.conf`: `logtarget = SYSTEMD-JOURNAL`.
  `fail2ban.service.d/10-halos.conf`: `StateDirectory=fail2ban` (bootc adds nothing to `/var` on an
  installed machine, so the package's `/var/lib/fail2ban` wouldn't exist after an upgrade),
  `ProtectSystem=strict`, no home, `CapabilityBoundingSet=CAP_DAC_READ_SEARCH` (bans go to
  firewalld over D-Bus as uid 0), `MemoryMax=256M`. `halosctl fail2ban [on|off|unban <address>]`:
  the service only; `unban` passes nothing but an address; output is cut to printable text.
  Selftest `fail2ban` (both jails, a count of shut-out addresses, never the addresses). Audit watch
  `-w /etc/fail2ban -k fail2ban`. Users override in `jail.d/90-local.local`. The VM test bans and
  unbans an address (a rich rule appears and goes), and runs the filter on the front door's real
  log line with its status set to 401 (Halogen is down there, so the real status is 503). Not
  covered: the initramfs SSH unlock; TLS handshake failures; a device on a private network.

## Lessons already learned

- `setpriv` and `runuser` keep the caller's working folder. Run as halogen from an admin's home
  (`sudo` from `/var/home/<admin>`, 0700), podman stopped with "cannot chdir … Permission denied"
  (selftest `scratch` on freyja) and `find` fails, so every `setpriv … env` and halogenctl's
  `as_owner` start with `env -C /`. `podman exec` gives the command the container's
  `Ulimit=memlock=-1:-1`; outside halogen's manager (whose `user@970` drop-in already allows
  unlimited memlock) halogen can't raise its own limit, so the selftest runs it under root's
  `prlimit --memlock=unlimited:unlimited`.

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
`v0.20.0`):

- Released: `v0.20.0` (2026-11-09), the first stable on Halogen 0.20.0, promoted from `rc.2`
  (built from main at #87; `rc.1` was beta.1 unchanged). It passed freyja's checks (selftest, bench,
  `flash check`, `npu off`/`on`, tab completion, restarts, OvisOCR3 `model pull`), and freyja was
  reinstalled with the guided installer (#42), which wiped `/srv`, so its settings were set again.
  On edge since: the tokenizer fill-in for checkpoints that ship none (#88). The issues for #14, #15,
  #40 and #56 are closed. Freyja serves the official checkpoint or its own (Signal-3.8-Flash-Next-HGN-v2),
  swapped as needed, at the `performance` profile.
- Next: clevis/tang (#44), GGUF in `flash pull` (#61).
- **Halogen 0.20.0** (stable since `v0.20.0`): 0.20.0 (ROCm 10.1 in its image, OvisOCR3 document parsing on the NPU as your
  own checkpoint, faster prefill, a strict-tool-call crash fixed; the Flash checkpoints and weights
  revision unchanged) is pinned by #78. Between source commits 47ceb43 and 8242b15, FLAGS.md,
  `deploy/entrypoint.sh` and host-setup's requirements are unchanged (only image tags in examples),
  so `options.allowed`, `halogen.env.default`, the Quadlet and kernel arguments stay as they are.
  OvisOCR3 (`ATH-MaaS/OvisOCR3`, 1.7 GB safetensors) goes through `model pull` into `custom` (the
  probe's base is `ovisocr3`, confirmed on freyja, not LFM or decider; its NPU programs in `models.txt` have no pinned revision, like
  `halogen-spotter-0.6b`, so an upstream push to them breaks the fetch's hash check), served as
  `OvisOCR3` from `/models/custom/OvisOCR3`; INSTALL mentions `HALOGEN_WEIGHTS_LOCK=1` (already
  allowed) beside it.
- **Halogen 0.20.1** (#95, on edge, not yet released): reply-end prompt-cache entries by default
  (one more entry per slot, about 112 MiB each; `HALOGEN_CACHE_REPLY` is read by
  `deploy/entrypoint.sh` but isn't in FLAGS.md, so it isn't allowed here), `HALOGEN_FORK_MAP=auto`
  retired (accepted and ignored), `HALOGEN_FORK_AUTO_KEEPS`/`_AUTO_END_ONLY` no longer read (the
  first dropped from `options.allowed` and the templates; `render-config` drops it from an old
  `halogen.env`). Between source commits 8242b15 and d2f4286 only that entrypoint line, FLAGS.md's
  fork rows and image tags in examples changed: Quadlet, kernel arguments, host-setup, the Flash
  checkpoints and weights revision stay. The image's `/opt/halogen/npu/models.txt` is byte-identical
  to 0.20.0's (read from the layer, anonymously from ghcr.io), so no NPU program downloads again.
- **Halogen 0.20.2** (#100): a little faster with concurrent requests and on long conversations'
  first token, and `d3-lite` 14 to 18% faster on the NPU (whether its NPU programs changed, and so
  download again, wasn't checked: the image's `models.txt` wasn't compared with 0.20.1's; the
  fetch checks whatever it downloads against it). Between source commits d2f4286 and
  2e05e1f, FLAGS.md and host-setup's requirements are unchanged (only image tags in examples), so
  `options.allowed`, the templates, the Quadlet and kernel arguments stay. `deploy/entrypoint.sh`
  passes two more names through, `HALOGEN_RENDER_ONCE` and `HALOGEN_TOKENIZE_SPLIT`, which aren't
  in FLAGS.md, so they aren't allowed here (as `HALOGEN_CACHE_REPLY`). The Flash checkpoints and
  weights revision are unchanged.
- **Halogen 0.20.4** (#111, includes 0.20.3): `d3-nano` 7 to 9% faster on the NPU (0.20.3); short
  follow-up turns read 15 to 50% faster, 10 to 20% more throughput above 8 KV slots, and
  `tool_choice: "none"` no longer leaks `<tool_call>` markup (halogen-flash-server#253). Between
  source commits 2e05e1f and de6e7f8, FLAGS.md is unchanged and host-setup changes only image tags,
  so `options.allowed`, the templates, the Quadlet and kernel arguments stay. `deploy/entrypoint.sh`
  passes one more name through, `HALOGEN_TOOL_NONE_MASK`, not in FLAGS.md, so not allowed here (as
  `HALOGEN_CACHE_REPLY`). The Flash checkpoints and weights revision are unchanged. The image's
  `models.txt` differs from 0.20.2's only in `d3-nano`'s NPU programs (new revision, about 135 MB,
  fetched again only where `d3-nano` is in `HALOGEN_NPU_MODELS`; not in the default templates).
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
