---
name: tmux-organize
description: Inspect every tmux pane, infer what it's about, then rename + reorder windows/sessions accordingly. Use when the user says "organize my tmux", "rename my windows based on what's in them", "clean up tmux", "auto-name tmux", "tidy tmux sessions", or invokes `/tmux-organize`. Builds on the tmux-archive skill to read pane contents, then emits an ordered rename/reorder plan the user approves before execution.
---

# tmux-organize skill

## When to use
The user wants descriptive, content-driven names on tmux windows (and optionally sessions) instead of whatever default or outdated name they carry now. Classic trigger: long-running tmux with 7 windows titled `bash`, `p1`, `zsh`, `p3`...

## What to do

### 1. Capture first

Run `tmux-archive` (the sibling skill) with `--latest` so you have fresh pane content to read:

```bash
tmux-archive --latest
```

The archive manifest at `~/.claude/skill-data/tmux-archive/archives/latest/manifest.json` now lists every pane with its `pane_id`, current command, cwd, and a file containing the captured buffer.

### 2. Understand each pane

For each pane in the manifest, read its captured `.txt` file. Form a short, descriptive name (≤30 chars, kebab-case) that answers "what is this pane *about*?" — e.g.:
- `claude` in `~/code/shop-search` after running the search tests → `search-filters-work`
- `zsh` scrolling through `systemctl status nginx` → `nginx-debug`
- `vim editing config.yaml` → `edit-config-yaml`
- Idle shell with no signal → `<session>-scratch-<n>` (don't rename to something misleading)

Prefer the dominant activity (long-running command, obvious topic in scrollback). When in doubt, keep the existing name. Never rename a pane you couldn't read.

#### Use the agent fields when present

The manifest's per-pane records now include Claude agent fields when the
pane has a live `claude` process in its subtree:

- `agent_status` — `busy` / `idle`
- `agent_name` — agent's display name (often empty for new sessions)
- `agent_session_id` — UUID of the Claude session
- `agent_pid`, `agent_kind`, `agent_started_at`

Use them to:

1. **Prefix busy panes for visibility.** If `agent_status == "busy"`,
   prepend `🟢-` (or `b-` if Unicode is unwanted) so the user can spot
   working sessions in tmux's status bar at a glance.
2. **Use `agent_name` as the basis for the new name** when set —
   it's the most recent thing the agent put in its tab title and is
   usually a better summary than buffer-scraped guesses.
3. **Order busy panes first within their session** when proposing
   reorders. Sort by `agent_status == "busy"` desc, then by
   `agent_started_at` (newest first), then keep tmux's natural order.
4. **Don't rename panes whose agent is `busy`** to anything that
   contradicts what the agent itself put in `agent_name` — the user
   probably set that title intentionally.

### 3. Propose a plan

Write a JSON plan to `/tmp/tmux-organize-plan.json` with this schema:

```json
{
  "windows": [
    {"target": "%5", "current_name": "p1",
     "new_name": "search-filters-work",
     "new_session": "shop-parallel",
     "new_index": 1,
     "reason": "claude session driving feat/search-filters in the shop-search worktree"}
  ],
  "sessions": [
    {"current_name": "3", "new_name": "shop-parallel",
     "reason": "5-window parallel worktree set; matches existing script naming"}
  ]
}
```

Rules:
- Use `pane_id` (the `%N` from tmux) to target windows, not `session:index` — pane IDs don't shift when reordering.
- Only propose reorders when there's a clear ordering signal (e.g., grouped by worktree set, test-order, priority). Otherwise leave indices alone.
- Session renames only when the user's request explicitly includes sessions, or the existing session name is obviously non-descriptive (like `0`, `1`, `2`, `default`).
- Never rename a window that actively contains an interactive program the user is mid-task in unless content clearly identifies it.

#### Cross-session moves (`new_session`)

`new_session` moves a window into another session. Only reach for it when the
user asks for topical regrouping, or when a window is plainly orphaned from the
workstream it belongs to. It is the highest-blast-radius operation here, so:

- **Name the destination as it will exist after renames.** Session renames run
  first, so `new_session` refers to the *new* name.
- **When one session both gives up and receives windows, order is load-bearing.**
  A session whose last window leaves is destroyed by tmux — the helper
  sequences inbound-before-outbound so this can't strand a move, but the plan
  should still avoid depending on a session that fully drains.
- **Draining a session destroys the session object, not its panes.** Every pane
  and process survives the move. Because it's still a visible change, the helper
  requires `--allow-empty-sessions`, and it hard-refuses to empty a session with
  attached clients (that would yank the user's own terminal).
- **Account for every pane.** When regrouping wholesale, diff the plan's targets
  against `tmux list-panes -a` so nothing is silently left behind.

### 4. Show the plan to the user

Render the plan as a markdown table so the user can eyeball it quickly. Add
an Agent column when any pane has agent data so the user can see at a glance
which renames are driven by live Claude state:

```
| Target        | Current  | →  New name        | Agent     | Reason                            |
| %5 (s3:w1)    | p1       | 🟢-search-filters  | busy 4m   | claude on shop-search             |
| %14 (s3:w2)   | p2       | csv-export-work    | idle      | claude on shop-csv-export         |
| %22 (s3:w3)   | bash     | nginx-debug        | —         | shell scrolling systemctl status  |
```

Ask: "Apply this plan? (yes / edit / cancel)"

### 5. Apply only after explicit approval

Preview with `--dry-run` first — it prints the exact op sequence and surfaces
any session that would end up empty, changing nothing:

```bash
tmux-apply-plan --dry-run /tmp/tmux-organize-plan.json
tmux-apply-plan /tmp/tmux-organize-plan.json
```

`tmux-apply-plan` needs bash 4 or newer; on macOS, put Homebrew's bash ahead of
`/bin/bash` on `PATH` (it says so and stops on bash 3.2).

The helper:
- Validates the JSON and that every `%N` target and session still exists
- Renames sessions **first**, so `new_session` can name the post-rename session
- Renames windows via `tmux rename-window -t <pane_id> <new_name>`
- Moves/reorders via `tmux move-window -s <pane_id> -t <session>:<new_index>`,
  parking each mover at a scratch-high index first so no move ever needs the
  destructive `-k` flag to clear an occupied index
- Skips any op that would be a no-op (same name, session, and index)
- Prints a summary of what changed

Flags:
- `--dry-run` — print the plan's effects, mutate nothing
- `--allow-empty-sessions` — required when a move drains a session completely

Report the summary to the user.

Verify afterward that nothing was lost — the pane-id and pane-pid sets should be
identical to the pre-apply manifest:

```bash
comm -3 <(jq -r '.panes[].pane_id' ~/.claude/skill-data/tmux-archive/archives/latest/manifest.json | sort) \
        <(tmux list-panes -a -F '#{pane_id}' | sort)   # empty = nothing lost
```

### 6. Preserve the plan

Save the plan alongside the archive so future runs can diff:

```bash
mv /tmp/tmux-organize-plan.json ~/.claude/skill-data/tmux-archive/archives/latest/organize-plan.json
```

## Safety
- Never kill panes/windows/sessions. This skill only renames and moves.
- Always show the plan and get explicit "yes" before applying.
- If the user asks to undo, use the prior `organize-plan.json` (the "before" state, including each window's original session and index, is in the archive manifest for that run).
- Never pass `tmux move-window -k` — it resolves an index collision by *killing*
  the window already there. The park-at-high-index approach never needs it.

## Gotchas
- `tmux rename-window -t <pane_id>` targets the window containing that pane — this is deliberate so reorders don't misfire on stale `session:index` coordinates.
- When reordering, tmux requires the destination index to be free. The helper resolves collisions by parking each mover at a temporary high index first.
- Session renames run **first** (pane ids are stable across them), so `new_session` values name the post-rename sessions.
- **Moving out a session's last window destroys that session.** No pane or
  process dies, but the session object disappears — hence
  `--allow-empty-sessions`. If a session both drains and receives, the inbound
  moves must land first or the destination evaporates mid-apply.
- `renumber-windows on` does *not* fire on `move-window` (only on window close),
  so indices stay put during a reshuffle. Don't count on it to tidy the gaps a
  cross-session move leaves behind; use `tmux move-window -r -t <session>` for that.
