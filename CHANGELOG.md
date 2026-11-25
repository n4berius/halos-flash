# Changelog

This file tells what changed in each halOS release, newest version first, in plain language. Dates
are UTC. The numbers link to the pull requests with the details. Halogen's own changes are in its
[changelog](https://github.com/peonist-ai/halogen-flash-server/blob/main/CHANGELOG.md).

Each pull request adds its lines under **Unreleased**. After a release, the lines move under the
release's version. A beta, RC or stable release that promotes an earlier release lists only what
it promotes.

## Unreleased

- Tab completion of `halogenctl` now completes the names of your checkpoints and models after
  `sudo` too (before, it found them only in a root shell). It also completes the draft head files
  for `flash drafter <name>` and your existing names after `--as` of `flash pull` and
  `model pull`, to update one. The names come from a list that halOS keeps in
  `/run/halos/model-names` for administrators (#174).

- Hardening from the same review (#166):
  - Unlocking from a tang server: `halosctl tang-unlock on` with `--tpm and` or `--tpm or`, and
    `halogen-enroll-tpm`, refuse while Secure Boot is off, since the TPM's check then doesn't stop
    a changed boot loader. Only SHA-256 server keys are taken (the 43-character ones
    `tang-show-keys` prints). The keys bound are recorded, so `tang-unlock renew` reuses them
    without asking and stops if a server now signs with another key; the selftest warns about
    such a server. The server's answer is read as the unprivileged `nobody` user. A bind stopped
    with Ctrl-C undoes what it had made.
  - `halosctl` and `halogenctl` ignore their test settings (`HALOS_*`, `HALOGEN_*`) when run with
    `sudo`, and start without reading any startup file from the environment.
  - A GGUF conversion (`halogenctl flash pull`) and `halogenctl flash check` no longer use the GPU
    at the same time: the check refuses while a conversion runs, and a conversion waits for a check.
  - CI: builds of pull requests and other branches run without the right to push packages or to
    sign. Only main's build has it.
- More hardening from the whole-image review, tried on a real machine before release (#167):
  - The conversion of a GGUF download (`halogenctl flash pull`) sees only its own download, with
    the rest of the system read-only, not every model.
  - Halogen's container has no IPv6 on its network link (it keeps IPv6 inside, where it listens).
  - The boot jobs that prepare Halogen's folders, hold the GPU clock, and renew HTTPS certificates
    run with fewer rights.
  - Four kernel settings: no terminal modules loaded on demand, stricter rules for files in shared
    temporary folders, and no switching to another kernel without a reboot (kexec).

- New release names (#168): `v<Halogen version>-<halOS number>-<stage>`, such as `v0.20.7-1-stable`
  and `v0.20.7-2-alpha`. The halOS number counts halOS's own changes on one Halogen version, so a
  new halOS feature can go out as an alpha, RC and stable release without a new Halogen version.
  Before, an alpha after a stable release reached no machine. Machines need to do nothing: the
  channels (`alpha`, `rc`, `stable`) stay, and every new release counts as newer than the old
  names. `halosctl rollback --to` takes the new names. `rollback --to 0.20.7` (a plain version) now follows that version's stable releases and weekly rebuilds instead of pinning one build. Each stable release now also has its own
  exact image tag (`0.20.7-1-stable`) beside the plain version tag (`0.20.7`).
- The release checks no longer fail in the no-NPU build job: one check read the job's edition
  setting and looked for the wrong file, which stopped the `v0.20.7-r2` release (#168).
- Fixes from a review of the whole image (#165):
  - A USB disk is now really left out when the machine looks at boot for SSH unlock keys or a
    tang binding. The check read the disk type from the partition, which never has one, so a USB
    stick with keys on it could start the network and SSH before the disk unlocked. A disk that
    can't be asked now counts as USB. A machine installed on a USB disk therefore gets no SSH or
    tang unlock, and `halosctl tang-unlock on` says so.
  - `halosctl switch`, `rollback --to` and `npu on|off` refuse an image whose label says it has
    the other kernel (the test kernel on a normal channel, or the reverse), as they already do
    for the other edition.
  - `halosctl tang-unlock` (status, `on`, `off` and `renew`) now says so when the disk has a clevis
    binding halOS can't read, instead of stopping without a word, and changes nothing. `renew` refuses more `--thp` than servers.
  - `halosctl ssh-passwords off` could fail at random while checking sshd's settings; fixed.
  - Release and refresh builds no longer keep the GitHub token on disk while they build.
  - CI: changes only to tests skip the image builds (the checks still run), and a change to the
    VM test's boot-menu picker runs the install test.

- The encrypted disk can now unlock from a tang server on your own network (clevis):
  `sudo halosctl tang-unlock on http://<server>`, also offered by `halosctl setup`. By default the
  machine's TPM must agree too, so a copied disk or a machine taken away stays locked; `--tpm off`
  (the server alone) and `--tpm or` (the TPM alone still unlocks) are the other choices. It shows
  the server's key to compare first, and the passphrase always works. The network starts before
  the disk unlocks only on machines set up for it (or for SSH unlock). The VM install test unlocks
  through a real tang server and asks for the passphrase without it; not yet tried on the test
  machine. (#44)
- `flash pull` now takes GGUF repositories of Qwen3.8 Flash Next (llama.cpp's format). It
  downloads one build (pick it with `--file` when there are several), adds Halogen's draft head
  from the official weights, converts it one time into a `.hgn` with Halogen's own `convert`
  (offline), checks it with Halogen's `verify`, and deletes the GGUF (`--keep-gguf` keeps it).
  Builds that Halogen can't read are refused before the download. Not yet tried on the test
  machine. `flash convert-stop <name>` now waits its turn: it refuses while a pull or conversion
  of that name runs. (#61)
- Your own Flash checkpoints now draft with Halogen's official draft head
  (`qwen38-flash-next-drafter-r2-ht4.hgn`), as the official checkpoint does. Before, Halogen used
  it only beside the official checkpoint, so yours drafted with their built-in head. If a
  checkpoint's repository supplies its own draft head file, `flash pull` now downloads and checks
  it, and `sudo halogenctl flash drafter <name> <file>` uses it; `off` goes back to the built-in
  head. Answers stay the same, only the speed changes. The selftest's new `draft-head` line says
  which one Halogen loaded. (#158)
- Halogen's container can no longer open connections to the internet, your LAN or this machine.
  It is on its own Podman network with no route out and no DNS. Requests through Caddy, the
  dashboard and bench work as before, and the downloads still use the network. Three new
  selftest lines check it: `network-out`, `network-config` and `network-port`. (#120, #157)
- Each build now records which Fedora base image it used (by digest), every installed package
  and the compilers. The image keeps this in `/usr/share/halogen/` (`release.env`,
  `packages.txt`, `toolchains.txt`), the selftest shows the base, and each release attaches a
  `build-info.txt` file for each edition. The base still follows Fedora's `45` tag, so weekly
  rebuilds still get Fedora's fixes, but all build stages and the installer now use the same
  base. (#121)
- You can now turn the API key off, for a network that you trust: `sudo halogenctl api-key off`
  (asks first) and `sudo halogenctl api-key on`. The key stays on by default, and the selftest
  checks that Halogen refuses a request without the key while it is on. (#155)
- The documentation now matches the current state: the edition without NPU also runs on real
  hardware since `v0.20.0`, the roadmap starts from `v0.20.6`, the download is about 130 GB
  (about 120 GB without the NPU), and examples use published versions. Statements like "this
  release" now name the release. (#153, #154)
- The documentation now follows ASD-STE100 Simplified Technical English: shorter sentences, one
  instruction per step and plain words. Only the wording changed: every command, setting, link
  and number is the same. (#152)
- The guided installer now gives the boot partitions fixed sizes: a 1 GiB EFI partition and a
  2 GiB `/boot`. Before, Anaconda chose the sizes, and its defaults change between Fedora releases.
  `/boot` holds a kernel for the running system, its rollback and a staged upgrade, and the boot
  files of halOS are larger than Fedora's. This applies to new installs only. (#151)
- Releases: the `alpha`, `rc`, `stable` and `latest` tags now move only after the install tests of
  both editions pass. So a machine never upgrades to a release that failed them (before, the tags
  moved first). The weekly stable rebuild now uses the newest *published* stable release, not only
  the newest tag. Some alphas or RCs reach no machine, because a newer stable of the same version
  exists. Such a release now stops at once with an explanation. Before, it built for 40 minutes and
  reached nobody. (#150)
- On a machine without disk encryption, `halogen-enroll-tpm` now says that the disk isn't
  encrypted, not a confusing error. The selftest warns when SSH unlock keys stay on the EFI
  partition: every boot would start an SSH server for nothing (`sudo halosctl ssh-unlock off`
  removes them). `sudo halosctl npu on|off` now works on a machine pinned to a stable rebuild
  such as `0.20.6-r2`. (#150)
- Halogen 0.20.7: the concurrency mode is now Halogen's default. One request alone is at least as
  fast in it (upstream: 3 to 29% more total throughput with several requests, about 4 to 6% faster
  single replies). To go back to the previous mode, set `HALOGEN_CONC_MODE=0` in `halogen.env`.
  Halogen also has a faster draft head (`qwen38-flash-next-drafter-r2-ht4.hgn`, 1.39 GiB). The
  first start after the upgrade downloads only that file and checks every official file once.
  0.20.6's draft head stays on disk for a rollback, and halOS checks it too while it stays. A new
  install doesn't download it. The Flash checkpoints and the NPU models are unchanged. (#148, #149)
- `:qad`, LFM3-1.7B's fastest form on the NPU (Halogen 0.20.6): `sudo halogenctl model pull
  LiquidAI/LFM3-1.7B --qad` also fetches Liquid's own 4-bit file, from the exact source that
  Halogen's image names. Then `/models/LFM/LFM3-1.7B:qad` can go in `HALOGEN_NPU_MODELS`. Halogen
  serves it as `LFM3-1.7B-qad`, at about 48 tokens a second against 30 and 42. halOS now accepts
  `HALOGEN_CK_OVERLAY=none` (that value only), Halogen's way back to the checkpoint's own draft
  head. With an own Flash checkpoint that has a quality sidecar, `none` also leaves out the
  sidecar. (#144)
- `sudo halosctl setup` now offers HTTPS as its fourth question. On a new install, when you press
  Enter, setup turns HTTPS on with halOS's own authority (self-signed). Then apps that use
  `https://` no longer send prompts, replies and the API key in plain text. Each app trusts the
  authority once (`sudo halosctl
  https ca`). A machine upgraded from an earlier release keeps plain HTTP unless you say yes. An
  HTTPS setting that you already have stays as it is. (#145)
- kernel-next follow-ups: when Fedora has a newer plain build of the test kernel, a weekly check
  opens a pull request. The test kernel gets no security fixes until its pin moves. The selftest
  warns when the test kernel is more than three weeks old. The image build now checks the test
  kernel's Secure Boot signature as the boot loader does, not only the signer's name. It checks
  the signature itself, a code-signing certificate under Fedora's CA from the image's own shim, and
  its revocation level. The Fedora signing keys that the build uses no longer stay in the image.
  The release workflow refuses a beta tag pushed by hand, because there are no beta releases now.
  The test kernel moves to 7.4-rc3, because Fedora stopped serving the signed rc2 build. (#146)

- A new channel, `kernel-next`, to try a newer kernel. It is the same build as `edge`, but with
  Linux 7.4 (a release candidate: Fedora 46's build, signed for Secure Boot) instead of Fedora 45's
  7.3. It brings about 25 fixes to the NPU driver and an IOMMU speed-up for the built-in GPU, which
  applies to the NPU edition. To follow it, run `sudo halosctl switch kernel-next`. To go back, run
  `sudo halosctl switch edge`. Releases keep Fedora 45's kernel. (#142)
- Halogen 0.20.6: replies are about 4% faster with a new draft head. This is a 1.4 GiB file that
  halOS now downloads once and checks beside the official checkpoint. Images read about four times
  faster. It also fixes problems with long shared prompts and with busy multi-agent sessions
  (rarely, a reply could come from the context of another conversation). `halogen.env.example`
  has two new settings, commented: `HALOGEN_CONC_MODE` (for many requests at once; a single
  request is slower) and, on the NPU edition, `HALOGEN_NPU_STALL_S`. Your own Flash checkpoints
  keep their own draft head for now. halOS doesn't support LFM3's new `:qad` form yet. (#143)
- Releases now go alpha, then RC, then stable. There are no beta releases now, and an RC promotes
  the newest alpha. A machine that follows `beta` keeps working and gets every RC and stable
  release, the same as `rc`. `halosctl switch beta` still works, but halOS no longer offers it.
  (#141)

- Halogen 0.20.5: answers are faster when several requests run at once, and saved conversations
  use less memory. Halogen reads Hindi, Thai and other Indic-script prompts the way the model was
  trained. Your own LFM3 checkpoints read long prompts about twice as fast on the NPU (their NPU
  files, about 440 MB each, download again once). It fixes structured output, the answer guard,
  unknown model names, and problems when Claude Code adds tools during a session. A stuck NPU job
  no longer needs a restart. `halogen.env.example` has two new settings, commented:
  `HALOGEN_DN_STATE` and `HALOGEN_TOKENIZER_NATIVE` (and `HALOGEN_NPU_KILL_S` on the NPU edition).
  Halogen rebuilds a prompt cache saved by 0.20.4 when it first uses it. With
  `HALOGEN_AGENT_GUARD=watch`, halOS no longer downloads `decider-4b`, because Halogen now loads it
  only for `hold`. (#140)

- Two commands no longer get in each other's way on the same checkpoint (#139):
  - If another command is busy with a checkpoint (or model), a pull, check, switch or removal of
    it says so and stops.
  - After you answer, `flash use` and `flash remove` (and `model remove`) check again that nothing
    changed. So a removal can't remove the checkpoint that you just chose.
  - While a `flash check` runs, a second check, a `flash use`, a `restart` or `model pull`'s
    restart refuses and says so. It doesn't put a second job on the GPU.

- The selftest's checks that run as the halogen user (Halogen's scratch folders, its generated
  service) now run in a session of their own. So nothing that they start can reach the terminal
  where you run `sudo halogenctl selftest`. (#138)
- Downloads, a last round (#136):
  - Halogen refuses to start when a link (or a folder that it can't read) stands where it loads
    its model files from: the official files, the tokenizer, the NPU folder. The next fetch
    removes it.
  - After a download, the NPU folder keeps only the files that Halogen's own record lists for the
    models it knows. A rollback may download a few files again.
  - The clean-up never follows a link out of the models folder.
  - When you stop a `model pull`, `flash pull` or `flash convert`, it removes its download at once.
  - Two pulls of the same name can no longer run at once and break each other. The second pull
    says so, and tells you how to stop the first.
- The selftest (and the install test of every change) now starts a tiny container that has the
  same setup as Halogen's. A Fedora update to crun 1.31, the program that podman starts containers
  with, broke every start of Halogen. Nothing found the problem before it reached a machine. The
  image now holds crun at 1.30.1 until a fixed version is available. (#137)

- More hardening for fail2ban and the firewall (#134):
  - fail2ban can no longer reach the system's message bus (so it can't reach firewalld either),
    and it may use fewer system calls.
  - The access log no longer records Halogen's reply headers.
  - The firewall no longer lets through ports that a container started with `sudo` publishes.
    Such a container may now refuse to start. Rootless containers, such as Halogen, aren't
    affected. INSTALL tells how to allow it.
- More hardening of the downloads (#135):
  - When the official files are on the disk, a model download can no longer change them. It can
    write only to the NPU folder.
  - After a download that could change them, halOS checks every official file against the hashes
    in this release. If a file differs, halOS removes it and fetches it again.
  - The note that says "models already downloaded" is now out of reach of the downloads. An
    upgraded machine checks all its official files once. This takes a minute or two and downloads
    nothing.
  - If a `model pull`, `flash pull` or `flash convert` download stops before the end, halOS
    removes it when the command ends, or at the next pull of the same name.

- fail2ban now shuts out addresses through its own firewall table (nftables), not through firewalld
  rules. So it also cuts the connections that a shut-out address already had open, a ban costs
  much less under a flood, and `firewall-cmd --reload` no longer drops the bans. The front door
  refuses requests with more than 32 KB of headers. So a wrong key can't hide from the count in a
  log line that is too long. fail2ban's own sandbox is tighter. In the HTTPS modes, a request for a
  name or address that the certificate doesn't cover no longer leaves its headers in the journal,
  API key included. (#132)
- Hardening of the downloads (#131):
  - While the model download runs, it can no longer replace one of Halogen's folders with a link.
    If an interrupted fetch left such a link, the next fetch removes it.
  - The fetch and the `flash` commands no longer write, move or copy through a link that a
    download left. One such link could have replaced the API key.
  - `model pull`, `flash pull`, `flash check` and `flash convert` refuse a folder that they reach
    through a link.
  - A custom Flash checkpoint that shares the official lookup table gets its own copy, not a hard
    link to the official file. The copy is free on the disks that the installers make.

- Hardening: SSH refuses logins as the `halogen` service user. On the NPU edition, Halogen's
  container gets the model and own-checkpoint folders with no programs allowed. The weight
  converter runs with no devices, shared memory or system logs in reach. The selftest looks in more
  of the `halogen` user's settings folders. (#130)

- fail2ban: if an address fails too many SSH logins (5 in 10 minutes) or sends a wrong API key too
  often (10 in 10 minutes), the firewall shuts it out for 10 minutes. fail2ban is on by default. It
  never shuts out this machine or private networks. `sudo halosctl fail2ban` shows the state,
  `unban <address>` lets someone back in, and `off` turns fail2ban off. (#129)
- Hardening: if a link replaces one of the folders mounted into Halogen's container (`npu`,
  `decider`, `LFM`, `custom`), Halogen refuses to start, as it already did for the prompt cache.
  The boot-time setup removes such a link and makes the folder again. The weight converter can no
  longer read the request records. The selftest also looks at the `halogen` user's own container
  settings folders. If you made a link yourself at one of halogen's folders (`/srv/models/npu`,
  `decider`, `LFM`, `custom`, `flash`, `.prompt-cache`, or `/srv/logs/halogen`), the next boot
  removes it and makes an empty folder. The boot doesn't change what the link pointed to. To keep
  such a folder on another disk, mount the disk there. Then give the folder to halogen:
  `sudo chown halogen:halogen <folder>` and `sudo chcon -t container_file_t <folder>`. (#128)

- Prompt cache hardening: the containers that download and check models no longer see the cache
  folder. Halogen refuses to start if a link replaces the folder or if the folder belongs to
  someone else. `halogenctl cache off` now also makes the folder read-only for Halogen.
  `records on` no longer reports a missing mount that is there. If you turned the cache off before
  this version, run `sudo halogenctl cache off` once more to make the folder read-only (the
  selftest tells you). If the selftest's `config-files` line says that `halogen.container`
  changed, remove its `.prompt-cache` line. The mount now has its own file, and with two mounts
  Halogen can't start. (#127)

- Halogen now also keeps its prompt cache on disk (`/srv/models/.prompt-cache`). So a
  conversation survives a restart of Halogen, and Halogen doesn't read it again in full. The cache
  is on by default, at most 64 GiB (`HALOGEN_CACHE_DISK_GIB`). A new Halogen version or a switch of
  checkpoint starts with an empty cache. `sudo halogenctl cache` shows it. An upgrade turns this on.
  To keep nothing on disk, run `sudo halogenctl cache off` and then `sudo halogenctl cache clear`.
  (#124)
- Audit: halOS now also watches `/etc/environment`, `/etc/fstab`, `/etc/nsswitch.conf`,
  authselect's folder, `/etc/sysctl.conf` and the library search settings. `halogenctl selftest`
  now runs with a clean environment, so a variable set for root can't point its checks at other
  files. (#126)

- Audit hardening: the audit rules are locked until reboot, so root can't quietly turn auditing
  off. Auditing now leaves out only Halogen's own login session: it records root when root acts as
  the `halogen` user. halOS watches more: how Halogen's container starts, the audit rules
  themselves, system services, PAM, kernel modules, the firewall and `crypttab`. The selftest gets
  `config-files` and `halogen-autostart`, and its `audit` line reports dropped records. (#125)
- Logs: an audit trail (auditd) records logins and `sudo`. It also records changes that an admin
  or root makes to these: halOS's settings, update signatures, SSH settings and sudo settings. It
  also records runs of the disk-encryption and update tools. Read it with
  `sudo ausearch -i -k halos-config` and the other keys in the install guide. It keeps 1 GB. If its
  disk fills, it pauses and doesn't stop the machine. The system journal now keeps at most 4 GB for
  90 days. The selftest reports both. halOS doesn't audit Halogen's own processes, to keep the cost
  off inference (the cost is still to be measured on real hardware). (#118)
- Hardening: Halogen's container now runs read-only, except its scratch folders (`/tmp`,
  `/var/tmp`). These stay on disk as before, so memory use is unchanged. The request records
  folder, and on new installs the whole `/srv/logs` volume, can't hold or run programs. (#115)
- Request records: `sudo halogenctl records on` makes Halogen keep a line for each request that it
  answers, in `/srv/logs/halogen`: which app sent it, its size, how it finished, and timings. It
  keeps counts only, unless you choose to keep text. `records stats` adds them up and
  `records prune` removes them. New installs give `/srv/logs` a 4 GiB volume of its own. (#113)
- Let's Encrypt: your DNS provider's credential now gets to Caddy through systemd's credentials
  (read-only, in memory, removed when Caddy stops), not as a copy in Caddy's own folder. The build
  stops if the Cloudflare plugin changes which token shapes it accepts, because the plugin prints a
  token that it refuses. `sudo halosctl https forget-dns` now restarts the front door for a moment,
  so Caddy removes its copy at once. (#112)
- Halogen 0.20.4 (#111):
  - In a cached conversation, Halogen reads a short follow-up message 15 to 50% faster.
  - 10 to 20% more throughput when Halogen serves more than 8 requests at once
    (`HALOGEN_KV_SLOTS` above 8; the default is 4).
  - `d3-nano` is 7 to 9% faster on the NPU (0.20.3). Its NPU programs (about 135 MB) download
    again where it is in use.
  - In a conversation that already used tools, a tool call no longer arrives as raw text when the
    app asked for none (`tool_choice: "none"`).
  - The Flash checkpoints and your settings are unchanged.
- Only root may use the disk service udisks2, which halOS keeps for firmware updates. An admin uses
  `sudo`, and the `halogen` user that runs Halogen can't call it at all. Firmware updates with
  `sudo fwupdmgr` work as before. (#110)
- Halogen 0.20.2: a little faster with several requests at once (up to about 1%). The first token
  on long conversations comes sooner (up to about 4%). NPU decisions on long prompts start a little
  sooner, and `d3-lite` answers 14 to 18% faster on the NPU. The Flash checkpoints and your
  settings are unchanged. (#100)
- New guides: [the command reference](docs/CLI.md) lists every halOS command. [Connecting
  apps](docs/CLIENTS.md) shows how to connect Claude Code, Codex, Pi, oh-my-pi, opencode, Cline,
  aider and others to the machine, and how each one trusts halOS's certificate. (#109)
- Firmware updates: `sudo fwupdmgr update` can now also update the Secure Boot revocation list
  (dbx). Before, it said "UEFI ESP partition not detected". If the TPM unlocks the disk, such an
  update makes the next boot ask for the disk passphrase. Then run `sudo halogen-enroll-tpm` once.
  (#106)
- HTTPS with Let's Encrypt: `sudo halosctl https letsencrypt <provider> <name>` gets certificates
  that every app already trusts, for a public name that you own, and renews them. It uses the API
  of Cloudflare, DuckDNS, Porkbun or Namecheap. halOS opens no port to the internet. `--staging`
  tries Let's Encrypt's test service first. The machine's own addresses keep halOS's authority.
  (#108)
- The SSH login message and the "Halogen is ready" notice show an address that other machines can
  use: the Let's Encrypt name, the machine's full name (such as `freyja.home.example`), or its IPv4
  address. Before, they showed a bare host name, such as `freyja`. (#108)
- The dashboard moved from port 8790 to **8732**, next to the API on 8731: `http://<machine>:8732`.
  On upgrade, the firewall changes by itself. You only change a bookmark. (#103)
- [Caddy](https://caddyserver.com) now answers on ports 8731 (API) and 8732 (dashboard). It sends
  the requests on to Halogen and the dashboard, which listen on the machine only. This is the first
  step to HTTPS (#102). Nothing changes for apps: the address and key stay the same, and replies
  still stream. While Halogen starts, the API answers with a short note and doesn't refuse the
  connection. If you used `systemctl edit halos-dashboard` (`IPAddressAllow=`) to let other
  networks see the dashboard, put those ranges in `/etc/halos/proxy.env` as
  `HALOS_DASHBOARD_ALLOW=`. The old setting no longer lets them in. (#104)
- HTTPS for the API and the dashboard: `sudo halosctl https self-signed` turns it on with halOS's
  own certificate authority. Copy the authority to your apps once with `sudo halosctl https ca`.
  To use your own certificate and key, run `sudo
  halosctl https custom <certificate> <key>`. Then plain `http://` redirects. HTTPS stays off until
  you turn it on, even after an upgrade. (#105)

## v0.20.1-alpha.2 (2026-11-11)

- The dashboard can no longer leak the API key in a crash report, and it may listen only on its
  own port. The selftest checks that its private-networks rule is really on. (#101)

## v0.20.1-alpha.1 (2026-11-10)

- A live dashboard of Halogen at `http://<machine>:8790`. It shows if Halogen is up, speed, busy
  slots, queue, KV pool, prompt cache and NPU, with charts up to 30 days. It is
  [halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) by Quaternion, built in
  unchanged. It uses about 12 MB of memory, and 430 MB of disk when it holds 30 days. It is on by
  default, even after an upgrade, with no login: anyone on your network can see it, but nobody can
  change anything. `sudo halosctl dashboard off` stops it, and `on` starts it again. (#98)
- The dashboard has more limits: it answers only this machine and private networks (home, office,
  Tailscale), uses at most one CPU core and writes no core files. The build doesn't run the
  install scripts of packages when it makes the dashboard's web page. (#99)
- Halogen 0.20.1: follow-up turns start faster. Halogen caches the end of each reply, on by default
  (about 0.4 GiB more RAM at 4 slots). A turn that ended inside its reasoning now gets its answer. A
  routine `kv pool` line no longer shows red in the logs. The Flash checkpoints and the NPU model
  files are unchanged, so nothing new downloads. Halogen no longer reads the setting
  `HALOGEN_FORK_AUTO_KEEPS`, and it ignores `HALOGEN_FORK_MAP=auto` with one line at start. A
  `halogen.env` that still has one of them keeps working. (#95)
- Hardening from the security reviews of #91, #93 and #94 (#96):
  - `halosctl version` says if halOS checks the signatures of updates. When it doesn't, the SSH
    login message warns. The selftest's new `signature-files` line warns if the policy, the
    registry setting or halOS's key differs from the image's copies, or if root has a policy of
    its own.
  - `halosctl upgrade` doesn't reboot by itself when the name it follows points to an older build.
    A switch refuses a changed halOS public key file.
  - SSH unlock keeps the fingerprints of the keys and of the early-boot host key on the encrypted
    disk. When the EFI partition's copies change, the selftest and `halosctl ssh-unlock` warn. If
    you then set up the keys again, halOS makes a new host key.
  - `sudo halosctl ssh-passwords off` allows SSH logins with keys only, when your account has a
    key. Setup offers it.
- `sudo halogenctl flash convert <repo>` converts full-precision Qwen3.8 Flash Next weights (BF16
  safetensors) into your own Flash checkpoint on the machine. It uses bf16-to-hgn, which is built
  into the image and uses only the CPU. It checks the model before the 360 GB download, and runs as
  its own service (many hours, probably a day or more). It checks the result twice and removes the
  downloaded weights (`--keep-source` keeps them). `convert-logs` follows it, and `convert-stop`
  stops it. (#97)
- The guided installer asks how an encrypted disk unlocks: TPM and SSH (recommended), TPM only,
  SSH only, or the passphrase at the keyboard. For SSH, it takes your public keys from GitHub,
  GitLab or Codeberg, or a key that you paste. The installer can also let the same keys log the
  admin user in (it asks; the default is no). First-boot setup then uses that choice as its
  default. (#13, #94)
- Unlock the disk over SSH at boot (#13): when the TPM can't unlock the disk, type the passphrase
  from another computer with `ssh root@<machine>`. To turn it on, run `sudo halosctl ssh-unlock on
  --github <user>` (or `--gitlab`, `--codeberg`, `--key`), or use `sudo halosctl setup`. The
  selftest shows it as `ssh-unlock`. (#93)
- Machines accept only images signed with halOS's key (#46). New installs check from the start.
  Older installs turn the check on with their next `sudo halosctl upgrade` after this release,
  which says so and asks. Releases before `0.19.1-alpha.3` aren't signed, so `rollback --to` can't
  reach them. halOS accepts images from other registries (Halogen's own, your own podman
  containers) as before. The selftest reports it as `image-signatures`. (#91)
- Image builds: the build downloads the signing tool before it pushes anything, and tries the
  download again for up to five minutes. A GitHub outage during the weekly stable refresh had left
  the `0.20.0` tag on an unsigned rebuild. (#90)
- `flash pull` and `flash verify` add the official tokenizer's vocabulary to a checkpoint whose
  `tokenizer/` folder has no `tokenizer.json`, and keep the checkpoint's own chat template.
  (Signal-3.8-Flash-Next-HGN-v2 ships only its chat template and settings.) Halogen couldn't start
  on such a checkpoint and restarted every 30 seconds. A checkpoint that still has no vocabulary,
  or has one of its own, now fails verify, so `flash use` refuses it. For a checkpoint pulled
  before this change, run `sudo halogenctl flash verify
  <name>`, then `sudo halogenctl restart` if Halogen serves it. (#88)

## v0.20.0 (2026-11-09)

The first stable release on Halogen 0.20.0, promoted from `v0.20.0-rc.2`. It has everything since
`v0.19.0-beta.1`, listed under the releases below. freyja was also reinstalled with the guided
installer, and it passed restarts, tab completion and a `model pull` of OvisOCR3.

## v0.20.0-rc.2 (2026-11-08)

Built from main, so it has one change in addition to the beta's notes (#86):

- `halogenctl model list` shows an NPU model as in use when one of your own checkpoints runs on it
  ("yes, for OvisOCR3") or the agent guard adds it. Before, it said "no". (#87)

## v0.20.0-rc.1 (2026-11-08)

Promoted from `v0.20.0-beta.1`, with no change.

## v0.20.0-beta.1 (2026-11-08)

Promoted from `v0.20.0-alpha.3`: the first beta on Halogen 0.20.0, with everything since
`v0.19.0-beta.1`. On freyja it passed the selftest. In `bench`, the power profile was at
`performance` and the fabric clock held. Earlier, it passed `bench`, `flash check` and
`halosctl npu off`/`on`.

## v0.20.0-alpha.3 (2026-11-08)

No change for users: the only change is the release notes for alpha.1 (#85). It has the same code
as alpha.2.

## v0.20.0-alpha.2 (2026-11-08)

- The power profile's boot service can now write only the one file that it sets, and it has no
  special rights, as the security review of #83 suggested. Nothing changes in use. (#84)

## v0.20.0-alpha.1 (2026-11-08)

- `halogenctl bench` reported that the GPU fabric clock was not held when it was. It now asks for
  the clock the same way as the selftest. `flash check` prints its numbers rounded, no longer shows
  a short download problem as an error, and gives the time it took on the test machine. (#81)
- **Halogen 0.20.0** ([its changelog](https://github.com/peonist-ai/halogen-flash-server/blob/8242b157ce78fd720f5b3da18d398d2fb8cebce5/CHANGELOG.md)):
  its image moves to ROCm 10.1 (less power when it generates, same speed). Halogen reads prompts a
  few percent faster, and it fixes a crash with strict tool calls under load. New: document
  parsing on the NPU with your own OvisOCR3 (`sudo halogenctl model pull ATH-MaaS/OvisOCR3`;
  INSTALL.md tells how to serve it). The Flash checkpoint and every setting stay the same. At
  temperature 0, replies can differ from 0.19.1's in the last bits. (#78)
- `halogenctl selftest` no longer reports a `chcon` SELinux denial. bootc causes that denial when
  it checks its own rights (it expects the refusal), each time halOS asks it for status. Other
  denials still fail. (#82)
- **Power profile:** halOS now sets the firmware's power profile to `performance` at every boot.
  Some machines, freyja among them, ship at `balanced`. On freyja, Halogen read prompts about 22%
  faster at `performance`. `sudo halosctl power balanced` (or `low-power`) selects a cooler,
  quieter profile, at once and for every boot. `sudo halosctl power` shows it, and the selftest
  warns when it isn't as chosen. (#83)

## v0.19.1-alpha.6 (2026-11-08)

No change for users: the project notes and roadmap are now up to date (#79).

## v0.19.1-alpha.5 (2026-11-08)

- **Hardening:** programs that run as the `halogen` user (Halogen's helpers, and anything that
  might break out of its container) can no longer type into an admin's root terminal or send it
  escape codes. `halogenctl` gives the scripts that it runs as `halogen` no access to your
  terminal. `status`, `selftest`, `api-key` and `model pull` remove control characters from
  anything that the `halogen` user could have written. The kernel's terminal-injection call
  (`TIOCSTI`) is already off in Fedora's kernel, and a setting keeps it off. (#76)
- Images now have a label that tells their edition (NPU or no-NPU). `halosctl` checks it before a
  switch. On a pinned machine, it also reads the label to find the edition of a build that waits
  for the next boot. Before, it asked you to reboot first. Images from before this change have no
  label, so for those it still asks. (#77)
- Tab completion for `halogenctl`, `halosctl` and `halogen-enroll-tpm`: commands, options,
  channels and LUKS devices. (#75)
- `sudo halogenctl flash check <name>` compares your own Flash checkpoint with the official one,
  with Halogen's `ppl`, on the same public text that Halogen's docs use. It measures perplexity, how
  often both pick the same next word, and how far apart their predictions are. Halogen stops while
  it runs and starts again after. `flash list` shows the result. (#74)
- `sudo halogenctl bench` measures how fast the server reads prompts and writes answers, with
  Halogen's own benchmark tool, without a restart. The report lists what the numbers depend on
  (versions, BIOS, kernel settings, power profile, checkpoint, settings). It is saved in
  `/srv/configs/bench/`, so you can compare later runs. `--quick` takes less than a minute. It uses
  the prompt cache as your server does, so its prompts can make the cache drop long cached
  conversations once. (#73)
- `sudo halosctl npu off` moves a machine to the no-NPU edition, and `npu on` moves it back. The
  machine keeps its channel (or exact release) and everything in `/srv`. It warns when you turn
  the NPU on for a machine that has none, and it says clearly what you lose when you turn the IOMMU
  off. A channel switch or `rollback --to` now keeps an edition change that waits for the next
  boot. When halosctl can't tell (a machine pinned to one release), it asks you to reboot first
  and doesn't guess. (#72)

## v0.19.1-alpha.4 (2026-11-07)

- halOS now tells you about a setting written twice in `halogen.env` (easy to do when you paste
  from the example file). `halogenctl status`, `config` and `options` name it, and Halogen's log
  says which line it uses (the last one). Nothing changes in what Halogen receives. (#71)
- When you restart Halogen yourself (`sudo halogenctl restart`, `flash use`, or after a settings
  change), the restart now always works. Before, a few restarts in a row hit Halogen's crash-loop
  guard ("start of the service was attempted too often"). Only automatic restarts should count
  towards that guard. (#70)
- **Security fixes from the full audit:**
  - halOS checks your own NPU checkpoints offline, with no access to your Hugging Face token,
    before the download step. The download step no longer reads them itself.
  - `model pull`'s download and check see only the folder of that checkpoint, and the check sees
    it read-only. `--revision` or `--as` with nothing after it no longer hangs.
  - `model list` prints no folder name that holds terminal control codes.
  - The docs no longer say that Halogen serves "offline": it never downloads, but its container
    can reach the network.
  - When your own checkpoints are counted in, the download log no longer claims more downloaded
    data than the estimate.
  - The build and release workflows use GitHub's actions pinned to exact commits. So a moved
    version tag can't change what runs beside the signing key. (#69)
- The installer, `halosctl setup` and the docs now say clearly what TPM unlock protects: a disk
  taken out of the machine, not the whole machine taken away. INSTALL.md section 8 tells how to
  protect the machine too (BIOS password, USB boot off, a boot menu password). (#68)
- The serial login prompt no longer restarts every 10 seconds on machines whose first serial port
  doesn't work (freyja logged "failed to get terminal attributes" from boot). A serial login
  prompt now starts only on a port that answers, and new installs get no serial console at all.
  (#67)
- **Guided installer.** The first boot menu entry asks only for the disk, the machine's name,
  encryption, root and the admin user, on a text screen. Then it installs by itself. It never
  offers USB drives. If a disk has data on it, or if there is a choice of disks, you must type the
  disk's name. Every machine gets the same volume names (`halos-root`, `halos-models` and more).
  The full graphical installer stays as "custom partitioning". (#66)

## v0.19.1-alpha.3 (2026-11-07)

- halOS also signs images with its own key, and every image has its public key at
  `/etc/pki/containers/halos-flash.pub`. A later release makes machines refuse images without
  that signature. (#65)
- This changelog, and [ROADMAP.md](ROADMAP.md): what comes next on the way to a stable release.
  (#62)
- **"API ready" at a glance.** The login screen shows Halogen's state: downloading with a
  percentage, checking, starting, or `ready` with the address. The SSH login message shows the
  same, with the release, channel and any staged update. When Halogen first answers after a boot,
  logged-in users get a one-time notice. (#63)
- **First-boot setup.** `sudo halosctl setup` asks how the disk unlocks (TPM or passphrase), for
  an optional Hugging Face token, and if you want to edit the settings. On a new install, the first
  download waits for setup, up to 30 minutes, so the token and settings apply from the start.
  `--skip` starts the download at once. Upgraded machines never wait. (#64)

## v0.19.1-alpha.2 (2026-11-06)

- **Your own Flash checkpoint.** `sudo halogenctl flash pull|list|use|verify|remove` runs a
  community or self-trained `.hgn` build of the Flash model in place of the official one. The
  official one always stays downloaded. A pull fetches only what Halogen loads, at an exact
  commit. It checks every file against the repository's hashes and with Halogen's `verify`, and
  halOS checks the checkpoint again after each Halogen update. See
  [INSTALL.md](INSTALL.md#your-own-flash-checkpoint). (#60)
- The model download and `model pull` no longer get the NPU device. (#60)

## v0.19.1-alpha.1 (2026-11-06)

- **Halogen 0.19.1.** Its image now has AMD's XRT, so halOS no longer ships or mounts its own.
  (#58, #59)
- **New Halogen options are easy to find.** `sudo halogenctl options --new` lists the options
  that your `halogen.env` doesn't name yet. `/srv/configs/halogen.env.example` holds every option,
  and halOS writes it again at each boot. Each release attaches the lists of both editions. halOS
  never changes `halogen.env` itself. (#57)
- **Security hardening** from a full audit:
  - Root never reads or writes in the `halogen` user's folders. (#51)
  - The root boot services run in a sandbox.
  - Halogen's checks run without network.
  - halOS tightens the kernel settings that cost nothing.
  - SSH X11 forwarding is off.
  - halOS pins the installer builder. (#52)
  - Halogen's container runs with no capabilities. (#53)
- `sudo halogenctl model list` is now easy to read. (#55)
- halOS rebuilds edge every week, so machines get Fedora fixes also in weeks with no halOS change.
  (#54)

## v0.19.0-beta.1 (2026-11-06)

Promoted from `v0.19.0-alpha.4`. Freyja passed the beta hardware checklist:
- TPM unlock
- `halosctl` switch, upgrade and rollback, each of which keeps `/srv`
- selftest 30 of 30

## v0.19.0-alpha.5 (2026-11-06)

- halOS signs every pushed image with cosign, keyless. Machines don't check the signature yet.
  (#50)

## v0.19.0-alpha.4 (2026-11-06)

- No more fstab warning at every boot. When there is nothing new, `halosctl upgrade` says
  "Already up to date" and doesn't ask. (#49)

## v0.19.0-alpha.3 (2026-11-05)

- To cut a release, you select alpha, beta, rc or stable. The workflow calculates the number, and
  beta, RC and stable promote the newest release one step below. (#48)
- Fixes the failed `v0.19.0-alpha.2` release run. That tag exists, but it has no release. (#47)

## v0.19.0-alpha.2 (2026-11-05, tag only)

- **`halosctl`**, one command for the OS: `version`, `switch <channel>`, `upgrade`, `rollback
  [--to]` and `history`. Channels follow newer, more stable releases. (#41)
- Root can never log in over SSH. (#45)
- When Halogen waits at boot, the selftest shows a warning. The image now has `wireless-regdb`.
  (#39)

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
- When you enroll the TPM again, it replaces the old binding. (#21)

## v0.18.23-alpha.2 (2026-11-05)

- **Boot and install fixes:**
  - LUKS boots on real hardware
  - better default partitioning
  - TPM unlock is tested (#12)

## v0.18.23-alpha.1 (2026-11-04)

- First release, with Halogen 0.18.23. (#6, #9, #10, #11)
