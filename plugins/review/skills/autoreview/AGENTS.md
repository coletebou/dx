# Autoreview Skill

- Canonical source: [dx](https://github.com/coletebou/dx), under `plugins/review/skills/autoreview`.
- Make and validate shared changes here (`scripts/tests/autoreview.test.sh` runs this skill's suites), then update the shared installation.
- Downstream repositories keep only the Markdown entrypoint from `references/repository-entrypoint.md`. Do not vendor this implementation, its tests, or its full instructions.
- Keep repository-specific review requirements in that repository's instructions. Shared behavior and fixes belong here.
- Parts of this skill carry another copyright: see `LICENSE` in this directory and the repository's
  `NOTICE.md`. Imported without history at revision `c6f58bd` (upstream openclaw/agent-skills
  `0d6205f` plus this repository's author's own changes).
