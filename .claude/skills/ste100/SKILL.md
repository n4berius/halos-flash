---
name: ste100
description: Rewrite or write halOS documentation in ASD-STE100 Simplified Technical English (STE). Use when asked to make docs simpler, clearer or STE-aligned, when writing a new user-facing document or section (README, INSTALL, docs/, RELEASING, SECURITY), or when reviewing documentation wording. Not for code, commit messages, CLAUDE.md or .claude/agents.
---

# Writing halOS documentation in Simplified Technical English

ASD-STE100 ("STE") is a controlled language for technical documentation. Its writing rules make
text short, direct and hard to misread, also for readers whose first language is not English.
The halOS owner is not a programmer, and many readers are not native speakers, so the
documentation follows these rules.

This skill gives the writing rules in short form. The full specification (rules and dictionary)
comes from ASD (asd-ste100.org) and is copyrighted: do not copy its text or dictionary into the
repository. Where this skill and common sense disagree with the full specification, keep the
meaning correct first.

## What to rewrite, and what never to change

Rewrite only the prose: sentences, list items and table text written for people.

Never change these. They are data, not prose, and `check.py` fails if one changes:

- Code blocks, inline code (`like this`), commands, file paths, option names, setting names
  (`HALOGEN_*`, `HALOS_*`), unit names, URLs and link targets.
- Numbers, sizes, versions, port numbers, dates, issue and PR numbers (`#123`).
- Quoted program output and error messages.
- Headings that other files or sections link to (`#anchor` links). If you must change one,
  change every link to it in the same edit; `check.py` reports links that no longer resolve.
- Legal text: licence names and terms, trademark statements, warranty disclaimers. Simplify
  the sentences around them only if the meaning stays exactly the same.
- Facts. Do not add, remove or "correct" a fact while rewriting. If a statement looks out of
  date, keep it and list it in your report for the owner.

Technical names are allowed as they are: halOS, Halogen, Fedora, bootc, LUKS, TPM, NPU, GPU,
Caddy, fail2ban, `halogenctl`, `halosctl`, and every other product, command and file name.

## The writing rules

### Words

1. Use simple, common words, and one word for one meaning. Choose a word and keep it
   ("remove", not "delete" in one place and "erase" in the next).
2. Use a word only as the part of speech it normally is. "Test" is a noun or a verb;
   "check" is a verb. Do not turn verbs into nouns ("do an installation of" → "install").
3. Use the simple form of verbs: present ("the fetch downloads"), past ("it failed"),
   future ("it will restart"), and the imperative ("Run the selftest"). Avoid "has been
   done", "would be", "should have", "is being".
4. Do not use "-ing" forms as verbs or nouns where a simple form works ("Before you
   install" not "Before installing"). Technical names that end in "-ing" stay.
5. Avoid phrasal verbs where a single verb exists ("start" not "fire up", "find" not
   "find out", "remove" not "get rid of", "make" not "set up" when you mean "make").
   Keep a phrasal verb only when it is the technical term (`log in`, `set up` in a command
   name, `back up`).
6. House choice: halOS docs keep the short forms "don't", "isn't", "can't" and "it's",
   which read naturally to the owner. Do not add other short forms ("they'd", "it'll").
7. Do not use slang, idioms, jokes or Latin abbreviations ("e.g.", "i.e.", "etc.", "via",
   "vs."). Write "for example", "that is", "and more", "through", "against".
8. Write numbers as digits with their units ("2 GiB", "30 seconds").

### Noun clusters

9. Do not put more than three nouns in a row. "Request record retention setting" →
   "the setting that keeps request records". Technical names count as one word.

### Sentences

10. Procedural sentences (instructions): 20 words or fewer. Descriptive sentences: 25 words
    or fewer. Code, paths and names count as one word each.
11. One instruction per sentence. Two actions at the same time may share a sentence.
12. Write instructions in the imperative: "Open Actions", not "You should open Actions" or
    "Actions should be opened".
13. Use the active voice: "The fetch checks the files", not "The files are checked by the
    fetch". Use the passive only when the actor is unknown or does not matter.
14. Keep articles ("a", "an", "the") and short words like "that". Do not drop them to save
    space: "Check that the service runs", not "Check service runs".
15. Put a condition before the instruction: "If the selftest shows FAIL, read the line",
    not "Read the line if the selftest shows FAIL".
16. House choice: use a colon and a vertical list for a long series of items, not one long
    sentence.

### Paragraphs

17. Write one topic per paragraph. Start with the topic sentence.
18. Use no more than six sentences in a paragraph.

### Procedures

19. Give steps as a numbered list, one action per step, in the order the reader does them.
20. Put the expected result after the step that causes it, as its own sentence.
21. Put a command in a fenced `bash` block of its own, as the docs already do.

### Safety and warnings

22. Start a warning or caution with a clear command ("Do not remove the USB drive until…"),
    then give the reason in a short sentence. Put it before the step it applies to.
23. House choice: halOS docs use only two labels. **Warning:** is for a risk of data loss or
    of a system that will not start, and **Note:** is for other important information. STE's
    own definitions differ (a warning is for danger to people, a caution for damage to
    equipment); halOS has no danger to people to describe, so it keeps one label for each.

### Words that read stiffly

24. Prefer "so" to "thus" and "therefore", and "even if" to "also if". Do not start a
    paragraph with a word that points back to the previous one ("Thus", "This"): join the
    two paragraphs, or name the thing again.

## How to rewrite a file

1. Read the whole file first, so you know what each section says and which headings other
   files link to (`grep -rn "FILE.md#" --include=*.md .`).
2. Rewrite section by section. Keep the order of sections and the facts in each.
3. Keep the same Markdown structure where you can: headings, tables, lists, code blocks.
   Line length: wrap prose near 100 characters, as the repository does.
4. Run the check, from the repository root, against the version before your edit:

   ```bash
   python3 .claude/skills/ste100/check.py --base origin/main FILE.md
   ```

   It compares every code block (exactly, in order), and counts every inline code span, link
   target and word with a digit in it (numbers, sizes, versions, `#123`), so a removed one
   fails even when the same value appears elsewhere. It also checks that every `#anchor` link
   in the repository finds its file and heading. Fix every problem it reports. It lists what
   you added as notes: confirm each one is right (a "5" that was "five" is fine; a new
   command is not, unless the original text named it).
   The check cannot see meaning. It misses two numbers that change places in a sentence, a
   dropped "not", a lost condition ("if you set X, Y happens" becoming "Y happens"), and a new
   sentence between a step and its command. So the next step is not optional.
5. Compare each changed paragraph with the old one (`git diff --word-diff`). Check that every
   condition, every "only", "not", "must" and "can", every actor and the order of events
   are the same. Then read your text once more as a new user would. If a sentence can be
   read two ways, rewrite it.

## Examples

Before: "Once the installation has been completed, the machine will be rebooted, after which
the first-boot setup can be carried out by running the setup command."

After: "When the installation is complete, the machine restarts. Then run the setup command."

Before: "It's recommended that the BIOS UMA frame buffer size be set to its minimum value."

After: "Set the BIOS UMA frame buffer to its minimum value."

Before: "Note that if you're running the no-NPU edition, NPU-related settings get ignored."

After: "**Note:** The no-NPU edition ignores the NPU settings."
