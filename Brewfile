# Brewfile: the Homebrew packages this setup expects on a Mac (most formulae work on Linux too).
# install.sh (the brew component) links it to ~/.Brewfile, so from anywhere:
#   brew bundle --global              install what is missing
#   brew bundle check --global        what is missing, changing nothing
#   brew bundle cleanup --global      what is installed but not listed (add --force to remove it)
# Take what you want: delete lines, or keep a Brewfile of your own next to it.

# Taps
tap "oven-sh/bun"

# Core CLI tools
brew "bat"
brew "fd"
brew "fzf"
brew "htop"
brew "jq"
brew "mas"       # Mac App Store CLI
brew "nano"      # GNU nano (macOS /usr/bin/nano is a pico symlink with no syntax highlighting)
brew "ncdu"
brew "ripgrep"
brew "tmux"
brew "tree"

# Shell: zsh plugins and the prompt the shell component configures
brew "starship"
brew "zsh-autosuggestions"
brew "zsh-syntax-highlighting"

# Modern CLI replacements
brew "eza"
brew "lazygit"
brew "zoxide"

# Git and forges
brew "git"
brew "git-delta"
brew "git-filter-repo"
brew "gh"
brew "glab"
brew "gitleaks"  # the git hooks refuse to run without it

# Languages and runtimes. The pinned global CLIs (node-tools/, the node-tools component) need
# Node 24: `fnm install 24 && fnm default 24`. The Codex CLI is one of those pinned npm tools,
# not a formula, so every platform gets the same version: don't add brew "codex" as well.
brew "node"
brew "fnm"
brew "oven-sh/bun/bun"
brew "go"
brew "pipx"
brew "cmake"

# Containers: a local Docker engine through Colima (docker ships its own shell completions)
brew "colima"
brew "docker"
brew "lima"

# Networking
brew "cloudflared"
brew "mtr"

# Media and documents (ffmpeg also powers the music-video plugin)
brew "ffmpeg"
brew "poppler"
brew "chafa"     # images in the terminal

# Cloud CLIs
brew "awscli"
cask "gcloud-cli"   # a cask only: there is no gcloud-cli formula

# Encryption
brew "age"

# GNU userland next to the BSD one. Installed g-prefixed (gsed, gfind, gtimeout, ...) so they
# never shadow the BSD tools macOS itself relies on; reach for them when porting Linux scripts.
brew "coreutils"   # gdate, gls, gtimeout, gcp, gmv and about 100 more
brew "gnu-sed"     # gsed (-i without the empty-suffix quirk)
brew "findutils"   # gfind, gxargs (-r)
brew "gawk"        # GNU awk (macOS ships a minimal awk)

# Fun
brew "figlet"
brew "fortune"
brew "ttyd"        # share a terminal in a browser

# --- GUI apps (macOS) ---

# Browsers
cask "google-chrome"
cask "brave-browser"

# Development
cask "ghostty"             # its config: ghostty/ (the ghostty component)
cask "visual-studio-code"  # settings and extensions: vscode/ (the vscode component)
cask "claude"
cask "mitmproxy"

# Desktop utilities
cask "maccy"   # clipboard history
cask "mos"     # smooth scrolling for a mouse wheel

# Fonts: Nerd Fonts carry the icons eza --icons and the starship prompt draw. Ghostty has its
# own glyph fallback; VS Code's terminal and browser terminals use installed fonts only.
cask "font-jetbrains-mono-nerd-font"
cask "font-meslo-lg-nerd-font"

# VS Code extensions are not listed here: vscode/extensions.json holds them, and
#   jq -r '.recommendations[]' ~/.dotfiles/vscode/extensions.json | xargs -n 1 code --install-extension
# installs them.
