# Security

Do not open a public issue for a vulnerability in this project. Use **Report a vulnerability**
on this repository's Security tab.

Report vulnerabilities in Halogen itself to its maintainers, as its documentation describes.

Only the newest stable release, and the newest pre-release of each channel, get fixes.

## Someone with the machine itself

LUKS with TPM unlock protects a disk taken out of the machine, not the machine taken whole: the
TPM unlocks the disk for anything that boots through the normal signed chain, the halOS
installer USB included, and the boot menu can be edited unless it has a password. For a machine
that could be taken, type the passphrase at every boot. A BIOS setup password, booting only from
the internal disk (no USB or network boot) and a boot menu password make the TPM's key harder to get, not impossible: the boot files
aren't encrypted, so someone who can open the case can still change them. INSTALL.md, section 8,
has the steps.

## Checkpoints you download

`halogenctl model pull` (NPU checkpoints) and `halogenctl flash pull` (Flash checkpoints) bring
weights from Hugging Face repositories that neither halOS nor Peonist checks. Treat them as
untrusted input to Halogen. halOS limits what such a file can reach:

- **Download.** It runs in Halogen's pinned image as the unprivileged `halogen` user, with no
  capabilities and no NPU device. A Flash checkpoint's download sees only its own folder, and
  the listing sees no folder at all.
- **Checks.** Halogen's `verify` and its lookup-table question run offline, with read-only
  models and no capabilities, the same way the official checkpoint is checked.
- **Only known files.** `flash pull` downloads only the files Halogen loads, by name, at an
  exact commit: the `.hgn` files, and the tokenizer's data files (`.json`, `.jinja`, `.txt`,
  `.model`, `.tiktoken`). No pickle or script comes along. `model pull` skips pickle and other
  formats Halogen doesn't read.
- **Checks before use.** Every Flash file must match the hash Hugging Face lists for it. The
  `.hgn` files must also pass Halogen's `verify`, which runs offline with no capabilities.
  `flash use` refuses anything else. A pull marks the folder unchecked until it passes, and
  never replaces the checkpoint Halogen serves. The server falls back to the official
  checkpoint if the choice is missing, unchecked or holds links.
- **Serving.** Halogen serves read-only and offline, with no capabilities.

`verify` checks that a `.hgn` file is well formed. It doesn't read the tokenizer or its chat
template, which Halogen applies to every request; Halogen checks only that the template's
thinking control works. It can't tell whether a model's answers are good or safe, and a
checkpoint built to mislead still passes. Use checkpoints from people you trust, and
compare their answers with the official model's before relying on them.

