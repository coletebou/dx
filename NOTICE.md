# Notices and credits

Everything in this repository is MIT-licensed (see [LICENSE](LICENSE)) unless a file says otherwise.

## Included under other licenses

- **Fonts** in `plugins/music-video/skills/music-video/template/fonts/`: Bricolage Grotesque, Caveat,
  Instrument Serif, Inter and JetBrains Mono, from [Google Fonts](https://fonts.google.com), under the
  [SIL Open Font License 1.1](https://openfontlicense.org). Each family's copyright notice and the license
  text are in that directory's [OFL.txt](plugins/music-video/skills/music-video/template/fonts/OFL.txt).

## Designs followed

- **Dreaming** (`scripts/dream`, the `dreaming` skill) is an independent implementation of the
  three-phase background memory consolidation (light, REM, deep) that
  [OpenClaw](https://github.com/openclaw/openclaw)'s memory-core describes (MIT). No OpenClaw code
  is included.

## Used, not included

These are other people's work. The tools here use them where they are installed; get them from
their authors:

- The `autoreview` skill and its helper, which `scripts/autoreview-pair` runs:
  [openclaw/agent-skills](https://github.com/openclaw/agent-skills).
- `show-me` (explain things visually) by Dex Horthy:
  [humanlayer/skills](https://github.com/humanlayer/skills) (MIT).
- React and Next.js performance rules by Vercel:
  [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) (MIT).
- tmux plugins the tmux config loads through [TPM](https://github.com/tmux-plugins/tpm):
  tmux-sensible, tmux-resurrect and tmux-continuum.
- [gitleaks](https://github.com/gitleaks/gitleaks), which the git hooks run.
