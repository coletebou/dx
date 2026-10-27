# shellcheck shell=bash
# shellcheck disable=SC2034  # every name here is read by the modules that source this file
# versions.sh: every tool the provisioner downloads, pinned to one version and the sha256 of each
# architecture's release asset, all from the project's own release URLs. A download whose hash
# differs stops the run. To bump a tool, change its version and both sums together, then check
# them against upstream with `provision --verify-pins`, which downloads every asset and compares.
#
# The sums were taken from the downloads themselves and, where the project publishes one, checked
# against its own checksum list (starship's .sha256 files, gitleaks', lazygit's and Node's
# SHASUMS256.txt, HashiCorp's SHA256SUMS, the Claude Code release manifest).

# tmux, built from its release tarball (Ubuntu 24.04's apt tmux is 3.4).
PIN_TMUX_VERSION=3.7b
PIN_TMUX_SHA256=87f2e99e3b685973f2ca002ffd6ed7e51a5744f7009daae5a15670b6d532db96

# fnm, the Node version manager the shell config uses, and the Node it installs.
PIN_FNM_VERSION=1.39.0
PIN_FNM_SHA256_x86_64=7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224
PIN_FNM_SHA256_aarch64=4eaff58b2c5bf30d0934027572dd0b5bbb60d2a1af309230b53662d4b1d45599
PIN_NODE_VERSION=24.22.1
PIN_NODE_SHA256_x86_64=eb6728e77c576a35162c122c45ccadf224d89ff00abc8dae46cc2897c6002d7c
PIN_NODE_SHA256_aarch64=33c37be234ba8bee041961047b19160f4d7d0f164e8e246f78bdd10feff148b3

# The prompt.
PIN_STARSHIP_VERSION=1.27.0
PIN_STARSHIP_SHA256_x86_64=10c8eb4cb3b761d9bf59ea828444c2dab36c900b7d69a69e08814b286969df89
PIN_STARSHIP_SHA256_aarch64=341f5cbf24699fa0b27ec88965ad25f862ea09e15d35a543fd6ffdff1d2aa00d

# Command-line tools the shell and git config use when they are there.
PIN_EZA_VERSION=0.23.5
PIN_EZA_SHA256_x86_64=35c70c5c43c29108075e58b893234c67ef585f0b53a7eaf8e9e7d4eec9f339b4
PIN_EZA_SHA256_aarch64=40b87ae8628aa2ff0f0d2dc24ab52f689631366385c3da630bae745671fd71ec
PIN_DELTA_VERSION=0.20.1
PIN_DELTA_SHA256_x86_64=69dcb4043f55c29118f408c6efd30115e0a4e0a6709253343b8c8fa814ab4a31
PIN_DELTA_SHA256_aarch64=da7f4338f593572ff426ae153e0870e2fdc72729416eff551b40cdeb67940db8
PIN_ZOXIDE_VERSION=0.10.0
PIN_ZOXIDE_SHA256_x86_64=2d93385b99f3e82cf2701609a1bffcad863fbeb75aa3fe7eb6be4d29be68b1ae
PIN_ZOXIDE_SHA256_aarch64=f1f16c5d6298d63dee467eedea1cdcd8490e43e493bea43acd416dc9033ef641
PIN_LAZYGIT_VERSION=0.63.1
PIN_LAZYGIT_SHA256_x86_64=8e033bc78c8e192dee9510e951f6c9e154289b7198d22c924ed1d0a951b0dac1
PIN_LAZYGIT_SHA256_aarch64=555dbc9a8efcf2e33bc24e7fbd9463e9fa375e3c5e23cc270763733c38eeae36
# The secret scanner the git hooks require (the same version CI pins).
PIN_GITLEAKS_VERSION=8.30.1
PIN_GITLEAKS_SHA256_x86_64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
PIN_GITLEAKS_SHA256_aarch64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080

# Claude Code, the native binary from its release bucket (the layout its own installer uses).
PIN_CLAUDE_VERSION=2.1.220
PIN_CLAUDE_SHA256_x86_64=674f61f20ff306f3100cf9200e4c36c4b70278b5bef2884549819b942a89c863
PIN_CLAUDE_SHA256_aarch64=159e4a51d796f3bf14677577100f7efb845611b1ceaf0c30cbd8d4650d942185

# The terminfo source for Ghostty: ncurses' own database at its 6.6 release tag. ncurses names
# the entry "ghostty"; Ghostty sets TERM=xterm-ghostty, so an alias of that name is added.
PIN_TERMINFO_SRC_TAG=v6_6
PIN_TERMINFO_SRC_SHA256=75673b421c25032306f7cdf26df57978c86ed9cf3d3fb16a6479233775f4f961

# tmux plugins (tmux.conf lists them), each at one commit of its repository.
PIN_TPM_COMMIT=e261deb1b47614eed3400089ce7197dc68acc4eb
PIN_TMUX_SENSIBLE_COMMIT=25cb91f42d020f675bb0a2ce3fbd3a5d96119efa
PIN_TMUX_RESURRECT_COMMIT=cff343cf9e81983d3da0c8562b01616f12e8d548
PIN_TMUX_CONTINUUM_COMMIT=0698e8f4b17d6454c71bf5212895ec055c578da0

