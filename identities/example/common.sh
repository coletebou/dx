# identities/example/common.sh — shell settings for this identity, on every
# machine and role. aliases sources it after base/aliases.sh and roles/<role>/,
# so anything here overrides them. Copy the directory to identities/<you>/,
# edit it, and install with `./install.sh --identity <you> ...`.
#
# Everything below is optional and commented out: uncomment what you use.

# Label this machine's tmux status bar, terminal tab and Claude Code statusline
# without a hosts file (otherwise the hosts file here, else the hostname).
# export DF_HOST_LABEL=desk

# Where a new interactive shell starts when it opens in $HOME.
# export DF_LOGIN_DIR="$HOME/code"

# Paired review (scripts/autoreview-pair): the file of exports the reviewers'
# credentials live in, if not ~/.env_secrets; empty skips it.
# export AUTOREVIEW_ENV_FILE="$HOME/.env_secrets"

# Memory tools: a command that exits 0 for a transcript, prompt or memory file
# that must never reach a model (see scripts/lib/memory-boundary.sh).
# export MEMORY_BOUNDARY_CMD="$HOME/bin/is-restricted"
# The model the memory passes use (an alias or a provider id).
# export CLAUDE_CONSOLIDATE_MODEL=haiku

# Session tools: words that mark a parked session as waiting on you (cc-park),
# and the launcher a handoff successor starts with per route (cc-handoff).
# export CC_PARK_OWNER="sam"
# export FSH_LAUNCHERS="mantle=yuma"
# export FSH_DEFAULT_LAUNCHER=claude

# Agents in parallel worktrees (pw) and the second-opinion advisor.
# export PW_CLAUDE_CMD="claude --dangerously-skip-permissions"
# export FABLE_LAUNCH_CMD="claude"
