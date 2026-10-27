---
name: autoreview
description: Structured code review through the shared autoreview skill installation.
---

# Auto Review

- Use canonical [autoreview skill](https://github.com/coletebou/dx/tree/master/plugins/review/skills/autoreview).
- Before reviewing: read complete installed `~/.claude/skills/autoreview/SKILL.md`
  (or `~/.agents/skills/autoreview/SKILL.md`) + required references.
  Another operator-selected location: use that installation.
- Repository entrypoint contains no review implementation.

- Skill missing: reuse or clone `https://github.com/coletebou/dx`; link its
  `plugins/review/skills/autoreview` directory as `~/.claude/skills/autoreview`
  and `~/.agents/skills/autoreview` (`./install.sh --with review` does the first).
- Windows: use `python`. Symlinks unavailable: copy the directory instead.

- Run shared `scripts/autoreview` helper with Python from reviewed repository;
  preserve working directory. Follow repository review requirements + canonical skill.
- Codex CLI unavailable: follow the canonical skill's Copilot subagent route,
  preferring an accessible Codex model or a comparable model. Preserve repository
  scope and severity requirements; disclose host/model and limitations. This is
  not a helper engine and does not provide helper isolation or validated status.

- Keep shared fixes/instructions in `coletebou/dx`.
- Update shared checkout once for all symlinked consumers; refresh copied
  installs after source update. Never add repository-local helpers or test copies.
