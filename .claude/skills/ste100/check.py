#!/usr/bin/env python3
"""Check that a documentation rewrite changed only the prose.

Usage: python3 .claude/skills/ste100/check.py [--base REF] FILE.md [FILE.md ...]

For each file, compares the working copy with the file at REF (default origin/main):
  - fenced code blocks must be identical, in the same order;
  - the set of inline code spans must be the same;
  - the set of link targets must be the same;
  - every number in the prose must still be there (and no new ones appear).
Then checks every Markdown file in the repository: each `#anchor` link (in the same file or
in another file) must point to a heading that exists.
Exits 1 when anything differs, 0 otherwise.
"""
import argparse
import collections
import re
import subprocess
import sys
from pathlib import Path

FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})", re.M)
INLINE = re.compile(r"(`+)(.+?)\1", re.S)
LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
NUMBER = re.compile(r"(?<![\w.#-])\d+(?:[.,]\d+)*(?![\w])")


def split_fences(text):
    """Return (prose, [code blocks]) with fenced blocks removed from the prose."""
    blocks, prose, lines, i = [], [], text.split("\n"), 0
    while i < len(lines):
        m = re.match(r"^\s*(`{3,}|~{3,})", lines[i])
        if not m:
            prose.append(lines[i])
            i += 1
            continue
        fence, body = m.group(1), [lines[i]]
        i += 1
        while i < len(lines) and not lines[i].strip().startswith(fence):
            body.append(lines[i])
            i += 1
        if i < len(lines):
            body.append(lines[i])
            i += 1
        blocks.append("\n".join(body).strip())
    return "\n".join(prose), blocks


def parts(text):
    prose, blocks = split_fences(text)
    inline = [m.group(2).strip() for m in INLINE.finditer(prose)]
    plain = INLINE.sub(" ", prose)
    links = LINK.findall(plain)
    plain = LINK.sub("]( )", plain)
    plain = re.sub(r"<[^>]+>", " ", plain)  # HTML tags and autolinks
    numbers = NUMBER.findall(plain)
    return blocks, inline, links, numbers


def slug(heading):
    h = re.sub(r"`", "", heading.strip().lower())
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", h)
    h = re.sub(r"[^\w\- ]", "", h)
    return h.replace(" ", "-")


def anchors(text):
    prose, _ = split_fences(text)
    seen, out = collections.Counter(), set()
    for line in prose.split("\n"):
        m = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m:
            continue
        s = slug(m.group(1))
        out.add(s if seen[s] == 0 else f"{s}-{seen[s]}")
        seen[s] += 1
    for m in re.finditer(r'<a\s+(?:name|id)="([^"]+)"', text):
        out.add(m.group(1))
    return out


def show(ref, path):
    r = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def compare(path, base_ref):
    problems = []
    new = Path(path).read_text()
    old = show(base_ref, path)
    if old is None:
        return [f"{path}: not in {base_ref}; nothing to compare"]
    ob, oi, ol, on = parts(old)
    nb, ni, nl, nn = parts(new)
    if ob != nb:
        for i, (a, b) in enumerate(zip(ob, nb)):
            if a != b:
                problems.append(f"{path}: code block {i + 1} changed:\n--- before\n{a}\n--- after\n{b}")
                break
        if len(ob) != len(nb):
            problems.append(f"{path}: {len(ob)} code blocks before, {len(nb)} after")
    for name, a, b in (("inline code", oi, ni), ("link target", ol, nl)):
        gone, added = sorted(set(a) - set(b)), sorted(set(b) - set(a))
        if gone:
            problems.append(f"{path}: {name} removed: " + ", ".join(repr(x) for x in gone))
        if added:
            problems.append(f"{path}: {name} added: " + ", ".join(repr(x) for x in added))
    gone = sorted(set(on) - set(nn))
    added = sorted(set(nn) - set(on))
    if gone:
        problems.append(f"{path}: numbers no longer in the prose: {', '.join(gone)}")
    if added:
        problems.append(f"{path}: new numbers in the prose: {', '.join(added)}")
    return problems


def check_anchors():
    files = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True).stdout.split()
    files = [f for f in files if Path(f).exists()]
    texts = {f: Path(f).read_text() for f in files}
    known = {f: anchors(t) for f, t in texts.items()}
    problems = []
    for f, t in texts.items():
        prose, _ = split_fences(t)
        for target in LINK.findall(INLINE.sub(" ", prose)):
            if "://" in target or "#" not in target or target.startswith("mailto:"):
                continue
            file_part, anchor = target.split("#", 1)
            dest = f if not file_part else str((Path(f).parent / file_part).resolve().relative_to(Path.cwd().resolve()))
            if dest in known and anchor not in known[dest]:
                problems.append(f"{f}: link to {target} finds no such heading in {dest}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()
    problems = []
    for f in args.files:
        problems += compare(f, args.base)
    problems += check_anchors()
    for p in problems:
        print(p)
    print(f"{len(problems)} problem(s)" if problems else "ok: only the prose changed, and every anchor link resolves")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
