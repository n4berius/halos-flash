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
- Releases are cut by the owner (Actions > Release > Run workflow, picking alpha, rc or
  stable; `scripts/next-tag.sh` numbers it, and rc/stable promote the newest published
  release one step below: rc the newest alpha, stable the newest rc. No beta step since
  November 2026 (owner's decision, #141); old beta tags stay and the `beta` channel tag moves with
  every rc and stable, so `halosctl switch beta` still works (with a note) but isn't offered).
  Tags are `v<Halogen version>-<halOS number>-<stage>` (`v0.20.7-1-stable`, `v0.20.7-2-alpha`;
  owner's decision, #168): an alpha takes the next halOS number of versions.env's Halogen version
  (over every stage, published or not; restarts at 1 per Halogen version), rc/stable keep the
  number they promote (from main: the next number). Order (`channels.sh`, also `--sort [stage]`,
  which next-tag.sh and refresh.yml use): version, number, stage; old-style tags (`-alpha.N`,
  `-rc.N`, bare, `-rN`) count as number 0, so the first new-style tag passes them. An existing
  promotion tag with no release, on the same commit, is run again (`retry=1`), never renumbered.
  New-style stables push their own exact tag; the plain version tag (`0.20.7`) moves in the
  channels job only with the stable channel, and is what refresh.yml rebuilds. A hand-pushed tag
  must be new-style. Nothing on a machine compares versions: bootc follows tags by digest, and
  halosctl only checks the shape (`rollback --to`, `npu`). `rollback --to <X.Y.Z>` follows the plain tag (no digest pin), like `npu` does; every other `--to` pins by digest, and `npu on|off` keeps that exact release. Don't create tags or releases yourself.
- If GitHub or a registry refuses an action (403 from the session proxy), stop and tell the
  owner. Don't work around it.
- Run `tests/run.sh` before every push. CI also runs shellcheck, which may not be installed
  locally.

## Layout

| Path | What it is |
|---|---|
| `versions.env` | Every pinned input: Fedora base, kernel-next's test kernel, Halogen version, digest and source commit, upstream file hashes, weights repo and revision, ISO builder, bf16-to-hgn and halogen-dashboard commits |
| `Containerfile` | The OS image. XRT is not in it: Halogen's image carries its own since 0.19.1 |
| `Containerfile.helpers` | bf16-to-hgn, halogen-dashboard (+ `dashboard-nodump.so`) and Caddy, built from source (#122). `scripts/build-helpers.sh <dir>` builds it on the base by digest into `<dir>/tree` and records `<dir>/inputs` (the versions.env base, its digest and version label, both commits, a hash of its sources); each stage's `toolchain.txt` (#121) travels in the tree; `build.sh` takes `HALOS_HELPERS=<dir>` (else builds it first), refuses a folder whose inputs differ (`--check`), passes it as `--build-context helpers=` and builds the OS image on that same digest, so the libraries match. `build.yml`'s `helpers` job (beside `check`, also the change detection) builds it once and hands it to the four image jobs as a tar artifact of the run (a zip drops modes); no cache crosses runs. Locally, the caddy stage reuses its Go and module layers after a source-only change (`go.mod`/`go.sum` copied first, the source built with `GOPROXY=off`) and keeps Go's compile cache in a podman cache mount (`halos-caddy-go-build`; the tests are compiled with `go test -c` and the binary run directly, so they always run: plain `go test` reused a cached pass after a comment-only change); bf16-to-hgn's and the dashboard's compilers are installed before their commit `ARG`; the caddy step runs the test binary and Caddy as nobody, who can't write to that cache (Go trusts an entry by its key). `release.yml`, `refresh.yml` and `iso.yml` still build it inside each job |
| `Containerfile.installer`, `installer/` | The live installer image, Anaconda defaults (storage layout for custom partitioning), branding and boot menu. `installer/guided/`: the guided install's kickstart and `plan-install` (#42) |
| `files/` | Copied into both editions: systemd units, `halosctl`, `halogenctl`, `halogen-enroll-tpm` (bash completion for all three in `usr/share/bash-completion/completions/`; `tests/completion.sh` fails when a tool gains a top-level command, or a `flash`/`model` subcommand, its completion doesn't offer; checkpoint folder names are written by halogen and its containers, so they are never passed to `compgen -W`, which expands `$(...)`: only plain names, matched by hand; under sudo completion runs as the admin, who can't read `/srv/models` (0750), so the names come from `/run/halos/model-names` (`model-names`, root, run by login-status every 30 s and by halogenctl's `names_now` after a pull or removal: `find` as halogen with setpriv, folder and `*drafter*.hgn` names only, never file contents; plain names, no line breaks; each `find` under root's `timeout -k` and cut at 1000 entries, one per folder; start points are the folders, so a link at `flash` is never followed; 0640 group wheel), while a root shell reads the folders directly), `/usr/libexec/halogen/*` (`flash-checkpoint` and `model-pull` download your own checkpoints) |
| `variants/npu`, `variants/no-npu` | Per-edition kernel arguments, Quadlet drop-ins, the allowed-options list and default `halogen.env` |
| `scripts/` | `build.sh`, `build-helpers.sh`, `build-info.sh` (an image's build record, #121), `build-iso.sh` (`installer` or `iso` builds one half: `iso.yml` builds the installer image beside the OS image, on the base `build-helpers.sh --resolve` prints, passed to both as `HALOS_BASE`), `ci-background.sh` (runs a slow CI step in the background and waits for it later: `iso.yml`'s disk cleanup, VM tools and ISO builder pull), `package-iso.sh` (single-file release ISO), `release-info.sh`, `gen-options.py` (options from upstream `FLAGS.md`), `halogen-update.sh` (pins a new Halogen release), `size-report.sh`, `channels.sh` (which channel tags a release moves), `next-tag.sh` (the next release tag), `push-image.sh`, `sign-image.sh` (cosign signing), `kernel-next-update.sh` (moves kernel-next's pin to Fedora's newest plain build), `searxng-update.sh` (moves the bundled web search's SearXNG pin to its newest dated release), `go-test.sh` (the Go tests of `src/caddy` without an image build; needs network; CI's `check` job in `build.yml` runs it and `tests/run.sh` once, and both edition builds wait for it, #123) |
| `files/usr/share/halos/search/`, `files/usr/libexec/halogen/search-*` | Web search (`halogenctl web-search`): SearXNG's settings template, the relay's Caddyfile, and the helpers that make the settings file and the relay's image |
| `files/usr/libexec/halogen/settings-tui`, `files/usr/share/halogen/npu-models.list`, `files/usr/share/halogen/option-kinds` | The settings screen behind `halogenctl settings` (Python curses), its list of Halogen's NPU models, and what each option takes (from FLAGS.md; check it with every Halogen pin) |
| `docs/` | `GUIDE.md` (using the machine: settings, updates, each feature and its reasons; INSTALL.md holds only the installation, first boot and disk unlock), `CLI.md` (every command; update it with a command or option), `CLIENTS.md` (connecting apps and coding agents, and trusting the certificate per agent, from each project's docs and source) |
| `CHANGELOG.md`, `ROADMAP.md` | What each release changed (PRs add to Unreleased), and the order of the work ahead |
| `src/` | halOS's own source: `dashboard-nodump.c` (built in `Containerfile.helpers`' dashboard stage), `authenticode-check.py` (kernel-next's Secure Boot check at build time) and `caddy/` (`main.go`, `go.mod`, `go.sum`: Caddy with the DNS providers, built in the caddy stage; Dependabot `gomod`) |
| `tests/` | `run.sh` (fast checks, no GPU or network), `iso-install.sh` + `vm-login.py` (QEMU install test) |
| `.claude/skills/ste100/` | Write or rewrite user documentation in ASD-STE100 Simplified Technical English (#152): the rules, what never changes, and `check.py` (code, inline code, links and numbers as on main; every `#anchor` link resolves). Not for CLAUDE.md or `.claude/agents` |
| `.claude/agents/` | Subagents: `code-reviewer` (QA review before merge) and `security-auditor` (audit, zero-cost hardening ideas). Both only read and report |
| `.github/workflows/` | `build.yml` (image, edge tag; also weekly, Thursday 05:37 UTC; pull requests and other branches run job `build`, read-only; main runs `publish`, the same steps by YAML anchors plus Push and Sign, with `packages`/`id-token: write` and the signing environment), `iso.yml` (ISO + VM install test), `release.yml`, `refresh.yml` (weekly rebuild of stable), `halogen-update.yml` (daily: opens a PR for a new Halogen release), `kernel-next-update.yml` (weekly: a PR for a newer test kernel), `searxng-update.yml` (weekly, Wednesday 06:41 UTC: a PR for a newer SearXNG) |

## How the running system works

- Halogen runs as the rootless `halogen` user (UID 970) through a Quadlet in
  `/etc/containers/systemd/users/970/`, with linger on. `halogenctl` wraps it, so run it with
  `sudo`. `halogenctl model pull|list|remove` manages your own NPU checkpoints. `halogenctl selftest`
  (`/usr/libexec/halogen/selftest`, root) runs the hardware checklist read-only; the VM
  install test runs it too and checks what a VM can pass.
- First boot: `halogen-prepare` (root) creates `/srv/models`, `/srv/configs`, `halogen.env`
  and the API key. `halogen-fetch` (user) pulls the pinned image, downloads models with `hf`
  inside that image, and runs Halogen's `verify`. Then `halogen.service` starts with the models
  read-only and never downloads (its container is on `halogen-internal`, see "Outbound network" below; before #120 it had network, audit F). Each restart of `halogen.service` reruns the fetch, which only downloads what's
  missing or changed.
- `halos-status.timer` runs `login-status` (root, sandboxed, writes only under `/run`) every 30 s:
  one line in `/run/issue.d/50-halos.issue` for the console login screen (agetty's `\4` fills
  in the IPv4 address; `agetty --reload` redraws on a change), the same with the hostname plus
  `halosctl version`'s channel/staged/rollback lines (cached 10 min) in `/run/motd.d/50-halos`
  for SSH, and one `wall` per boot when `/health` first answers. It reads as halogen with
  `setpriv` and `systemctl --user` on `/run/user/970`, not `runuser` or `--machine=halogen@.host`:
  both of those open a full PAM login (logind session, lastlog write, journal lines), far too much
  every 30 s. When `/health` answers it asks the service manager nothing else. Every run it also runs
  `model-names` (a few `find`s as halogen, each cut at 1000 entries) for tab completion under sudo. Before setup it says "waiting for setup".
- First-boot setup (#43): `prepare` touches `/var/lib/halogen/setup-pending` only when
  `halogen.env` doesn't exist yet (a new install, never an upgrade). `fetch-models` waits while it
  exists, up to `HALOGEN_SETUP_WAIT_S` (1800 s, counted with `$SECONDS`, not the marker's mtime:
  the wall clock jumps at first boot), then removes it and starts with the defaults. `sudo halosctl
  setup` asks TPM unlock (`halogen-enroll-tpm`), HF token (`halogenctl hf-token`), and editing
  `halogen.env` the sudoedit way (root edits a private copy, written back as halogen; never an
  editor as halogen on root's tty), then removes the marker; `--skip` removes it at once. Step 4 (#145, #102's last step) offers HTTPS:
  it reads `https mode`; when `off` it asks, Enter = yes only while root's own
  `/var/lib/halos/new-install` is there (a regular file owned by the running user, `-O`; prepare
  writes it as root beside `setup-pending`, `ReadWritePaths` gained `/var/lib/halos`; halogen's
  `setup-pending` was the first version's signal, but it goes after 30 minutes or `--skip` and
  halogen can make or remove it: code review and security audit), removed once step 4 has run, so an
  upgrade or a later run defaults to no. Then it runs `"$0" https self-signed --yes` (no test hook:
  `tests/setup.sh` drives the real switch through fake `https`, `systemctl`, `curl`; the whole
  switch with its revert if Caddy doesn't come up; only the front door restarts), and a failure
  doesn't stop setup: it reads the mode again and says off, on-but-something-failed, or other;
  `invalid` gets its own line; any other mode is left alone; `--skip` never touches HTTPS. `show`
  now says to trust the authority per app, not in the system store (the guide's advice).
  `tests/setup.sh` pads every answer list with two closing `n` lines: `script` never passes the
  end of input on, so a question a test doesn't name would wait forever. The VM test still skips
  setup and turns self-signed on with its own step. The VM
  test checks the pending line, then skips. On the serial console, `agetty --reload` can swallow
  output written while the status changes, so the VM test saves such output to a file and prints
  it later.
- Settings screen (`halogenctl settings`): `/usr/libexec/halogen/settings-tui`, halOS's only
  Python helper (`#!/usr/bin/python3 -I`, the stdlib's curses; the Containerfile checks the import;
  `tests/static.sh` parses it instead of `bash -n` and skips it in shellcheck). halogenctl (root)
  reads `halogen.env` as halogen into a `mktemp -d` folder with a `state` file of plain names only
  (running, chosen checkpoint, own checkpoints with `verified` and `drafter=` files, `flash-drafter`
  lines, downloaded `npu/*`, own `decider|LFM|custom/*`), runs the screen on root's terminal (it
  never opens halogen's files; everything it draws is cut to printable characters), and applies its
  answer: `env.new` (the whole file, edited line by line: the last active line replaced, older ones
  commented, `#KEY=` uncommented, else appended under a marker; an empty entry or `r` = the
  template's own value (halOS's, else commented out keeping the old value: `#KEY=old`); read as a
  plain file of at most 1 MiB) written back as halogen through its own `mktemp` name, only if the
  file still matches what was read (else exit 1 before any checkpoint switch or restart);
  `choices` (`flash`, `drafter`, `restart`) through `flash-checkpoint use|drafter` (their own locks
  and checks); then `gpu_lock` and one `start_halogen restart` when asked. Exit 3 = nothing to save.
  The NPU checklist comes from `files/usr/share/halogen/npu-models.list` (from Halogen's NPU.md:
  update it with a Halogen pin that adds models) plus own checkpoints and any name the file already
  has (kept, never dropped); no `:fast`/`:qad` forms yet. `halogen-spotter-0.6b` is left out
  (`GUARD_ONLY`: only the agent guard uses it, and `HALOGEN_AGENT_GUARD` adds it at start); a file
  that names it keeps it, unshown, also through `d`. Options, sections, descriptions and
  defaults are parsed from the edition's template (`Default:` in the line above each option);
  `COMMON` lists the "Common settings". `--batch` (stdin commands) is for `tests/settings.sh`, which
  also drives the real screen in a pty (`xterm` keypad sends `ESC O B`, so the test types `j`).
  `--editor` is setup's old step 3 (sudoedit-style).
  What each option takes (#179): `files/usr/share/halogen/option-kinds` (tab-separated: name, kind
  `onoff|choice|int|dec|form|text`, accepted values/range/regex/length, presets, hint), read by hand
  from FLAGS.md 0.20.7 and passed as `--kinds` (halogenctl: `HALOGEN_OPTION_KINDS` test hook).
  On/off and choices open a pick list (with `default`), numbers and forms a list of presets plus
  `type a value`, text the line editor; a typed value is asked again until `Kind.check` accepts it,
  and batch `set` exits 2 on a refused one. A value already in the file that fails is shown with
  its reason and left alone. Without the file every value is typed and checked only for one line.
  `--check-kinds` (in `tests/settings.sh`, both editions) needs a line for every template option,
  presets and halOS's template values that pass; the test also refuses lines for options no edition
  allows. So a Halogen pin that adds an option fails the tests until option-kinds has its line.
  `halosctl setup` step 3 runs `halogenctl
  settings --no-restart` (Enter = yes while setup is pending) and asks to restart at its end.
- Settings: users edit `/srv/configs/halogen.env` (or use the settings screen above). `render-config` keeps only the names in
  `options.allowed`, and `locked.env` wins over it. `halogenctl config` shows the result.
  `halogen.env` is copied once and never changed by halOS. `prepare` rewrites
  `/srv/configs/halogen.env.example` (the edition's template) at every boot, `halogenctl options
  [--new]` lists every option as set, commented or new, and each release attaches both editions'
  templates as `halos-flash-<tag>-<edition>-halogen.env.example`.
- API key switch: `HALOGEN_API_KEY_FILE=/run/secrets/halogen-api-key` left `locked.env`; `render-config`
  sets it unless root's `/etc/halos/api-key-off` is a regular file (anything else keeps the key; halogen
  can't write `/etc/halos`; a fixed path, no variable: render-config runs under halogen's manager, whose
  environment halogen can set, security audit; `tests/config.sh` runs a `sed` copy), and drops `HALOGEN_API_KEY`/`_FILE` from `halogen.env` (also blocked in
  gen-options). `halogenctl api-key [status|on|off [--yes]]` (bare still prints the key; on/off need root,
  ask `is-active` over halogen's own socket, take the GPU lock before writing when Halogen runs, and
  restart only a running Halogen; `mv -T`, then a check, so a folder at the name never reads as "off"). The key file and its mount stay, so the dashboard, bench and the
  selftest keep sending it (Halogen's docs say it then checks no key; unconfirmed on freyja that a key sent anyway is accepted). Selftest `api-key`: a request with no key to 18731
  must get 401 while on (200 FAILs); off WARNs, and says "still asks" on a 401. A rollback to an image
  from before the switch has the key in `locked.env` again, so it is on. Halogen's docs: no key is
  required unless one of the two is set (FLAGS.md, configuration.md). Left for the owner (audit): Caddy
  accepting 8731 only from private ranges while off, `/metrics` blocked on 8731, a login-screen note.
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
  identical to the official one is copied (a reflink, #131), not downloaded. `fetch-models` re-verifies the
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
  results go to `halos.info` (`checked_*`) and `check.json`.
- GGUF repositories (#61): `flash pull` turns to `gguf_pull` when the repository has no `.hgn`
  candidate and has `*.gguf`, or `--file` names a non-`.hgn`. `gguf_builds` groups files (any
  folder depth) into builds, a split `<base>-NNNNN-of-MMMMM.gguf` only when complete, skipping
  `mmproj`/`draft`/`imatrix`; `--file` takes a build name or any of its files. Names matching
  `gguf_refused_re` (Q4_1, plain Q5_0 and Q6_K, Q2_K, Q3_K, IQ1, IQ2, TQ, BF16/F16/F32: Halogen's
  gguf.md, or larger than RAM) are refused before any download; `.gguf` is matched case-sensitively. Work folder `flash/.convert/<name>` (shared with `flash convert`, so
  `convert-stop <name>` deletes it; each refuses the other's `convert.info`/`gguf.info`):
  `gguf/` (shards at the exact commit, only those not already there at their size), `head/`
  (`qwen38-flash-next-mtp.hgn` from `HALOGEN_WEIGHTS_REPO` at the pinned revision, sha256 from
  the same HfApi listing; halOS's fetch doesn't otherwise download it), each a mount of its own
  for the download container, then links, FIFOs, hard links and strays swept, each shard hashed
  (a mismatch is deleted). Space: download + GGUF size + 32 GiB. Convert: Halogen's
  `convert IN OUT` through `offline` in `gguf_convert` (named `halogen-pull-flash-<name>`, `--replace`,
  client in the background with traps that remove it, as `online`; GPU devices as Halogen's docs run it, no network, models
  read-only) with `--oom-score-adj=1000` (Halogen keeps serving; 137 says stop Halogen and pull
  again), `HALOGEN_MTP_HEAD` set, writing `out/<name>/model.hgn` (the only writable mount; anything
  else it leaves is removed, `HGN1` checked), `mv -T -n` to `flash/<name>` (refused if it exists),
  `halos.info` with `gguf=` and `converted_with=`, then `verify_dir` (which copies the official
  tokenizer). No vision tower. Only after verify passes is the GGUF deleted (unless `--keep-gguf`);
  a failed convert or verify keeps it. Folders a container owned are opened up (`open_up`, `chmod -R
  u+rwX`) before a sweep or `rm -rf`. `halogenctl flash convert-stop <name>` deletes through
  `flash-checkpoint convert-clear` under the name's lock (it used to `rm -rf` as halogen unlocked).
  Not run on freyja yet: the conversion's memory and GPU use beside a serving Halogen, its time.
  Narrower convert container (owner agreed, merged only after a freyja try): `gguf_convert` runs
  its own `podman run` (not `offline`): the work folder `flash/.convert/<name>` read-only at
  `/models` (Halogen's image has `/models`, so nothing is made under `--read-only`'s root),
  `out/<name>` writable at `/models/out/<name>` (its mount point stands in the work folder),
  scratch as in `halogen.container` (`--read-only --read-only-tmpfs=false --tmpfs /run`, anonymous
  volumes `/tmp`, `/var/tmp`, `/root` on disk, `-v /dev/shm:/dev/shm`), both mounts
  `noexec,nosuid,nodev`, `model.hgn` chmod 0640 after the HGN1 check, paths `/models/gguf/…` and
  `HALOGEN_MTP_HEAD=/models/head/…`; GPU devices and `--ipc=host` stay (whether repack needs them:
  freyja). `tests/static.sh` exempts that
  one line from the prompt-cache mount rule. Left for the owner (security audit of #160): the draft
  head's sha256 in `weights.sha256` (needs huggingface.co, which the review session couldn't reach).
  GPU: `flash-checkpoint`'s `gpu_work` (halogen's
  `$HALOGEN_STATE_DIR/gpu-work.lock`, fd 6, closed for podman like fd 9): a conversion waits for
  it, `check-prepare` and `check` refuse with 75 while a conversion holds it (halogenctl's
  `gpu_lock` is root's and covers only its own commands).
- Draft heads for own Flash checkpoints (owner's choice: official by default, a third party's when
  chosen): Halogen 0.20.7's entrypoint (`drafter_head`) uses `qwen38-flash-next-drafter-r2-ht4.hgn`
  beside the checkpoint only when `HALOGEN_CK_OVERLAY` is unset and the checkpoint's basename is
  `qwen38-flash-next-*.hgn`, and then also sets `HALOGEN_MTP_GATE_RULE=cost` and
  `HALOGEN_SAMPLED_GATE=cost`; own checkpoints (`model.hgn` etc.) got nothing. `render-config` now
  names `/models/<that file>` in `HALOGEN_CK_OVERLAY` for an own checkpoint, with both rules
  (`SAMPLED_GATE` only if halogen.env doesn't set it), unless `/srv/configs/flash-drafter` has
  `<name>=off` (built-in head) or `<name>=<file>`: a draft head file the pull listed as `drafter=` in
  `halos.info` (repo files matching `*drafter*.hgn`, hash-checked, not given to verify; a copy of an
  official draft head is reflink-copied, not downloaded), a plain file starting `HGN1`, else the
  official one. Skipped (built-in head) with a quality sidecar `<ckpt>.overlay.hgn` (`CK_OVERLAY`
  holds one file), a converted GGUF (header bytes 40..103 say gguf, as `check_sidecar` reads), a
  missing/linked official file, or `HALOGEN_CK_OVERLAY=none` in halogen.env (wins). `flash drafter
  <name> [official|off|<file>]` writes the line through `flash-checkpoint drafter` (name lock plus
  `flash-drafter.lock` for the shared list; `official` drops the line); `flash remove` drops it.
  #170: the name is optional (one argument that isn't a checkpoint is the choice for the served
  one); `official-r2` (stored as is) names 0.20.6's `qwen38-flash-next-drafter-r2.hgn` left in
  `/srv/models` (render-config: plain file, `HGN1`, else the official one); halogenctl maps file
  names and paths (`/srv/models/<official name>`, `/srv/models/flash/<name>/<listed file>`, `/var`
  prefix too) to choices, a bare official name preferring the checkpoint's own listed file, and
  refuses anything else with the choices; `valid_name` refuses `off` and `official-r2` as names.
  With an explicit `CK_OVERLAY` path the entrypoint prints `overlay <path>`, not `draft head`; the
  selftest's `draft-head` reads Halogen's journal since `ExecMainStartTimestamp` (`--timestamp=unix`).
  Also skipped unless `halos.info` has `own_precision=1` (`verify_dir` records `flash_serve
  --resident-gib`'s third field: with a w4b-style checkpoint `CK_OVERLAY` selects the precision
  sidecar; pulls from before need `flash verify` once). `verify_dir` skips only `*drafter*.hgn`
  names listed as `drafter=` and never the `checkpoint=` file. For a checkpoint named
  `qwen38-flash-next-*.hgn` with a drafter under Halogen's names beside it (Peonist's layout),
  render-config says `none` (or the sidecar's path) outright where it names no draft head, since
  the entrypoint's `drafter_head` would pick the folder's file over off or a sidecar (code
  review). Pull removes links, hard links and non-files at `*drafter*.hgn` before its container
  gets the folder and before hashing (security audit). Left for the owner (audit P1, from before
  this): a failed pull leaves `halos.info` that its container could have forged.
  Whether the official head speeds up a fine-tune is unmeasured (bench on freyja).
- Unlock from a tang server (#44, clevis): owner's default is "TPM and tang" on a machine with a TPM
  (`halosctl tang-unlock on <url>... [--tpm and|or|off] [--thp <S256|S1>]...`; tang alone without a
  TPM). `/usr/libexec/halogen/tang-unlock` (helper) makes one clevis binding per server on
  crypttab's first volume: `and` = `sss {"t":2, pins: {tpm2: PCR 7 sha256, tang: [...]}}`, `off`/`or`
  = plain `tang`; any server unlocks alone. It checks the passphrase first (`PASSWORD` or a prompt,
  piped to `clevis luks bind -f -k -`; never `-y`, which skips clevis's thumbprint check), binds the
  new ones, then unbinds the old clevis tang slots (a failure unbinds what this run made); `and`/`off`
  then remove systemd's TPM token (`luksKillSlot -q` + `token remove`, no passphrase needed), `or`
  enrolls it when missing. The mode is read back from the header: `sss` with tpm2 = and, else a
  systemd-tpm2 token = or, else off. halosctl fetches `<url>/adv` (curl, `--proto =http,https`) and
  refuses `.local` names (no mDNS at boot) and shows the S256 thumbprints to compare with `tang-show-keys`, or takes `--thp` (S256 or S1); `--yes`
  needs `--thp`. `renew` rebinds the same servers and mode (after a PCR 7 change in `and`).
  `halogen-enroll-tpm` refuses beside `and`/`off`; setup's step 1 then skips the TPM offer and
  offers tang (default no) before SSH. Selftest `luks-tang` (PASS when every server answers `/adv`
  now, WARN otherwise; `luks-tpm` says "no TPM-only unlock" then). Initramfs: dracut modules
  `90halos-initrd-net` (network up/teardown, mask of `nm-wait-online-initrd`, shared with SSH
  unlock) and `90halos-tang-unlock` (depends on clevis, clevis-pin-tang/-sss/-tpm2; removes clevis's
  `cryptsetup.target.wants/clevis-luks-askpass.path`, so other machines boot as before;
  `halos-tang-unlock.service` waits up to 60 s for a crypto_LUKS device, greps `clevis luks list`
  for `tang`, then `halos-initrd-net up` and starts `clevis-luks-askpass.path`, whose agent retries
  every 0.5 s while the prompt waits; `SuccessExitStatus=SIGTERM`: switch-root stops it, often within a second
  on freyja's TPM unlock, and a oneshot killed by SIGTERM is otherwise "failed", listed at every login;
  `tests/static.sh` checks every initramfs oneshot that conflicts with switch-root). No kernel arguments. The Containerfile installs clevis,
  clevis-luks, clevis-dracut, clevis-systemd and tpm2-tools and checks the initramfs. VM test
  (NPU, LUKS): Debian's tangd as QEMU `guestfwd=tcp:10.0.2.100:80-cmd:tangd <keys>`, keys made by
  `tangd-keygen` on the runner, through a wrapper that sends tangd's stderr to `tang.log` (QEMU's `cmd:`
  gives the child the guest's socket as stderr too, and tangd logs each request before replying); third boot binds (and renews), fourth unlocks with no passphrase
  typed (`TANGJ`), fifth (no guestfwd) must ask. Not run on freyja yet. Security audit fixes: with
  several signing keys the person pastes the one `tang-show-keys` prints (never the first listed);
  any systemd-tpm2 token beside a tang binding reads `or`; `mode` exits 3 (`unknown`) on clevis tokens
  it can't read and halogen-enroll-tpm then refuses (fails closed); `PASSWORD` is unset after reading
  and not documented for users (sudo argv); the initramfs counts only non-removable, non-USB LUKS
  devices (USB asked with `lsblk -rsno TRAN`, the device and every device under it: lsblk reads TRAN
  through a `device` link a partition lacks, so a partition's own was always empty and USB
  partitions passed; whole-image audit, #165; SSH unlock's module and helper the same). Hardening
  (owner agreed, after #165's audit): `bind` with `and`/`or` and `halogen-enroll-tpm` refuse while
  Secure Boot is off (`tang-unlock secure-boot` reads the `SecureBoot-8be4df61-…` efivar's byte 5,
  `HALOS_EFIVARS` hook); only S256 thumbprints (43 base64url characters; `thumbprints` prints S256
  only); `bind` writes `/var/lib/halos/tang-unlock.keys` (`<url> <thp>` per line, root, 0600)
  after success, since `clevis luks list` shows only the url; `tang-unlock bound` prints it only
  while its url set equals the bound one; `renew` takes those keys without asking and refuses a
  server whose `/adv` no longer lists one (hint: `on` with the new key); the selftest's
  `luks-tang` WARNs on such a server; `/adv` is fetched and read by curl and jose as nobody
  (`setpriv --reuid=65534 … --no-new-privs`, skipped with `HALOS_FETCH_AS_ROOT=1` for the tests);
  an INT/TERM/HUP during `bind` unbinds what this run made (`undo_new`, plus a TPM token an `or`
  bind added) and keeps the old; after the new bindings are made, signals are ignored until the
  old slots and the TPM-only unlock are gone. Review fixes: every pair is checked before the first
  bind; `bind`/`remove` take `flock -n` on `<record>.lock` (two admins at once would remove each
  other's slots); the nobody fetch runs under `setsid -w` with no terminal on any fd (a hijacked
  curl/jose could otherwise take root's tty and read the passphrase typed next); clevis itself
  still fetches `/adv` as root at bind; a failed record write deletes the record; setup skips the
  TPM offer and binds tang alone while Secure Boot is off; every "key changed" hint names the
  current `--tpm` mode.
  Test hooks under sudo: `tang-unlock` and `halogen-enroll-tpm` unset theirs, and `halosctl` and
  `halogenctl` unset every `HALOS_*`/`HALOGEN_*` variable, when `SUDO_COMMAND` is set (sudo's
  env_reset already drops them; this covers a sudoers `env_keep`); `halosctl` and
  `halogen-enroll-tpm` are `#!/bin/bash -p` like halogenctl.
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
  The tool's prompts are the same every run (`lead_line(i)`), so the prompt cache on disk answered
  every prefill from the second run on (freyja: 0.2 s at every length, 165,593 tok/s at 32K). It now
  runs through `/usr/share/halogen/bench-cold.py` (passed with `python3 -I -c`, so still no mount),
  which loads the tool as a module, prefixes `lead_line` with a per-run `Run <12 hex>. ` and wraps
  `ask` to record `timings.cache_n` of each prefill pass (one token, 256+ prompt tokens) into the
  JSON's `halos_cold.passes`; the report warns when a pass is over half cached, and only reports
  with `halos_cold` are compared. It refuses a tool without `lead_line`/`ask`/`main` (check at each
  Halogen pin). Checked against upstream's real `halogen-bench.py` and a stand-in prefix-cache server.
- `halogenctl bench tools [--quick]` (`/usr/libexec/halogen/bench-tools`, as halogen): tool-eval-bench
  (SeraphimSerapis, MIT; `TOOL_EVAL_BENCH_COMMIT`/`_VERSION`, v3.1.0) against 18731 with the key in
  `TOOL_EVAL_API_KEY`. Its Python source comes from `Containerfile.helpers`' `tool-eval-bench` stage
  (no web page; `_version.py` written there) into `/usr/lib/halos/tool-eval-bench`, run by the
  `-I` launcher `/usr/libexec/halogen/tool-eval-bench`; its libraries are Fedora's (python3-httpx,
  -pyyaml, -rich, -dotenv); the build compiles it and runs `--dry-run --short` and `--version`.
  Full = `--trials 3 --temperature 1.0 --seed 42` (johnlockejrr's leaderboard space: no licence,
  so only its settings are matched), quick = `--short`. It runs in `/srv/configs/bench/tools`
  (its own `runs/` and `data/benchmarks.sqlite` land there; it reads a `.env` there or above).
  Progress from its stderr JSON events; categories over three runs from `per_scenario` means and
  the events' scenario→category map. Earlier results are compared like `bench`'s (shape-checked,
  stamp names only). Accuracy benchmarks are next (BenchKit Apache-2.0 ships GPQA in plain text
  and runs HumanEval code on the host; lm-evaluation-harness MIT).
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
  edition, or the other kernel (`io.github.n4berius.halos.kernel`: `next` only for the kernel-next
  tags; the same key signs both, #165); NPU presence is read from PCI, 1022:1502/17f0, since
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
  hardening (after #165's audit, merged only after a freyja try: `dev.tty.ldisc_autoload=0`,
  `fs.protected_fifos=2`, `fs.protected_regular=2`, `kernel.kexec_load_disabled=1`; and more sandbox
  on `halogen-prepare` (Protect*, `PrivateDevices`, `RestrictNamespaces`, a capability set of
  CHOWN, DAC_OVERRIDE, DAC_READ_SEARCH, FOWNER, FSETID, SETUID, SETGID, AUDIT_WRITE, SYS_RESOURCE
  for its chown/chcon and runuser), `halogen-fabric-clock` (no `ProtectKernelTunables`,
  `PrivateDevices`: it writes the clock in /sys; `CapabilityBoundingSet=`, as root owns those
  files) and `halos-https-refresh`
  (`CapabilityBoundingSet=`)). The ISO builder is pinned by digest (`IMAGE_BUILDER` in `versions.env`).
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
  conflicts with `initrd-switch-root.target`) and (since #44, from the shared module
  `90halos-initrd-net`: `halos-initrd-net up|teardown`) `halos-initrd-net-teardown.service` in every
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
  (Quat3rnion, MIT/Apache-2.0, `native/` Apache-2.0) is built in `Containerfile.helpers`'
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
  `Containerfile.helpers`' `dashboard` stage from `HALOGEN_DASHBOARD_COMMIT` with Fedora's rust (1.99), nodejs
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
  in `Containerfile.helpers`' `caddy` stage from `src/caddy` with Fedora's Go, `GOTOOLCHAIN=local`,
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
  with `-k`; login-status and `halosctl dashboard` show `https://`. GUIDE.md advises trusting the
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
  GUIDE.md warns. Review and audit fixes: `dns_value_ok` (provider shapes) runs in `dns-stage` and
  again in `env` (a hand-edited token never reaches Caddy); `dns-stage` never echoes a line without
  `field=`; `halosctl` runs `https set --check` (names, email) before asking for any secret, puts
  back the credentials if `set` refuses, traps INT/TERM/HUP during the wait to revert, reads
  Caddy's errors with `jq` (escaped quotes), and drops `.prev` once the new credentials work
  (`https forget-dns` removes them all, refused while in use); `set self-signed` alone doesn't keep
  the Let's Encrypt names. A new credential is first used at Caddy's next renewal when the name
  already has a valid certificate (GUIDE.md says so). Real issuance can't run in CI; first checked
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
  401), and `CPUQuota=50%`, `Nice=10`, `TasksMax=64` in the drop-in. Known limits, in GUIDE.md:
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
  Done since in #132 (see above): the `nftables` action (cuts open connections, cheaper bans, needs
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
  log line with its status set to 401 (Halogen is down there, so the real status is 503). In the VM it runs in `fail2ban_t`, bans and unbans through a rich rule, and uses about 21 MB. Not
  covered: the initramfs SSH unlock; TLS handshake failures; a device on a private network.
- Link checks (#128, security audit of #127, owner agreed): `preflight` fails on a link, or on
  something not a folder of its own user, at `/srv/models/{npu,decider,LFM,custom}` (each is
  mounted into Halogen's container by `10-npu.conf`, three writable; the download container can
  write the top of `/srv/models`, and podman follows a link at a mount source, so `decider ->
  ../configs` would hand Halogen the keys; a missing folder passes, the edition may not use it).
  The selftest's `npu-folder` and `folder-*` FAIL on a link. `prepare` removes a link (as halogen)
  at each folder it makes before `install -d`, which followed it (changing the target's mode) and
  failed the unit on a dangling one; a deliberate link to another disk is therefore undone at boot (the
  target's contents stay): mount the disk there and chown/chcon it to halogen and `container_file_t`,
  since a fresh filesystem's top folder is root's, on which `install -d` as halogen fails and preflight's `-O` refuses. A plain file in a folder's place still fails prepare (it doesn't delete non-links); preflight names the remedy. The convert sandbox's `InaccessiblePaths` also takes `/srv/logs`. The
  selftest's `halogen-autostart` also looks in `/run/user/970/{containers/systemd,systemd/user,
  systemd/user.control}`, and `prompt-cache` reads the generated unit: two cache mounts FAIL, and
  an off drop-in the unit doesn't follow WARNs (halogen's own Quadlet folders override root's
  same-named drop-in, so the file alone isn't proof).

- Hardening round 3 (#130, security audit of #128 and the NPU-folder item, owner agreed):
  `DenyUsers halogen` in `sshd_config.d/00-halos.conf` (a key planted in `/var/lib/halogen/.ssh`
  could otherwise open a session for port forwarding despite `nologin`; not verified, the fix is
  free). `10-npu.conf` mounts `npu` (`ro`) and `decider`/`LFM`/`custom` with
  `noexec,nosuid,nodev`: freyja's `/proc/<pid>/maps` of every halogen process showed no executable
  mapping from them with OvisOCR3 and the NPU models loaded. The convert sandbox adds
  `PrivateUsers=yes`, `PrivateDevices=yes` and `-/dev/shm -/sysroot -/var/log` to
  `InaccessiblePaths` (the converter runs as host uid 970 in the `halogen` group, so it could open
  `/dev/kfd`, the NPU and the shm Halogen shares with the host); and it replaces
  `RestrictAddressFamilies=none` with `SystemCallFilter=~socket socketpair` +
  `SystemCallErrorNumber=EAFNOSUPPORT`: `systemd-run -p RestrictAddressFamilies=none` is refused
  with "Invalid argument" on systemd 262 (fine in a unit file), so since #97 every conversion would
  have failed at its first sandboxed step, after the download; `tests/flash.sh` fakes systemd-run
  and never saw it (code review of #130, which booted systemd in a container). The filter also refuses
  `io_uring_setup/enter/register` (the security audit made an `AF_UNIX` socket with
  `IORING_OP_SOCKET` past a socket/socketpair filter and connected out of a private network
  namespace to a socket file, which would reach the system D-Bus as halogen; bf16-to-hgn has no
  io_uring in its Cargo.lock or source at the pinned commit), with `SystemCallArchitectures=native`,
  `ProtectControlGroups` and `ProtectKernelTunables`. Left open: a hijacked converter can still
  signal same-uid processes (Halogen); `PrivatePIDs` is untested on 262. `flash-checkpoint
  sandbox-check` (halogen only, no links, `rmdir` not `rm -rf`) now runs the real `sandboxed()` call (unbound from the convert unit) with probes
  and the converter's `--help`, and the VM test runs it as halogen (`CONVSB`). The freyja maps
  check covered decider/LFM/custom; `npu` holds `.elf` NPU programs and weights, no libraries, and
  is to be confirmed with the same check before the PR merges. `halogen-autostart` also looks at `.ssh`, `mounts.conf`, `policy.json`, `storage.conf`,
  `registries.conf(.d)`, user-tmpfiles.d and D-Bus services.

- fail2ban follow-ups (#132, the audit of #129, owner agreed): bans go through fail2ban's
  `nftables` action (`banaction = nftables[type=multiport, blocktype="reject with tcp reset"]`;
  table `inet f2b-table`, chain at input priority -1, so before firewalld's
  `ct state established` accept: open connections are cut; one set per jail and family, made at
  the first ban, removed at stop; untouched by `firewall-cmd --reload`), no longer firewalld rich
  rules, and `fail2ban-firewalld` isn't installed (`nftables` is named in the Containerfile, which
  checks `nft`). The unit gets `CAP_NET_ADMIN` beside `CAP_DAC_READ_SEARCH`, plus
  `IPAddressDeny=any`, `ProtectProc=invisible`, `PrivateIPC`, `UMask=0077`,
  `SystemCallFilter=@system-service`. `halosctl fail2ban off` deletes a left-over table itself.
  Tried with fail2ban 1.1.0 and nft 1.1.6 in a Fedora 45 container (ban, unban, stop removes the
  table); under systemd and SELinux (`fail2ban_t` running nft) only the VM test shows it:
  `F2BBAN 1 2`, `F2BRELOAD 1`, `F2BUN 0`, with fail2ban's log and AVC lines printed. Caddy's
  `max_header_size 32KB` (all three Caddyfiles; Go adds 4 KB of slack, 431 above) with journald's
  `LineMax=256K`: with Caddy 2.11.9 a 36,000-character Host gave a 36.4K log line, a 40,000 one
  431 (HTTP/2: no slack, a protocol error above about 32.7K). Over HTTP/1.1 bytes that aren't
  text in Host or the method get Go's 400 before any log line; over HTTP/2 (custom-certificate
  mode) a Host of 31,000 such bytes is logged six characters each, one line of 186K, which is
  what `LineMax` is sized for. `ExecStartPre=-nft delete table inet f2b-table`: fail2ban removes
  only what it made in the same run, so after a kill an ended ban stayed (code review, run).
  The paragraph on #129 below describes the rich-rule method this replaced. Security audit of
  #132: the TLS server name isn't bounded by the header cap (60,000 bytes of 0xff in custom mode
  gave a 360K 401 line), so the log filter deletes `request>tls>server_name`; in self-signed and
  Let's Encrypt modes a request matching no site was logged by Caddy's default logger with
  headers and query in full (`x-api-key`, `?api_key=`), so both HTTPS Caddyfiles have
  `log default { exclude http.log.access }`; `banaction_allports` keeps the plain reject (a tcp
  reset rule fails for a udp/all jail). A reset reaches only the client: the server's end of an
  open connection lasts until keepalive or timeout. With SELinux, `fail2ban_t` has no
  `net_admin` itself: only `iptables_exec_t` programs (nft) get it; through nft a compromised
  fail2ban could add any table (drop everything, NAT, mirror), though not touch firewalld's
  owner-flagged one. Ideas left for the owner: hide the D-Bus socket, `~@privileged @resources`,
  firewalld `StrictForwardPorts=yes`, `resp_headers delete`, an IPv6 and an sshd ban in the VM test. Not
  measured: the extra netfilter hook's cost (bench on freyja), and a real ban cutting a real
  open connection.
- Download-path hardening (#131, security audit of #128, owner agreed): `fetch-models` first
  removes a leftover `halogen-fetch-download` container (`podman rm -f -i -t 0`; bash as PID 1
  ignores SIGTERM and the container sits outside the service's cgroup), refuses a link at
  `npu`/`decider`/`LFM`/`custom`/`flash`, and gives its download container (network, token,
  `/models` writable; `--name … --replace`) each existing one as a mount of its own (`npu`
  writable, the rest `:ro`): a mount point can't be renamed, removed or exchanged from inside
  (EBUSY, also from a nested namespace; podman 4.9.3, rootful). The top level and `npu/*` stay
  writable to it, so the host side never trusts names there: `write_new` (`rm -f`, then create
  under `set -C`) for `.fetch-stamp.new`, `.own-bases.new` and flash-checkpoint's `halos.info.new`
  (a planted `.fetch-stamp.new -> ../configs/api-key` used to replace the key with the stamp, a
  hash the container can compute); the old `npu/<version>` move deletes a link of that name;
  `fill_tokenizer` refuses a tokenizer folder holding links and copies with `cp -P`. `plain_dir`
  and `mk_plain` (a `mkdir -p` that looks at each step) in `model-pull` and `flash-checkpoint`
  refuse a bind source whose real path isn't its name under the real `/srv/models`. `flash pull`
  copies a shared official lookup table (`cp --reflink=auto`: no extra blocks on XFS, a full
  copy elsewhere) and removes a link or hard-linked table an older pull left, before its
  container gets the folder. None of this runs in the VM (no download there): freyja's next
  fetch and pull are the first real run.
- Download-path hardening, round 2 (#135, the rest of #131's audit, owner agreed):
  - When the official files (`qwen38-flash-next-v2.hgn`, `-ngram.hgn`, `-vision.hgn` when
    `HALOGEN_VISION_TOWER` is on, `tokenizer/tokenizer.json`: what `fetch-in-container` looks for)
    are all there, the download container gets `-v /srv/models:/models:ro`, with `npu` its own
    writable mount. hf with `--local-dir /models/npu/<id>` writes only under it (its `.cache` too;
    checked with podman 4.9.3 and a current huggingface_hub, not the image's pinned one). A link
    at one of those names or at `tokenizer` is removed first, so it is downloaded again.
  - When one is missing, the top stays writable for that download, and afterwards every official
    file (and each `tokenizer/*` file) is checked against `files/usr/share/halogen/weights.sha256`
    (from `scripts/weights-sums.sh`: HF's LFS sha256 at `HALOGEN_WEIGHTS_REVISION`; small files
    downloaded at that commit, checked against their git blob id, then hashed; `tests/static.sh`
    fails when the file's revision line differs from `versions.env`). A mismatch or link is
    removed (for `tokenizer/*`, `tokenizer.json` too, which is what the download looks for), the
    fetch fails without a stamp, and the next start downloads it again. About 118 GB is hashed
    then (about a minute, not measured on freyja); a fetch that downloaded only NPU programs
    hashes nothing. The check is driven by a marker, `/var/lib/halogen/weights-unchecked`, set
    before a download with the top writable and whenever there is no stamp (so the first fetch
    after the upgrade to #135 hashes everything once), removed only once every file matched: a
    fetch cut short after the files landed (an unknown NPU model is refused only after the
    weights) is checked by the next one (code review reproduced the skip). The "already match"
    exit also needs the official files there: the stamp lives on `/var`, the models on their own
    volume. A kept vision tower is hashed while the tower is off (turned on later it would be
    there, unchecked), and anything in `tokenizer/` that `weights.sha256` doesn't list is
    removed (security audit). Before the check it opens up `/srv/models` and `tokenizer/`
    (`chmod`, which doesn't follow links) and stops on any removal that fails: a download that
    planted `tokenizer -> /srv/configs` and made `/models` read-only (it owns the mount root, so
    a `--cap-drop=all` container can) had the cleanup `rm -rf` the API key through the link
    (security audit of round 3, reproduced; the test fakes the failing `rm`, since it may run as
    root). NPU programs are checked only inside the download container and by
    Halogen's own `HALOGEN_NPU_VERIFY=1` (locked) at its start, against the image's record.
    Round 3 (#136, the rest of #135's audit, owner agreed): `preflight` fails on a link at
    the official names or `tokenizer`, and on any link or non-file/non-folder under `tokenizer/`
    or `npu/` (one `find … -print -quit` each; halOS and hf make none: hf's `--local-dir`
    metadata in `npu/<id>/.cache/huggingface` is plain files), and on a folder its owner can't
    list or `find` failing (a folder made `0111` hid a link at a listed name: security audit).
    Before the download the fetch removes links at all three `.hgn` names (the tower too while
    it's off) and links or non-files in `tokenizer/` (then `tokenizer.json` too, so the same run
    downloads the tokenizer); `official_there` needs `tokenizer/` plain and no link at the tower's
    name (code review: a link there kept "already match" forever while preflight refused it).
    `top`/`weights-unchecked` depend on the official files alone; the fast path also needs
    `npu` plain and no `/var/lib/halogen/npu-unclean`, a marker set before the download and
    removed after the NPU cleanup, so a fetch cut short in between cleans next time. After every
    download fetch-models reads the pinned image's `/opt/halogen/npu/models.txt`
    (`--network=none --read-only --cap-drop=all … --entrypoint cat`) into `declare -A` sets
    (exact names: `grep -qxF` took a file name with a newline for two listed ones), opens `npu`
    up (`chmod -R u+rwX`, which doesn't follow links: the download owns its mount root and could
    make it `0555` so a planted `npu/<known id> -> /srv/configs` couldn't be removed, and the old
    `"$npu_dir"/*/` glob then walked the link and deleted the keys: security audit, reproduced),
    removes links and non-files under `npu` (any failure stops the fetch; a second `find` checks
    nothing is left), and walks each real `npu/<id>` folder the record knows (no trailing slash,
    links skipped), removing files it doesn't list (`.cache/huggingface` kept); folders of models
    it doesn't know (an older release's) stay for a rollback, since Halogen loads only known
    ones. The trade-off: a rollback re-downloads files a newer record dropped from a model both
    know (say 135 MB for `d3-nano`). The test fakes the failing `rm` (it may run as root). model-pull's
    `in_image` and flash-checkpoint's `online` are subshell functions that run the podman client
    in the background and `wait`, with their own TERM/HUP/INT traps removing the named container
    (bash holds a trap while a plain foreground command runs, and the client waits on a
    container that may ignore the signal: model-pull's `:fast` check, a plain `if in_image awk`,
    kept a stopped pull waiting; in a pipeline the main shell's trap did fire at once, which is
    why the test hangs both steps, the download and that check). `<&0` keeps their stdin (a background job's default is /dev/null).
    One `flock -n` per name (`$HALOGEN_STATE_DIR/pull-npu-<name>.lock`,
    `pull-flash-<name>.lock` for flash pull and both convert steps), taken before any container
    is removed or the EXIT trap may remove one; background progress loops close fd 9 (`9>&-`),
    or their `sleep` kept the lock for up to 10 minutes after the command ended (tests found it),
    and so does every podman call (`podman() { command podman "$@" 9>&-; }`: conmon inherited it,
    so after a hard kill a leftover container kept the name locked for as long as it ran; checked
    rootful with podman 4.9.3, rootless's pause process not checked). The lock file holds the
    holder's process group; a refused pull prints `sudo kill -- -<pgid>` when the number is above
    1, `ps -o pgid=` of it is itself (a live group leader) and `/proc/<pgid>` is still this
    user's (a pull stopped with Ctrl-C under `systemd-run --pipe` keeps running), else just
    "wait" (`1` would have printed `kill -- -1`, every process, run as root: re-review). flash
    pull refuses a `tokenizer/` that is a link before removing anything in it (the pull's
    container could leave one pointing at a folder of matching copies; the message gives the
    `sudo rm` that removes the link), and copies the official tokenizer into a checkpoint
    without one only when it holds no link. The tokenizer check's stray-file sweep (from #135)
    matches names in a `declare -A` set too (`tokenizer.json<newline>evil` passed `grep -qxF`).
    Re-review found four tests that passed without their change; each test now fails with its
    change reverted (a folder name with a newline, the listing step hung for the stop, a link
    in `npu` leaving the top read-only, the flash hint).
    `weights-sums.sh` stops on a `Link: … rel="next"` header and on `tokenizer/<sub>/…` files
    (`WEIGHTS_SUMS_OUT` for `tests/weights-sums.sh`).
  - The stamp and the checkpoint-base note are `/var/lib/halogen/fetch-stamp` and `own-bases`
    (`HALOGEN_STATE_DIR`), which no container mounts; the old `/srv/models/.fetch-stamp` and
    `.own-bases` are not migrated (a container could have forged them): an upgraded machine
    fetches (checks) once more, downloading nothing, then removes them. `prepare` still treats an
    old stamp as "not a new install", so an upgrade never waits for first-boot setup.
  - The pull containers are named: `halogen-pull-npu-<name>` (model-pull, every container) and
    `halogen-pull-flash-<name>` (flash pull's online ones), `halogen-convert-<name>` (convert-run's
    downloads), with `--replace`; a leftover is removed first and the last one by an EXIT trap
    (with INT/TERM/HUP traps that exit, so it runs). flash-checkpoint works the name out again
    in the trap (its containers run in pipelines and `$(...)`), and only a pull or a conversion
    (`ctr_owned`) names or removes one, so `verify`/`check` never touch a running pull's.

- crun 1.31 (Fedora, Nov 2026; crun#2480, podman#30265 proposed) no longer creates a missing mount
  point under a read-only root (commit ef668b8, "do not defer the read-only remount of bind
  mounts"), so podman's `--read-only` with a file mounted at `/run/secrets/…` (Halogen's key; its
  image has no `/run/secrets`) fails every start: `crun: open …/merged/run/secrets/halogen-api-key:
  No such file or directory`, exit 127. freyja's edge image from #132's merge hit it; the rollback
  (crun 1.30.1) works. The base image `quay.io/fedora/fedora-bootc:45` is a moving tag (#121), so a
  base update changes podman/crun without any change here, and the VM test never starts Halogen
  (no models). `/usr/libexec/halogen/container-check` (as halogen) imports a tiny image (Fedora's
  static `ldconfig` and the folders Halogen's image has, not `/run/secrets`) as
  `localhost/halos-container-check:1` and runs it with Halogen's shape (`--read-only --tmpfs /run`,
  scratch volumes, a stand-in key at `/run/secrets/halogen-api-key`, no network or capabilities);
  the selftest's `container-start` runs it (FAIL on 1), so the VM test does too. The image holds
  crun at 1.30.1 (`CRUN_PIN_URL`/`CRUN_PIN_SHA256` in versions.env, Koji's RPM checked by sha256,
  `dnf downgrade` after the main install, the build checks the version); 1.31's two CVE fixes
  (CRIU restore keys; deferred read-only remount target resolution) are given up until then.
  Remove the hold once Fedora ships podman#30265 or a crun fix (versions.env lists the places;
  the build log prints the base's crun). Old code rebuilt from a tag has no hold: a promotion of
  a release from before #137 would ship crun 1.31. `refresh.yml` was disabled until then; v0.20.5
  and v0.20.6 carry the hold, so it is safe again. `container-check` names its container
  (`halos-container-check`, a leftover removed first with its volumes). Security audit of #137:
  the pinned RPM is Fedora's signed copy (Koji `data/signed/f577861e/`, same header and payload
  as the base's 1.30.1; the build runs `rpmkeys -K` against Fedora 45's key besides the sha256)
  and the downgrade changes only crun; CVE-2026-115520 (CRIU) is unreachable here and no
  practical path to 115521 was found (pinned image; every mount target a direct child of a
  read-only or pinned folder); the build warns once Fedora ships crun beyond 1.31. The selftest starts container-check through `run_alone` (#138: `setsid -w` before `timeout`): code run as halogen under root's selftest could
  otherwise open root's terminal (`/dev/tty`, `tcsetpgrp`: read keystrokes, fake a prompt;
  TIOCSTI is already off). The older halogen-run selftest lines (`podman exec`, `systemctl --user`)
  have the same pattern: left for the owner to agree. Alternatives that keep 1.31, unverified: mount
  a folder with the key on an empty folder the pinned image already has and point
  `HALOGEN_API_KEY_FILE` there; or drop `ReadOnly=true`. (#137)
- fail2ban hardening round 2 (#134, the audit of #132, owner agreed): fail2ban's unit adds
  `SystemCallFilter=~@privileged @resources` (default action: a refused call kills it, so it is
  audited and restarted; EPERM would hide it; strace of a file-backend run used none of them) and
  `InaccessiblePaths=/run/dbus` (the folder: a socket made again comes out from under a mask on
  the file; masking `/run/systemd/private` too made the unit fail with 226/NAMESPACE "Failed to set up mount namespacing: /run/systemd/private: Permission denied" in the VM, so SELinux alone guards it: `fail2ban_t` has no `service` class rights) (with nft it
  never needs firewalld; root fail2ban could otherwise drive firewalld over D-Bus, which the
  policy allows `fail2ban_t`); the access log deletes `resp_headers`; the Containerfile sets
  firewalld's `StrictForwardPorts=yes` (checks the line was `no` first), so ports DNAT'd by
  others (rootful `podman -p`, or a NAT rule a compromised `CAP_NET_ADMIN` process adds) aren't
  let through by firewalld's generic `ct status dnat accept`; Halogen is rootless on 127.0.0.1,
  so nothing of halOS's is affected. The VM test also bans 2001:db8::9 on the API and
  203.0.113.10 on SSH (`F2BV6 1 1`, `F2BSSH 1 1`, lifted by halosctl: `F2BUN2 0 0`); the selftest's `firewall-ports` reads the same chain (a locally changed firewalld.conf keeps its own value through updates); the VM test checks
  `FWSTRICT` (firewalld's running `filter_INPUT_dnat` chain rejects) and `F2BSEC 1 1` (seccomp on, no bus socket in its mount namespace).

- kernel-next (#142, owner asked): `KERNEL_TRACK=next` (`scripts/build.sh`, default `fedora`)
  swaps Fedora 45's kernel for the exact Fedora 46 build `versions.env` pins (`KERNEL_NEXT_NVR`,
  `_URL` (Koji's `data/signed/<key>/x86_64`), `_SHA256` for `kernel`, `-core`, `-modules`,
  `-modules-core`: the four the base has; the build refuses any other `kernel*` but kernel-tools).
  The Containerfile step (after crun's hold, before the initramfs) checks each sha256 and Fedora
  46's signature (the base ships `RPM-GPG-KEY-fedora-46-x86_64`), `rpm -U`s them (rpm's own
  dependency check passes against Fedora 45: offline `rpm -U --test`), removes the old modules
  folder, and fails unless one kernel is left with `vmlinuz`, `amdxdna` and `amdgpu`, none of
  `PROVE_LOCKING KASAN DEBUG_VM DEBUG_OBJECTS DEBUG_KMEMLEAK DEBUG_PAGEALLOC` (Rawhide's plain
  rcN build is the non-debug one; its git snapshots are debug builds) and "Fedora Secure Boot
  Signer" in `vmlinuz`. Tried on the real base in a container (podman 4.9.3, downloads stood in):
  swap, dracut and `bootc container lint` pass; a wrong sha256 stops it. `release.env` gets
  `HALOS_KERNEL`, the image label `io.github.n4berius.halos.kernel`, the release name
  `-kernel-next`, and the selftest a "Kernel track" line. `build.yml` builds both editions with
  both kernels; main pushes and signs the test-kernel ones as `kernel-next[-no-npu]` beside edge.
  The job is named `build (<edition>)` for Fedora's kernel and `build (<edition>, kernel-next)` for
  the test one, so main's required checks (`build (npu)`, `build (no-npu)`, ruleset) keep reporting
  (a second matrix key alone renames them; code review). Both workflows set `IMAGE_TAG=kernel-next`
  on the test-kernel jobs, so its installer follows `:kernel-next`, which exists (a version-named
  tag never would).
  `iso.yml` adds an NPU-edition install test with it (`HALOS_EXPECT_KERNEL`: the installed system's
  selftest must print that kernel). `halosctl switch kernel-next` (a channel; `npu on|off` keeps
  it); releases, `release.yml` and `refresh.yml` never use it. Why 7.4 (v7.3..v7.4-rc2, torvalds
  tree): about 25 `accel/amdxdna` fixes (BO races, mailbox, use-after-free, NPU busy time in
  fdinfo) and `iommu/amd: Enable PerfOpt automatically for integrated GPUs` (b32ecac779bb), which
  applies in identity mode, so to the NPU edition's `iommu=pt`. No fabric-clock (fclk) change was
  found; Halogen's NPU.md expects that fault's fix from a BIOS/SMU update
  (ROCm/TheRock#8709), so the clock hold stays. Not measured on freyja yet.
  Follow-ups (#146, owner agreed, from #142's security audit): `src/authenticode-check.py` (python3
  and openssl only: the base has no sbverify, pesign or objcopy) replaces the signer-name grep. It
  checks the PE's Authenticode SHA-256 hash against the signed one, the messageDigest (over the
  SpcIndirectDataContent's value, without its tag and length), the RSA signature over the signed
  attributes with the signer's certificate, the chain to the CA in the base's own shim (`.vendor_cert`
  of `/usr/lib/efi/shim/*/EFI/fedora/shimx64.efi`, `fedoraca`, sha256 A3:B3:84:81:…:EF:33:2E;
  `-no_check_time`), the code-signing EKU, and `.sbat`'s `kernel.fedora` generation against the base
  kernel's (copied before `rpm -U`). Checked against Fedora's real 7.3.3, 7.4-rc2 and rc3 kernels and on the
  base in podman; `tests/authenticode.sh` signs tiny PEs with throwaway keys
  (`tests/authenticode-fixture.py`) for each refusal. The Containerfile reaches it with `RUN
  --mount=type=bind` (nothing left in the image). The base's rpm keyring starts empty (rpm 6.1,
  `/usr/share/rpm/pubkeys`); crun's and the kernel's steps `rpmkeys --delete` Fedora 45's
  (`f577861e`) and 46's (`91211fce`) keys after use. `release.env` gets `HALOS_KERNEL_BUILT`
  (kernel-core's BUILDTIME, both tracks); the selftest's `kernel-next` line is INFO, or WARN past 21
  days. `scripts/kernel-next-update.sh` (`.github/workflows/kernel-next-update.yml`, Tuesdays
  06:23 UTC, like halogen-update.yml: a PR, then build.yml and iso.yml started on its branch) reads
  Koji's listings and takes the newest `0.rcN.M.<dist>` or `M.<dist>` at the pin's kernel line or
  newer, same dist tag (a new dist's key may not be in the base), with all four packages in one
  signed-key folder; `tests/kernel-next-update.sh` fakes Koji. Against the real Koji on 2026-11-17 it
  found `7.4.0-0.rc3.26.fc46`, now the pin: Koji had dropped rc2.19's signed copies (`data/signed/`
  empty, the unsigned ones kept) within about a week, so every kernel-next build failed at the
  download (code review of #146). `release.yml` refuses a hand-pushed `*-beta.*` tag. Security
  audit of #146: `-CAfile` adds to openssl's default trust (the system's public roots), so the
  verify call takes `-no-CApath -no-CAstore` (the audit had a stranger CA in `SSL_CERT_DIR`
  accepted); the code-signing check matches the exact `Code Signing` item, not a substring
  (`msCodeInd` passed); the update script's curl calls are `--proto =https --proto-redir =https`.
  `tests/authenticode.sh` covers both (each fails without its fix) and that a changed PE checksum
  field still passes; it runs the fixture with `-B` (no `src/__pycache__`). The patched checker
  passes Fedora's real rc2 kernel against the base's shim. Left for the owner: shim's own
  revocation lists (`vendor_dbx`, `.sbatlevel`), every package's name and NVR checked after
  `rpm -U`, the update workflow's write token only in the step that pushes, picking builds by
  Koji tag instead of folder listing.

- Selftest sessions (#138, the security audit of #137, owner agreed): whatever root runs as halogen
  through `setpriv` that reaches halogen-controlled programs (podman, `systemctl --user`) runs in a
  session of its own: halogen's own podman and systemd settings decide what those run, and a
  process sharing root's terminal could open `/dev/tty`, take the foreground (`tcsetpgrp`) and read
  keystrokes or fake a prompt (TIOCSTI is already off). In the selftest `run_alone` (`setsid -w
  timeout …`): setsid goes before timeout, since GNU timeout signals its own process group and a
  child that left it took its children out of the limit (code review: `timeout 2 setsid sh -c
  'sleep 8 & wait'` returned after 8 s). halogenctl's `as_manager` (`daemon-reload`, not timed)
  ends in `setsid -w systemctl`. `tests/static.sh` checks both files. `runuser -u halogen`
  (`as_owner`) runs only plain programs (`test`, `cat`, `head`, `stat`, `sed`, `du`, `find`) whose
  behaviour halogen can't change, so it stays as it is.

- Checkpoint locks (#139, Codex #119, after the per-pull locks of #136): every command on a
  Flash checkpoint takes `/var/lib/halogen/pull-flash-<name>.lock` (`name_lock`: pull, both convert
  steps, `verify`, `check-prepare`, `check`, and the new `flash-checkpoint use|remove <name>`), and
  `model-pull` and the new `model-pull --remove <name>` take `pull-npu-<name>.lock` (`take_lock`);
  a held lock is a message and exit 75, never a wait. The locks are taken by the halogen-side
  helpers, not by halogenctl: halogenctl's helpers run through `systemd-run` in halogen's manager,
  outside root's process tree (a pull stopped with Ctrl-C goes on, still holding its lock), and
  root must not open files in halogen's folder. So halogenctl asks first, then hands the final
  step to the helper, which checks again under the lock: `flash use` (the folder is still plain,
  `halos.info` there, `verified=pass`; the choice is written with `write_new` + `mv`), `flash
  remove` (still plain, not chosen meanwhile), `model remove` (still plain, not in
  `HALOGEN_NPU_MODELS`, read with `render-config --show`, refused if that fails; halogenctl passes
  the kind it asked about, `model-pull --remove <kind> <name>`, its lookup skips links, and the
  helper checks only that folder: "changed while you were asked", never another folder of the same
  name, security audit A1). The choice is written with `mv -T -f`, so a folder at its name fails
  the switch (A2). The choice write now runs in halogen's manager (`flash-checkpoint use`), so the
  `halogen-config` audit watch no longer records it; the halogenctl exec rule still records the
  command. The `.prompt-cache` check is skipped for `use|remove|sandbox-check` (no container), so
  `flash use official` works whatever stands there. The lock file gets the holder's process group
  only for pull and convert (`name_lock <name> owned`, `take_lock pull`); other commands leave it
  empty, so a command they block says "wait", not "kill". `fetch-models` says a busy re-verify (75)
  serves the checkpoint as checked by the older Halogen this time and checks it again at the next
  start, not "failed" (render-config unchanged). GPU: halogenctl's `gpu_lock`
  (`/run/halos-locks/gpu.lock`, a folder only root writes, fd 8, held until exit), taken after the
  answer, so a question left open blocks nothing: by `flash check` before `check-prepare` (so a
  second check never arms the trap that stops the first's `halogen-flash-check` unit and starts
  Halogen), by `flash use` after `restart_now`, by `start|restart`, and by `model pull` before it
  edits `halogen.env` for its restart. Lock order: GPU, then the checkpoint's. Left for the owner
  to agree (audit B1–B4, review 8): close fd 8 for what runs as halogen (`8>&-`); name the real
  lock holder (`/proc/locks`) instead of the written group; timeouts and type checks on reads of
  the choice file (`head -c 256`); more tests; name and remove the ppl check's container. Tests:
  `tests/halogenctl.sh` runs the real helpers through the fake `systemd-run` with `FAKE_BEFORE`
  standing in for another terminal during the question.

- Release path (#150, code review): `release.yml`'s `image` job pushes only the exact tag
  (`podman push --digestfile`) and signs that digest (`sign-image.sh` takes `repo@sha256:…` as
  given), and hands it on as the artifact `digest-<edition>`: a stable release's tag (`0.20.6`) is
  also what `refresh.yml` pushes, so nothing after the push reads the tag (security audit). The
  `iso` job pulls that digest and tags it locally for `build-iso.sh`; the `channels` job
  (`needs: [info, iso]`, holds the `channel-tags-<edition>` concurrency group shared with
  `refresh.yml`, no credentials in its checkout) works the channels out then with main's
  `channels.sh` and copies the digest to the release's own tag and each channel tag with `skopeo
  copy --all --preserve-digests`, checking each digest and the signatures after; `publish` needs it
  and uploads only `iso-*` and `info-*` (build record, #121) artifacts. A run whose `publish` fails after `channels` has moved them
  leaves a tag with no release (and `next-tag.sh` won't promote it). So a release whose install
  test fails moves no channel. The `info` job stops a release `channels.sh` gives no channel for
  (an alpha or rc of a version with a stable release: `next-tag.sh alpha` gives one until the next
  Halogen pin). `refresh.yml` rebuilds the newest *published* stable release (`gh release list
  --exclude-pre-releases`, `sort -V`), not the newest tag; it still has no VM test. Also from that
  review: `halogen-enroll-tpm` says the disk isn't encrypted when crypttab names no volume
  (`HALOS_CRYPTTAB` test hook; sudo resets the environment), the selftest WARNs about SSH unlock
  keys on the ESP of an unencrypted machine, and `halosctl npu` maps a pinned `X.Y.Z-rN` to the
  plain `X.Y.Z` tag (`release-info.sh` publishes -rN builds under it), which it then follows like a
  plain stable pin (later `-rN` and weekly rebuilds), not that exact build.

- Outbound network (#120): `halogen.container` has `Network=halogen-internal.network`
  (`Internal=true`, `DisableDNS=true`, netavark): the container gets only a link route on its
  bridge (inside halogen's rootless network namespace, so no clash with a LAN 10.x), so any new
  connection out fails at once with ENETUNREACH; without capabilities it can't add a route. The
  published `127.0.0.1:18731` still works: rootlessport connects into the bridge from the rootless
  namespace (checked with rootless podman 4.9.3, netavark 1.4, slirp4netns: port answered, 200 MB at
  the same speed as the default network, outbound, DNS and the gateway refused). Halogen's docs:
  no outbound connections with `HALOGEN_DOWNLOAD` unset (blocked here), no image URL fetching. The
  fetch, pull, probe and bench containers keep their own networks. Quadlet's `network create
  --ignore` keeps an existing network of that name as it is (a changed `.network` file never
  reaches an upgraded machine until the network is removed), so the selftest's `network-config`
  reads, from the host, the container's networks and `podman network inspect` (internal, no DNS,
  IPv6, routes or gateway: podman 4.9.3 gives an internal network without DNS no gateway), and
  `network-out` asks the running container (`python3 -I`, since its `/root` is writable: connects to
  192.0.2.1 and 2001:db8::1, PASS only on no-route answers; an `AF_VSOCK` socket, which no network
  namespace limits, only WARNs: Podman's seccomp profile should refuse it). The build checks
  Quadlet's dry run, and the VM test the unit and the network (`HNET`). A published port on an
  internal network is something upstream treats as a bug for its pasta port forwarder (container-libs
  `firstIPsFromStatus`: "internal networks must not receive ports", podman#29792); the default
  forwarder, rootlessport, has no such check. So `container-check` (image `:2`, `:1` removed) also
  starts the tiny image on its own `halos-check-internal` network (`--internal --disable-dns`) with
  `127.0.0.1:18739` published and the machine's python3 (real path under `/usr`, `/usr` mounted
  read-only, `lib`/`lib64` links in the image) as a listener on `::`, which reports its own
  connections out; the host must get the answer, with ENETUNREACH for IPv4. Exit 3 is the
  selftest's FAIL `network-port`; the VM test needs PASS `network-port` (so Podman 6 on Fedora 45
  is checked on every ISO run). Checked with rootless podman 4.9.3: PASS, and exit 3 without
  `--internal`. Open (security audit): the
  container's `eth0` keeps an `fe80::` address, so anything listening on `::` in halogen's rootless
  network namespace is on-link (expected nothing: check `podman unshare --rootless-netns ss -tulpnH`
  on freyja); `Sysctl=net.ipv6.conf.eth0.disable_ipv6=1` would close it once Halogen's start with it
  is checked. Now set (owner agreed, merged only after a freyja try): `halogen.container` has
  `Sysctl=net.ipv6.conf.eth0.disable_ipv6=1` (eth0 only: Halogen listens on `::`). The Containerfile's Quadlet dry run checks the `--sysctl`. Halogen sees a bridge address as the client (in
  that check, the container's own: rootlessport connects from inside its namespace); Caddy logs the
  real one. On freyja still: Halogen's start, a bench (the path is
  rootlessport, not pasta's splice), and both editions.

- Web search (#184, owner asked: opt-in, bundled or your own): `halogenctl web-search
  [status|bundled|external <url>|off|restart|edit]`. Two networks of halogen's (Quadlet,
  `files/etc/containers/systemd/users/970/`): `halos-search` (internal, no DNS, `Subnet=10.89.250.0/29`,
  no gateway in podman 4.9.3) and `halos-search-out` (ordinary, DNS, `isolate=strict`: cut from every other Podman network, the default one included; the selftest's `web-search` WARNs otherwise). The search
  container stands at 10.89.250.2:8080 on both and publishes `127.0.0.1:18730`: `halos-search.container`
  (SearXNG's own image by digest, `SEARXNG_IMAGE`/`_VERSION` in versions.env, `Pull=missing`, so it
  downloads at first start and after a pin change; `User=977:977` (a subuid, not halogen),
  `--cap-drop=all`, read-only, `GRANIAN_HOST=0.0.0.0` (its `::` default fails without IPv6),
  only `settings.yml` mounted read-only over the image's `/etc/searxng` volume, so the entrypoint's
  ownership warning stays quiet; `search-prepare` (as halogen) makes it from
  `/usr/share/halos/search/settings.yml` with a random secret, JSON on, limiter and image proxy off)
  or `halos-search-relay.container` (halOS's static Caddy in `localhost/halos-search-relay:1`, made by
  `search-relay-image` from the binary, `relay.caddy` and the trust store, remade when their sha256
  (and the script's) label differs; `/tmp` 1777 for Caddy's lock; GET/HEAD only to
  `HALOS_SEARCH_UPSTREAM` from root's `/etc/halos/web-search.env`, `header_up Host`). The two
  `Conflicts=`. Halogen joins only while root's drop-in `halogen.container.d/30-web-search.conf`
  exists (`Wants=`/`After=` the chosen unit, `Network=halos-search.network:ip=10.89.250.3`,
  `Sysctl=net.ipv6.conf.eth1.disable_ipv6=1`); podman 4.9.3's Quadlet ignores drop-ins, Fedora's 6
  reads them (records relies on that too). render-config sets `HALOGEN_WEB_SEARCH_URL=http://10.89.250.2:8080`
  (+ `HALOS_SEARCH_PATH` for external, re-checked) only with the drop-in; `search_conf` is a fixed
  path (tests sed it). `external` checks the URL's shape (no userinfo, query, `..`, `.local`,
  loopback, 10.89.250.x) and asks `<url>/search?format=json` as nobody (`as_nobody`, like
  tang-unlock) before writing anything. Caddy serves 8730 (`(search)` in sites.caddy: dashboard's
  private-ranges rule and `HALOS_DASHBOARD_ALLOW`, IPv4, no access log) in all three Caddyfiles
  (`HALOS_SEARCH_SITES`, `HALOS_ACME_SEARCH_SITES`); `SocketBindAllow=tcp:8730`; firewalld service
  `halos-search` open by default like the dashboard's. Selftest: `web-search` (unit, health from
  the host and from Halogen's container with urllib), `network-config` accepts `halos-search`
  only with the drop-in and checks it the same way, `config-files` excuses the drop-in's two exact
  forms. Checked here with rootless podman 4.9.3 and SearXNG's real image: JSON on the internal
  address from a Halogen-like container that has no route out, the relay to another SearXNG, 405
  for POST. Podman 6's Quadlet writes `--flag value` (4.9.3: `--flag=value`) and orders the network's
  flags differently, so every check of its output matches `[= ]`; the Containerfile also dry-runs
  Quadlet with the drop-in. IPv6 upstreams are refused (`halos-search-out` has no IPv6). `halosctl
  rollback` warns while the drop-in exists (an older image has no `halos-search.network`, and
  Quadlet then makes no halogen.service). The VM test's first boot has no network, so
  `iso-install.sh` copies SearXNG's index and amd64 image (`skopeo --all --preserve-digests`, other
  blobs deleted) onto the probe disk and the VM `skopeo copy`s it into halogen's storage (`WSIMG`).
  Not run on freyja yet (Podman 6, SELinux, a real search).
  Hardening (#186, security audit of #184, owner agreed all five): `bundled|external` refuse while root's
  `api-key-off` exists and `api-key off` refuses while the drop-in exists (the search container
  reaches Halogen's API at 10.89.250.3 past Caddy, fail2ban and the access log); render-config also
  keeps `HALOGEN_API_KEY_FILE` while the drop-in exists, whatever the off file says (its
  `search_dropin` is now a fixed path, like `api_key_off`: halogen can set its manager's
  environment; `tests/config.sh` seds it), and the selftest's `api-key` WARNs on both files (FAIL
  on a 200 then); `halos-search-out` is `isolate=strict` (`true` cuts only networks that also set
  it; halogen's other bridges are internal and the download containers use pasta, so it's
  future-proofing; the build checks Quadlet's `--opt`, the selftest's `web-search` WARNs on another
  value once the unit is active, since `--ignore` keeps an old network's options; netavark 1.4
  here refuses `strict`, Fedora 45's 2.1 takes it); both search containers
  `UserNS=auto:size=4096|2048` (no ID maps to halogen's 970; the auto ranges come from halogen's
  subuids, so they overlap low IDs of halogen's default-userns containers, nothing of halOS's runs
  as those; tried rootless with SearXNG's real image and the relay) and
  `Sysctl=net.ipv6.conf.default.disable_ipv6=1`: with a user namespace libpod makes the links after
  the runtime writes sysctls, so naming eth0/eth1 fails the start (`open sysctl … no such file`,
  security audit of #186, reproduced with runc; Halogen's own container has no userns and keeps
  eth0/eth1); links made later copy `default`, `lo` keeps its own. The build checks `--userns` and
  that sysctl; the selftest reads both links' `disable_ipv6` in the bundled container (the relay's
  image has no `cat`). The relay runs as 1000 (65534 would need a 65535-ID range) and passes only
  GET/HEAD to `$HALOS_SEARCH_PATH/search` and `/healthz`, 404 for the rest, 405 for other methods
  (`handle` blocks: a bare `respond @other` is ordered after `handle`, so a POST would have been
  proxied); each `handle` `rewrite`s to its literal path (`/search?{query}`), since Caddy matches
  the cleaned, decoded, case-folded path but forwards the raw one (code review: `stats/../search`
  and `preferences/..%2fsearch` went on as sent; tried with halOS's Caddy and a stand-in upstream).
  `scripts/searxng-update.sh`: Docker Hub's tag list with `last_updated`, the newest
  `YYYY.M.D-<commit>` by date (`sort -V`), then push time (a day has several releases and the hex
  orders nothing); on the pin's own date only a tag pushed later moves it, never back; a date after
  tomorrow UTC is refused; the raw index's sha256 is the pin, checked to be an index with
  linux/amd64 whose revision label is a full commit starting with the tag's, the same digest on
  `ghcr.io/searxng/searxng`, and the commit `behind`/`identical` to master in GitHub's anonymous
  compare API (this session's proxy refuses that API, so only the fakes ran it);
  `tests/searxng-update.sh` fakes curl and skopeo and checks each refusal's message. The workflow
  (`searxng-update.yml`, like kernel-next's) commits only `versions.env` and stops if anything else
  changed.
- Build record (#121): the base stays the moving tag `fedora-bootc:45` (Fedora's fixes, weekly
  rebuild). `scripts/build-helpers.sh` (run by `build.sh`, or once per CI run, #122) resolves it once with `skopeo inspect` (a pinned `repo@sha256:` is checked
  to answer with that digest; a tag+digest reference is asked for as `repo@digest`, since
  containers/image refuses both), builds every stage `FROM` that digest, and labels the image
  `io.github.n4berius.halos.base` and `org.opencontainers.image.revision`. release.env gains
  `HALOS_BASE_IMAGE`, `HALOS_BASE_VERSION` (the base's version label) and `HALOS_SOURCE_COMMIT`
  (`-modified` with a dirty tree); the image keeps `/usr/share/halogen/packages.txt` (`rpm -qa`,
  written after the kernel swap) and `toolchains.txt` (each build stage's compilers). The
  selftest prints a "Fedora base" line. `scripts/build-info.sh <image>` prints labels, release.env,
  toolchains and packages (rpm inside the image for older images); `build.sh` writes it to
  `output/build-info-<edition>-<kernel>.txt`, build.yml and refresh.yml keep it as an artifact
  (refresh also puts the base lines in the run summary), and release.yml's image job runs main's
  copy (`continue-on-error`: the tag is already pushed) and publishes
  `halos-flash-<tag>-<edition>-build-info.txt`. `build-iso.sh` builds the installer on the OS
  image's label, else the tag. Not reproducible: dnf still installs from Fedora's current repos.

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
  (`ignoredisk`, a 1 GiB EFI partition and a 2 GiB `/boot` with fixed sizes instead of `reqpart --add-boot`'s Anaconda defaults (#151; the VM test's `BOOTSZ` checks them and prints how full `/boot` is), VG `halos`, fixed LV names), users, hostname, reboot.
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
  key mapping, or it is silently dropped. Typing costs about 0.05 s a key: the 11,700-character
  report took about 10 minutes at each of the NPU test's three boots. So the long lines (report,
  selftest, HTTPS, SSH unlock) are `SCRIPTS` in `vm-login.py`, written by `vm-login.py --scripts`
  onto a read-only `HALOS_PROBE` disk that `iso-install.sh` attaches to every boot from the
  installed disk; after login only the mount and `bash /run/halos-probe/<name>.sh` are typed. Add
  new checks to a script, not to a typed line.
- Until 0.19.0 Halogen needed the host's XRT, which halOS took from Debian trixie-backports
  and mounted at three paths. From 0.19.1 its image carries XRT 2.25, so halOS mounts none (a
  host mount must be all three libraries or none). `tests/static.sh` keeps it that way.
- Halogen 0.18.x listened on IPv4 only, so we published `0.0.0.0:8731`. From 0.19.0 it listens
  on IPv6 too, and the port is published dual-stack.
- `HALOGEN_AGENT_GUARD=watch|hold` makes Halogen add `halogen-spotter-0.6b` at start, and `hold`
  also `decider-4b` (since 0.20.5; before, both modes added both). The server never downloads, so
  `fetch-models` adds them to the fetch, and `halogenctl model list` marks them "agent guard".
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
- GitHub's runners have no native overlay diff (their kernel has `CONFIG_OVERLAY_FS_REDIRECT_DIR`),
  so every committed build step walks the whole tree: about 8 s per step for the OS image, 3 s for
  the installer. The four workflows set `BUILDAH_LAYERS=false` (one commit per stage); local builds
  keep layers, which #161's Caddy caching relies on.
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
- Next: tang unlock (#44) awaits a run on freyja; GGUF in `flash pull` (#61) too.
- **Halogen 0.20.0** (stable since `v0.20.0`): 0.20.0 (ROCm 10.1 in its image, OvisOCR3 document parsing on the NPU as your
  own checkpoint, faster prefill, a strict-tool-call crash fixed; the Flash checkpoints and weights
  revision unchanged) is pinned by #78. Between source commits 47ceb43 and 8242b15, FLAGS.md,
  `deploy/entrypoint.sh` and host-setup's requirements are unchanged (only image tags in examples),
  so `options.allowed`, `halogen.env.default`, the Quadlet and kernel arguments stay as they are.
  OvisOCR3 (`ATH-MaaS/OvisOCR3`, 1.7 GB safetensors) goes through `model pull` into `custom` (the
  probe's base is `ovisocr3`, confirmed on freyja, not LFM or decider; its NPU programs in `models.txt` have no pinned revision, like
  `halogen-spotter-0.6b`, so an upstream push to them breaks the fetch's hash check), served as
  `OvisOCR3` from `/models/custom/OvisOCR3`; GUIDE.md mentions `HALOGEN_WEIGHTS_LOCK=1` (already
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
- **Halogen 0.20.5** (#140): faster decoding with several requests (a new decoding-state form;
  `HALOGEN_DN_STATE=fp32` restores 0.20.4's, and a prompt cache saved by 0.20.4 is rebuilt),
  Indic-script prompts tokenized by the checkpoint's own pattern (`HALOGEN_TOKENIZER_NATIVE`), LFM3
  on the NPU about twice as fast on long prompts, XRT 2.27 in the image (halOS mounts none), and
  `HALOGEN_NPU_KILL_S` (NPU edition: a stuck NPU job takes the NPU engine down after 1800 s and it
  restarts). All three are in FLAGS.md, so allowed and commented in the templates. Between source
  commits de6e7f8 and 1548d42, host-setup changes only image tags, so the Quadlet and kernel
  arguments stay. `deploy/entrypoint.sh` also passes `HALOGEN_TOKENIZER_NATIVE`, and
  `HALOGEN_FORK_UNMATCHED_RELEASE` and `HALOGEN_MODEL_NAME_CHECK` as front-end-only names not in
  FLAGS.md, so those two aren't allowed here (as `HALOGEN_CACHE_REPLY`); `watch` no longer loads
  `decider-4b`, so `fetch-models` and `model list` follow. The Flash checkpoints and weights
  revision are unchanged (upstream: "the Flash checkpoints and the GEMM tuning are 0.20.4's"). The
  image's `models.txt` differs from 0.20.4's only in `lfm3-1.7b` and `lfm3-1.7b-fast` (new
  revisions, about 440 MB each, fetched again only where an LFM3 checkpoint is in
  `HALOGEN_NPU_MODELS`; read from the layer, anonymously from ghcr.io).
- **Halogen 0.20.6** (#143, the update workflow's PR, finished by hand): a draft head
  `qwen38-flash-next-drafter-r2.hgn` (1.4 GiB) that the entrypoint uses when it lies beside the
  checkpoint (`dirname $HALOGEN_CHECKPOINT`) and `HALOGEN_CK_OVERLAY` is unset (blocked here, a
  path); upstream fetches it only with `HALOGEN_DOWNLOAD`, which halOS never sets, so it is an
  official file now: `fetch-in-container`'s list, `fetch-models`' `official` and link removal,
  `preflight`, `weights-sums.sh`. It was added to the weights repo in `bd9765d` (2026-11-16) with
  every other file's LFS oid and the tokenizer unchanged, so `HALOGEN_WEIGHTS_REVISION` moved there
  and `weights.sha256` gained one line. An upgraded machine finds it missing, downloads only it
  with the top writable, and hashes all official files once. Custom Flash checkpoints (folder
  `flash/<name>`) have no draft head beside them and keep their own (not copied: whether it suits a
  fine-tune isn't known). New in FLAGS.md and allowed: `HALOGEN_CONC_MODE`, `HALOGEN_NPU_STALL_S`
  (NPU). Host-setup changes only image tags. `models.txt` adds `lfm3-1.7b-qad` (441 MB) and pins
  revisions for `halogen-spotter-0.6b` and `ovisocr3` (same files). `:qad` (#144): an own LFM3
  path with `:qad` is probed with `halogen-npu probe <dir> --form qad`, as the entrypoint does, which
  answers `base=lfm3-1.7b-qad`; `own_parts` then fetches that model's programs, `own-bases` keeps
  `<path>:qad=lfm3-1.7b-qad` (`model list` maps it as is), `own_models` strips `:qad` and stats the
  folder's `*.gguf`, and `halogenctl`/`model-pull`'s in-use checks strip `:qad` like `:fast`.
  `model pull --qad` (after the normal pull) reads the `<base>-qad` line's `source=<repo>@<40-hex>`
  from the image's `models.txt` (`LiquidAI/LFM3-1.7B-GGUF@cd0c74c…` for 0.20.6), downloads only
  `*-QAD-Q4_0.gguf` at that commit into the checkpoint's folder (same named container, the folder
  alone writable, no HF token: the repo is public; on a first pull while the folder is still
  `.pull/<name>`, which Halogen's container can't reach, security audit; a failed 4-bit step still
  moves the folder and prints `path=`, and halogenctl offers the other forms, then exits 1), probes it `--form qad` offline and read-only, requires `base=<base>-qad`, and
  prints `qad=1`, after which halogenctl offers the `:qad` entry; without `--qad` it only mentions
  the form when the image has one. Like the safetensors pull, the GGUF isn't hash-checked beyond
  hf's own transfer (no HF sha256 compare). `HALOGEN_CK_OVERLAY` left gen-options' BLOCKED (owner:
  yes); `render-config` passes only the value `none` (a path would reach files the fetch doesn't
  check), and the templates say so (code review of #144: upstream's `check_sidecar` runs a
  checkpoint with a quality sidecar (`<ckpt>.overlay.hgn`, which `flash pull` fetches) bare under
  `none`; the template's text says so). Code review of #143: `flash pull` skips
  the drafter as a checkpoint candidate (Peonist's layout now ships one beside the checkpoint);
  the selftest's weights line reads the drafter's download record first (an upgraded machine
  keeps v2's from the older pin) and says every file is hash-checked; `flash list` counts the
  drafter in the official size. With `HALOGEN_NPU_STALL_S` (60 s default) a long NPU job makes
  `/health` answer 503 `engine_stalled`: login-status shows "starting", the selftest's `api-ipv4`
  FAILs and `bench` refuses while it lasts; no restart follows (the Quadlet has no Health keys and
  the image no Healthcheck).
- **Halogen 0.20.7** (#148, the update workflow's PR, finished by hand in #149): the
  concurrency mode is the default (`HALOGEN_CONC_MODE` unset = on wherever it can run, `0` = the old
  mode; the entrypoint falls back with one startup line beside a GGUF, w4b or `HALOGEN_MTP=0`), and a
  new draft head `qwen38-flash-next-drafter-r2-ht4.hgn` (1.39 GiB, weights commit `5c72aef`; the pin
  moved to `05ec74b`, a README upload after it, with every other file's hash unchanged). The
  entrypoint reads `-ht4` beside the checkpoint, else 0.20.6's `drafter-r2` (`DRAFTER_PREV`). The
  `-ht4` file replaced `drafter-r2` in the official list (`fetch-in-container`, `fetch-models`,
  `weights-sums.sh`, the tests); `drafter-r2` is no longer fetched, but one kept on disk stays for a
  rollback, is hashed like a kept vision tower (`weights.sha256` still lists it) and a link at its
  name is removed and refused (`preflight`) as before. FLAGS.md changed only `HALOGEN_CONC_MODE`'s and
  `HALOGEN_CK_OVERLAY`'s text and a vision timing; host-setup only image tags; `models.txt` is
  byte-identical to 0.20.6's (read from the layer), so no NPU program downloads again.
- **Halogen 0.21.0** (#182; the update workflow stopped at `tests/run.sh` on the new option and
  opened nothing, so `halogen-update.yml` now opens a draft PR with the failing lines in its body
  and fails the run after): Flash-Next's engine is 0.20.7's. New: Qwen3.8-27B in the same image
  (the entrypoint's `engine_for_checkpoint` reads the HGN header's model id, bytes 40..103, and picks
  `flash_serve` or `flash_serve-dense27` when the image sets `HALOGEN_IMAGE_ENGINES`; it refuses an
  id it has no engine for, also in `verify`, so an own checkpoint with an unexpected id fails the
  re-verify and render-config serves the official one; bf16-to-hgn writes `qwen3.8-flash-next-v2`,
  what convert writes for a GGUF wasn't checked). halOS doesn't serve the 27B yet: `flash pull`
  refuses a `qwen38-27b*` checkpoint before downloading and `verify_dir` fails a file whose header
  says `qwen3.8-27b*` (render-config would give it Flash's draft head via `HALOGEN_CK_OVERLAY`,
  `--resident-gib` runs Flash's binary, the vision tower name differs: `qwen38-27b-vision.hgn`).
  `HALOGEN_WEB_SEARCH_URL` (SearXNG for `/v1/messages`' `web_search` tool) stays in gen-options'
  BLOCKED: only `halogenctl web-search` turns it on (see "Web search" above). Several API keys now split the prompt
  cache per key (halOS has one key). FLAGS.md otherwise changed only text; host-setup only image
  tags; the weights repo and revision are unchanged (Flash-Next unchanged). This session could
  read ghcr.io manifests but not blobs, so the image's `models.txt`, env and `halogen-bench.py`
  weren't compared with 0.20.7's (bench refuses a tool without `lead_line`/`ask`/`main`).
- Hardening after #182 (its security audit, owner agreed): `preflight` fails on anything at
  `/srv/models/adapters` or `/srv/models/flash/*/adapters` (0.21.0's `adapters_setup` runs
  `lora_to_hgn.py --scan` on the folder beside the checkpoint at every start, 27B only today;
  the download and pull containers can write there, halOS makes none). `halogen-update.yml` and
  `kernel-next-update.yml`: `permissions: {}` at the top, the write rights on the job, checkout
  with `persist-credentials: false`, and the token reaches git only in the step that opens the PR
  (`GIT_CONFIG_COUNT`/`_KEY_0`/`_VALUE_0` for `http.https://github.com/.extraheader`, the base64
  masked, `core.hooksPath=/dev/null`), so `tests/run.sh` and the update scripts can't leak it by
  accident (a hostile earlier step could still reach it through `$GITHUB_ENV`: a second job would
  be the wall). preflight skips `flash/<x>/adapters` when `<x>` isn't a name render-config serves,
  and prints the removal with `printf %q` through `runuser -u halogen`.
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
