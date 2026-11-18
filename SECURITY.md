# Security

Do not open a public issue for a vulnerability in this project. Use **Report a vulnerability**
on the Security tab of this repository.

Report vulnerabilities in Halogen itself to its maintainers, as its documentation tells you.

Only the newest stable release and the newest pre-release of each channel get fixes.

## Someone with the machine itself

LUKS with TPM unlock protects a disk that someone takes out of the machine. It does not protect
the machine if someone takes all of it. The TPM unlocks the disk for each system that starts
through the normal signed chain, and the halOS installer USB is one of them. Also, a person can
edit the boot menu if it has no password. If someone can take the machine, type the passphrase
at each boot.

These steps make the TPM's key harder to get, but not impossible: a BIOS setup password, a rule to
start only from the internal disk (no USB or network boot), and a boot menu password. The boot files
aren't encrypted, so a person who can open the case can still change them. INSTALL.md, section
8, has the steps.

## Checkpoints you download

`halogenctl model pull` (NPU checkpoints) and `halogenctl flash pull` (Flash checkpoints)
download weights from Hugging Face repositories. halOS and Peonist do not check these
repositories. Treat these weights as untrusted input to Halogen. halOS limits what such a file
can reach:

- **Download.** The download runs in Halogen's pinned image as the unprivileged `halogen` user,
  with no capabilities and no NPU device. A Flash checkpoint's download sees only its own folder.
  The step that lists the files sees no folder.
- **Checks.** Halogen's `verify` and its lookup-table question run offline, with read-only
  models and no capabilities. Halogen checks the official checkpoint in the same way.
- **Only known files.** `flash pull` downloads only the files that Halogen loads, by name, at an
  exact commit: the `.hgn` files and the data files of the tokenizer (`.json`, `.jinja`, `.txt`,
  `.model`, `.tiktoken`). It downloads no pickle and no script. `model pull` skips pickle and
  other formats that Halogen doesn't read.
- **Checks before use.** Each Flash file must match the hash that Hugging Face lists for it. The
  `.hgn` files must also pass Halogen's `verify`, which runs offline with no capabilities.
  `flash use` refuses a checkpoint that does not pass these checks. A pull marks the folder as unchecked until it passes. A
  pull never replaces the checkpoint that Halogen serves. If the chosen checkpoint is missing,
  unchecked or holds links, the server uses the official checkpoint.
- **Serving.** Halogen serves with read-only models and no capabilities, and it never downloads
  files. Its container can still reach the network. So if a checkpoint can take control of
  Halogen, it can also send data out.

`verify` checks that a `.hgn` file has a correct structure. It doesn't read the tokenizer or its
chat template, which Halogen applies to each request. Halogen checks only that the thinking
control of the template works. `verify` can't tell if the answers of a model are good or safe,
and a checkpoint that someone made to mislead you also passes. Use checkpoints from people that
you trust. Before you rely on them, compare their answers with the answers of the official model.
