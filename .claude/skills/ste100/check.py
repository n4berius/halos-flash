#!/usr/bin/env python3
"""Check that a documentation rewrite changed only the prose.

Usage: python3 .claude/skills/ste100/check.py [--base REF] FILE.md [FILE.md ...]

For each file, compares the working copy with the file at REF (default origin/main):
  - fenced code blocks must be identical, in the same order;
  - inline code spans, link targets (autolinks too) and every word that contains a digit
    (numbers, sizes, versions, #PR numbers) are counted: one that is gone, or appears fewer
    times, is a problem; a new one is listed for a person to confirm.
Then checks every Markdown file in the repository: each `#anchor` link must point to a file and
a heading that exist.
Exits 1 on a problem, 0 otherwise. It cannot see meaning: a swap of two numbers in a sentence,
a dropped "not", or a new sentence between a step and its command. Read the diff for those.
"""
import argparse
import collections
import os
import re
import subprocess
import sys
from pathlib import Path

FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})", re.M)
INLINE = re.compile(r"(`+)(.+?)\1", re.S)
LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
TOKEN = re.compile(r"[#\w.:/%+-]*\d[\w.:/%+-]*")
AUTOLINK = re.compile(r"<((?:https?|mailto):[^>\s]+)>")


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
    # A span that wraps onto the next line is the same span: compare it with its spaces folded.
    inline = [" ".join(m.group(2).split()) for m in INLINE.finditer(prose)]
    plain = INLINE.sub(" ", prose)
    links = LINK.findall(plain) + AUTOLINK.findall(plain)
    plain = LINK.sub("]( )", plain)
    plain = re.sub(r"<[^>]+>", " ", plain)  # HTML tags and autolinks (compared above)
    plain = re.sub(r"(?m)^(\s*)\d+[.)]\s", r"\1", plain)  # numbered-list markers are layout, not facts
    numbers = [t.strip(".,:;/-") for t in TOKEN.findall(plain)]
    return blocks, inline, links, [t for t in numbers if any(c.isdigit() for c in t)]


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


def compare(path, base_ref, notes):
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
    for name, a, b in (("inline code", oi, ni), ("link target", ol, nl), ("number or version", on, nn)):
        ca, cb = collections.Counter(a), collections.Counter(b)
        gone = sorted((ca - cb).elements())
        added = sorted(set((cb - ca).elements()))
        if gone:
            problems.append(f"{path}: {name} removed (or fewer times than before): " + ", ".join(repr(x) for x in gone))
        if added:
            notes.append(f"{path}: {name} added, confirm it is right: " + ", ".join(repr(x) for x in added))
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
            if not file_part:
                dest = f
            else:
                try:
                    dest = str((Path(f).parent / file_part).resolve().relative_to(Path.cwd().resolve()))
                except ValueError:
                    problems.append(f"{f}: link to {target} points outside the repository")
                    continue
            if not dest.endswith(".md"):
                continue
            if dest not in known:
                problems.append(f"{f}: link to {target} finds no file {dest}")
            elif anchor not in known[dest]:
                problems.append(f"{f}: link to {target} finds no such heading in {dest}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()
    # Paths are taken from where the command runs; the anchor check needs the repository root.
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
    files = [os.path.relpath(os.path.abspath(f), top) for f in args.files]
    os.chdir(top)
    problems, notes = [], []
    for f in files:
        problems += compare(f, args.base, notes)
    problems += check_anchors()
    for n in notes:
        print("note:", n)
    for p in problems:
        print(p)
    if problems:
        print(f"{len(problems)} problem(s)")
    else:
        print("ok: nothing was removed, and every anchor link resolves"
              + (f"; {len(notes)} addition note(s) above to confirm" if notes else ""))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