# Opt-in modules.
PIN_AWSCLI_VERSION=2.36.12
PIN_AWSCLI_SHA256_x86_64=4c9bb5a213f5f2cdc73947abfe16efc45901ed7cd294fec567bd8d77dee0b704
PIN_AWSCLI_SHA256_aarch64=e2d827be76a2dc2aea3697ab866e1e650286429fb8268eec7b109c475d8b7c6d
PIN_TERRAFORM_VERSION=1.17.0
PIN_TERRAFORM_SHA256_x86_64=c168cab7c637a8769fdb90089ddd19de701bc6ff8aca64dc2e2185fe46f59f67
PIN_TERRAFORM_SHA256_aarch64=f32478134ffc6d710eec474bbd316652cdddc0f4e336973a3745e8d3a3309cdf

# apt repositories: the primary key fingerprint each signing key must have. Docker's is the one
# its install guide prints; Tailscale publishes none, so this is the key its repository served
# when it was pinned (a rotation stops the module with this message, which is the point).
PIN_DOCKER_APT_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
PIN_TAILSCALE_APT_FPR=2596A99EAAB33821893C0A79458CA832957F5868

# pin_url TOOL: the release asset of TOOL for this machine's architecture.
pin_url() {
    local a="${BOOTSTRAP_ARCH:-$(bootstrap_arch)}" gh=https://github.com
    local deb=amd64 short=x64
    [ "$a" = x86_64 ] || { deb=arm64; short=arm64; }
    case "$1" in
        tmux) echo "$gh/tmux/tmux/releases/download/$PIN_TMUX_VERSION/tmux-$PIN_TMUX_VERSION.tar.gz" ;;
        fnm) [ "$a" = x86_64 ] && echo "$gh/Schniz/fnm/releases/download/v$PIN_FNM_VERSION/fnm-linux.zip" \
                 || echo "$gh/Schniz/fnm/releases/download/v$PIN_FNM_VERSION/fnm-arm64.zip" ;;
        node) echo "https://nodejs.org/dist/v$PIN_NODE_VERSION/node-v$PIN_NODE_VERSION-linux-$short.tar.gz" ;;
        starship) echo "$gh/starship/starship/releases/download/v$PIN_STARSHIP_VERSION/starship-$a-unknown-linux-musl.tar.gz" ;;
        eza) echo "$gh/eza-community/eza/releases/download/v$PIN_EZA_VERSION/eza_$a-unknown-linux-gnu.tar.gz" ;;
        delta) [ "$a" = x86_64 ] \
                 && echo "$gh/dandavison/delta/releases/download/$PIN_DELTA_VERSION/delta-$PIN_DELTA_VERSION-x86_64-unknown-linux-musl.tar.gz" \
                 || echo "$gh/dandavison/delta/releases/download/$PIN_DELTA_VERSION/delta-$PIN_DELTA_VERSION-aarch64-unknown-linux-gnu.tar.gz" ;;
        zoxide) echo "$gh/ajeetdsouza/zoxide/releases/download/v$PIN_ZOXIDE_VERSION/zoxide-$PIN_ZOXIDE_VERSION-$a-unknown-linux-musl.tar.gz" ;;
        lazygit) [ "$a" = x86_64 ] \
                 && echo "$gh/jesseduffield/lazygit/releases/download/v$PIN_LAZYGIT_VERSION/lazygit_${PIN_LAZYGIT_VERSION}_linux_x86_64.tar.gz" \
                 || echo "$gh/jesseduffield/lazygit/releases/download/v$PIN_LAZYGIT_VERSION/lazygit_${PIN_LAZYGIT_VERSION}_linux_arm64.tar.gz" ;;
        gitleaks) echo "$gh/gitleaks/gitleaks/releases/download/v$PIN_GITLEAKS_VERSION/gitleaks_${PIN_GITLEAKS_VERSION}_linux_$short.tar.gz" ;;
        claude) echo "https://downloads.claude.ai/claude-code-releases/$PIN_CLAUDE_VERSION/linux-$short/claude" ;;
        terminfo) echo "https://raw.githubusercontent.com/ThomasDickey/ncurses-snapshots/$PIN_TERMINFO_SRC_TAG/misc/terminfo.src" ;;
        awscli) echo "https://awscli.amazonaws.com/awscli-exe-linux-$a-$PIN_AWSCLI_VERSION.zip" ;;
        terraform) echo "https://releases.hashicorp.com/terraform/$PIN_TERRAFORM_VERSION/terraform_${PIN_TERRAFORM_VERSION}_linux_$deb.zip" ;;
        *) die "no release URL for $1" ;;
    esac
}

# pin_sha TOOL: the pinned sha256 of TOOL's asset for this architecture.
pin_sha() {
    case "$1" in
        tmux) echo "$PIN_TMUX_SHA256" ;;
        terminfo) echo "$PIN_TERMINFO_SRC_SHA256" ;;
        *) pin "PIN_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_SHA256" ;;
    esac
}

# pin_version TOOL
pin_version() {
    case "$1" in
        terminfo) echo "$PIN_TERMINFO_SRC_TAG" ;;
        *) local v; v="PIN_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_VERSION"; echo "${!v}" ;;
    esac
}

# Every downloaded tool, for --verify-pins.
PINNED_TOOLS="tmux fnm node starship eza delta zoxide lazygit gitleaks claude terminfo awscli terraform"
