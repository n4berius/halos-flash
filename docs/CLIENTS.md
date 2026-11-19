# Connecting apps and coding agents

This page tells you how to connect an app to halOS. With HTTPS on, it also tells you how to make
the app trust halOS's certificate. The [command reference](CLI.md) has the commands.
[INSTALL.md](../INSTALL.md#https) explains HTTPS itself.

## What every app needs

| | Value |
|---|---|
| Address (OpenAI-style APIs) | `http://<machine>:8731/v1`, or `https://…` with HTTPS on |
| Address (Anthropic Messages API, Claude Code) | `http://<machine>:8731`, or `https://…`, without `/v1` |
| API key | `sudo halogenctl api-key` on the machine |
| Model name | `halogen-qwen3.8-flash-next`. Each name that is not the name of an NPU model goes to this model. `GET /v1/models` lists all the models |

Halogen supports the OpenAI Chat Completions, Completions and Responses APIs and the Anthropic
Messages API ([Halogen's API reference](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/api.md)).
Apps send the key as `Authorization: Bearer <key>` or `x-api-key: <key>`. Each app uses one of the
two.

Halogen's own guides give the other settings of each agent, for example reasoning effort, output
limits and tool calls:
[Claude Code](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/claude-code.md),
[Codex](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/codex.md), and
[Pi, oh-my-pi, opencode, Cline, Roo Code, aider and others](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/agent-harness.md).

## With HTTPS: does the app need anything?

| HTTPS mode (`sudo halosctl https`) | What apps need |
|---|---|
| off | Nothing: `http://` |
| letsencrypt | Nothing: all apps already trust Let's Encrypt. Use the public name, for example `https://halos.example.com:8731/v1`. The machine's own addresses keep halOS's authority, as below |
| custom, from a public authority | Nothing. Use the name on the certificate |
| custom, from your own authority | Trust your authority, as below |
| self-signed | Trust halOS's authority one time, as below |

## Getting halOS's authority

On the machine, run:

```bash
sudo halosctl https ca > halos-ca.crt
```

Then copy the file to your own computer. In this example, `admin` is your user on the machine:

```bash
scp admin@<machine>:halos-ca.crt ~/
```

Compare its fingerprint with the fingerprint that `sudo halosctl https` shows on the machine:

```bash
openssl x509 -in ~/halos-ca.crt -noout -fingerprint -sha256
```

Use an address that the certificate covers. `sudo halosctl https` lists these addresses: localhost,
the host name, the `.local` name and all addresses of the machine, also Tailscale's. The machine
refuses a name that is not on the list. To add names, give all the names: the new list replaces
the names that you gave before. Run `sudo halosctl https self-signed <name1> <name2>`.

## Trust it per app, or on the whole computer

**Per app** (recommended): each app below trusts halOS's authority, and nothing else changes. An
authority that the whole computer trusts can confirm any website. So a person who steals it
from the machine can act as any site on that computer.

**The whole computer**: use this when an app has no setting of its own (VS Code extensions,
browsers):

| System | Commands |
|---|---|
| Fedora, RHEL | `sudo cp halos-ca.crt /etc/pki/ca-trust/source/anchors/` then `sudo update-ca-trust` |
| Debian, Ubuntu | `sudo cp halos-ca.crt /usr/local/share/ca-certificates/halos-ca.crt` then `sudo update-ca-certificates` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain halos-ca.crt` |
| Windows | `certutil -addstore -f Root halos-ca.crt` (as administrator) |

Then restart the app. To undo the change, remove the file and run the same update command. On
macOS, use Keychain Access. On Windows, use `certmgr.msc`. For a browser and the dashboard only,
it is sufficient to accept the browser's warning one time.

## Per agent

Each app reads the setting below when it starts. So put the setting in the shell (or service)
that starts the app. Then restart the app. In the examples, `192.168.1.20` is the machine.
`HALOS_API_KEY` holds the key from `sudo halogenctl api-key`. These settings come from the
documentation and source of each project (November 2026). Open WebUI, Claude Code, Pi and
oh-my-pi work against halOS on the test machine. The others are not tried yet, so tell us what
works.

"Adds" means that the app trusts halOS together with all the websites that it already trusts.
"Replaces" means that the app then trusts only the file that you give it (see the bundle below).
The second column gives the language of the app. The language sets which setting the app reads.

| Agent | Written in | Trust halOS's authority with | Adds to, or replaces, the usual authorities |
|---|---|---|---|
| [Pi](#pi-and-oh-my-pi) | Node | `NODE_EXTRA_CA_CERTS=~/halos-ca.crt` | Adds |
| [oh-my-pi (omp)](#pi-and-oh-my-pi) | Bun | `NODE_EXTRA_CA_CERTS=~/halos-ca.crt` (also in `~/.omp/agent/.env`) | Adds |
| [opencode](#opencode) | Bun / Node | `NODE_EXTRA_CA_CERTS=~/halos-ca.crt`, or the computer's store | Adds |
| [Codex](#codex) | Rust | `CODEX_CA_CERTIFICATE=~/halos-ca.crt` (not `SSL_CERT_FILE`) | Adds |
| [Claude Code](#claude-code) | Node | `NODE_EXTRA_CA_CERTS=~/halos-ca.crt`, or the computer's store | Adds |
| [Cline, Roo Code](#cline-and-roo-code) | VS Code | The computer's store, then reload VS Code | Adds |
| [Cline CLI](#cline-and-roo-code) | Bun | `NODE_EXTRA_CA_CERTS=~/halos-ca.crt`, or the computer's store | Adds |
| [aider](#aider) | Python | `SSL_CERT_FILE=~/halos-bundle.pem` (a bundle, see below) | **Replaces** |
| [hermes-agent](#hermes-agent) | Python | `ssl_ca_cert:` in the provider's settings | **Replaces**, for that provider |
| [OpenAI SDKs, curl](#scripts-openai-sdks-and-curl) | | See below | |

"Replaces" means that the app then trusts only that file. Its other services (for example, the
download of model lists from the internet) stop unless the file also holds the usual
authorities. So make a bundle:

```bash
cat "$(python3 -m certifi)" halos-ca.crt > halos-bundle.pem
```

If it says that there is no such module, run `python3 -m pip install certifi` first.

### Pi and oh-my-pi

```bash
export NODE_EXTRA_CA_CERTS=~/halos-ca.crt
export HALOS_API_KEY=<the key>
pi    # or omp
```

Pi's `~/.pi/agent/models.json` ([Pi's models guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md)):

```json
{
  "providers": {
    "halos": {
      "baseUrl": "https://192.168.1.20:8731/v1",
      "api": "openai-completions",
      "apiKey": "$HALOS_API_KEY",
      "models": [{ "id": "halogen-qwen3.8-flash-next" }]
    }
  }
}
```

oh-my-pi's `~/.omp/agent/models.yml`. Here `apiKey` is the name of the variable, without `$`:

```yaml
providers:
  halos:
    baseUrl: https://192.168.1.20:8731/v1
    api: openai-completions
    apiKey: HALOS_API_KEY
    models:
      - id: halogen-qwen3.8-flash-next
```

Pi's per-provider environment settings in `auth.json` can't hold the authority, because Node
reads it only when it starts. oh-my-pi also reads `NODE_EXTRA_CA_CERTS` from `~/.omp/agent/.env`.
Pi's prebuilt single-file binaries run on Bun, not on Node. If one of them still shows a
certificate error, trust the authority on the whole computer.

### opencode

```bash
export NODE_EXTRA_CA_CERTS=~/halos-ca.crt
opencode
```

If opencode runs as a background service, also give the setting to the service: `opencode service
set env NODE_EXTRA_CA_CERTS ~/halos-ca.crt`. Then restart the service. opencode also trusts the
computer's store. In `opencode.json`, add halOS as an OpenAI-compatible provider. Give its
`baseURL`, the key and the model `halogen-qwen3.8-flash-next` under `"models"`
([opencode's providers guide](https://opencode.ai/docs/providers/)). If you use a proxy
(`HTTPS_PROXY`), add `NO_PROXY=localhost,127.0.0.1,::1,192.168.1.20`.

### Codex

```bash
export CODEX_CA_CERTIFICATE=~/halos-ca.crt
export HALOS_API_KEY=<the key>
codex
```

```toml
# ~/.codex/config.toml
model = "halogen-qwen3.8-flash-next"
model_provider = "halos"

[model_providers.halos]
name = "halOS"
base_url = "https://192.168.1.20:8731/v1"
wire_api = "responses"
env_key = "HALOS_API_KEY"
requires_openai_auth = false
```

Use `CODEX_CA_CERTIFICATE`, not `SSL_CERT_FILE`. If you set `SSL_CERT_FILE`, Codex trusts only the
authorities in it, and then it can't connect to OpenAI's own servers. `codex doctor` checks that
Codex can read the file. For more, see [Halogen's Codex guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/codex.md).

### Claude Code

```bash
export NODE_EXTRA_CA_CERTS=~/halos-ca.crt
export ANTHROPIC_BASE_URL=https://192.168.1.20:8731
export ANTHROPIC_API_KEY=<the key>
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000
claude
```

You can also put `NODE_EXTRA_CA_CERTS` in the `env` section of `~/.claude/settings.json`. Claude
Code also trusts the computer's store. The address has no `/v1`. For more information, including the reason for
the output limit, see [Halogen's Claude Code guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/claude-code.md).

### Cline and Roo Code

The VS Code extensions have no certificate setting of their own. VS Code gives them the
authorities that the computer trusts (its `http.systemCertificates` setting, on by default). Add
halOS's authority to the computer's store (above). Then run "Developer: Reload Window". In the
extension, pick the "OpenAI Compatible" provider. Give the Base URL `https://192.168.1.20:8731/v1`
and the key.

The Cline command-line tool reads `NODE_EXTRA_CA_CERTS`. It also adds the computer's store.

### aider

```bash
cat "$(python3 -m certifi)" halos-ca.crt > ~/halos-bundle.pem
export SSL_CERT_FILE=~/halos-bundle.pem
export OPENAI_API_BASE=https://192.168.1.20:8731/v1
export OPENAI_API_KEY=<the key>
aider --model openai/halogen
```

`SSL_CERT_FILE` replaces the usual authorities, so you need the bundle. Do not use
`--no-verify-ssl`: it stops the check for all sites.

### hermes-agent

In `~/.hermes/config.yaml`, give the authority to halOS's provider. hermes-agent uses it only for
that provider:

```yaml
providers:
  halos:
    api: https://192.168.1.20:8731/v1
    key_env: HALOS_API_KEY
    transport: chat_completions
    ssl_ca_cert: /home/you/halos-ca.crt
```

`SSL_CERT_FILE` does not help here: with it, hermes-agent uses only the computer's store for
providers. You can also add the authority to the computer's store.

### Scripts: OpenAI SDKs and curl

```bash
curl --cacert halos-ca.crt -H "Authorization: Bearer $HALOS_API_KEY" https://192.168.1.20:8731/v1/models
```

Python (`openai`): set `SSL_CERT_FILE` to a bundle, as for aider. Or give an SSL context:

```python
import os, ssl, openai
ctx = ssl.create_default_context(cafile="halos-ca.crt")
client = openai.OpenAI(base_url="https://192.168.1.20:8731/v1", api_key=os.environ["HALOS_API_KEY"],
                       http_client=openai.DefaultHttpxClient(verify=ctx))
```

Version 3 of the `openai` package also has `DefaultHttpx2Client`. `DefaultHttpxClient` still
works.

Node (`openai`): start Node with `NODE_EXTRA_CA_CERTS=halos-ca.crt`.

## When it doesn't connect

- **"self-signed certificate in certificate chain", "unable to get local issuer certificate",
  `CERTIFICATE_VERIFY_FAILED`**: the app doesn't trust the authority yet. Make sure that the
  setting is in the environment of the process that runs the app, and restart the app. Make sure
  that the file is the one that `sudo halosctl https ca` shows.
- **"Hostname/IP does not match", "certificate is not valid for …"**: the certificate does not
  cover the address. `sudo halosctl https` lists the covered addresses. To add names, give all
  the names, because the new list replaces the earlier names:
  `sudo halosctl https self-signed <name1> <name2>`. The certificate covers a new address of the
  machine in a minute or less.
- **Nothing answers, or a proxy error**: if you use a proxy (`HTTPS_PROXY`), add the machine's
  address to `NO_PROXY`. Give the exact address, because not all apps understand ranges.
- **Connection reset**: look at the machine's firewall and port. `sudo halogenctl selftest`
  checks the two. From your computer, `curl -k https://<machine>:8731/health` shows whether Caddy
  answers.
