# Handoff brief

`cc-handoff init` writes the skeleton at `~/code/.briefs/<chain>/gen-NN/brief.md`, with the
live facts already in it (IDs and paths, background jobs, the first prompt, the active
/goal, the sessions this one messaged or launched, the last todo list). Fill every FILL
placeholder; `cc-handoff launch` refuses a brief that still has one, an empty section or a
missing Summary line.

Rules for the content:

- Every fact is something checked in this session: a SHA from `git rev-parse`, a count
  from a test run you saw. Write "not verified" rather than guess.
- Fill every section. Write "none" rather than leave one empty.
- If the user's latest request has not been started, it is the first item of Left,
  quoted word for word.
- The three Summary lines are one line each: they become the new session's prompt, which
  tells it that they are only a summary of this file.

The shape (headings exactly as written; init produces them):

```text
# Handoff brief: <chain>, generation <N> to <N+1> (<YYYY-MM-DD HH:MM>Z)

## Summary
Continuing: <the task the next session continues, in plain words>
Done: <the most important things finished and verified>
Left: <what is still open, highest priority first>

## What happened
- <what was asked, tried, learned; the latest unfinished request word for word>

## Done
- <item>: <evidence: commands and results, SHAs, links>

## Left
1. <item>: <state>. Next: <the concrete next action>. Needs the user's go: <no | yes: which>.

## Proposed improvements
- <what to do differently next time, or "none">

## Driver and manager
- Driven by: <the user directly | a lead session (name, pane) | a bot | a /goal>
- Reports to: <who hears about progress, and how: drover_send id, a STATUS.md path>
- Manages: <sessions this one started or steers (name, host, tmux target), or none>

## Background jobs
<init's table: id | kind | running for | what>
- Adopter: <per job: "the successor restarts it with ...", "finishes on its own by HH:MMZ">

## IDs and paths
<filled by init: chain, host, session id, raw transcript, resume command, tmux target and
pane, working directory and git state, earlier generations>

## Rules
<what the successor may do without asking; PRs, MRs, merges, branch deletes, force-pushes
and comments need the user's go unless this says otherwise>
```
