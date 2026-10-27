---
name: parallel-worktrees
description: Spawn N parallel Claude Code OR OpenAI Codex sessions, each in its own git worktree with a pre-loaded prompt, coordinated via tmux with a merged append-only log. Per-row engine selection via an optional 4th manifest column (`codex:sol:xhigh`, `codex:luna:high`) or a run-wide `--engine=codex`; codex always uses ChatGPT auth. Also broadcasts the same prompt to every Claude pane in an existing tmux session via `pw broadcast` (handles paste-collapse, 12k tmux send-keys cap, pane state detection, engagement verification — useful for fleet-style multi-box updates and post-launch refinement), and reports each pane's state via `pw status` (flags panes stalled on a permission or "Run a dynamic workflow?" prompt). Use when the user says any of "run N in parallel", "fan out these prompts", "parallel worktrees", "spawn sessions", "parallel claude", "parallel codex", "codex subagents", "worktree fanout", "broadcast to all panes", "tell every agent the same thing", or when they explicitly invoke `/parallel-worktrees`. Works in any git repo. Pass `--test` to use sandboxed branches that won't collide with real work.
---

# Parallel worktrees skill

## When to use
The user wants to split an independent-subtasks plan (e.g., a feature with 3–7 isolated slices) across concurrent Claude Code sessions, each on its own branch, with tmux as the window manager and a single merged log for easy follow-up review.

## What to do

1. **Gather the manifest.** Ask the user to list tasks as `tag\tbranch\tprompt-file[\tengine]` rows, or produce them yourself from the conversation and confirm with the user before launching. Supported formats:
   - Inline prompt: `clarity\tfeat/dcr-clarity\t@/abs/path/to/prompt.md`
   - Optional 4th column picks the engine per row (see "Engine selection" below): `review\tfix/x\t@/abs/path/to/review.md\tcodex:sol:xhigh`
   - Each tag must be a filesystem-safe identifier (letters, digits, dashes).
   - Each branch may or may not exist; the launcher creates missing ones.

2. **Put the manifest at** `~/.claude/skill-data/parallel-worktrees/manifests/<repo>-<YYYYMMDD-HHMM>.tsv` (or any path the user specifies) so future sessions can find it via `pw log` / `pw teardown`.

