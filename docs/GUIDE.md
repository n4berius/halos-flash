# Running halOS

This guide tells you how to use a halOS machine after the installation: settings, updates, and
each feature, with the reasons for it. [INSTALL.md](../INSTALL.md) tells how to install. The
[command reference](CLI.md) lists every command and option. Halogen's
[official documentation](https://github.com/peonist-ai/halogen-flash-server/tree/main/docs) is the
reference for Halogen itself. If it disagrees with this guide about Halogen, follow Halogen's
documentation for your version.

- [Everyday commands](#everyday-commands)
- [Settings](#settings)
- [Where things are](#where-things-are)
- [Updates and rollback](#updates-and-rollback)
- [Power profile](#power-profile)
- [Tools on the machine](#tools-on-the-machine)
- Network: [the front door](#the-front-door), [the API key](#the-api-key), [HTTPS](#https),
  [the dashboard](#the-dashboard), [fail2ban](#fail2ban), [SSH logins with keys only](#ssh-logins-with-keys-only)
- Halogen: [measuring speed](#measuring-speed), [measuring tool calls](#measuring-tool-calls),
  [prompt cache on disk](#prompt-cache-on-disk), [request records](#request-records), [logs and the audit trail](#logs-and-the-audit-trail)
- Models: [your own NPU checkpoints](#your-own-npu-checkpoints),
  [your own Flash checkpoint](#your-own-flash-checkpoint)
- [Design choices](#design-choices)

## Everyday commands

Run the commands with `sudo`. `halogenctl`, `halosctl` and `halogen-enroll-tpm` complete with
Tab: commands, options, channels and the names of your own checkpoints. They complete the names
only when you can read `/srv/models`, because `sudo` completes as you.

```bash
sudo halosctl setup          # first-boot questions: TPM unlock, HF token, settings, HTTPS (again any time)
sudo halogenctl status       # service state
sudo halogenctl fetch-logs   # first-boot download progress
sudo halogenctl logs         # server and fetch logs; add a number for more lines
sudo halogenctl doctor       # BIOS, kernel, NPU, clock and memlock checks
sudo halogenctl restart      # after editing /srv/configs/halogen.env
sudo halogenctl config       # show the settings in effect, and any set twice
sudo halogenctl api-key      # print the API key
sudo halogenctl hf-token     # save a Hugging Face token for faster model downloads
sudo halogenctl selftest     # the hardware checklist; prints nothing private
sudo halogenctl bench        # measure speed (--quick: under a minute); reports in /srv/configs/bench
sudo halogenctl bench tools  # measure tool calls (--quick: 15 scenarios); reports in /srv/configs/bench/tools
sudo halogenctl model list   # your own NPU checkpoints (NPU edition)
sudo halogenctl flash list   # the official Flash checkpoint and your own; flash use switches
```

In a terminal, `logs` and `fetch-logs` show new lines until you push Ctrl+C. If you send their
output to `tail`, `grep` or a file, they print and stop.

The screen of the machine shows Halogen's state above the login prompt: downloading, starting, or
`ready` with the address. The SSH login message also shows it, with the release, the channel and
any staged update. The first time that Halogen answers after a boot, logged-in users get a
notice.

Clients use `http://<host>:8731/v1`, on IPv4 and IPv6, with `Authorization: Bearer <api-key>`.
With [HTTPS](#https) on, they use `https://`. [Connecting apps](CLIENTS.md) tells how to connect
Claude Code, Codex, Pi and other agents.

## Settings

`sudo halogenctl settings` opens [the settings screen](#the-settings-screen). You can also edit
`/srv/configs/halogen.env` yourself. The file lists each option that halOS lets Halogen use, as a
comment. To use an option, remove the comment mark, set the value and apply it:

```bash
sudo nano /srv/configs/halogen.env
sudo halogenctl restart
sudo halogenctl config    # what is in effect, and the locked settings
```

Only the listed options get to Halogen. halOS ignores typing errors and locked settings, and
writes them to the log. So they cannot change the server or stop it. halOS reads the file as
plain settings and never runs it as a script. The locked values are in
`/usr/share/halogen/locked.env`, on the read-only OS. Upgrades keep your file exactly as it is.
To see what a newer Halogen added:

```bash
sudo halogenctl options --new   # options your halogen.env doesn't mention yet, with what they do
sudo halogenctl options         # every option: set, commented, or new
```

`/srv/configs/halogen.env.example` always has the full list for the release that you run. halOS
writes it again at each boot. Copy a line from it into `halogen.env`. Each release on GitHub
also has the list for each edition attached (`halos-flash-<version>-<edition>-halogen.env.example`).

For what each option does, see
[`docs/FLAGS.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md).
You don't set the Flash checkpoint (`HALOGEN_CHECKPOINT`) in this file:
`sudo halogenctl flash use` chooses it.

To change what is allowed or locked:

1. Edit `files/usr/share/halogen/locked.env` or `BLOCKED` in `scripts/gen-options.py`.
2. Run that script on the new `docs/FLAGS.md`.
3. Build the image again.

### The settings screen

`sudo halogenctl settings` shows one screen for the models and the settings. Use it instead of
editing `/srv/configs/halogen.env`. Each item shows its default. Nothing changes until you save.

- **Flash checkpoint.** The model on the GPU: `official`, or one of your own checkpoints. A
  checkpoint that did not pass Halogen's verify is shown but you cannot choose it.
- **Draft heads.** For each of your own checkpoints: `official` (the default), `off`, or a draft
  head file that came with the checkpoint.
- **NPU models** (NPU edition). A checklist of Halogen's NPU models and your own checkpoints. Press
  Space to tick or untick a model. `on disk` shows the models that are downloaded. Halogen downloads
  the other ticked models before its next start. Press `d` to go back to the default list.
  `halogen-spotter-0.6b` is not in the list: only the agent guard uses it, and
  `HALOGEN_AGENT_GUARD` (`watch` or `hold`, under All settings) adds it.
- **Common settings** and **All settings.** Each line shows the value from your file, or
  `default:` and the default. Under the list, the screen tells what the selected setting does,
  which values it takes and an example. Press Enter to change the setting, `r` for the default,
  `u` to undo your change, and `/` to search. When you press Enter:
  - A setting that is on or off (`0` or `1`), or that has a fixed set of values (such as
    `HALOGEN_REASONING_EFFORT`), shows a list of its values with what each one does, and
    `default`. Choose one with Enter.
  - A number shows a list of usual values, `default`, and `type a value`.
  - Text with a set form (such as `HALOGEN_PLD`, `3,3`) shows examples and `type a value`.
  - Other text: you type it. An empty value means the default.

  The screen checks a value before it takes it, with the limits in
  [Halogen's FLAGS.md](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md):
  a number must be a number in its range, on, off and choices must be one of their values, and
  text must have the right form. Where FLAGS.md gives no lower limit for a count, the screen asks
  for 1 or more. If your file has a value that the
  screen does not accept, the screen tells you. It does not change that value until you do.
- **Review and save.** Shows all changes. Then save and restart Halogen one time, or save and
  restart later with `sudo halogenctl restart`.

The screen changes only the lines that you change, and keeps your comments. If somebody else
changes `halogen.env` while the screen is open, your changes are not saved. Then run the command
again. `sudo halogenctl settings --editor` opens the file in an editor instead.

## Where things are

| Location | Contents | How to change it |
|---|---|---|
| OS image | Kernel arguments, services, firewall, Halogen digest | Rebuild, then `bootc upgrade` |
| `/srv/configs` | `halogen.env` (yours), `halogen.env.example` (every option, written again at each boot), `api-key`, `flash-checkpoint` (the Flash checkpoint that Halogen serves) | Edit `halogen.env`. For `flash-checkpoint`, use `sudo halogenctl flash use` |
| `/usr/share/halogen` | Locked settings and the list of allowed options | Rebuild only (read-only) |
| `/srv/models` | Flash weights and NPU models, about 130 GB (about 120 GB without the NPU), on their own volume | The first boot downloads them |
| `/srv/logs/halogen` | Halogen's request records, when they are on: only counts, unless you choose text | `sudo halogenctl records` ([how](#request-records)) |
| `/srv/models/flash` | Your own Flash checkpoints, about 60 to 110 GB each | `sudo halogenctl flash pull` ([how](#your-own-flash-checkpoint)) |
| BIOS | UMA frame buffer at its explicit minimum, not Auto; the newest firmware | Set it by hand |

The [command reference](CLI.md#files) lists every file that the commands write.

## Updates and rollback

Automatic updates are off, because a reboot stops inference and Halogen must load the models
again. `halosctl` controls the OS, and `halogenctl` controls Halogen. OS changes apply at the next
reboot, or immediately with `--reboot`. Each command asks before it changes something:

```bash
sudo halosctl version            # release, edition, channel, Halogen version, staged update, rollback image
sudo halosctl switch rc          # follow a channel: alpha, rc, release (stable), edge or kernel-next
sudo halosctl upgrade            # stage the newest release on your channel (--check only looks)
sudo halosctl rollback           # back to the previous image (--to 0.20.5 for an older one)
sudo halosctl history            # every change made with halosctl
sudo halosctl npu off            # the no-NPU edition (faster prefill, IOMMU off); npu on goes back
```

A machine that you install from a release stays on that exact build, so an upgrade finds nothing
new. To get new releases, select a channel one time (`sudo halosctl switch alpha`, for example)
and reboot. Then `sudo halosctl upgrade` stages the newest release on that channel.

- Each channel also gets newer releases of the more stable channels. For example, `alpha` gets an
  RC or stable release when it is newer than the newest alpha.
- There are no more beta releases. A machine that follows `beta` gets the same releases as `rc`.
- `halosctl` keeps your edition, and adds `-no-npu` for you.
- `sudo bootc status` shows the same data from bootc itself.
- If the GHCR package is private, the machine needs a read-only token in `/etc/ostree/auth.json`.
- [RELEASING.md](../RELEASING.md) defines the channels and the release names.

If you use `bootc` directly: a `bootc switch` to the name that the machine already follows does
nothing ("Image specification is unchanged"), even when that tag now points to a newer build. To
get the newest build of the current name, use `sudo bootc upgrade` (or `sudo halosctl upgrade`).

Machines from before `halosctl` (`v0.19.0-alpha.1` and older, also those on the old image name
`ghcr.io/n4berius/halogen-flash-bootc`, which gets no new builds) must switch one time by hand.
Run `sudo bootc switch ghcr.io/n4berius/halos-flash:alpha` (or `rc`, `stable`; on the no-NPU
edition, add `-no-npu`). Files, settings and models do not change. Then use `halosctl`.

halOS keeps the NPU models in one folder, `/srv/models/npu/<model>`. It checks each file against
the record of the new version, so a new version downloads only the NPU files that changed. A
rollback to a version that also uses one folder downloads only the files that are different. A
rollback to an image from before the single folder (the 0.18.23 releases and earlier) downloads
all its NPU models again, about 15 GB.

### Signed images

halOS signs every halOS image with its key. A machine accepts an update only when that signature
is correct. So nobody can give you a different image as a halOS image. `sudo halogenctl
selftest` shows this check as `image-signatures`. Machines that you install from `v0.20.0-alpha.4`
or later do the check from the start.

Older installs turn the check on at their next `sudo halosctl upgrade`, after a reboot into
`v0.20.0-alpha.4` or later. `halosctl` tells you about the check and asks. Then it stages the newest
image of the name that the machine follows, with the check on. So the first upgrade to such a
release installs without the check, and the next upgrade turns it on. Each upgrade needs a reboot.

- Releases before `0.19.1-alpha.3` don't have the key signature. So `halosctl rollback --to`
  can't go back to them. `halosctl rollback` to the previous image on the disk still works.
- The rules are in `/etc/containers/policy.json`. halOS images need the halOS signature. The
  machine accepts images from other registries (Halogen's own, or containers that you run with
  podman) as before. If somebody changes or removes that file, `halosctl` refuses to switch. It
  tells you how to put back the halOS copy
  (`sudo cp /usr/etc/containers/policy.json /etc/containers/policy.json`).
- `halosctl` also refuses to switch if `/etc/pki/containers/halos-flash.pub` isn't the copy from
  the image.
- If you use `bootc switch` manually, add `--enforce-container-sigpolicy`. If you don't, the
  machine stops the check. `halosctl` always adds it. `sudo halosctl version` tells you if the
  machine checks updates. When it doesn't check them, the SSH login message also tells you.
- The `signature-files` line of the selftest compares the policy, the registry setting and the
  halOS public key with the copies of the image in `/usr/etc`. It also warns about a policy file
  in the home folder of root, because that file replaces the system file.
- If the name that you follow ever points back to an older build, `halosctl upgrade` tells you.
  It then does not reboot automatically, so you can examine the build first. (The other channels
  and the other edition have different build times, so `switch` and `npu` don't compare them.)

## Power profile

```bash
sudo halosctl power performance  # firmware power profile: low-power, balanced or performance (the default)
```

`power` applies immediately and needs no reboot. halOS sets `performance` at each boot, unless
you choose a different profile. Some machines come at `balanced`, which gives the chip less power.
Halogen's
[troubleshooting guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/troubleshooting.md)
measured its own numbers at about 85 W. It reports one owner's machine at about 70 W at
`balanced` against about 127 W at `performance`. On freyja, `performance` read prompts about 22%
faster. `balanced` and `low-power` make the machine cooler and quieter.

## Tools on the machine

The OS is small, but it includes these tools for maintenance:

| Command | What it's for |
|---|---|
| `amd-smi metric` | GPU temperature, power and clocks. On Strix Halo, some fields show N/A |
| `nvtop` | Live GPU use, and which process holds GPU memory |
| `htop` | Live CPU and memory use |
| `tmux` | Lets a long command continue if your SSH connection stops |
| `lspci`, `lsusb` | Show the hardware |
| `nvme list`, `sudo nvme smart-log /dev/nvme0` | Disk health |
| `fwupdmgr` | Firmware updates from the vendor, if the board supports them |

Firmware updates use [fwupd](https://fwupd.org/). To find updates, run
`sudo fwupdmgr refresh && sudo fwupdmgr get-updates`. To apply them, run
`sudo fwupdmgr update`. A BIOS update reboots the machine. This stops Halogen until the machine
starts again.

fwupd can also update the Secure Boot revocation list (dbx), the list of start-up programs that
the firmware must refuse. The TPM unlock of the disk is tied to the Secure Boot settings. So after
a dbx update, the next boot asks for the disk passphrase (at the screen, or over SSH if you set
that up). Have the passphrase ready. When the machine is up, run `sudo halogen-enroll-tpm`, so
that the machine unlocks automatically again. Without TPM unlock, nothing changes at boot.

## The front door

[Caddy](https://caddyserver.com) (`halos-proxy.service`) answers the network on three ports:
**8731** for the API of Halogen, **8732** for the dashboard and **8730** for the page of
[web search](#web-search). Halogen and the dashboard listen only on this machine
(`127.0.0.1:18731` and `127.0.0.1:18732`), and so does web search (`127.0.0.1:18730`). So every connection from another
computer goes through Caddy, over plain HTTP or [HTTPS](#https).

- Caddy sends replies on as Halogen sends them. It adds no buffer.
- While Halogen starts, downloads or is stopped, the API answers `503` with a short note (JSON, as
  Halogen's own errors are). It doesn't refuse the connection.
- Caddy writes one line for each API request to the journal (`sudo journalctl -u halos-proxy`):
  the time, the address of the client, the path and the status. It writes no request headers and
  no query string. So the API key never goes into the journal, however an app sends it.
- Caddy runs as its own user, with no access to your files and with no admin interface.
  `sudo halogenctl selftest` checks that Caddy answers (`proxy`). Its other API checks and
  `halogenctl bench` talk to Halogen directly, so their numbers are Halogen's own.
- Halogen's own [docs](https://github.com/peonist-ai/halogen-flash-server/tree/main/docs) show no
  setting that depends on the address of the client. So Halogen works the same behind Caddy.
- Halogen's container can't open connections out (#120).
- The front door refuses a request if its first line and headers together are larger than 32 KB
  (431 over HTTP/1.1, a protocol error over HTTP/2). No app comes near that limit. The limit keeps
  each request on a single log line, so no request gets past the [fail2ban](#fail2ban) count.

## The API key

By default, every request to Halogen's API on port 8731 must include the API key. halOS makes the
key at the first boot. Halogen's `/health` page stays open without the key.

If you trust every device that can reach port 8731, you can turn the key off:

```bash
sudo halogenctl api-key status   # on or off
sudo halogenctl api-key off      # asks first, then restarts Halogen
sudo halogenctl api-key on       # the same key as before
```

**Warning:** Do not turn the key off on a network that you do not control. Without the key,
anybody who can reach port 8731 can use Halogen. They can send prompts, read the replies and fill
its memory, and HTTPS does not stop them.

The firewall lets every address reach port 8731. This includes global IPv6 addresses, Tailscale
and port forwards on your router. A home network with IPv6 can be reachable from the internet.

- The key stays in `/srv/configs/api-key`. When you turn it on again, apps use the same key.
- Apps that send the key are expected to work while it is off: Halogen's documentation says
  that without a key it checks no key. This is not confirmed on the test machine yet.
- The dashboard, `sudo halogenctl bench` and the selftest work in both states.
- fail2ban gives no protection to the API while the key is off. It counts wrong keys, and no
  request has a wrong key.
- While the key is off, anybody can read Halogen's `/metrics`. Each read resets two values that
  the dashboard shows (see [The dashboard](#the-dashboard)).
- `sudo halogenctl selftest` shows `api-key`. It sends a request without the key. While the key is
  on, it shows FAIL if Halogen answers the request, and WARN for an unexpected answer.
- The setting is the file `/etc/halos/api-key-off`, which only root can write. A rollback to a
  release from before this switch turns the key on again. The file stays, so the next upgrade
  turns the key off again. To keep the key on, run `sudo halogenctl api-key on` after the upgrade.

The API key has 64 random characters, so nobody can guess it.

## HTTPS

Plain HTTP sends prompts, replies and the API key across your network without encryption. HTTPS
encrypts them. On a new install, `sudo halosctl setup` offers HTTPS with the halOS authority
(Enter: yes). Machines that upgrade stay on HTTP until you turn it on, so no app stops working
unexpectedly.

```bash
sudo halosctl https                        # the state, and what apps use
sudo halosctl https self-signed            # on, with halOS's own authority
sudo halosctl https custom cert.pem key.pem   # on, with your certificate (PEM, key without a passphrase)
sudo halosctl https letsencrypt cloudflare halos.example.com   # on, with Let's Encrypt (see below)
sudo halosctl https off                    # back to plain HTTP
```

With HTTPS on, all three ports use it. Apps use `https://<address>:8731/v1`, and the dashboard is at
`https://<address>:8732`. On each port, Caddy redirects a plain `http://` request to `https://`.
Apps that send the key over `http://` still send it one time before they follow the redirect.
So change their address to `https://`.

If Caddy doesn't answer with a new setting, `halosctl` puts back the previous setting, including
the certificate. The halOS tools (`halogenctl bench`, the API checks of the selftest, the check of
the login line) connect to Halogen directly on the machine, so they work the same in each mode.
halOS releases before `v0.20.1-alpha.3` have no HTTPS and no Caddy. After `sudo halosctl rollback`
to one of them, the API uses plain HTTP again.

### Self-signed

`self-signed` makes the halOS certificate authority (Caddy's, which the machine keeps). It also
makes a certificate for each name and address of this machine: `localhost`, its host name, the
`.local` name and every address that it has, including Tailscale's. Apps and browsers must trust
the authority one time:

```bash
sudo halosctl https ca > halos-ca.crt
```

Give `halos-ca.crt` to each app that connects to the machine. [Connecting apps](CLIENTS.md)
shows the CA setting of each coding agent. Do not add the file to the trusted certificates of
your whole computer. An authority that the full system trusts can vouch for any website. So
anyone who stole it from this machine could act as any site on that computer.

- For a browser and the dashboard, it is sufficient to accept the warning one time for
  `https://<address>:8732`.
- `sudo halosctl https` shows the fingerprint of the authority. Compare it with the file that you
  copied.
- For other names (for example, a DNS name that you gave the machine), add them to the command:
  `sudo halosctl https self-signed freyja.example`.
- If the address of the machine changes, `sudo systemctl restart halos-proxy` adds it. Until then,
  the selftest warns.

### Your own certificate

Your certificate must name the address that apps use (usually a DNS name). halOS checks that the
key belongs to the certificate and that the certificate is not expired. It shows you whose
certificate it is, and asks before it uses it. It keeps both files in `/etc/halos/https/` (root
only, with the previous pair). `sudo halogenctl selftest` warns 2 weeks before the certificate
ends. To renew, run `https custom` again with the new files.

### Let's Encrypt

Let's Encrypt gives certificates that every app and browser already trusts, and renews them
automatically. It needs a public DNS name that you own (for example `halos.example.com`). Caddy
opens nothing to the internet: it proves that the name is yours with a temporary TXT record. It
writes this record through the API of your DNS provider (the DNS-01 challenge). The only
requirement is that the name points to this machine. A private address such as `192.168.1.20` is
fine.

Some home routers block public names that point to private addresses ("DNS rebinding
protection"). If the name doesn't resolve on your network, allow the name in the router.

1. Make an API credential at your DNS provider. Let it change the zone of that name and nothing
   more. A credential that can change the DNS of your main domain is valuable to an attacker who
   gets into the machine. A domain (or a DuckDNS name) that you use only for halOS decreases that
   risk:

   | Provider | What `halosctl` asks for | Where |
   |---|---|---|
   | `cloudflare` | `api_token` | My Profile > API Tokens > Create Token, template "Edit zone DNS", for that zone only |
   | `duckdns` | `api_token` | The token at the top of duckdns.org after you sign in. The name is `<yours>.duckdns.org` |
   | `porkbun` | `api_key`, `api_secret_key` | Account > API Access. Then turn on "API Access" on the domain itself |
   | `namecheap` | `api_key`, `user`, `client_ip` | Profile > Tools > Business & Dev Tools > API Access. Add the public IPv4 address of this network to its allowed list. Give the same address as `client_ip` |

   **Warning:** For Namecheap, write down your records first, or use a domain (or a DuckDNS name)
   only for this. The Namecheap API can only replace the full list of records of a domain. So
   each certificate writes the list again.

2. Try it against the test service of Let's Encrypt. Its limits are generous. (Apps don't trust
   its certificates, so they will still warn.)

   ```bash
   sudo halosctl https letsencrypt cloudflare halos.example.com --staging
   ```

   `halosctl` asks for the credential (it doesn't show it while you type). Then it waits for the
   certificate, usually less than a minute. If no certificate comes in 5 minutes, it shows the
   answer from Let's Encrypt and puts back the previous setting.

3. Do it for real. `halosctl` offers to use the credential that you gave again:

   ```bash
   sudo halosctl https letsencrypt cloudflare halos.example.com --email you@example.com
   ```

   `--email` is optional. Let's Encrypt uses it only for important notices about your account.

Apps then use `https://halos.example.com:8731/v1`, and the dashboard is at
`https://halos.example.com:8732`. The names and addresses of this machine keep the halOS authority
(as with self-signed). So apps that connect by address continue to work after they trust it.
Certificates are public: every name that you certify shows in the
[Certificate Transparency](https://certificate.transparency.dev/) logs, which anyone can search.
So don't use a name that you want to keep private.

halOS keeps the credential in `/etc/halos/https/dns/`, and only root can read it. Caddy gets it
from systemd each time it starts, read-only and in memory. Caddy loses it when it stops. The
credential never shows in a command line, the settings file or the journal. halOS removes it from
the error messages of DuckDNS and Namecheap. It also refuses a Cloudflare token with a shape that
Caddy's plugin would print back.

`sudo halogenctl selftest` checks the certificate as an app would. It warns 10 days before the
certificate ends, because then the renewal has failed.

To give a new credential, run the same command, and answer no when it offers the old one. When the
new setting works, halOS deletes the old credential. Also revoke the old credential at the
provider. If the name already has a valid certificate, Caddy keeps it and first uses a new
credential at the next renewal (Caddy renews about a month before the end). The selftest warns if
that renewal fails. When you no longer use Let's Encrypt, `sudo halosctl https forget-dns` deletes
the saved credential and restarts Caddy.

Without a terminal, `--yes` reads the credential as `field=value` lines on standard input. Put the
lines in a file that only you can read. Never put them in the command itself, because the shell
history keeps the command. Delete the file after use:

```bash
sudo halosctl https letsencrypt cloudflare halos.example.com --yes < cloudflare.txt   # api_token=...
```

## The dashboard

For a live view of Halogen, open `https://<this machine's address>:8732` in a browser on your
network (`http://` with [HTTPS](#https) off). The dashboard shows:

- If Halogen is up
- Generation and prefill speed
- Busy slots and queued requests
- The KV pool, the prompt cache and the NPU
- Charts from the last 5 minutes to the last 30 days

`sudo halosctl dashboard` shows its state and address. It is
[halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) by Quaternion. halOS
includes it without changes (licences in `/usr/share/licenses/halogen-dashboard/`).

The dashboard reads Halogen one time each second with your API key. It keeps its history in
`/var/lib/halos-dashboard`: 48 hours in full, then one-minute summaries for 30 days. When full,
this history is about 430 MB. The dashboard uses about 12 MB of memory and almost no CPU. It runs
as its own user, with no access to Halogen's files, models or tokens.

- **No login.** Anyone who can get to port 8732 on your network can see the dashboard. But nobody
  can change anything through it. It never shows your API key or anything sent to Halogen. It
  does show when and how much people use the server. If you don't want that, turn it off:
  `sudo halosctl dashboard off` stops it (port 8732 then only says that it's off). `on` turns it
  on again.
- **On by default**, also on machines that upgrade to a release that has it.
- **Private networks only.** The dashboard answers only this machine and private addresses: 10.x,
  172.16-31.x, 192.168.x, link-local, and 100.64.0.0 to 100.127.255.255. (This last range is
  Tailscale, and also the shared addresses of some internet providers.) A computer with a public
  address (for example, through a port forward) gets no answer. The exception is when something
  on your network sends the request on (a reverse proxy, a tunnel or `tailscale serve`). Caddy
  applies this rule, on IPv4.

  If your network uses other addresses, browsers get no answer. Then do these steps:

  1. Add your ranges to `/etc/halos/proxy.env` as `HALOS_DASHBOARD_ALLOW=<range> <range>`.
  2. Run `sudo systemctl restart halos-proxy`.
  3. Check the result with `sudo systemctl status halos-proxy`. A mistyped range stops Caddy,
     and with it the API, until you correct it.
- **The API key stays out of crash reports.** The dashboard blocks memory dumps. So if it
  crashes, nothing that it holds (including the key) goes to the disk or into the system log. It
  listens only on its own local port, and accepts connections only from this machine (Caddy).
  `sudo halogenctl selftest` checks the crash-report protection, and that this address filter is
  really active.
- **Memory is capped at 256 MB**, so the dashboard can never take memory from Halogen. Its own
  30-day view needs about 100 MB. A special request that reads much more makes it restart after
  30 seconds. This has no effect on Halogen.
- **Only one reader of `/metrics`.** Each time something reads `/metrics`, Halogen resets two of
  its speed values. So the dashboard must be the only reader. Don't point Prometheus or a script
  at the `/metrics` of Halogen. The dashboard serves its own copy at
  `http://<address>:8732/metrics`.
- If you change the API key in `/srv/configs/api-key`, restart the dashboard:
  `sudo systemctl restart halos-dashboard`.

## Web search

Halogen can search the web for a model that asks for it. Claude Code's WebSearch tool uses this
(the `web_search` tool of `/v1/messages`). Web search is off by default. You can turn it on in
two ways:

- **SearXNG on this machine.** halOS runs [SearXNG](https://github.com/searxng/searxng), a
  metasearch engine, in a container of its own. SearXNG sends the searches to public search
  engines and gives the results to Halogen.
- **Your own SearXNG.** Halogen uses a SearXNG server that you already have, for example on
  your NAS or in Kubernetes. Halogen's searches then go only to that server.

Halogen's container has no connection out of the machine (see [Design choices](#design-choices)),
and web search doesn't change that. Halogen gets one more private network, `halos-search`. Only
the search container is on that network with Halogen. With your own SearXNG, the search
container is a small relay: it sends Halogen's requests to your server's address, and to no
other address. So Halogen still can't connect to the internet or to your network.

**Note:** Halogen's model writes the search queries from the conversation. So text from the
conversation can leave the machine in a query: to public search engines with SearXNG on this
machine, or to your own server. Text in a document or a search result can also tell the model
what to search for. Turn on web search only if that is acceptable for what you send to Halogen.

To use SearXNG on this machine:

1. Run this command:

   ```bash
   sudo halogenctl web-search bundled
   ```

   The first start downloads SearXNG's image (about 100 MB). Then Halogen restarts.
2. Look at the result:

   ```bash
   sudo halogenctl web-search
   ```

To use your own SearXNG, give its address, with `http://` or `https://`:

```bash
sudo halogenctl web-search external https://search.example.com
```

Before it changes something, halOS sends one search to that address and asks for JSON, as
Halogen will. If the server doesn't answer in JSON, halOS changes nothing. Then add `json` to
`search: formats:` in that server's `settings.yml`. If the server uses SearXNG's bot limiter,
let this machine's address through. The relay can't find `.local` names: give an IP address or
a DNS name. The relay uses IPv4 only, so give an IPv4 address or a name with an IPv4 address.

`sudo halogenctl web-search off` turns web search off again. Halogen restarts.

**Warning:** Turn web search off before you go back to a halOS image from before web search
(`sudo halosctl rollback`). That image can't start Halogen while web search is on, and its
`halogenctl` can't turn it off. If you forgot, remove the file
`/etc/containers/systemd/users/970/halogen.container.d/30-web-search.conf` and run
`sudo halogenctl restart`.

**SearXNG's page.** With SearXNG on this machine, its page is on port 8730:
`https://<this machine's address>:8730` (`http://` with [HTTPS](#https) off). Use it to try a
search and to set your own preferences, which your browser keeps. The page has the same rules as
[the dashboard](#the-dashboard): no login, and only this machine and private networks get an
answer. When web search is off, port 8730 only says that it's off. The front door keeps no log of
what you search on that port. SearXNG's own messages in halogen's journal can still show a query,
for example when a search engine fails.

**SearXNG's settings.** halOS makes `/srv/configs/searxng/settings.yml` at SearXNG's first start,
with a secret of its own, and never changes it after that. halOS's settings turn on the JSON
answers that Halogen needs, and turn off SearXNG's bot limiter and image proxy. To change the
settings:

1. Run `sudo halogenctl web-search edit`. The file opens in an editor.
2. Save the file and close the editor. SearXNG restarts with the new settings.

All SearXNG settings are in [SearXNG's documentation](https://docs.searxng.org/admin/settings/).
If you change the file in another way, run `sudo halogenctl web-search restart`.

Some facts about web search:

- SearXNG runs as its own user in its container, without capabilities, on a read-only image. It
  can use at most 768 MB of memory and two CPU cores, so it can't take much from Halogen.
- SearXNG's image comes from the SearXNG project, at the exact version that halOS names
  (`SEARXNG_IMAGE` in `/usr/share/halogen/release.env`). A halOS update can name a newer
  version. SearXNG then downloads again at its next start.
- What a web page says can try to give the model instructions. Treat search results as you treat
  any text from the internet.
- `sudo halogenctl selftest` checks that the search answers, also from Halogen's container
  (the `web-search` line).

## fail2ban

halOS runs [fail2ban](https://github.com/fail2ban/fail2ban). It looks for an address that fails
again and again. Then it tells the firewall to shut out that address for some time:

| Watches | Shut out after | For |
|---|---|---|
| SSH logins | 5 failures within 10 minutes | 10 minutes |
| Halogen's API on port 8731: a missing or wrong API key | 10 within 10 minutes | 10 minutes |

```bash
sudo halosctl fail2ban                       # state, and who is shut out now
sudo halosctl fail2ban unban 203.0.113.9     # let an address back in at once
sudo halosctl fail2ban off                   # turn it off (on again: fail2ban on)
```

- **This machine and private networks are never shut out**: home and office address ranges, and
  Tailscale's. Without this rule, an app on your network with an old API key would lock out its
  full computer, and the server would look down. So fail2ban protects against the internet, when
  the internet can get to the machine. It doesn't stop a device on your own network that guesses
  keys.
- To change that list or the numbers, put your own lines in
  `/etc/fail2ban/jail.d/90-local.local`. Don't put them in the halOS file `50-halos.conf`, because
  updates replace that file. Then run `sudo systemctl reload fail2ban`. For example, to exempt
  only this machine:

  ```ini
  [DEFAULT]
  ignoreip = 127.0.0.0/8 ::1
  ```
- It can't protect the [SSH unlock at boot](../INSTALL.md#unlock-over-ssh-at-boot): fail2ban
  starts only after the disk is unlocked.
- Its own messages (who was shut out and let back in) are in the journal:
  `sudo journalctl -u fail2ban`.
- A ban is complete: it also cuts the connections that the address already had open. fail2ban
  keeps the bans in its own firewall table, next to the firewalld rules. After the first ban,
  `sudo nft list table inet f2b-table` shows this table. `sudo firewall-cmd --reload` doesn't
  change the bans.
- The halOS firewall lets through only the ports that firewalld opens itself. It blocks ports that
  a container started with `sudo podman run -p …` publishes. So such a container may refuse to
  start ("Port forwarding not possible as firewalld StrictForwardPorts enabled"). Run your own
  containers without `sudo` (rootless, as Halogen runs). If you need a rootful container, set
  `StrictForwardPorts=no` in `/etc/firewalld/firewalld.conf` and run
  `sudo systemctl restart firewalld`.

What it can't do:

- **Several people behind one address are shut out together.** In an office, on a mobile network
  or on a VPN, other people use the same public address. Any of them can get that address shut out
  for 10 minutes with a few wrong keys. SSH stays open when the API is shut (and the reverse). So
  `sudo halosctl fail2ban unban <address>` is always available.
- **A proxy or tunnel in front hides the real addresses.** With a reverse proxy on another
  machine, every client has the address of the proxy. Then one bad client shuts out all of them.
  With a tunnel that ends on this machine (cloudflared and similar tools), every client is this
  machine. This machine is never shut out, so fail2ban does nothing for the API.
- **fail2ban counts IPv6 per address,** and one network has many addresses. So fail2ban doesn't
  slow a determined sender.

Nobody can guess the API key, with or without fail2ban. For the API, fail2ban decreases the junk
requests that get to Halogen. For SSH, it decreases the noise.

## SSH logins with keys only

After your account can log in over SSH with a key, you can turn off passwords for SSH logins. Then
nobody on the network can try to guess a password:

```bash
sudo halosctl ssh-passwords off
```

The command refuses while your account has no key in `~/.ssh/authorized_keys` that sshd would
accept. (Add one from your computer with `ssh-copy-id`.) Before the command applies the setting, it
checks that sshd will really use it. The screen of the machine still accepts the password.
`sudo halosctl ssh-passwords on` allows passwords again. `sudo halosctl setup` also offers this,
with no as the default.

Root never logs in over SSH, with a password or a key, even if the installer allowed it. Log in as
your admin user and use `sudo`.

## Measuring speed

```bash
sudo halogenctl bench            # a few minutes
sudo halogenctl bench --quick    # under a minute: one prompt length, one pass
```

It measures the running server with Halogen's own
[`sweep` tool](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/performance.md#served-throughput-end-to-end-over-http).
Halogen's published numbers come from this tool, so you can compare your numbers with them. It
needs no restart, but other requests are slower while it runs. It measures:

- **Reading the prompt** (prefill, `pp` in Halogen's docs): how fast Halogen reads a prompt of
  512, 2,048, 8,192 and 32,768 tokens.
- **Writing the answer** (generation, `tg`): how fast Halogen writes 128 tokens, as the mean over
  the 10 prompt shapes of Halogen. Code is about two times as fast as prose, so compare means, not
  single prompts.

The report starts with a one-line summary and one table for each:

- **Speed**: tokens per second.
- **Spread**: the variation between passes. For writing, most of it comes from the prompt type.
- **Time**: how long that length takes, for example how long a 32K-token prompt takes before the
  answer starts.
- **Last run**: the change from your last run of the same kind (full or quick), with "faster",
  "slower" or "about the same". "About the same" means that the change is less than 2%, or for
  reading, less than the normal variation between passes. Below the tables, the report tells
  which items changed since that run: the halOS and Halogen versions, the edition, the kernel, the
  BIOS, the GTT size, the IOMMU, the fabric clock, the power profile, the Flash checkpoint or a
  setting.

halOS saves the report as text and JSON in `/srv/configs/bench/`, with the date in the name. The
saved text also has the details that the screen does not show: the board, the kernel arguments
and every setting. So you can compare a run after an upgrade, a BIOS change or `flash use` with
an earlier run.

Halogen's [measurements](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/performance.md)
used about 85 W of sustained power. A machine with a lower power limit shows lower numbers. The
run uses the prompt cache as your server does. So compare the reading speeds with Halogen's "cache on (a cold
request)" rows, not with the cache-off headline figures.

Halogen's tool sends the same prompts at each run. The prompt cache keeps them on disk, so it can
answer them again without reading them: then a 32K-token prompt seems to take 0.2 s. To prevent
this, halOS starts each prompt with a word that is new for each run. If the cache still answers
most of a prompt, the report shows a warning. Reports from before this change are not used for
"Last run", because their reading speeds can be too high.

The prompts of the run also go into the cache. Each full run adds about 3 GB that no later run
uses, and the cache keeps 64 GiB by default, so many runs can push out long conversations from
the cache. Those conversations then read their history again one time.

## Measuring tool calls

```bash
sudo halogenctl bench tools            # 69 scenarios, three times each: tens of minutes or more
sudo halogenctl bench tools --quick    # 15 scenarios, one time
```

It measures how well the model calls tools, with
[tool-eval-bench](https://github.com/SeraphimSerapis/tool-eval-bench) (MIT). Each scenario is a
conversation with fake tools, for example weather, email, files and a calculator. Nothing is
really sent or changed. The benchmark checks if the model picks the right tool, gives the right
values, chains calls, stops when no tool is necessary and recovers from tool errors. A right
answer gets 2 points and a partly right answer 1 point.

The report shows:

- **Score**: the points out of 100, with a short rating.
- **Reliable**: in a full run, the scenarios that were right in all three runs. "Right at least
  once" counts the scenarios that were right in one run or more.
- **Category**: the score for each kind of task.
- **Last run**: the change from your last run of the same kind.

A full run uses the settings of the public
[Qwen3.8 Flash Next tool-calling leaderboard](https://huggingface.co/spaces/johnlockejrr/qwen38-flash-next-hgn-leaderboard)
(temperature 1.0, seed 42, thinking on), so you can compare your score with that table. The
answers change from run to run, so a change of a few points can be chance.

halOS saves the report as text and JSON in `/srv/configs/bench/tools/`. The text also lists each
scenario that went wrong. tool-eval-bench keeps every conversation in `runs/` in the same folder.
It needs no restart, but other requests are slower while it runs. These records stay until you
delete them, on the small `/srv/configs` volume: a run needs 200 MB free there. To make space,
delete old folders in `/srv/configs/bench/tools/runs/` with `sudo rm -r`.

## Prompt cache on disk

Halogen keeps the state of each conversation, so the next turn doesn't read the full conversation
again. halOS also keeps that state on disk, in `/srv/models/.prompt-cache`. So a conversation
continues after a restart of Halogen: its next turn starts in seconds, and doesn't read everything
again (Halogen's [prompt cache on disk](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/configuration.md#prompt-cache-on-disk-resume-a-conversation-after-a-restart)).
Halogen writes the cache in the background, so answers don't wait for the disk.

```bash
sudo halogenctl cache          # on or off, and the space used
sudo halogenctl cache off      # keep the cache in memory only; Halogen can then only read the folder (restarts Halogen)
sudo halogenctl cache clear    # delete everything saved
```

- It uses about 27 KiB per token of conversation: 0.9 GB at 32,000 tokens, 7.2 GB at 262,000.
  Halogen keeps 64 GiB at most, and first removes the conversations that it used longest ago. To
  change the limit, set `HALOGEN_CACHE_DISK_GIB` in `halogen.env`.
- A different Halogen version, checkpoint or setting never reads the files of another. halOS tells
  Halogen to delete those files at start (`HALOGEN_CACHE_PRUNE_OLD=1`), so nothing stays behind.
  So the cache starts empty after an upgrade to a new Halogen version, and after
  `halogenctl flash use` switches checkpoint. It also starts empty after a change to a setting
  that changes what Halogen saves (for example, the context size). To keep the other files, set it
  to `0` in `halogen.env`. Then a rollback or a switch back finds its cache, but these files count
  in addition to the limit until you run `cache clear`.
- Halogen says that very long conversations (more than about 64,000 tokens) save fastest with
  `HALOGEN_KV_POOL_POSITIONS=262144`. The `halogen.env` of the NPU edition already sets it.
- The folder holds the state of your conversations, so protect it as you protect the
  conversations. Only the `halogen` user can read it. It has protection at rest only if you
  selected disk encryption at install. A backup of `/srv/models` also copies it. `cache off` keeps
  the saved data, and `cache clear` deletes it. Also use `cache clear` after you try a checkpoint
  that you don't trust.

## Request records

Halogen can keep one line for each request that it answers. Each line shows:

- The API and the client that sent the request
- Its size and settings
- How it finished
- The tokens generated and the tool calls
- The timings

The records show what your apps and agents really send. Recording is off until you turn it on.
halOS keeps **counts only**, with no message text, unless you change this. See Halogen's
[request records](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/configuration.md#request-records-a-log-of-what-your-clients-send-opt-in)
for the contents of each line.

```bash
sudo halogenctl records on        # restarts Halogen
sudo halogenctl records           # on or off, what text is kept, space used
sudo halogenctl records stats     # counts by API, client, finish, cache share, tool errors
sudo halogenctl records prune --days 7    # or --gib 1, --all
sudo halogenctl records off       # what was kept stays until you prune it
```

`stats` and `prune` also work while recording is off or Halogen is stopped. They then run the
Halogen tool in a short-lived container that sees only the records folder.

The records go to `/srv/logs/halogen`, and only the `halogen` user can read them. Three settings in
`/srv/configs/halogen.env` control them. After a change, run `sudo halogenctl restart`.

- `HALOGEN_RECORD_TEXT`: `none` on halOS (counts only), or `all`, or a list of `prompt`,
  `reply`, `reasoning`, `args` and `results`. **Before you keep text on a server that other
  people use:** Halogen writes to disk everything that they send. The API key keeps strangers out,
  but Halogen also records anyone who has the key. If you turn the key off, Halogen records
  anybody who can reach port 8731. The session fields show only what a client claims.
- `HALOGEN_RECORD_GIB`: the size limit of the folder, 2 GiB by default. Above this limit, Halogen
  drops new records and counts them. It never slows or refuses requests.
- `HALOGEN_RECORD_DAYS`: the number of days to keep records, 90 by default. While recording is on,
  Halogen deletes older records itself. After `records off`, use `records prune`.

The `/health` address of Halogen answers anyone who can get to port 8731. While recording is on,
it shows the counts (records written and dropped) and which text Halogen keeps. It never shows the
records.

New installs give `/srv/logs` its own 4 GiB volume, so records can never fill `/var`. Nothing
there can run as a program (`noexec`), on the volume and in Halogen's mount of the folder.
Machines installed earlier keep it as a folder on `/var` (60 GiB), where the 2 GiB limit keeps it
small. Its own volume there would need free space in the volume group (`sudo vgs`, column VFree).
The guided install leaves no free space: the models volume uses all the remaining space, and XFS
can't shrink.

## Logs and the audit trail

halOS keeps three types of log. Each type has its own size limit, so no log can fill the disk:

- **The system journal** (`sudo journalctl`): the messages of every service, including Halogen
  (`sudo halogenctl logs`). halOS keeps 4 GB at most, for 90 days at most, and keeps 1 GB free.
  `sudo journalctl --disk-usage` shows its size.
- **The audit log** (`/var/log/audit/audit.log`, auditd). See below.
- **[Request records](#request-records)**, when you turn them on.

The audit log records these events:

- Logins, `sudo` and account changes
- Changes that an admin or root makes to the halOS settings, the update signature policy, and
  the SSH and sudo settings
- Each time a logged-in user runs the disk-encryption tools, the update tools, `halosctl` or
  `halogenctl`

auditd keeps 20 files of 50 MB (1 GB) and rotates them itself. If its disk becomes full, auditd
pauses. It does not stop the machine. To read the log by topic:

```bash
sudo ausearch -i -k halos-config     # changes in /etc/halos
sudo ausearch -i -k halogen-config   # changes in /srv/configs
sudo ausearch -i -k signature-policy # which images updates are taken from
sudo ausearch -i -k sshd-config      # also sudoers, accounts, pam, luks-tpm, os-update, halosctl, halogenctl
sudo ausearch -i -k quadlet          # how Halogen's container is started; also containers, systemd-config,
                                     # audit-config, modules, preload, udev, firewall, sysctl,
                                     # environment, mounts, fail2ban
sudo aureport --summary              # counts, and sudo aureport --login for logins
```

The rules are locked while the system runs. Nobody, including root, can turn auditing off or
change a rule without a reboot, and the audit log records each attempt. So a change to the rules
in `/etc/audit/rules.d` applies at the next boot.

halOS excludes Halogen's own login session from auditing, so auditing adds no work to the engine.
The audit log records root or an admin who acts as the `halogen` user (`sudo -u`, `runuser`), as
it records all other users. So it doesn't record files that Halogen's own services write in
`/srv/configs` (benchmark reports, for example), but it records your changes there. The cost on
the rest of the system (including the front door, Caddy) is probably small. Nobody has measured it
yet.

`sudo halogenctl selftest` shows:

- If auditd runs with the halOS rules, locked (`audit`)
- If the audit rules and the container definition of Halogen are still the image's own
  (`config-files`)
- If the `halogen` user has new services of its own, which halOS never makes (`halogen-autostart`)
- How large the journal is (`logs`)

Fedora keeps some plain log files (failed and past logins, `btmp` and `wtmp`). `logrotate` rotates
them monthly, as on all Fedora systems.

## Your own NPU checkpoints

On the NPU edition, Halogen also runs checkpoints that you supply. Examples are LiquidAI's `d1-2B`,
the LFM3 family, or your own fine-tune of one of its NPU models. Halogen's
[NPU guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#your-own-model)
shows what runs. To download one from Hugging Face, use:

```bash
sudo halogenctl model pull LiquidAI/LFM3-1.7B     # add --as <name> or --revision <commit> if you like
sudo halogenctl model list
sudo halogenctl model remove LFM3-1.7B
```

`model pull` uses your Hugging Face token if you saved one (gated repos need it). An interrupted
pull continues where it stopped. `model pull` puts the checkpoint in the correct folder:

| Folder | What goes there | Named in `HALOGEN_NPU_MODELS` as |
|---|---|---|
| `/srv/models/decider` | `d1-2B`, fine-tunes of `decider-0.8b` | `/models/decider/<name>` |
| `/srv/models/LFM` | LFM3-1.7B, LFM3-VL-2B, LFM3-Audio-2B, LFM3-Omni-2B | `/models/LFM/<name>` |
| `/srv/models/custom` | Fine-tunes of the embedding, reranking or guard models; OvisOCR3 | `/models/custom/<name>` |

`model pull` then shows the line to put in `/srv/configs/halogen.env`. It offers to make the change
and restart Halogen. Halogen serves the model under the name of its folder. At its first start,
Halogen converts the checkpoint for the NPU (about a minute) and keeps the result next to it. The
download step gets only the NPU programs that the checkpoint runs on, never Halogen's weights for
them.

Only these three folders are writable for the server, so the server can keep the conversion. Use
`model pull` to fill them. A folder that root copies in manually is read-only for the server. The
server then converts it again at every start.

**LFM3-1.7B's three forms.** With the name `/models/LFM/<name>`, it runs at full quality.
`/models/LFM/<name>:fast` is faster, with a small loss of quality. Since Halogen 0.20.6,
`/models/LFM/<name>:qad` runs Liquid's own 4-bit file, which is the fastest. It gives about 48
tokens a second, against 30 and 42 for the other forms (from Halogen's
[NPU guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#your-own-lfm3-17b)).

To get that 4-bit file, run `sudo halogenctl model pull LiquidAI/LFM3-1.7B --qad`. It comes from
`LiquidAI/LFM3-1.7B-GGUF`, at the commit that Halogen's image uses. Its weights are Liquid's, so a
fine-tune of your own can use only the first two forms. You can name all three forms together.
Halogen serves each form under its own name (`LFM3-1.7B`, `LFM3-1.7B-fast`, `LFM3-1.7B-qad`).

**Document parsing (OvisOCR3).** Since Halogen 0.20, the NPU reads document pages into Markdown,
with tables as HTML and formulas as LaTeX. It uses your own
[OvisOCR3](https://huggingface.co/ATH-MaaS/OvisOCR3) checkpoint (Apache 2.0, about 1.7 GB). To get
it, run `sudo halogenctl model pull ATH-MaaS/OvisOCR3 --revision
17f255e2c8ae6d18d5d5edb0a474bd4ed39aef90` (the version that Halogen 0.20.0 was tested with). Then
add `/models/custom/OvisOCR3` to `HALOGEN_NPU_MODELS`.

OvisOCR3 answers as `OvisOCR3`. It takes one or two page images for each request, and about 20
seconds for each page. Halogen's
[NPU page](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#your-own-ovisocr3)
has the prompts and limits. When OvisOCR3 and several other NPU generation models start work at
the same time, the next Flash request can wait about 40 seconds. During that time, Halogen reads
the Flash weights back. To keep them in memory, set `HALOGEN_WEIGHTS_LOCK=1` in `halogen.env`.

## Your own Flash checkpoint

Both editions can serve a different build of the Flash model in place of the official one. This
can be a community conversion, or your own fine-tune or quantization in Halogen's `.hgn` format.
The official checkpoint always stays on disk. So one command goes back to it, and downloads
nothing.

There are three ways to get one:

- [`flash pull`](#pulling-a-hgn-checkpoint) downloads a `.hgn` checkpoint.
- [`flash pull`](#pulling-a-gguf) also converts a llama.cpp GGUF one time.
- [`flash convert`](#converting-full-precision-weights) converts full-precision weights.

Then, for each of them:

```bash
sudo halogenctl flash list               # official and yours: size, which is active, verified
sudo halogenctl flash check mine         # compare its quality with the official one (stops Halogen ~15 min, ~25 the first time)
sudo halogenctl flash use mine           # switch; asks first, then restarts Halogen
sudo halogenctl flash use official       # back to the official checkpoint
sudo halogenctl flash verify mine        # check it again (done for you after a Halogen update)
sudo halogenctl flash remove mine
```

Things to know for every checkpoint of your own:

- **Checked twice.** Every downloaded file must agree with the hash that Hugging Face shows for
  it. The checkpoint (not the lookup table or a draft head file) must also pass Halogen's own
  [`verify`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/checkpoint-tools.md).
  `flash use` refuses a checkpoint that failed or that halOS didn't check. After a Halogen update,
  the next start checks the selected checkpoint again with the new Halogen.
- **The selftest and `flash list` show what Halogen serves.** If your choice is missing or failed
  a check, Halogen serves the official checkpoint without a message, so that it still starts. The
  selftest, `flash list` and `status` then tell you this, and why.
- **Halogen may refuse it at start,** for example if the thinking control of its chat template
  doesn't work ([`HALOGEN_TEMPLATE_UNCHECKED`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md)),
  or if it needs more memory than is free. `sudo halogenctl status` and the selftest then tell
  you. `sudo halogenctl flash use official` brings back the official model.
- **Images.** With `HALOGEN_VISION_TOWER=1`, images work only if the checkpoint has a vision tower
  (`qwen38-flash-next-vision.hgn`, or `qwen38-27b-vision.hgn` for Qwen3.8-27B). Without one,
  images stay off, and `halogenctl config` tells why.
- **Qwen3.8-27B.** Halogen can also serve a smaller model. See
  [Qwen3.8-27B, when memory is short](#qwen38-27b-when-memory-is-short).
- **The model name in the file.** Since 0.21.0, Halogen reads the model name inside a checkpoint
  file and refuses a name that it doesn't know. Then the check after the update fails, and halOS
  serves the official checkpoint. `sudo halogenctl status` tells you this.
- **Where things live.** Checkpoints are in `/srv/models/flash/<name>/`. The choice is in
  `/srv/configs/flash-checkpoint`, which only `halogenctl flash use` writes. You can't set
  `HALOGEN_CHECKPOINT` in `halogen.env`.
- **Disk activity.** Downloads and checks read from the disk while Halogen continues to serve.
  Until they finish, long prompts can be a little slower.
- **Use the checkpoints of people that you trust.** [SECURITY.md](../SECURITY.md#checkpoints-you-download)
  tells what halOS limits, and what `verify` can't see.

### Qwen3.8-27B, when memory is short

Since 0.21.0, Halogen can also serve Qwen3.8-27B, a smaller model than the Flash model. Use it
when you need memory for other work on the machine, or when the Flash model doesn't fit.

**Chosen by memory.** Until you choose a checkpoint with `flash use`, halOS chooses by the memory
that the OS sees. Under 100 GiB, the Flash model doesn't fit, so:

1. At the next start, Halogen's download step downloads the 27B (`flash pull 27b`), and not the
   Flash model (about 118 GB) when it isn't already on disk.
2. Halogen serves the 27B (`qwen3.8-27b`). If the 27B download fails and the Flash model isn't on
   disk, Halogen doesn't start. `sudo halogenctl restart` tries again.

At 100 GiB or more, Halogen serves the official checkpoint. `sudo halogenctl status` and
`flash list` show what memory chose and why.

A 128 GB machine that shows less than 100 GiB has the BIOS setting "UMA frame buffer" on Auto.
Set it to its minimum (see [Where things are](#where-things-are)), and Halogen serves the
Flash model again. `halogenctl selftest` warns about this.

To choose yourself:

```bash
sudo halogenctl flash pull 27b           # Peonist's own 27B, peonist-ai/halogen-qwen3.8-27b-ht4 (about 14 GiB)
sudo halogenctl flash use qwen3.8-27b    # switch; asks first, then restarts Halogen
sudo halogenctl flash use official       # the Flash model, whatever the memory
sudo halogenctl flash use auto           # choose by memory again
```

How much memory each one needs. These are Halogen's own estimates before it starts:

| | Flash model (official) | Qwen3.8-27B |
|---|---|---|
| Weights in memory | about 68 GiB | about 13 GiB |
| Lookup table | 47.7 GiB, read through the file cache, so it also wants that much free memory | none |
| Each position of context | about 29 KiB | about 73 KiB |
| Context with halOS's default (`HALOGEN_KV_POOL_POSITIONS=262144`) | about 7 GiB | about 18 GiB |

So the 27B needs much less memory for its weights, but more for each position of context. To use
less, set a smaller `HALOGEN_KV_POOL_POSITIONS` in `halogen.env`. At each start Halogen writes its
budget to the log: `sudo halogenctl logs 300 | grep 'KV budget'`.

For the 27B:

- Apps must ask for the model `halogen-qwen3.8-27b`, not `halogen-qwen3.8-flash-next` (unless
  you set `HALOGEN_MODEL_ID`). `halogenctl config` shows the name.
- It has its own vision tower (`qwen38-27b-vision.hgn`), which `flash pull 27b` downloads.
- Each halOS release pins the 27B to one commit of Peonist's repository, and to the sha256 of
  each of its files (`HALOGEN_27B_REVISION` and `HALOGEN_27B_SHA256` in `versions.env`). So every
  machine on the release gets the same files, and `flash pull 27b` stops if a file is different.
  A Halogen update moves the pin to the newest commit. A 27B that you downloaded before keeps its
  files. To get the files of the new pin, pull it again (first `sudo halogenctl flash use official`
  if Halogen serves it). To get a different commit, give the repository and `--revision`:
  `sudo halogenctl flash pull peonist-ai/halogen-qwen3.8-27b-ht4 --revision <commit> --as <name>`.
- It has no lookup table and takes no draft head file, so `flash drafter` doesn't apply.
- `flash check` doesn't apply, because it compares a checkpoint with the official Flash model.
- halOS ignores `HALOGEN_COMPOSABLE_CONTEXT=1`, because Halogen 0.21.0 refuses to start the 27B
  with it.
- A 27B from another repository must supply `tokenizer/`. The official tokenizer is for the Flash
  model.
- Halogen can load LoRA adapters for the 27B from an `adapters/` folder beside it. halOS doesn't
  support this yet, and doesn't start Halogen while such a folder is there.
- When you chose the 27B with `flash use`, the Flash model's files stay on disk (about 118 GB),
  and each start still downloads what is missing, so that `flash use official` works at once.
- When memory chose the 27B, halOS doesn't download the Flash model. `flash use official` then
  downloads it at the next start (about 118 GB), before Halogen starts.
- Its speed and its answers are those of a different model. halOS hasn't measured them yet.

### Pulling a `.hgn` checkpoint

```bash
sudo halogenctl flash pull someone/Some-Flash-HGN --revision <commit> --as mine
```

- **One exact version.** It asks Hugging Face to which commit `--revision` points (a branch, tag
  or commit; `main` if you don't give it). It downloads that commit and records it. `flash list`
  shows it.
- **Only what Halogen loads.** This is the `.hgn` checkpoint, its quality sidecar (if it has
  one), the vision tower, and `tokenizer/`. It gets the lookup table
  (`qwen38-flash-next-ngram.hgn`, about 48 GB) only when the checkpoint doesn't have its own.
  Halogen's server tells which. If the table is the same file as the official one, the checkpoint
  shares the official file, with no extra disk space. (`flash list` still counts it in the size of
  the checkpoint.) If the repository has a draft head file (a name with `drafter` that ends in
  `.hgn`), it gets that file too. It downloads nothing else from the repository, so there's no
  Python pickle or script to run.
- **Several checkpoints.** If the repository has more than one `.hgn` checkpoint, select one with
  `--file <name>.hgn`.
- **No tokenizer.** If the repository has no tokenizer, `flash pull` copies in the official
  tokenizer. If its `tokenizer/` has a chat template and settings but no `tokenizer.json` (the
  vocabulary), it adds the official vocabulary and keeps the chat template of the checkpoint. If
  it has its own vocabulary but no `tokenizer.json`, halOS can't make one. The checkpoint then
  fails the check, and `flash use` refuses it. To correct a checkpoint that you pulled before
  halOS did this, run `sudo halogenctl flash verify <name>`. If Halogen serves it, then run
  `sudo halogenctl restart`.
- **Draft head.** Your checkpoint uses Halogen's official draft head
  (`qwen38-flash-next-drafter-r2-ht4.hgn`), the same as the official checkpoint. A draft head
  proposes tokens, and the model checks each one, so the answers do not change. Only the speed
  changes. To use the draft head file from the repository, run
  `sudo halogenctl flash drafter <name> <file>`. To use the draft head inside the checkpoint, run
  `sudo halogenctl flash drafter <name> off`. To use the draft head of Halogen 0.20.6
  (`qwen38-flash-next-drafter-r2.hgn`, if it is still in `/srv/models`), run
  `sudo halogenctl flash drafter <name> official-r2`. If you do not give `<name>`, the command
  sets the checkpoint that Halogen serves. Compare the speed with `sudo halogenctl bench`. A
  checkpoint with a quality sidecar keeps its sidecar and its own draft head. halOS uses the
  official draft head only for a checkpoint that keeps its own precision. Halogen's server tells
  this during the check. For a checkpoint that you pulled before this change, run
  `sudo halogenctl flash verify <name>` one time.
- **Room first.** It checks the free space before it downloads anything. A custom checkpoint
  usually needs 60 to 110 GB, in addition to the 110 GB of the official model.
- **Updates in place.** If you pull the same name again, `flash pull` moves the checkpoint to the
  new commit of the repository. It also removes files that the new commit doesn't have. It doesn't
  replace the checkpoint that Halogen serves: first switch to the official one.
- **Resumes.** If a download stops, run the same command again to continue it. A pull can take
  hours. So over SSH, run it in `tmux`, which keeps it alive if the connection stops.
- **Your token.** It uses your Hugging Face token if you saved one. Gated and private repositories
  need it.

### Pulling a GGUF

Many people publish Qwen3.8 Flash Next as a llama.cpp **GGUF**, not as a Halogen `.hgn`.
Halogen can read a GGUF, and its image can convert one into a `.hgn` one time
([Halogen's GGUF page](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/gguf.md)).
`flash pull` does this for you:

```bash
sudo halogenctl flash pull someone/Some-Flash-GGUF --file UD-IQ4_XS/Some-Flash-UD-IQ4_XS-00001-of-00003.gguf --as iq4
sudo halogenctl flash check iq4          # then judge it, before serving it
```

- **Which build.** A GGUF repository often has many builds (quantizations), in folders or side
  by side. If it has more than one, `flash pull` lists them, and you pick one with `--file`. Give
  the name of the build, or the name of any of its files. A build in parts (`-00001-of-00003`)
  must have all its parts. halOS ignores projector files (`mmproj`), llama.cpp draft heads and
  importance matrices.
- **Builds that Halogen can't read.** Halogen refuses `Q4_1`, `Q2_K`, `Q3_K`, the `IQ1` and
  `IQ2` builds, a plain `Q5_0` build and a plain `Q6_K` build. Full-precision builds (`BF16`,
  `F16`, `F32`) are larger than the memory of the machine. `flash pull` refuses these names
  before it downloads.
- **Good choices** are `IQ4_XS` and `IQ4_NL` builds, for example unsloth's `UD-IQ4_XS`.
  Halogen's page compares some of them. K-quant builds (`Q4_K_M`, `UD-Q4_K_XL`) can give empty
  replies when two requests overlap (Halogen's "Known issue (0.18.4)").
- **What it downloads.** It downloads the parts of the build at an exact commit, and Halogen's
  draft head (`qwen38-flash-next-mtp.hgn`, 1.4 GiB) from the official weights repository. A GGUF
  has no draft head that Halogen can use. It checks each file against the hash from Hugging Face.
  If the download stops, run the same command again to continue it.
- **The conversion.** Halogen's own `convert` then writes `model.hgn`, with the lookup table and
  the draft head in it. It runs in the pinned Halogen image with no network, and it can write only
  to the new checkpoint's folder. Halogen's docs give about ten minutes on an NVMe disk. Then
  Halogen's `verify` checks the result, as for any `flash pull`.
- **Space.** During the conversion, the GGUF and the result are both on the disk. The result is
  a little larger than the GGUF (about 106 GB for a 91 GB `IQ4_XS`). `flash pull` checks the free
  space first.
- **Memory.** Halogen continues to serve during the conversion. If the memory isn't sufficient,
  the kernel stops the conversion, not Halogen. Then `flash pull` tells you to stop Halogen and
  pull again. Nobody has measured the memory that a conversion uses.
- **The GGUF is deleted** after the conversion. `--keep-gguf` keeps it in
  `/srv/models/flash/.convert/<name>/gguf`. If the conversion or the check fails, the GGUF stays,
  so the next pull doesn't download it again. `sudo halogenctl flash convert-stop <name>` deletes
  it.
- **Text only.** The result has no vision tower, so images stay off with it. It has no tokenizer
  of its own, so it gets the official one.
- **Not tested on real hardware yet.** Halogen's docs describe each step, but halOS has not
  converted a real GGUF yet. Run `flash check` before you serve it.

### Converting full-precision weights

Many models are available only in full precision (BF16 `.safetensors`), the format of their
training, not as a Halogen `.hgn`. For **Qwen3.8 Flash Next** weights, halOS can convert them on
the machine. It uses [bf16-to-hgn](https://github.com/Quat3rnion/bf16-to-hgn), a third-party tool
(MIT or Apache-2.0) that the image includes at a pinned version:

```bash
sudo halogenctl flash convert someone/Some-Flash-BF16 --revision <commit> --as mine
sudo halogenctl flash convert-logs       # follow it (Ctrl-C stops following, not the conversion)
sudo halogenctl flash convert-stop       # stop it; add the name to delete the downloaded weights too
sudo halogenctl flash check mine         # then judge it, before serving it
```

- **Checked before the big download.** It first downloads the small files of the repository. It
  refuses anything that is not Qwen3.8 Flash Next, and weights without an MTP head or vision
  tower. (The converter uses the repository's own and puts nothing official in their place.) Then
  it checks that there is space for the weights (about 360 GB) and the result (about 119 GB).
- **Runs on its own.** After you confirm, the download, the conversion and the checks run as a
  service. So if you close the terminal, they don't stop. A stopped download continues. A
  stopped conversion starts again from the beginning.
- **Takes long.** The conversion runs on the CPU with low priority, and takes many hours, probably
  a day or more. Parts of it use several cores (`--threads`: by default half the cores, 16 at
  most). Nobody has measured the time of a full-size conversion yet. Nobody has measured how much
  it slows a Halogen that serves requests.
- **Checked twice.** bf16-to-hgn's own `verify` checks each value that it wrote against the
  weights. Then Halogen's `verify` checks the result, as for `flash pull`. The converter runs in a
  sandbox with no network. It can't see your settings, keys or token, and it can write only to its
  own work folder. The result shows under `/srv/models/flash/<name>` only after both checks pass.
- **The weights are deleted** after the conversion, to free the 360 GB. `--keep-source` keeps them
  in `/srv/models/flash/.convert/<name>/source`.
- **Judge it before serving it.** Nobody has measured the quality of a conversion yet, and Halogen
  has not served a converted checkpoint yet. Before `flash use`, run `flash check`. Switch to it
  when you can monitor it. If it doesn't start, go back with `sudo halogenctl flash use official`.

### Checking quality

`verify` proves that the file has a correct form, not that its answers are good. `flash check`
compares a checkpoint with the official one. It uses Halogen's
[`ppl`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/checkpoint-tools.md#how-does-it-compare-to-the-shipped-checkpoint)
on the public wikitext-2 test text, the comparison that Halogen's docs use:

- **perplexity**: how surprised the model is by the text. Lower is better. A good conversion is
  close to the official one.
- **same next token**: how frequently both checkpoints would write the same word.
- **KL median**: how different their predictions are. A few hundredths is the normal difference
  between two quantizations of the same model. Much more means that it answers differently in
  some places. This is expected of a fine-tune, and a warning sign for a plain conversion.

The check needs the GPU, so Halogen stops while it runs. On the test machine, this takes about
15 minutes, and about 25 the first time on a Halogen version. Then Halogen starts again, even if
the check fails or stops, or if your SSH connection stops. If you stopped Halogen yourself, it
stays stopped. The check downloads the text (1.3 MB) one time, before Halogen stops, and checks
it against its known hash.

halOS keeps the result, and `flash list` shows it. The full output, with the 5 places where the
two checkpoints disagree most, is in `/srv/models/flash/<name>/check.json`. The check measures
one type of text, so also try your own prompts.

## Design choices

- **halOS always keeps the official Flash checkpoint.** A [checkpoint of your
  own](#your-own-flash-checkpoint) is next to it, so a return to the official one never waits for
  a 110 GB download.
- **XRT comes with Halogen.** Since 0.19.1, Halogen's image contains AMD's XRT (2.27 since
  Halogen 0.20.5) with its NPU plugin, so halOS installs and mounts no XRT ([Halogen's NPU host
  notes](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#host)). Only
  the NPU driver and firmware come from the OS.
- **The NPU edition keeps the IOMMU on,** because the NPU needs it. The cost is the prefill gain
  that the no-NPU edition gets.
- **`amd_iommu=off` is a real security trade-off.** It turns off DMA translation for the full
  machine. This is acceptable on a dedicated server. To keep the IOMMU on, change the edition's
  `kargs.d` file.
- **The build downloads Halogen's script and terms** and checks them by hash, so this
  repository redistributes none of them. Halogen's image and weights keep their own licenses.
- **Halogen never downloads.** halOS downloads and checks the models before Halogen starts, and
  Halogen's container has no route out.
