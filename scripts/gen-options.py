#!/usr/bin/env python3
"""Build each edition's option list and commented config from Halogen's docs/FLAGS.md.

Usage: scripts/gen-options.py path/to/FLAGS.md
Run it when moving to a new Halogen version, and review the new options.
"""
import pathlib, re, sys

# Offered to nobody: they need a path, mount, port or check this OS controls.
BLOCKED = set("""API API_KEY API_KEY_FILE API_LOG API_PORT BIND CACHE_DIR CACHE_FILE
CHAT_TEMPLATE CHECKPOINT CK_OVERLAY DOWNLOAD ENGINE GGUF_CACHE GGUF_THREADS
MATMUL_TUNING_FILE MTP_HEAD NPU_VERIFY NPU_WITH_GPU PORT RECORD_DIR
TEMPLATE_CHECK TEMPLATE_UNCHECKED TOKENIZER""".split())
# Where halOS's default differs from Halogen's. Recording itself is turned on with
# sudo halogenctl records on (render-config sets HALOGEN_RECORD_DIR); the owner chose counts only.
DEFAULTS = {"RECORD_TEXT": "none on halOS (counts only; recording is off until: sudo halogenctl records on)",
            "CACHE_PRUNE_OLD": "1 on halOS (an upgrade removes the previous version's cache files; 0 keeps them for a rollback)"}
NPU_ONLY = re.compile(r"^(NPU_|GUARD_|AGENT_GUARD$)")
ACTIVE = {
    "npu": {
        "HALOGEN_NPU_MODELS": "decider-0.8b,qwen3-embedding-0.6b,qwen3-reranker-0.6b,qwen3guard-gen-0.6b,qwen3.5-2b",
        "HALOGEN_KV_POOL_POSITIONS": "262144",
    },
    "no-npu": {},
}
HEADER = """# Halogen settings for this machine. Copied once to /srv/configs/halogen.env, then it is yours.
# After an update, sudo halogenctl options --new lists options your file doesn't mention yet.
#
# Uncomment a line and set its value, then run: sudo halogenctl restart
# Check what is in effect with: sudo halogenctl config
# Only the options listed here are used. Anything else is ignored and logged.
# Locked settings are in /usr/share/halogen/locked.env.
# The full reference is docs/FLAGS.md in Halogen's repository.
"""


def clean(text):
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    return re.sub(r"[`*]", "", text).strip()


def summary(text):
    text = clean(text)
    parts = re.split(r"(?<=[.:;])\s", text, maxsplit=2)
    # A lead-in as short as "A preview:" says too little alone, so keep the next clause.
    first = (" ".join(parts[:2]) if len(parts) > 1 and len(parts[0]) < 25 else parts[0]).rstrip(":;.")
    return first + "." if len(first) <= 110 else first[:107].rsplit(" ", 1)[0] + "..."


sections, section = {}, ""
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("## "):
        section = line[3:].strip()
    match = re.match(r"\| `(HALOGEN_[A-Z0-9_]+)`[^|]*\| ([^|]*)\| (.*)", line)
    if match:
        name, default, text = match.groups()
        sections.setdefault(section, []).append((name, clean(default), summary(text)))

root = pathlib.Path(__file__).resolve().parent.parent
for edition, active in ACTIVE.items():
    allowed, out = [], [HEADER]
    for title, rows in sections.items():
        if title == "Benchmark tooling":
            continue
        kept = []
        for name, default, text in rows:
            short = name.removeprefix("HALOGEN_")
            if short in BLOCKED or (edition == "no-npu" and NPU_ONLY.match(short)):
                continue
            allowed.append(name)
            default = DEFAULTS.get(short, default)
            kept.append(f"# {text} Default: {default or 'unset'}\n"
                        + (f"{name}={active[name]}\n" if name in active else f"#{name}=\n"))
        if kept:
            out.append(f"\n## {title}\n\n" + "\n".join(kept))
    dest = root / "variants" / edition / "usr/share/halogen"
    (dest / "options.allowed").write_text("\n".join(sorted(allowed)) + "\n")
    (dest / "halogen.env.default").write_text("".join(out))
    print(edition, len(allowed), "options")
