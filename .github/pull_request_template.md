## Summary

<!-- What changes and why, in a sentence or two. Link the issue it settles (Closes #123). -->

## Testing

<!--
The suites you ran or added, for example:
  bash scripts/tests/<name>.test.sh
  python3 scripts/tests/<name>.test.py
  bash scripts/tests/lint.sh
A behavior change needs a case that fails before it and passes after it (CONTRIBUTING.md).
-->

## Evidence

<!--
The real flow, run on this head. The PR Labels workflow reads this section.
- The command and its output in a code block: an install into a throwaway HOME, a skill or CLI run in tmux, a hook firing in a Claude Code session.
- A screenshot or recording for anything you look at (the statusline, a tmux layout).
- Suites, lint and CI alone are not evidence; list them under Testing.
- Docs-only and test-only PRs can leave this empty.
Rules: .github/docs/pull-requests.md
-->

## Risk

<!-- What could break if this merges (an install, a hook in every session, data in ~/.claude), and how you would notice. -->

- [ ] No secrets, hostnames, personal paths or real data in code, tests or docs (CONTRIBUTING.md).
