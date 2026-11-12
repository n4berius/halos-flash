# Connecting apps and coding agents

How to point an app at halOS, and, with HTTPS on, how to make it trust halOS's certificate. The
commands are in the [command reference](CLI.md); HTTPS itself is in
[INSTALL.md](../INSTALL.md#https).

## What every app needs

| | Value |
|---|---|
| Address (OpenAI-style APIs) | `http://<machine>:8731/v1`, or `https://…` with HTTPS on |
| Address (Anthropic Messages API, Claude Code) | `http://<machine>:8731`, or `https://…`, without `/v1` |
| API key | `sudo halogenctl api-key` on the machine |
| Model name | `halogen-qwen3.8-flash-next`. Any name other than the NPU models' reaches it; `GET /v1/models` lists them all |

Halogen speaks the OpenAI Chat Completions, Completions and Responses APIs and the Anthropic
Messages API ([Halogen's API reference](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/api.md)).
Apps send the key as `Authorization: Bearer <key>` or `x-api-key: <key>`, whichever they use.

Halogen's own guides cover each agent's settings beyond the address and key (reasoning effort,
output limits, tool calls):
[Claude Code](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/claude-code.md),
[Codex](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/codex.md), and
[Pi, oh-my-pi, opencode, Cline, Roo Code, aider and others](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/agent-harness.md).

## With HTTPS: does the app need anything?

| HTTPS mode (`sudo halosctl https`) | What apps need |
|---|---|
| off | Nothing: `http://` |
| custom, from a public authority | Nothing. Use the name on the certificate |
| custom, from your own authority | Trust your authority, as below |
| self-signed | Trust halOS's authority once, as below |

## Getting halOS's authority

On the machine:

```bash
sudo halosctl https ca > halos-ca.crt
```

Then copy it to your own computer (with `admin` being your user on the machine):

```bash
scp admin@<machine>:halos-ca.crt ~/
```

Compare its fingerprint with the one `sudo halosctl https` shows on the machine:

```bash
openssl x509 -in ~/halos-ca.crt -noout -fingerprint -sha256
```

Use an address the certificate covers: `sudo halosctl https` lists them (localhost, the host
name, the `.local` name and every address of the machine, Tailscale's included). A name it
doesn't list is refused. To add names, list all of them, since they replace the ones given
before: `sudo halosctl https self-signed <name1> <name2>`.

## Trust it per app, or on the whole computer

**Per app** (recommended): each app below trusts halOS's authority and nothing else changes. An
authority trusted by the whole computer could vouch for any website, so anyone who stole it from
the machine could pass for any site on that computer.

**The whole computer**, when an app has no setting of its own (VS Code extensions, browsers):

| System | Commands |
|---|---|
| Fedora, RHEL | `sudo cp halos-ca.crt /etc/pki/ca-trust/source/anchors/` then `sudo update-ca-trust` |
| Debian, Ubuntu | `sudo cp halos-ca.crt /usr/local/share/ca-certificates/halos-ca.crt` then `sudo update-ca-certificates` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain halos-ca.crt` |
| Windows | `certutil -addstore -f Root halos-ca.crt` (as administrator) |

Restart the app afterwards. To undo: remove the file and run the same update command (macOS:
Keychain Access; Windows: `certmgr.msc`). For a browser and the dashboard alone, accepting the
browser's warning once is enough.

## Per agent

Each setting below is read when the app starts, so set it in the shell (or service) that starts
the app, then restart it. In the examples, `192.168.1.20` is the machine and `HALOS_API_KEY` holds
the key from `sudo halogenctl api-key`. These come from each project's own documentation and
source (November 2026); none was tried against halOS yet, so tell us what works.

"Adds" means the app trusts halOS on top of every website it already trusts; "replaces" means it
then trusts only the file you give it (see the bundle below). The second column is what the app
is written in, which decides the setting it reads.

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

"Replaces" means the app then trusts only that file. Its other services (such as downloading
model lists from the internet) stop working unless the file also holds the usual authorities, so
make a bundle:

```bash
cat "$(python3 -m certifi)" halos-ca.crt > halos-bundle.pem
```

(`python3 -m pip install certifi` first if it says there is no such module.)

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

oh-my-pi's `~/.omp/agent/models.yml`, where `apiKey` is the name of the variable, without `$`:

```yaml
providers:
  halos:
    baseUrl: https://192.168.1.20:8731/v1
    api: openai-completions
    apiKey: HALOS_API_KEY
    models:
      - id: halogen-qwen3.8-flash-next
```

Pi's per-provider environment settings in `auth.json`
can't carry the authority: Node reads it only when it starts. oh-my-pi also reads
`NODE_EXTRA_CA_CERTS` from `~/.omp/agent/.env`. Pi's prebuilt single-file binaries run on Bun
rather than Node; if one of them still reports a certificate error, trust the authority on the
whole computer instead.

### opencode

```bash
export NODE_EXTRA_CA_CERTS=~/halos-ca.crt
opencode
```

If opencode runs as a background service, give the service the setting too: `opencode service
set env NODE_EXTRA_CA_CERTS ~/halos-ca.crt`, then restart the service. opencode also trusts the
computer's store. halOS goes in `opencode.json` as an OpenAI-compatible provider with its
`baseURL`, the key and the model `halogen-qwen3.8-flash-next` under `"models"`
([opencode's providers guide](https://opencode.ai/docs/providers/)). With a proxy set
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

Use `CODEX_CA_CERTIFICATE`, not `SSL_CERT_FILE`: Codex treats `SSL_CERT_FILE` as the only
authorities to trust, and then can't reach OpenAI's own servers. `codex doctor` checks the file
can be read. More in [Halogen's Codex guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/codex.md).

### Claude Code

```bash
export NODE_EXTRA_CA_CERTS=~/halos-ca.crt
export ANTHROPIC_BASE_URL=https://192.168.1.20:8731
export ANTHROPIC_API_KEY=<the key>
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000
claude
```

`NODE_EXTRA_CA_CERTS` can also go in the `env` section of `~/.claude/settings.json`. Claude Code
also trusts the computer's store. The address has no `/v1`. More, including why the output limit,
in [Halogen's Claude Code guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/claude-code.md).

### Cline and Roo Code

The VS Code extensions have no certificate setting of their own: VS Code gives them the
computer's trusted authorities (its `http.systemCertificates` setting, on by default). Add
halOS's authority to the computer's store (above), then run "Developer: Reload Window". In the
extension, pick the "OpenAI Compatible" provider, with Base URL `https://192.168.1.20:8731/v1` and
the key.

The Cline command-line tool reads `NODE_EXTRA_CA_CERTS` (it adds the computer's store too).

### aider

```bash
cat "$(python3 -m certifi)" halos-ca.crt > ~/halos-bundle.pem
export SSL_CERT_FILE=~/halos-bundle.pem
export OPENAI_API_BASE=https://192.168.1.20:8731/v1
export OPENAI_API_KEY=<the key>
aider --model openai/halogen
```

`SSL_CERT_FILE` replaces the usual authorities, hence the bundle. Don't use `--no-verify-ssl`:
it turns the check off for every site.

### hermes-agent

In `~/.hermes/config.yaml`, give halOS's provider the authority; it is used for that provider
only:

```yaml
providers:
  halos:
    api: https://192.168.1.20:8731/v1
    key_env: HALOS_API_KEY
    transport: chat_completions
    ssl_ca_cert: /home/you/halos-ca.crt
```

Setting `SSL_CERT_FILE` doesn't help here: hermes-agent then uses only the computer's store for
providers. Adding the authority to the computer's store works too.

### Scripts: OpenAI SDKs and curl

```bash
curl --cacert halos-ca.crt -H "Authorization: Bearer $HALOS_API_KEY" https://192.168.1.20:8731/v1/models
```

Python (`openai`): set `SSL_CERT_FILE` to a bundle as for aider, or pass an SSL context:

```python
import os, ssl, openai
ctx = ssl.create_default_context(cafile="halos-ca.crt")
client = openai.OpenAI(base_url="https://192.168.1.20:8731/v1", api_key=os.environ["HALOS_API_KEY"],
                       http_client=openai.DefaultHttpxClient(verify=ctx))
```

(Version 3 of the `openai` package also offers `DefaultHttpx2Client`; `DefaultHttpxClient` still
works.)

Node (`openai`): start Node with `NODE_EXTRA_CA_CERTS=halos-ca.crt`.

## When it doesn't connect

- **"self-signed certificate in certificate chain", "unable to get local issuer certificate",
  `CERTIFICATE_VERIFY_FAILED`**: the app doesn't trust the authority yet. Check the setting is in
  the environment of the process that runs the app (restart it), and that the file is the one
  `sudo halosctl https ca` prints.
- **"Hostname/IP does not match", "certificate is not valid for …"**: the address isn't covered.
  `sudo halosctl https` lists the covered ones; to add names, give all of them (they replace the
  earlier ones): `sudo halosctl https self-signed <name1> <name2>`. A new address of the machine is covered within a minute.
- **Nothing answers, or a proxy error**: with a proxy set (`HTTPS_PROXY`), add the machine's
  address to `NO_PROXY` (the exact address; not every app understands ranges).
- **Connection reset**: the machine's firewall and port. `sudo halogenctl selftest` checks both,
  and `curl -k https://<machine>:8731/health` from your computer shows whether Caddy answers.
