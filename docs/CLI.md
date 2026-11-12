# halOS command reference

halOS has three commands of its own. Run them with `sudo`. `halosctl help` says the same in
short; `halogenctl` prints a one-line summary when given a command it doesn't know.

| Command | What it looks after |
|---|---|
| [`halosctl`](#halosctl-the-operating-system) | The operating system: updates, editions, power, SSH, the dashboard, HTTPS |
| [`halogenctl`](#halogenctl-halogen-and-its-models) | Halogen: the server, its settings, models and checkpoints, checks and benchmarks |
| [`halogen-enroll-tpm`](#halogen-enroll-tpm) | Unlocking the encrypted disk with the TPM |

How to install and the reasons behind each feature are in [INSTALL.md](../INSTALL.md); this page
lists what each command does. Halogen's own settings (`HALOGEN_*` in `/srv/configs/halogen.env`)
are described in Halogen's [FLAGS.md](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md).

Common options:

- `--yes` answers yes to the question a command asks before it changes something, where the
  table shows it. Without a terminal (a script, `ssh host cmd`), those commands refuse unless it
  is given. Commands without it (`start`, `stop`, `restart`, `power`, `dashboard`, `records stats`) don't ask;
  `model remove` always asks, in a terminal.
- `--reboot` restarts the machine at once after an OS change, instead of at your next reboot.
  A reboot stops Halogen until it is back. It waits for you instead while models are downloading,
  or when an upgrade would stage an older build than the one running.

## halosctl: the operating system

### Updates

| Command | What it does |
|---|---|
| `halosctl version` | The release running, its edition, the channel it follows, what boots next, the rollback image, and whether updates must be signed with halOS's key. The default when no command is given. |
| `halosctl upgrade [--check] [--reboot] [--yes]` | Fetches the newest release on your channel and stages it for the next boot. `--check` only says whether there is one. |
| `halosctl switch alpha\|beta\|rc\|release\|edge [--reboot] [--yes]` | Follows another channel. `release` is the stable one; `alpha`, `beta` and `rc` are test releases; `edge` is every change to `main`. Each channel also gets the newer releases of the more stable ones. |
| `halosctl rollback [--to <version>] [--reboot] [--yes]` | Boots the previous image next time, or, with `--to`, an exact release such as `0.20.0`. |
| `halosctl npu on\|off [--reboot] [--yes]` | Moves to the NPU edition (`on`) or the no-NPU edition (`off`, the IOMMU off for faster prefill), keeping the channel and `/srv`. |
| `halosctl history` | Every change made with halosctl: when, what, from what to what, and who. |

Changes to the OS apply at the next reboot. Each update is checked against halOS's signing key;
`version` says so on its `Signatures:` line.

### First boot and the machine

| Command | What it does |
|---|---|
| `halosctl setup [--skip]` | The first-boot questions: TPM unlock, SSH unlock, SSH logins with keys only, your Hugging Face token and your settings. Halogen waits for it (up to 30 minutes) on a new install. `--skip` starts with the defaults. |
| `halosctl power [low-power\|balanced\|performance]` | The firmware's power profile, now and at every boot. `performance` (the default) serves fastest; the others draw less power and run cooler and slower. Alone, it shows the profile. |

### SSH

| Command | What it does |
|---|---|
| `halosctl ssh-unlock` | Whether the encrypted disk can be unlocked over SSH at boot, and with which keys. |
| `halosctl ssh-unlock on --github <user>` (or `--gitlab`, `--codeberg`, `--key '<public key>'`, several allowed) `[--yes]` | Lets those keys unlock the disk over SSH at boot, when the TPM can't. It prints the lines your SSH client needs. |
| `halosctl ssh-unlock off [--yes]` | Turns it off. |
| `halosctl ssh-unlock record [--yes]` | Keeps fingerprints of the unlock keys, so the selftest notices a change. |
| `halosctl ssh-passwords [on\|off] [--yes]` | `off`: SSH logins with keys only (your account needs a key first). `on`: passwords again. Alone, it shows which. The console always takes the password. |

### The dashboard and HTTPS

| Command | What it does |
|---|---|
| `halosctl dashboard [on\|off]` | The live web page of Halogen's load and health on port 8732, for your local network, without a login. Alone, it shows the state and its address. |
| `halosctl https` | Whether HTTPS is on, and what apps use. |
| `halosctl https self-signed [<name>...] [--yes]` | HTTPS on both ports with halOS's own certificate authority, for this machine's names and addresses and any extra names you list. Apps must trust the authority once. |
| `halosctl https custom <certificate> <key> [--yes]` | HTTPS with your own certificate and key (PEM files, the key without a passphrase). It shows whose certificate it is and asks first. |
| `halosctl https letsencrypt <cloudflare\|duckdns\|porkbun\|namecheap> <name>... [--email <address>] [--staging] [--yes]` | HTTPS with Let's Encrypt certificates for public names you own, through your DNS provider's API; no port is opened to the internet. It asks for the provider's credential (not shown while you type; with `--yes`, as `field=value` lines on standard input), waits for the certificate and, if none comes within five minutes, puts the previous setting back. `--staging` uses Let's Encrypt's test service first. This machine's own addresses keep halOS's authority. |
| `halosctl https forget-dns [--yes]` | Deletes the saved DNS provider credential, once Let's Encrypt is no longer in use, and restarts the front door for a moment so Caddy lets go of its copy too. Revoke it at the provider too. |
| `halosctl https ca` | Prints halOS's authority (PEM), to give to your apps: `sudo halosctl https ca > halos-ca.crt`. See [trusting it](CLIENTS.md#trust-it-per-app-or-on-the-whole-computer). |
| `halosctl https off [--yes]` | Back to plain HTTP. |

With HTTPS on, `http://` on either port is redirected to `https://`. If Caddy doesn't answer
after a change, the previous setting comes back by itself.

## halogenctl: Halogen and its models

### The server

| Command | What it does |
|---|---|
| `halogenctl status` | The download-and-check step and the server, and which Flash checkpoint is served. The default. |
| `halogenctl start`, `stop`, `restart` | Starts, stops or restarts Halogen. A restart downloads only what is missing or changed first. |
| `halogenctl logs [lines]` | Halogen's log and the download step's together (100 lines by default), following them on a terminal. |
| `halogenctl fetch-logs [lines]` | Only the download-and-check step's log. |
| `halogenctl api-key` | Prints the API key apps need (`/srv/configs/api-key`). |
| `halogenctl records [on\|off] [--yes]` | Halogen's [request records](../INSTALL.md#request-records): a line per request in `/srv/logs/halogen`, counts only unless `HALOGEN_RECORD_TEXT` says otherwise. `on` and `off` restart Halogen. Alone, it shows the state and space used. |
| `halogenctl records stats` | Counts by API, client, finish, the cache's share and tool errors, from Halogen's own tool (Halogen must be running). |
| `halogenctl records prune --days <n>\|--gib <g>\|--session <hash>\|--unit <hash>\|--all [--yes]` | Deletes records, after asking. |
| `halogenctl hf-token [--remove]` | Saves your Hugging Face read token (asked for, not shown), for gated models; `--remove` deletes it. |

### Settings

| Command | What it does |
|---|---|
| `halogenctl config` | The settings Halogen gets: yours from `/srv/configs/halogen.env` that halOS allows, then the ones halOS fixes. |
| `halogenctl options [--new]` | Every option this release offers, and whether yours is set, commented out or new; `--new` lists only those your file doesn't mention. |
| `halogenctl doctor` | Checks the settings and the machine before a start (halOS's own checks), and says what to change. |

Edit settings with `sudo nano /srv/configs/halogen.env`, then `sudo halogenctl restart`.

### Checks and speed

| Command | What it does |
|---|---|
| `halogenctl selftest` | The hardware and setup checklist, read only: PASS, WARN, FAIL, SKIP or INFO for each item, with what to do. |
| `halogenctl bench [--quick]` | Measures the running server with Halogen's own tool, and saves the report in `/srv/configs/bench/`. `--quick` takes under a minute. |

### Your own NPU checkpoints (NPU edition)

| Command | What it does |
|---|---|
| `halogenctl model pull <hf-repo> [--revision <rev>] [--as <name>]` | Downloads a checkpoint Halogen's NPU runs (such as `LiquidAI/LFM3-1.7B`) into the folder that fits it. |
| `halogenctl model list` | Your NPU checkpoints, and which are in use. |
| `halogenctl model remove <name>` | Deletes one (asks first; refused while it is in `HALOGEN_NPU_MODELS`). |

### Your own Flash checkpoint

| Command | What it does |
|---|---|
| `halogenctl flash pull <hf-repo> [--revision <rev>] [--as <name>] [--file <checkpoint.hgn>]` | Downloads a Flash checkpoint in Halogen's format, checks it against Hugging Face's hashes and Halogen's `verify`. |
| `halogenctl flash list` | The official checkpoint and yours, and which is served. |
| `halogenctl flash use <name>\|official [--yes]` | Switches Halogen to that checkpoint and restarts it now, after asking (`--yes` skips the question). The official checkpoint is always kept. |
| `halogenctl flash verify <name>` | Runs Halogen's `verify` on it again. |
| `halogenctl flash check <name> [--yes]` | Compares its quality with the official one (perplexity on a standard text). Stops Halogen while it runs, then starts it again. |
| `halogenctl flash convert <hf-repo> [--revision <rev>] [--as <name>] [--threads <n>] [--keep-source] [--yes]` | Converts full-precision weights to Halogen's format on this machine (many hours, likely a day or more, and about 480 GB of space). |
| `halogenctl flash convert-logs [lines]`, `flash convert-stop [<name>] [--yes]` | `convert-logs` follows a conversion. `convert-stop` stops it; with a name it also deletes that conversion's downloaded weights (it asks first), and without one it lists what is left on disk. |
| `halogenctl flash remove <name> [--yes]` | Deletes one of yours (not the one in use). |

## halogen-enroll-tpm

`sudo halogen-enroll-tpm [device]` binds the encrypted disk to this machine's TPM, so it unlocks
by itself at boot. Run it again after a BIOS update, a Secure Boot change or a firmware update of
the Secure Boot lists (the dbx): those change what the TPM checks, so the next boot asks for the
passphrase once. Keep the passphrase: it is your recovery key.

## Files

| Path | What it holds |
|---|---|
| `/srv/configs/halogen.env` | Your Halogen settings |
| `/srv/configs/halogen.env.example` | This release's template, with every option |
| `/srv/configs/api-key` | The API key |
| `/srv/configs/bench/` | Benchmark reports |
| `/srv/logs/halogen/` | Halogen's request records, when on |
| `/srv/models/` | The models, and your own checkpoints |
| `/etc/halos/https.env` | The HTTPS setting (only root can change it) |
| `/etc/halos/https/` | Your certificate and key, and the DNS provider's credential for Let's Encrypt (root only) |
| `/srv/configs/hf-token` | Your Hugging Face token, if you saved one |
| `/srv/configs/flash-checkpoint` | Which Flash checkpoint `flash use` chose |
| `/etc/halos/proxy.env` | Optional: more networks allowed to see the dashboard (`HALOS_DASHBOARD_ALLOW`) |
| `/var/lib/halos/history` | What `halosctl history` shows |