3. **Launch with the bundled script.** `pw` is in this plugin's `bin/`, which Claude Code puts on the Bash tool's `PATH` while the plugin is enabled (`install.sh --with worktrees` also links it into `~/.local/bin`):
   ```bash
   pw launch <manifest.tsv>
   ```
   Add `--test` to sandbox (prefix `test-` on worktrees, `test/` on branches, suffix `-test` on the session).
   Add `--force` to recreate a pre-existing tmux session with the same name.
   Add `--no-bootstrap` to skip the per-worktree bootstrap (see below).
   Add `--engine=codex` to make every window a Codex session instead of Claude.

   ### Engine selection (Claude or Codex)

   Each window can run **Claude Code** (default) or **OpenAI Codex CLI**. Pick
   per row via the optional 4th manifest column, or set a run-wide default with
   `--engine` / `PW_ENGINE`.

   **Engine spec** (4th column, or `--engine` value):

   | Spec | Result |
   |------|--------|
   | *(empty)* / `claude` | Claude Code session (default) |
   | `codex` | Codex, default model + effort |
   | `codex:MODEL` | Codex with a model, default effort |
   | `codex:MODEL:EFFORT` | Codex with a model and reasoning effort |

   - **MODEL** accepts short aliases **`sol`** → `gpt-5.6-sol` and **`luna`** →
     `gpt-5.6-luna`, or any full model id (unknown ids pass through unchanged).
   - **EFFORT** is a codex `model_reasoning_effort` level: `low`, `medium`,
     `high`, `xhigh`, `max` (availability varies by model). Set via `-c
     model_reasoning_effort="<effort>"` on the codex command.

   **Run-wide defaults** (flags override env; per-row column overrides both):

   | Flag | Env | Default |
   |------|-----|---------|
   | `--engine=claude\|codex` | `PW_ENGINE` | `claude` |
   | `--codex-model=<m>` | `PW_CODEX_MODEL` | `gpt-5.6-sol` |
   | `--codex-effort=<e>` | `PW_CODEX_EFFORT` | `high` |
   | `--codex-sandbox=bypass\|full-auto` | `PW_CODEX_SANDBOX` | `bypass` |

   Examples:
   ```bash
   # Every window Codex, gpt-5.6-sol at xhigh:
   pw launch m.tsv --engine=codex --codex-model=gpt-5.6-sol --codex-effort=xhigh

   # Mixed fleet, per-row (tab-separated):
   #   audit-sec   review/sec    @sec.md     codex:sol:xhigh
   #   audit-perf  review/perf   @perf.md    codex:luna:high
   #   implement   feat/x        @impl.md            ← empty ⇒ Claude
   pw launch m.tsv
   ```

   **Codex auth is always ChatGPT.** The launcher `unset`s `OPENAI_API_KEY`
   (and `OPENAI_BASE_URL`) in each codex window before invoking `codex`, so it
   uses the stored ChatGPT login in `~/.codex/auth.json` rather than an ambient
   API key. Run `codex login` once beforehand if that file is missing.

   **Codex autonomy.** pw agents work unattended in isolated worktrees and must
   run `git`/`gh` (network + writes), so codex windows launch with
   `--dangerously-bypass-approvals-and-sandbox` by default — the analogue of
   claude's `--dangerously-skip-permissions`. Set `--codex-sandbox=full-auto`
   for codex's workspace-write sandbox instead, but note it **denies network by
   default**, which stalls `gh`.

   **Codex transcripts** land in `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl`
   (codex assigns the rollout id at runtime, so the merged-log header points at
   the day's session dir rather than a pre-named file).

   **Worktree creation delegates to `wt-helper`** (`scripts/wt-helper` in this
   repo; `install.sh --with worktrees` puts it on `PATH`), the same primitive
   that the solo `wt` shell function uses. `pw` invokes it with
   `--from fresh --no-cd --no-fetch --target <path>` so each worktree branches
   off `origin/HEAD` (the remote's default branch) and lands at the path `pw` chose — by default nested inside the repo at
   `<repo>/.claude/worktrees/<repo>-<tag>` (git-ignored), keeping the tag-based
   name. A repo can move its worktrees with `worktree.baseDirectory` in
   `.claude/settings.local.json` (or `.claude/settings.json`), e.g. onto an
   external drive: they then go in `<dir>/<repo>-<tag>`, and a `<dir>` on a
   volume that is not mounted stops the launch instead of filling the root
   disk. Set `WT_LAYOUT=sibling` to revert to the old flat-sibling layout
   (`<parent>/<repo>-<tag>`), `WT_LAYOUT=nested` to stay inside the repo
   whatever the setting says, or `WT_BASE_DIR=<dir>` for a collected layout.
   `pw` asks `wt-helper --print-base-dir` for the directory, so it follows
   exactly the layout solo `wt` does. Sharing the primitive means: same
   default-branch policy, same conflict-resolution logic, same path layout.

   **Per-worktree bootstrap** (default on, runs after `wt-helper`):

   A fresh worktree starts from a clean `git worktree add` and is missing
   the gitignored files that make dev tooling work — env vars, `node_modules`,
   tool-version pins. `pw` then:

   1. **Copies untracked dev-time files** from the source repo if they exist
      there (none are required):
      - `.env`, `.env.keys`, `.env.local`
      - `.npmrc`, `.tool-versions`, `.nvmrc`, `.node-version`
      - `docker-compose.override.yml` (Compose auto-loads this but it's
        usually gitignored — without it the worktree silently loses override
        behavior like host AWS-creds mounts)
   2. **Writes `.envrc`** with `export COMPOSE_PROJECT_NAME=<repo>-<tag>` so
      each worktree gets its own Docker Compose project (containers, network,
      volumes). Without this, Compose attaches to whatever project the main
      repo is already running and silently mounts the *main repo's* code into
      the worktree's containers — a notorious "I edited the file but the
      change isn't visible" footgun. If `direnv` is installed the export
      auto-loads on `cd`; otherwise `source .envrc` manually. The same
      `COMPOSE_PROJECT_NAME` is also exported into each tmux window (see
      "env vars" below).
   3. **`npm install`** if `package.json` is present:
      `npm install --prefer-offline --no-audit --no-fund --legacy-peer-deps`.
      Output goes to `/tmp/pw-npm-$$.log` on failure (logged as a warning,
      doesn't abort the launch). `PW_NPM_INSTALL=0` skips it.
   4. **`PW_BOOTSTRAP_HOOK`**, if set: a shell command run (`sh -c`) in each
      new worktree, last, with `PW_SOURCE_REPO`, `PW_WORKTREE` and `PW_TAG`
      set. It is the place for a repo's own setup, for example regenerating
      configs or warning about pending database migrations:
      ```bash
      # Warn when this branch carries migrations the default branch lacks.
      PW_BOOTSTRAP_HOOK='git diff --quiet origin/HEAD -- migrations/ || echo "re-run migrations"' \
        pw launch m.tsv
      ```
      A failing hook is a warning (its output is kept in a temp log), not a
      stop. `pw` only ever runs a hook you set in the environment, never a
      script a repo ships.

   Skip steps 1-4 with `--no-bootstrap` if your repo has its own setup script.

4. **Attach** with the command the script prints: `tmux attach -t <session>`.

5. **Monitor progress** via the merged log:
   ```bash
   pw log              # follow latest
   pw log <manifest>   # specific run
   ```
   `pw log` opens the merged log in `less +F` (follow mode): tails new
   appends like `tail -F` does, but Ctrl-C drops you into normal less paging
   so you can scroll back through finished sessions, search with `/`, jump
   with `gg`/`G`, and resume follow with Shift-F. Quit with `q`. If `less`
   isn't installed, `pw log` falls back to `tail -F`.

   **Tmux layout**: `pw launch` puts the merged log on **window 0** (named
   `log`), auto-running `pw log <manifest>` so you can watch every agent's
   summary appear in real time. Agents live in windows 1..N. After
   attaching, the session lands you on the first agent (window 1) — the
   log is one keybind away (`Ctrl-b 0`).

   **Pane state (`pw status`, `pw broadcast`).** `pw status <session>` is
   read-only: one line per pane (`target state command`), from the same
   classifier `pw broadcast` uses. States: `claude` (input box, safe to type
   into), `shell`, `permission` (tool-permission prompt), `workflow-prompt`
   (the "Run a dynamic workflow?" confirmation), `unknown`. It exits 2 when any
   pane is in `permission` or `workflow-prompt`, 1 on error. `pw broadcast`
   skips both waiting states and never sends keys to them: option 1 ("Yes, run
   it") is preselected, so a broadcast's closing Enter would approve the
   workflow.

   **After launching an `ultracode` prompt unattended, run `pw status
   <session>` 2-5 minutes later. `workflow-prompt` means a human must
   approve.** The keyword opts the session into dynamic workflows; it does not
   pre-approve them, and the session waits at the confirmation with no error
   (one sat there about 70 minutes). On Claude Code 2.1.283, a
   bypass-permissions session (the `pw launch` default) ran the workflow
   without asking, and an auto-mode session asked.

   For a peer on another box, run `ssh <host> ~/.local/bin/pw status <session>`
   if `install.sh --with worktrees` ran there. Otherwise fall back to raw tmux (keep the
   outer double quotes: the remote shell reads an unquoted `#{...}` as a
   comment):
   ```bash
   ssh <host> "tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'"
   ssh <host> tmux capture-pane -p -J -t <target> -S -40   # look for "Run a dynamic workflow?"
   ```

6. **Teardown** (kills session, removes worktrees, optionally deletes branches):
   ```bash
   pw teardown <manifest>
   ```
   It tears down the repo recorded in the run's log header (`# repo=`, found
   through `<manifest>.log-path`), so while that record exists it works from
   any directory. It kills this manifest's sessions only: launch marks each
   session with its manifest (`@pw_manifest`), and a `--test` fleet and a
   real one share the repo's two session names, so the other one may be
   another manifest's fleet, which it leaves running. It removes the
   worktrees at the paths the launch logs of this manifest record (every run
   of it, both modes; `# tag=... worktree=`, read only up to the blank line
   that ends the header, since agents append to the log after it), so a
   `worktree.baseDirectory` or `WT_*` lever changed since launch does not
   leave them behind, and also the ones `wt-helper --print-base-dir` places
   now under the plain and `test-` names when they are on this manifest's
   branch for that tag (another manifest may use the same tag). It removes
   only directories git lists as linked worktrees of that repo and says
   which others it left.
   Without the record it falls back to the main checkout of the repo you run
   it from. If no session, worktree, or (with `--delete-branches`) branch
   matches, it exits 1, lists what it tried, and keeps the sidecar.

## Prompt template

Every prompt you hand to a spawned session MUST end with this footer so the session writes its summary to the merged log:

```
When you finish, atomically append your summary to the merged log:
{
  printf '\n<<SESSION tag=%s branch=%s worktree=%s finished_at=%s>>\n' \
    "$PARALLEL_TAG" "$PARALLEL_BRANCH" "$PWD" "$(date -Iseconds)"
  cat <<'SUMMARY_EOF'
<YOUR UNDER-150-WORD SUMMARY HERE — include: what you changed, tests status, any deviations>
SUMMARY_EOF
  printf '<<END SESSION %s>>\n' "$PARALLEL_TAG"
} | "$PARALLEL_APPEND"
```

`$PARALLEL_APPEND` is a small helper (`bin/pw-append`) that wraps the write in a portable mkdir-mutex, so two sessions finishing within milliseconds don't interleave their output. It works on macOS, Linux, and WSL with no `flock` dependency.

The `pw launch` script exports these env vars in each window:
- `PARALLEL_LOG` — merged log file path
- `PARALLEL_TAG` — this session's tag
- `PARALLEL_BRANCH` — this session's branch
- `PARALLEL_SESSION_ID` — Claude session UUID (also baked into the log header)
- `PARALLEL_TRANSCRIPT` — absolute path to this session's `.jsonl` transcript
- `PARALLEL_APPEND` — path to the locking append helper (use as shown above)
- `COMPOSE_PROJECT_NAME` — `<repo>-<tag>`; mirrors what bootstrap wrote to
  `.envrc`. Exported directly so `docker compose` works in the window even
  when `direnv` isn't installed and `.envrc` hasn't been sourced.

The launcher also writes the transcript path for every agent into the log's header block at launch time, so a post-hoc merge reviewer can open any session's full JSONL without hunting for it.

Copy this footer into every task's prompt file before launching. The `pw validate <manifest>` command warns if any prompt is missing `$PARALLEL_LOG`/`$PARALLEL_APPEND`, or if it still uses the legacy `flock(1)` pattern (which fails on macOS).

## Why it's designed this way

- **Worktree per task** — hard branch isolation, zero stash juggling, parallel builds.
- **tmux for orchestration** — attach/detach without killing work, window-per-task for clean navigation (`Ctrl-b 0…N`).
- **Single merged log with sentinels** — downstream merge agents can `grep -A 999 "<<SESSION tag=clarity"` and extract one session's work without parsing TUI transcripts.
- **mkdir-mutex around writes** — `bin/pw-append` holds a directory-based lock at `$PARALLEL_LOG.lockd` while writing, so two sessions finishing within ms don't interleave output. `mkdir(2)` is atomic on every POSIX local filesystem, so the same helper works on macOS, Linux, and WSL with no `flock(1)` dependency.
- **Manifest-driven** — the same launcher works for 2 tasks or 20, the count is whatever the manifest contains.
- **`--test` mode** — sandboxed names (`test-` prefix, `test/` branches, `-test` session) so trial runs don't collide with real worktrees.

## Gotchas

- **The launcher starts an INTERACTIVE Claude session per window.** `pw` runs
  `claude --dangerously-skip-permissions --session-id <uuid> "<prompt>"` —
  the positional prompt is the session's *first* user message, but the
  session stays open for follow-up. (One-shot mode requires `-p/--print`,
  which `pw` does not pass.) The agent is expected to do its work, append
  its summary to `$PARALLEL_LOG` via `$PARALLEL_APPEND`, and then either
  idle on a confirmation prompt or `/exit`. If you want hard one-shot
  semantics (close the window when the agent finishes), the prompt itself
  must end with a step that exits — e.g. an `exit` typed into the shell
  via the agent's own Bash tool — because `pw` doesn't enforce it.
- macOS does not ship `flock(1)`, and `shlock(1)` was retired long ago — both are unavailable on a stock Mac. The skill avoids both: spawned agents pipe their summary into `$PARALLEL_APPEND` (`bin/pw-append`), which uses a portable mkdir-mutex. If you find an old prompt file that still calls `flock`, run `pw validate <manifest>` — it will flag the `flock` reference so you can update the footer.
- **`pw teardown` works from anywhere; `pw launch` does not.** Inside a linked worktree (e.g. a Claude worktree under `<repo>/.claude/worktrees/`), `git rev-parse --show-toplevel` names that worktree, not the repo, so teardown uses the repo recorded at launch and exits 1 when nothing matches. **Launch still uses the cwd's toplevel, so launch from the main checkout.** From a linked worktree the session is named after that worktree, the new worktrees nest inside it, and bootstrap copies `.env` files from it rather than from the main checkout.
- **tmux resolves a bare `-t <name>` by prefix.** With only `<repo>-parallel-test` running, `tmux has-session -t <repo>-parallel` succeeds, and `kill-session` kills the test session, so a non-test `pw launch --force` could kill a running `--test` fleet. `pw` targets its own sessions as `-t "=<name>"`, which matches exactly. Do the same in ad-hoc scripts; in zsh, quote it, since a bare `=name` is equals-expansion.
- `git worktree add` fails if the target path exists. The launcher reuses an existing worktree only if it's on the correct branch; otherwise it aborts with a clear message.
- If a prompt file is missing, the launcher aborts before creating any worktrees (fail-fast).
- **Missing `.env` in fresh worktrees** — without bootstrap, `docker compose up` in a new worktree will warn about ~100 "variable is not set" lines and compose mounts a *directory* at `./.env` when the file is absent. If you see that, stop the stack, `rmdir .env`, copy the env files from the source repo, and restart. The default bootstrap prevents this; disable only if you have a repo-specific reason.
- **Host `node_modules` vs container `node_modules`** — `npm install` populates the host `node_modules`, which is what hot-reloading tools like `tsx watch` use. Container images have their own baked-in `node_modules`; if you add a new dependency, you either rebuild the image (`docker compose build <svc>`) or `docker compose exec <svc> npm install --legacy-peer-deps` then restart the container.
- **Docker Compose project name collisions across worktrees** — Compose identifies projects by directory name of the compose file that was *first* used to launch the stack. If the main repo already has a running project (e.g. `myapp`) and you then `docker compose up` from a worktree, Compose attaches to the existing project and **mounts the main repo's `packages/` dir, not the worktree's** — so every code change you make in the worktree is invisible to the containers. Symptom: you edit a file, tsx watch claims to restart, but the running code is unchanged. Diagnose with `docker inspect <container> --format '{{range .Mounts}}{{.Source}}->{{.Destination}}{{"\n"}}{{end}}'` and check whether the source path is your worktree or the main repo. Two fixes:
  1. **Isolate**: prefix every worktree's compose commands with a unique project name: `COMPOSE_PROJECT_NAME=myapp-<tag> docker compose up -d`. Each worktree gets its own containers, network, and volumes. Requires unique ports or the stack will conflict with whatever else is running.
  2. **Swap**: tear down the old project (`docker compose -p myapp --project-directory /path/to/main/repo down`) and `docker compose up -d` from the worktree. Simpler when you don't need the main repo's stack running.
- **`docker-compose.override.yml` is per-checkout** — Compose auto-loads `docker-compose.override.yml` next to the main compose file, but the file is typically gitignored (contains dev-specific mounts like host AWS creds). Fresh worktrees won't have it, so a stack that "just worked" in main silently loses override behavior — e.g. a service loses its `~/.aws` mount and can no longer reach AWS. Copy the override when bootstrapping, or add it to the file list `pw` copies. Check with `ls docker-compose*.yml` in the worktree vs the main repo.
- **Shell env pollution overrides `.env`** — Docker Compose's `${VAR}` interpolation reads the *invoking shell's* environment **before** falling back to `.env`. If your shell has e.g. `AWS_REGION=us-east-1` exported from a dotfile or earlier work, and `.env` declares `AWS_REGION=eu-west-1`, the container ends up with `us-east-1`. Symptom: AWS calls fail with `UnrecognizedClientException` ("token invalid") even though the keys are fine — they are valid for a different region or account than the one the shell-pinned value points at. Diagnose by comparing `env | grep ^AWS_` in your shell vs `grep ^AWS_ .env`. One-shot fix: `env -u AWS_REGION -u AWS_BEARER_TOKEN_BEDROCK docker compose up -d --force-recreate <svc>`. Permanent fix: find where the shell exports the var (`grep -r 'AWS_REGION' ~/.zshrc ~/.bashrc ~/.config/`) and remove or scope it to a different directory (`direnv` `.envrc`, `autoenv`, etc.). This isn't AWS-specific — any env var shared between your dev environment and `.env` is vulnerable.
- **The positional prompt starts work immediately — client-side slash commands never run.** `pw` passes the prompt as the session's first user message, so anything you would normally *type* first (`/effort`, `/model`, `/loop`) is not available to it: those are client-side commands, not text the agent can act on. If a track needs a non-default effort or model, launch with a standby prompt ("Reply with exactly READY and do nothing else; your task arrives next"), wait for READY in the pane, `tmux send-keys` the slash command and confirm the pane echoes its confirmation, then send a one-line pointer at a brief file on disk. Putting the real task in the positional prompt instead means it runs at session defaults.
- **`PW_CLAUDE_CMD` overrides the launch command for every claude window** (default `claude --dangerously-skip-permissions`). This is the supported lever for launching the fleet on a different route or wrapper — e.g. `PW_CLAUDE_CMD=yuma pw launch m.tsv` (this repo's optional Bedrock Mantle launcher, see `docs/infra/aws.md`) to run every window against a route billed through AWS instead of the Claude subscription, which keeps a fan-out alive when the subscription's model allowance is exhausted. Verify what the wrapper actually resolves to before launching N sessions on it: a wrapper that blanks `ANTHROPIC_DEFAULT_*` env vars can resolve `--model opus` to a different version than your interactive shell does.
- **The bootstrap's install is npm — wrong for bun repos.** Step 3 runs `npm install --legacy-peer-deps`, which in a bun workspace repo (`bun.lock`, no `package-lock.json`) builds a second, divergent dependency tree. Launch with `PW_NPM_INSTALL=0 PW_BOOTSTRAP_HOOK='bun install --frozen-lockfile'`, which keeps the `.env*` copy and the Compose isolation. Budget disk first — a bun-installed worktree of a mid-size monorepo runs ~1.9 GB, so five parallel tracks is ~10 GB. Check `df -h /` before launching and skip the install for tracks that only write docs or non-JS code.
- **Under heavy load the submit Enter after a pasted prompt is dropped.** Seen at load average 155 on a 10-core Mac: `tmux send-keys -l "<prompt>"` then `Enter` left the text sitting in the input box below the separator line in 3 of 7 panes, with no spinner and no `⏺`. The tell is layout: a submitted prompt renders above the `─── ultracode ─` separator with a spinner or `⏺` under it; stuck text renders below the separator, in the box. Fix is one extra `tmux send-keys -t <pane> Enter` per stuck pane, which is idempotent (an Enter on an empty box does nothing), so never re-paste. Verify engagement 60 to 90 seconds after dispatch, not immediately: rendering itself lags tens of seconds at that load.
