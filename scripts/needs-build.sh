#!/bin/bash
# Exit 0 if the changed files, read from stdin, can affect an image.
# Docs, repository settings, the tests (the check job runs them whatever changed; iso.yml has
# its own list for the VM test's files) and Claude's own files do not, so CI can skip the build.
set -uo pipefail
while IFS= read -r file; do
  case "$file" in
    ''|*.md|LICENSE|.github/ISSUE_TEMPLATE/*|.github/rulesets/*|.github/CODEOWNERS|.github/dependabot.yml|tests/*|.claude/*) ;;
    *) exit 0 ;;
  esac
done
exit 1
