# Contributing

Issues and pull requests are welcome. This is one person's working setup, so changes that make it
more general (a new machine type, a tool that works without another, a portability fix) are the
most likely to land; changes that bend it toward another workflow may be better kept in a fork.

## Before you open a pull request

- **Keep it small** and focused on one change, with a [Conventional Commits](https://www.conventionalcommits.org)
  message (`fix(tmux): ...`, `feat(memory): ...`).
- **Test behavior changes.** Most scripts have a suite in `scripts/tests/` (or next to their skill);
  add a case that fails before your change and passes after it. Run the suites you touched:

  ```bash
  python3 scripts/tests/<name>.test.py
  bash scripts/tests/<name>.test.sh
  bash base/claude/statusline.test.sh
  ```

  Suites that start tmux servers refuse to run while a real tmux socket is visible, so a test can
  never reach your sessions. On Linux run them under a private `/tmp` (see
  `scripts/tests/lib/tmux-sandbox.sh`); on macOS set `TSB_ALLOW_SHARED_TMP=1`.
- **Lint shell** with `shellcheck -x -S warning`, and keep scripts working on macOS's stock bash
  3.2 unless they say they need bash 4 (no `mapfile`, associative arrays or GNU-only flags).
- **No secrets, personal paths, hostnames or real data** in code, tests or docs: use `$HOME`,
  placeholders and `example.com`.
- Don't reformat files you aren't changing.

## Gotchas this code has already hit

- **Claude Code's projects dir encodes a cwd by turning every character that is not a letter or
  digit into `-`** (`/home/me/.dotfiles` is `-home-me--dotfiles`). Mapping only `/` works until a
  path has a dot or an underscore, which the default `<repo>/.claude/worktrees` layout always has.
  Use `sed 's/[^A-Za-z0-9]/-/g'`.
- **tmux 3.4's `display-message -p -t <pane>` exits 0 with empty output for a pane that is gone.**
  To test that a pane exists, compare the printed `#{pane_id}` with the target, or use
  `list-panes -t`, which fails properly.
