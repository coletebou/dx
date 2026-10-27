Working directory: the current directory (a git worktree on branch `$PARALLEL_BRANCH`). Run `pwd` and `git branch --show-current` to confirm before making changes.

<!-- Replace the block below with the actual task for this session. -->

TASK: <describe the task here>

Constraints:
- Touch only the files listed in this prompt.
- Run the relevant test command before committing.
- Commit with Conventional Commits. Do NOT push.

---

When you finish (success OR blocked), atomically append your summary to the merged log so the post-run reviewer can find it. Run this block verbatim:

```bash
{
  printf '\n<<SESSION tag=%s branch=%s worktree=%s finished_at=%s>>\n' \
    "$PARALLEL_TAG" "$PARALLEL_BRANCH" "$PWD" "$(date -Iseconds)"
  cat <<'SUMMARY_EOF'
<YOUR ≤150-WORD SUMMARY — include: what you changed, tests status, any deviations>
SUMMARY_EOF
  printf '<<END SESSION %s>>\n' "$PARALLEL_TAG"
} | "$PARALLEL_APPEND"
```

`$PARALLEL_APPEND` is a small helper (`bin/pw-append`) that holds a portable mkdir-mutex around the append, so concurrent sessions can't interleave their summaries. It works the same on macOS, Linux, and WSL — no `flock` required.

The `pw launch` script has already exported `PARALLEL_LOG`, `PARALLEL_TAG`, `PARALLEL_BRANCH`, `PARALLEL_SESSION_ID`, `PARALLEL_TRANSCRIPT`, and `PARALLEL_APPEND` in this shell — don't redefine them. The launcher also recorded your full transcript path (`$PARALLEL_TRANSCRIPT`) in the log header, so a reviewer can open it without grepping.
