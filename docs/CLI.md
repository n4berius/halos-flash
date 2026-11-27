# halOS command reference

halOS has three commands of its own. Run them with `sudo`. `halosctl help` gives the same
data in short form. If you give `halogenctl` a command that it doesn't know, it prints a summary
of one line.

| Command | What it controls |
|---|---|
| [`halosctl`](#halosctl-the-operating-system) | The operating system: updates, editions, power, SSH, the dashboard, HTTPS |
| [`halogenctl`](#halogenctl-halogen-and-its-models) | Halogen: the server, its settings, models and checkpoints, checks and benchmarks |
| [`halogen-enroll-tpm`](#halogen-enroll-tpm) | The TPM unlock of the encrypted disk |

[INSTALL.md](../INSTALL.md) tells how to install, and [Running halOS](GUIDE.md) tells the
reasons for each feature. This page tells what each command does. Halogen's
[FLAGS.md](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md) tells about
Halogen's own settings (`HALOGEN_*` in `/srv/configs/halogen.env`).

Common options:

- `--yes` gives the answer yes to the question that a command asks before it changes
  something. The tables show which commands have it. Without a terminal (a script,
  `ssh host cmd`), these commands refuse unless you give `--yes`. The commands without it
  (`start`, `stop`, `restart`, `power`, `dashboard`, `records stats`) don't ask. `model remove`
  always asks, in a terminal.
- Press Tab to complete commands, options and names, also after `sudo`. For `halogenctl`, Tab
  also completes the names of your checkpoints and models: `flash use`, `flash check`,
  `flash remove`, `flash verify`, `flash drafter` (and its draft head files), `flash convert-stop`,
  `model remove`, and `--as` of `flash pull` and `model pull` (to update a model that you have).
  These names come from `/run/halos/model-names`, which halOS updates every 30 seconds and after
  each pull or removal. Only members of the `wheel` group (the administrators) can read it.
- `--reboot` restarts the machine immediately after an OS change, not at your next reboot.
  A reboot stops Halogen until the machine is back. In two cases it does not restart, and waits
  for you: while models download, and when an upgrade stages an older build than the one that
  runs.

## halosctl: the operating system

### Updates

| Command | What it does |
|---|---|
| `halosctl version` | Shows the release that runs, its edition, the channel that it follows, what starts at the next boot, the rollback image, and if updates must have halOS's key signature. This is the default when you give no command. |
| `halosctl upgrade [--check] [--reboot] [--yes]` | Downloads the newest release on your channel and stages it for the next boot. `--check` only tells if there is a newer release. |
| `halosctl switch alpha\|rc\|release\|edge\|kernel-next [--reboot] [--yes]` | Follows a different channel. `release` is the stable channel. `alpha` and `rc` are test releases. `beta` still works and gets the same releases as `rc`. There are no more beta releases. `edge` is every change to `main`. `kernel-next` is `edge` with a test kernel (a Linux 7.4 release candidate) in place of the Fedora 45 kernel. Each channel also gets the newer releases of the more stable channels. |
| `halosctl rollback [--to <release>] [--reboot] [--yes]` | Starts the previous image at the next boot. With `--to`, it starts an exact release, for example `0.20.7-1-stable` or an older name such as `0.20.0`. An exact release such as `0.20.7-1-stable` never changes, so it gets no weekly Fedora fixes. With a plain version such as `0.20.7`, the machine is not pinned: it follows the newest stable release of that Halogen version and its weekly rebuild. |
| `halosctl npu on\|off [--reboot] [--yes]` | Moves to the NPU edition (`on`) or to the no-NPU edition (`off`: the IOMMU is off for faster prefill). It keeps the channel and `/srv`. |
| `halosctl history` | Shows each change that halosctl made: when, what, from what to what, and who. |

Changes to the OS apply at the next reboot. halOS checks each update against its signing key.
The `Signatures:` line of `version` shows this.

### First boot and the machine

| Command | What it does |
|---|---|
| `halosctl setup [--skip]` | Asks the first-boot questions: TPM unlock, unlock from a tang server, SSH unlock, SSH logins with keys only, your Hugging Face token, the settings screen and HTTPS. On a new install, Enter turns on `https self-signed`. An upgraded machine keeps plain HTTP unless you answer yes. On a new install, Halogen waits for setup (up to 30 minutes). `--skip` starts Halogen with the defaults. |
| `halosctl power [low-power\|balanced\|performance]` | Sets the firmware's power profile, now and at each boot. `performance` (the default) serves fastest. The other profiles use less power, and the machine is cooler and slower. Without a profile name, it shows the current profile. |

### SSH

| Command | What it does |
|---|---|
| `halosctl ssh-unlock` | Shows if you can unlock the encrypted disk over SSH at boot, and with which keys. |
| `halosctl ssh-unlock on --github <user>` (or `--gitlab`, `--codeberg`, `--key '<public key>'`, several allowed) `[--yes]` | Lets these keys unlock the disk over SSH at boot, when the TPM can't. It prints the lines that your SSH client needs. |
| `halosctl ssh-unlock off [--yes]` | Turns off the SSH unlock. |
| `halosctl ssh-unlock record [--yes]` | Records the fingerprints of the unlock keys, so that the selftest finds a change. |
| `halosctl tang-unlock` | Shows if a tang server on your network unlocks the encrypted disk at boot, which servers, and if the TPM must agree too. |
| `halosctl tang-unlock on <server>... [--tpm and\|or\|off] [--thp <key>]... [--yes]` | Lets these tang servers (`http://<address>[:port]`) unlock the disk at boot. It shows the key of each server to compare with `tang-show-keys` on the server, or takes it from `--thp` (one for each server, in the same order; the SHA-256 key of 43 characters that `tang-show-keys` prints). `--tpm and` (the default with a TPM): the TPM must agree too. `off`: the server alone. `or`: the TPM alone also unlocks. `and` and `or` need Secure Boot on. It asks for the disk passphrase. It replaces all servers from before. |
| `halosctl tang-unlock renew [--thp <key>]... [--yes]` | Binds again to the same servers, in the same way, with the keys they were bound to. It stops if a server now signs with a different key: then use `tang-unlock on` with the same `--tpm` mode and compare the new key. `--thp` gives one key for each server, in the order that `sudo halosctl tang-unlock` shows them. Use it after a BIOS or Secure Boot change (with `--tpm and`). |
| `halosctl tang-unlock off [--yes]` | Removes the tang unlock. Then `halogen-enroll-tpm` can add the TPM unlock again. |
| `halosctl ssh-passwords [on\|off] [--yes]` | `off`: SSH logins with keys only (first, your account needs a key). `on`: passwords are possible again. Without `on` or `off`, it shows the current state. The console always accepts the password. |

### Network: fail2ban, the dashboard and HTTPS

| Command | What it does |
|---|---|
| `halosctl fail2ban` | Shows if [fail2ban](GUIDE.md#fail2ban) is on, and which addresses it blocks now because of failed SSH logins (`sshd`) or API keys (`halos-api`). |
| `halosctl fail2ban on\|off` | Turns fail2ban on (the default) or off. `off` also removes all blocks. |
| `halosctl fail2ban unban <address>` | Removes the block on one address immediately. |
| `halosctl dashboard [on\|off]` | Turns on or off the live web page of Halogen's load and health on port 8732. The page is for your local network and has no login. Without `on` or `off`, it shows the state and the address. |
| `halosctl https` | Shows if HTTPS is on, and what apps use. |
| `halosctl https self-signed [<name>...] [--yes]` | Turns on HTTPS on the three ports (8731, 8732 and 8730) with halOS's own certificate authority. The certificates are for the names and addresses of this machine, and for other names that you give. Apps must trust the authority one time. |
| `halosctl https custom <certificate> <key> [--yes]` | Turns on HTTPS with your own certificate and key (PEM files, the key without a passphrase). It shows whose certificate it is, and asks before it changes something. |
| `halosctl https letsencrypt <cloudflare\|duckdns\|porkbun\|namecheap> <name>... [--email <address>] [--staging] [--yes]` | Turns on HTTPS with Let's Encrypt certificates for public names that you own, through the API of your DNS provider. It opens no port to the internet. It asks for the provider's credential, and does not show it while you type. With `--yes`, it reads the credential as `field=value` lines on standard input. Then it waits for the certificate. If no certificate comes in five minutes, it puts back the previous setting. `--staging` uses the Let's Encrypt test service first. The addresses of this machine keep halOS's authority. |
| `halosctl https forget-dns [--yes]` | Deletes the saved credential of the DNS provider, when you no longer use Let's Encrypt. It restarts the front door for a short time, so that Caddy also removes its copy. Also revoke the credential at the provider. |
| `halosctl https ca` | Prints halOS's authority (PEM) for your apps: `sudo halosctl https ca > halos-ca.crt`. See [trusting it](CLIENTS.md#trust-it-per-app-or-on-the-whole-computer). |
| `halosctl https off [--yes]` | Goes back to plain HTTP. |

When HTTPS is on, each port redirects `http://` requests to `https://`. If Caddy doesn't answer
after a change, halOS puts back the previous setting automatically.

## halogenctl: Halogen and its models

### The server

| Command | What it does |
|---|---|
| `halogenctl status` | Shows the state of the download-and-check step and of the server, and which Flash checkpoint Halogen serves. This is the default. |
| `halogenctl start`, `stop`, `restart` | Starts, stops or restarts Halogen. Before a restart, it downloads only what is missing or changed. |
| `halogenctl logs [lines]` | Shows the logs of Halogen and of the download step together (100 lines by default). On a terminal, it shows new lines as they come. |
| `halogenctl fetch-logs [lines]` | Shows only the log of the download-and-check step. |
| `halogenctl api-key` | Prints the API key that apps need (`/srv/configs/api-key`). |
| `halogenctl api-key status` | Shows if Halogen requires the [API key](GUIDE.md#the-api-key) (on, the default) or not (off). |
| `halogenctl api-key on\|off [--yes]` | Requires the API key again, or stops requiring it. `off` asks first, and refuses while web search is on. If Halogen runs, both restart it. The key itself does not change. |
| `halogenctl cache [status]` | Shows if Halogen's [prompt cache on disk](GUIDE.md#prompt-cache-on-disk) is on, and the space that it uses. |
| `halogenctl cache on\|off [--yes]` | Turns the cache on (the default) or off. If Halogen runs, it restarts Halogen. `off` keeps the saved data, and then Halogen can only read the folder. |
| `halogenctl cache clear [--yes]` | Asks, then deletes all saved conversation states. It stops Halogen for a short time and starts it again. |
| `halogenctl records [on\|off] [--yes]` | Controls Halogen's [request records](GUIDE.md#request-records): one line for each request in `/srv/logs/halogen`. They contain only counts, unless `HALOGEN_RECORD_TEXT` sets a different value. `on` and `off` restart Halogen. Without `on` or `off`, it shows the state and the space used. |
| `halogenctl web-search` | Shows if [web search](GUIDE.md#web-search) is on, and if the search answers. |
| `halogenctl web-search bundled [--yes]` | Turns on web search with SearXNG on this machine. Its page is on port 8730. Halogen restarts. Refused while the API key is off. |
| `halogenctl web-search external <url> [--yes]` | Turns on web search with your own SearXNG server, through a relay that goes only to that server. It first checks that the server answers a search in JSON. Only searches pass through the relay. Halogen restarts. Refused while the API key is off. |
| `halogenctl web-search off [--yes]` | Turns web search off. Halogen restarts. SearXNG's settings stay. |
| `halogenctl web-search edit` | Opens SearXNG's settings (`/srv/configs/searxng/settings.yml`) in an editor, then restarts SearXNG. |
| `halogenctl web-search restart` | Restarts the search, for example after you change its settings. |
| `halogenctl records stats` | Shows counts by API, client and finish, the part that the cache supplied, and tool errors. It uses Halogen's own tool: inside Halogen's container while it runs, else in a short-lived copy of the pinned image with only the records folder. |
| `halogenctl records prune --days <n>\|--gib <g>\|--session <hash>\|--unit <hash>\|--all [--yes]` | Asks, then deletes records. |
| `halogenctl hf-token [--remove]` | Asks for your Hugging Face read token and saves it, for gated models. It does not show the token. `--remove` deletes it. |

### Settings

| Command | What it does |
|---|---|
| `halogenctl settings [--editor] [--no-restart]` | Opens the settings screen: the Flash checkpoint, the draft heads, a checklist of NPU models, and Halogen's settings, each with its default. You pick on/off settings, choices and usual numbers from a list, and the screen checks each value that you type. It saves all changes together, then restarts Halogen one time if you choose that. `--editor` opens `halogen.env` in an editor instead. `--no-restart` saves only (`halosctl setup` uses it). See [the settings screen](GUIDE.md#the-settings-screen). |
| `halogenctl config` | Shows the settings that Halogen gets: your allowed settings from `/srv/configs/halogen.env`, then the settings that halOS locks. |
| `halogenctl options [--new]` | Shows each option of this release, and if it is set, commented out or new in your file. `--new` shows only the options that your file doesn't mention. |
| `halogenctl doctor` | Checks the settings and the machine before a start (halOS's own checks), and tells what to change. |

To change the settings, run `sudo halogenctl settings`. You can also edit the file with `sudo nano /srv/configs/halogen.env`, then run `sudo halogenctl restart`.

### Checks and speed

| Command | What it does |
|---|---|
| `halogenctl selftest` | Runs the checklist of the hardware and the setup. It changes nothing. It shows PASS, WARN, FAIL, SKIP or INFO for each item, with what to do. |
| `halogenctl bench [--quick]` | Measures the server while it runs, with Halogen's own tool, and saves the report in `/srv/configs/bench/`. `--quick` takes less than a minute. |
| `halogenctl bench tools [--quick]` | Measures how well the model calls tools, with [tool-eval-bench](https://github.com/SeraphimSerapis/tool-eval-bench), while the server runs. A full run is 69 scenarios, three times each, at the settings of the public leaderboard, and takes tens of minutes or more. `--quick` is 15 scenarios, one time. The report goes in `/srv/configs/bench/tools/`. |

### Your own NPU checkpoints (NPU edition)

| Command | What it does |
|---|---|
| `halogenctl model pull <hf-repo> [--revision <rev>] [--as <name>] [--qad]` | Downloads a checkpoint that Halogen's NPU runs (for example `LiquidAI/LFM3-1.7B`) into the correct folder. `--qad` also downloads Liquid's own 4-bit file for an LFM3-1.7B, from the exact repository and commit that Halogen's image names. Halogen can then serve it as `<path>:qad`, the fastest form (since Halogen 0.20.6). The weights of this file are Liquid's, not those of a fine-tune. |
| `halogenctl model list` | Shows your NPU checkpoints, and which of them are in use. |
| `halogenctl model remove <name>` | Asks, then deletes one checkpoint. It refuses while the checkpoint is in `HALOGEN_NPU_MODELS`. |

### Your own Flash checkpoint

| Command | What it does |
|---|---|
| `halogenctl flash pull <hf-repo>\|27b [--revision <rev>] [--as <name>] [--file <checkpoint.hgn\|build.gguf>] [--keep-gguf]` | Downloads a Flash checkpoint in Halogen's format. It checks the checkpoint against the hashes from Hugging Face and with Halogen's `verify`. From a GGUF repository, it downloads one build, converts it one time into a `.hgn` with Halogen's `convert`, then deletes the GGUF (`--keep-gguf` keeps it). See [Pulling a GGUF](GUIDE.md#pulling-a-gguf). `27b` in place of a repository downloads Peonist's Qwen3.8-27B (`peonist-ai/halogen-qwen3.8-27b-ht4`) as `qwen3.8-27b`, a smaller model for a machine short of memory (see [Qwen3.8-27B](GUIDE.md#qwen38-27b-when-memory-is-short)). `27b` downloads only the commit and the files that this release pins, and checks each file against the pinned sha256. It doesn't take `--revision`. |
| `halogenctl flash list` | Shows the official checkpoint and yours, and which one Halogen serves. |
| `halogenctl flash use <name>\|official\|auto [--yes]` | Asks, then switches Halogen to that checkpoint and restarts Halogen immediately (`--yes` skips the question). halOS always keeps the official checkpoint. `auto` (also when you never chose) goes by memory: under 100 GiB, Qwen3.8-27B (`qwen3.8-27b`, which the next start downloads), else the official checkpoint. See [Qwen3.8-27B](GUIDE.md#qwen38-27b-when-memory-is-short). |
| `halogenctl flash drafter [<name>] [official\|official-r2\|off\|<file>] [--yes]` | Sets the draft head that your checkpoint uses. Without `<name>`, it sets the checkpoint that Halogen serves. `official` (the default) is Halogen's official draft head (`qwen38-flash-next-drafter-r2-ht4.hgn`), which the official checkpoint always uses. `official-r2` is the draft head of Halogen 0.20.6 (`qwen38-flash-next-drafter-r2.hgn`), if it is still in `/srv/models`. `off` is the draft head inside the checkpoint. `<file>` is a draft head file that the checkpoint's repository supplies: `flash pull` downloads it, checks it against the repository's hash and shows its name. You can also give the name of a draft head file as `ls /srv/models` or `ls /srv/models/flash/<name>` shows it, or its full path. The command does not accept other files, because Halogen's container sees only `/srv/models` and halOS uses only draft heads whose hash it checked. If a name does not match, the command shows the choices. The answers do not change, because the model checks each token that a draft head proposes. Only the speed changes, so compare `halogenctl bench` with each setting. A checkpoint with a quality sidecar (`<checkpoint>.overlay.hgn`) keeps the sidecar. If Halogen serves the checkpoint, the command asks, then restarts Halogen. Without a setting, it shows the setting and the choices. A Qwen3.8-27B checkpoint takes no draft head file, so the command refuses it. |
| `halogenctl flash verify <name>` | Runs Halogen's `verify` on the checkpoint again. |
| `halogenctl flash check <name> [--yes]` | Compares the quality of the checkpoint with the official one (perplexity on a standard text). It stops Halogen during the check, then starts it again. Not for a Qwen3.8-27B checkpoint, which is a different model. |
| `halogenctl flash convert <hf-repo> [--revision <rev>] [--as <name>] [--threads <n>] [--keep-source] [--yes]` | Converts full-precision weights to Halogen's format on this machine. This takes many hours, possibly a day or more, and about 480 GB of space. |
| `halogenctl flash convert-logs [lines]`, `flash convert-stop [<name>] [--yes]` | `convert-logs` shows the progress of a conversion. `convert-stop` stops it. With a name, it also asks, then deletes the downloaded weights of that conversion. Without a name, it shows what stays on the disk. |
| `halogenctl flash remove <name> [--yes]` | Deletes one of your checkpoints (not the one in use). |

Only one command at a time can work on a checkpoint. While one of `pull`, `convert`, `verify`,
`check`, `use`, `drafter` and `remove` works on a name, a second command on the same name refuses with "Another
… is running". The same applies to `model pull`/`model remove` of the same model. After you
answer, `use` and `remove` check again that nothing changed in the meantime.

While a `flash check` measures, these commands refuse after you answer: a second check,
`flash use`, `start`, `restart` and the restart that `model pull` offers. They tell you, and change
nothing. Run them again when the check is complete. Commands on different checkpoints can run at
the same time.

## halogen-enroll-tpm

`sudo halogen-enroll-tpm [device]` binds the encrypted disk to the TPM of this machine. Then the
disk unlocks automatically at boot. Run the command again after one of these changes: a BIOS
update, a Secure Boot change, or a firmware update of the Secure Boot lists (the dbx). They
change what the TPM checks, so the next boot asks for the passphrase one time. Keep the
passphrase: it is your recovery key.

The command refuses when Secure Boot is off. The TPM checks the Secure Boot state (PCR 7), and
with Secure Boot off that check does not stop a changed boot loader from getting the key.

When a tang server unlocks the disk with `--tpm and` or `--tpm off` (`halosctl tang-unlock`), the
command refuses: a TPM-only unlock would let the machine unlock away from your network. After a
BIOS or Secure Boot change, use `sudo halosctl tang-unlock renew` instead.

## Files

| Path | What it holds |
|---|---|
| `/srv/configs/halogen.env` | Your Halogen settings |
| `/srv/configs/halogen.env.example` | The template of this release, with every option |
| `/srv/configs/api-key` | The API key |
| `/etc/halos/api-key-off` | Present only while the API key is off (`sudo halogenctl api-key off`) |
| `/srv/configs/bench/` | Benchmark reports (`tools/`: the tool-calling benchmark, with every conversation) |
| `/srv/models/.prompt-cache/` | Halogen's prompt cache on disk: conversation states, which only `halogen` can read |
| `/srv/configs/prompt-cache` | `off` after `halogenctl cache off`. If not, the cache is on |
| `/etc/containers/systemd/users/halogen.container.d/15-prompt-cache.conf` | `halogenctl cache off` writes it, and `cache on` removes it. It mounts the cache folder read-only |
| `/srv/logs/halogen/` | Halogen's request records, when they are on |
| `/srv/configs/searxng/settings.yml` | SearXNG's settings, when web search uses SearXNG on this machine |
| `/etc/halos/web-search.env` | Which web search is on, and the address of your own SearXNG (root's, written by `halogenctl web-search`) |
| `/srv/models/` | The models, and your own checkpoints |
| `/etc/halos/https.env` | The HTTPS setting (only root can change it) |
| `/etc/halos/https/` | Your certificate and key, and the credential of the DNS provider for Let's Encrypt (only root) |
| `/srv/configs/hf-token` | Your Hugging Face token, if you saved one |
| `/run/halos/model-names` | The names of your checkpoints and models, for Tab completion (root writes it, the `wheel` group can read it) |
| `/srv/configs/flash-checkpoint` | The Flash checkpoint that `flash use` chose (`official`, `auto` or a name; no file is `auto`) |
| `/srv/configs/flash-drafter` | The draft head of each of your Flash checkpoints that does not use the official one (`flash drafter`), as `<name>=off`, `<name>=official-r2` or `<name>=<file>` |
| `/etc/halos/proxy.env` | Optional: more networks that can see the dashboard (`HALOS_DASHBOARD_ALLOW`) |
| `/var/lib/halos/history` | What `halosctl history` shows |
| `/var/log/audit/` | The audit log (`sudo ausearch -i -k halos-config`; [the keys](GUIDE.md#logs-and-the-audit-trail)) |
