#!/usr/bin/env python3
"""Hermetic tests for scripts/reflections: a throwaway dotfiles tree, git repos,
Codex home and index per test. Nothing under the real HOME is read or written."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / "reflections"


@unittest.skipUnless(shutil.which("git"), "git is required for repo fixtures")
class ReflectionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="reflections-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name).resolve()
        self.dot = root / "dotfiles"
        self.home_webapp = self.dot / "identities/personal/claude/memory/webapp"
        self.home_webapp.mkdir(parents=True)
        (self.home_webapp / "MEMORY.md").write_text("- [x](x.md)\n")
        (self.home_webapp / "gotcha_sqlite_locks.md").write_text(
            "---\nname: sqlite-wal-locks\ndescription: WAL checkpoints stall under NFS\n"
            "metadata:\n  type: project\n---\nNever put the search index on NFS; WAL needs shared memory.\n")
        (self.dot / "claude").mkdir()
        conf = self.dot / "claude/memory-homes.conf"
        conf.write_text(f"# repo home\nWebApp {self.home_webapp}\n")
        feature_log = root / "features/feature-log.jsonl"
        feature_log.parent.mkdir()
        feature_log.write_text(
            json.dumps({"ts": "2026-09-01T00:00:00Z", "id": "feat-1", "state": "in-progress",
                        "title": "Chat parity for mobile", "repo": "webapp"}) + "\n")
        codex = root / "codex/memories"
        codex.mkdir(parents=True)
        (codex / "MEMORY.md").write_text("# Task Group: gondola deploys\nUse the blue lane for gondola.\n")
        self.repo = root / "code/WebApp"
        self.repo.mkdir(parents=True)
        self.other = root / "code/shop"
        self.other.mkdir(parents=True)
        git_env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        for d in (self.repo, self.other):
            subprocess.run(["git", "init", "-q", "-b", "master"], cwd=d, check=True, env=git_env)
            subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "init"], cwd=d, check=True, env=git_env)
        self.worktree = self.repo / ".claude/worktrees/feat"
        subprocess.run(["git", "worktree", "add", "-q", "-b", "feat", str(self.worktree)], cwd=self.repo,
                       check=True, env=git_env)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CLAUDE", "CODEX", "DF_", "REFLECTIONS"))}
        self.env.update(REFLECTIONS_DOTFILES=str(self.dot), MEMORY_HOMES_CONF=str(conf),
                        REFLECTIONS_INDEX=str(root / "state/index.sqlite"),
                        REFLECTIONS_CLAUDE_PROJECTS=str(root / "projects"), CODEX_HOME=str(root / "codex"),
                        REFLECTIONS_HOST="host-a", DF_IDENTITY="personal", GIT_CONFIG_GLOBAL=os.devnull,
                        REFLECTIONS_FEATURE_LOG=str(feature_log))

    def run_cli(self, *args, cwd=None, host=None, stdin=None, check=True):
        env = {**self.env, **({"REFLECTIONS_HOST": host} if host else {})}
        r = subprocess.run([str(CLI), *args], cwd=cwd or self.repo, env=env, input=stdin,
                           capture_output=True, text=True, timeout=60)
        if check and r.returncode != 0:
            self.fail(f"reflections {' '.join(args)} failed: {r.stderr}")
        return r

    def add(self, title, *extra, **kw):
        out = self.run_cli("add", "--title", title, "--json", *extra, **kw).stdout
        return json.loads(out)["items"][0]["id"]

    def listing(self, *extra, **kw):
        return json.loads(self.run_cli("list", "--json", *extra, **kw).stdout)

    def log_lines(self, host="host-a"):
        path = self.home_webapp / f"reflections/{host}.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_add_list_done_roundtrip_in_registered_home(self):
        iid = self.add("Wire StopFailure retry", "--kind", "action", "--tags", "hooks,retry")
        items = self.listing()
        self.assertEqual([i["id"] for i in items], [iid])
        self.assertEqual(items[0]["status"], "open")
        self.assertEqual(items[0]["repo"], "webapp", "registered repo keys by its memory home")
        self.assertEqual(items[0]["tags"], ["hooks", "retry"])
        self.assertEqual(self.log_lines()[0]["op"], "add")
        self.run_cli("done", iid[:4], "--note", "shipped in abc123")
        self.assertEqual(self.listing(), [])
        done = self.listing("--status", "done")
        self.assertEqual(done[0]["status"], "done")
        self.assertIn("shipped in abc123", done[0]["notes"])
        self.run_cli("reopen", iid)
        self.assertEqual(self.listing()[0]["status"], "open")

    def test_registered_home_outside_the_identity_tree_is_indexed(self):
        home = Path(self.tmp.name).resolve() / "elsewhere/memory/tools"
        home.mkdir(parents=True)
        (home / "cache_rule.md").write_text("---\nname: cache-rule\ndescription: Bust the CDN cache on deploy\n"
                                         "---\nPurge after every release.\n")
        conf = Path(self.env["MEMORY_HOMES_CONF"])
        conf.write_text(conf.read_text() + f"Tools {home}\n")
        iid = self.add("Rotate the CDN key", "--kind", "action", "--repo", "Tools")
        self.assertTrue((home / "reflections/host-a.jsonl").is_file(), "the item is logged in that home")
        self.assertEqual([i["id"] for i in self.listing("--repo", "Tools")], [iid])
        hits = json.loads(self.run_cli("search", "purge", "release", "--json").stdout)
        self.assertEqual((hits[0]["source"], hits[0]["repo"]), ("memory", "tools"))

    def test_duplicate_open_title_is_not_recorded_twice(self):
        first = self.add("Fix  load-memory hook", "--kind", "action")
        out = json.loads(self.run_cli("add", "--title", "fix load-memory HOOK", "--json").stdout)
        self.assertTrue(out["items"][0]["duplicate"])
        self.assertEqual(out["items"][0]["id"], first)
        self.assertEqual(len(self.log_lines()), 1)

    def test_other_host_closes_item_through_its_own_log(self):
        iid = self.add("Rotate the bot token", "--kind", "action")
        self.run_cli("done", iid, host="host-b")
        self.assertEqual(self.log_lines("host-a")[-1]["op"], "add", "host-a's log is never touched by host-b")
        self.assertEqual(self.log_lines("host-b")[0]["op"], "set")
        self.assertEqual(self.listing("--status", "done")[0]["id"], iid)

    def test_batch_defaults_status_by_kind(self):
        batch = json.dumps([
            {"kind": "learning", "title": "asyncRewake wakes idle sessions"},
            {"kind": "question", "title": "Does Codex have a compaction hook?"},
            {"kind": "action", "title": "Add PreCompact reflector", "priority": 1},
        ])
        out = json.loads(self.run_cli("add", "--batch", "-", "--origin", "precompact", "--json",
                                      stdin=batch).stdout)
        self.assertEqual(len(out["items"]), 3)
        open_titles = [i["title"] for i in self.listing()]
        self.assertEqual(open_titles[0], "Add PreCompact reflector", "priority 1 sorts first")
        self.assertIn("Does Codex have a compaction hook?", open_titles)
        notes = self.listing("--status", "note")
        self.assertEqual([n["title"] for n in notes], ["asyncRewake wakes idle sessions"])
        self.assertTrue(all(e.get("origin") == "precompact" for e in self.log_lines()))

    def test_search_spans_reflections_memories_codex_and_features(self):
        self.add("Blue lane is flaky for gondola deploys", "--kind", "gotcha")
        hits = json.loads(self.run_cli("search", "gondola", "--json").stdout)
        self.assertEqual({h["source"] for h in hits}, {"reflection", "codex"})
        mem = json.loads(self.run_cli("search", "WAL", "NFS", "--json").stdout)
        self.assertEqual(mem[0]["source"], "memory")
        self.assertEqual(mem[0]["repo"], "webapp")
        feat = json.loads(self.run_cli("search", "mobile", "parity", "--source", "feature", "--json").stdout)
        self.assertEqual(feat[0]["status"], "open")
        only = json.loads(self.run_cli("search", "gondola", "--source", "codex", "--json").stdout)
        self.assertEqual({h["source"] for h in only}, {"codex"})
        show = self.run_cli("show", mem[0]["id"]).stdout
        self.assertIn("WAL needs shared memory", show)

    def test_secrets_are_redacted_before_they_reach_git(self):
        self.add("Token handling", "--body", "used sk-ant-api03-" + "x" * 40 + " and AKIA" + "A" * 16)
        body = self.log_lines()[0]["body"]
        self.assertNotIn("sk-ant-api03", body)
        self.assertIn("[REDACTED:anthropic-key]", body)
        self.assertIn("[REDACTED:aws-key]", body)
        # Fake values are assembled at runtime so no credential-shaped literal sits in
        # the source (the pre-push gitleaks scan would rightly refuse it).
        fake_aws = "wJalr" + "XUtnFEMI/K7MDENG/bPxRfiCY" + "EXAMPLEKEY"
        fake_ts = "ts_live_" + "abcdef" + "123456"
        fake_pw = "hunter2" * 2
        self.add("Env handling", "--body",
                 f"export AWS_SECRET_ACCESS_KEY={fake_aws}; EXAMPLE_API_KEY={fake_ts} node x; "
                 + '{"password": "' + fake_pw + '"}; echo $EXAMPLE_API_KEY; max_tokens: 4096')
        body = self.log_lines()[-1]["body"]
        for leaked in ("wJalrXUtnFEMI", "ts_live_abcdef", "hunter2hunter2"):
            self.assertNotIn(leaked, body)
        self.assertIn("AWS_SECRET_ACCESS_KEY=[REDACTED:assignment]", body, "names stay readable")
        self.assertIn("echo $EXAMPLE_API_KEY", body, "variable references are not secrets")
        self.assertIn("max_tokens: 4096", body, "short values are left alone")

    def test_context_is_empty_without_items_and_lists_open_first(self):
        self.assertEqual(self.run_cli("context").stdout, "")
        self.add("Resume the cutover", "--kind", "handoff")
        self.add("SQLite FTS needs tokenchars for ids", "--kind", "gotcha")
        text = self.run_cli("context").stdout
        self.assertIn("Open items:", text)
        self.assertIn("[handoff] Resume the cutover", text)
        self.assertIn("Recent learnings:", text)

    def test_worktree_and_unregistered_repo_resolution(self):
        where = json.loads(self.run_cli("where", cwd=self.worktree).stdout)
        self.assertEqual(where["repo"], "webapp", "worktrees map to their main repo")
        other = json.loads(self.run_cli("where", cwd=self.other).stdout)
        self.assertEqual(other["repo"], "shop")
        self.assertEqual(Path(other["home"]), self.dot / "identities/personal/claude/memory/shop")
        iid = self.add("Shop-only item", "--kind", "action", cwd=self.other)
        self.assertEqual(self.listing(cwd=self.other)[0]["id"], iid)
        self.assertEqual(self.listing(), [], "other repos' items stay out of this repo's list")
        self.assertEqual(len(self.listing("--all")), 1)

    def exported(self):
        return [json.loads(x) for x in self.run_cli("export").stdout.splitlines()]

    def test_exact_checkout_keeps_private_worktree_and_branch(self):
        iid = self.add("Private worktree learning", cwd=self.worktree)
        row = next(x for x in self.exported() if x["id"] == iid)
        self.assertEqual(row["repo"], "webapp", "grouping remains the main repo")
        self.assertEqual(row["cwd"], str(self.repo), "legacy cwd remains the grouped root")
        self.assertEqual(row["checkout"], str(self.worktree.resolve()))
        self.assertEqual(row["branch"], "feat")
        self.assertNotEqual(row["checkout"], str(self.repo))

    def test_exact_checkout_resolves_subdirectory_and_symlink(self):
        nested = self.worktree / "nested"
        nested.mkdir()
        alias = Path(self.tmp.name) / "alias"
        alias.symlink_to(nested, target_is_directory=True)
        iid = self.add("Nested learning", cwd=alias)
        row = next(x for x in self.exported() if x["id"] == iid)
        self.assertEqual(row["checkout"], str(self.worktree.resolve()))

    def test_legacy_rows_never_infer_checkout_from_cwd(self):
        iid = self.add("Legacy item")
        log = self.home_webapp / "reflections/host-a.jsonl"
        rows = self.log_lines()
        for row in rows:
            row.pop("checkout", None)
        log.write_text("".join(json.dumps(row) + "\n" for row in rows))
        self.assertIsNone(next(x for x in self.exported() if x["id"] == iid)["checkout"])

    def test_cross_checkout_content_edit_permanently_withholds_provenance(self):
        iid = self.add("Main item")
        self.run_cli("edit", iid, "--body", "Private branch secret", cwd=self.worktree)
        self.assertIsNone(next(x for x in self.exported() if x["id"] == iid)["checkout"])
        self.run_cli("edit", iid, "--title", "Main title again")
        self.assertIsNone(next(x for x in self.exported() if x["id"] == iid)["checkout"])

    def test_cross_host_content_edit_withholds_provenance(self):
        iid = self.add("Local item")
        self.run_cli("edit", iid, "--body", "Foreign-host secret", host="host-b")
        self.assertIsNone(next(x for x in self.exported() if x["id"] == iid)["checkout"])

    def test_same_checkout_edit_and_batch_edit_keep_provenance(self):
        iid = self.add("Local item")
        self.run_cli("edit", iid, "--body", "Same-checkout update")
        self.run_cli("apply", "--batch", "-", stdin=json.dumps([
            {"op": "edit", "id": iid, "title": "Same-checkout batch update"}]))
        self.assertEqual(next(x for x in self.exported() if x["id"] == iid)["checkout"], str(self.repo))
        self.run_cli("apply", "--batch", "-", cwd=self.worktree, stdin=json.dumps([
            {"op": "edit", "id": iid, "body": "Private worktree batch secret"}]))
        self.assertIsNone(next(x for x in self.exported() if x["id"] == iid)["checkout"])

    def test_derived_index_v1_migrates_without_backfilling_legacy_authority(self):
        import sqlite3
        iid = self.add("Before upgrade")
        log = self.home_webapp / "reflections/host-a.jsonl"
        rows = self.log_lines()
        rows[0].pop("checkout", None)
        log.write_text("".join(json.dumps(row) + "\n" for row in rows))
        with sqlite3.connect(self.env["REFLECTIONS_INDEX"]) as db:
            db.execute("ALTER TABLE items DROP COLUMN checkout")
            db.execute("UPDATE meta SET v='1' WHERE k='schema'")
        row = next(x for x in self.exported() if x["id"] == iid)
        self.assertIsNone(row["checkout"])
        with sqlite3.connect(self.env["REFLECTIONS_INDEX"]) as db:
            self.assertIn("checkout", [r[1] for r in db.execute("PRAGMA table_info(items)")])
            self.assertEqual(db.execute("SELECT v FROM meta WHERE k='schema'").fetchone()[0], "2")

    def test_batch_cannot_spoof_checkout_provenance(self):
        out = self.run_cli("add", "--batch", "-", "--json", cwd=self.worktree,
                           stdin=json.dumps([{"title": "Spoof attempt", "checkout": str(self.repo)}]))
        iid = json.loads(out.stdout)["items"][0]["id"]
        self.assertEqual(next(x for x in self.exported() if x["id"] == iid)["checkout"], str(self.worktree))

    def test_torn_line_and_ambiguous_prefix(self):
        iid = self.add("Survives a torn write", "--kind", "action")
        log = self.home_webapp / "reflections/host-a.jsonl"
        with open(log, "a") as f:
            f.write('{"v":1,"ts":"2026-')  # interrupted append
        self.assertEqual(self.listing()[0]["id"], iid)
        # An empty or tiny prefix must never pick "the only item" by accident.
        for bad in ("", "a"):
            r = self.run_cli("done", bad, check=False)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("too short", r.stderr)
        with open(log, "a") as f:
            f.write("\n")
            for n in ("1111", "2222"):
                f.write(json.dumps({"v": 1, "ts": "2026-09-29T00:00:0%sZ" % n[0], "op": "add",
                                    "id": "zzzz" + n, "repo": "webapp", "kind": "action",
                                    "status": "open", "title": "seeded " + n, "host": "host-a"}) + "\n")
        r = self.run_cli("done", "zzzz", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ambiguous", r.stderr)
        self.assertEqual(len(self.listing()), 3, "nothing was closed by the failed commands")

    def test_edit_changes_title_everywhere(self):
        iid = self.add("Old title", "--kind", "action")
        self.run_cli("edit", iid, "--title", "Renamed item", "--priority", "2")
        item = self.listing()[0]
        self.assertEqual((item["title"], item["priority"]), ("Renamed item", 2))
        hits = json.loads(self.run_cli("search", "renamed", "--json").stdout)
        self.assertEqual(hits[0]["id"], iid)

    def test_edit_without_changes_is_refused_and_records_nothing(self):
        iid = self.add("Leave me alone", "--kind", "action")
        before = len(self.log_lines())
        r = self.run_cli("edit", iid, check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("nothing to change", r.stderr)
        self.assertEqual(len(self.log_lines()), before)

    def test_repos_summary(self):
        self.add("A", "--kind", "action")
        self.add("B", "--kind", "learning")
        rows = json.loads(self.run_cli("repos", "--json").stdout)
        self.assertEqual(rows, [{"repo": "webapp", "o": 1, "s": 0, "d": 0, "n": 1, "last": rows[0]["last"]}])

    # ------------------------------------------------ stale, apply, candidates

    def seed(self, iid, title, days_old, origin="precompact", status="open", kind="action", session=None):
        """An item written `days_old` days ago (add stamps the current time, so write the event)."""
        from datetime import datetime, timedelta, timezone
        ts = (datetime.now(timezone.utc) - timedelta(days=days_old)).strftime("%Y-%m-%dT%H:%M:%SZ")
        log = self.home_webapp / "reflections/host-a.jsonl"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a") as f:
            f.write(json.dumps({"v": 1, "ts": ts, "op": "add", "id": iid, "repo": "webapp", "kind": kind,
                                "status": status, "title": title, "origin": origin, "host": "host-a",
                                **({"session_id": session} if session else {})}) + "\n")
        return iid

    def test_old_automatic_items_read_as_stale_and_come_back_when_touched(self):
        self.seed("oldauto1", "Old automatic action", 9)
        self.seed("oldcura1", "Old curated action", 9, origin="reflect")
        self.seed("freshau1", "Fresh automatic action", 1)
        self.assertEqual({i["id"] for i in self.listing()}, {"oldcura1", "freshau1"},
                         "an automatic row ages out after 7 days; a curated one gets 30")
        self.assertEqual([i["id"] for i in self.listing("--status", "stale")], ["oldauto1"])
        self.assertIn("1 stale hidden", self.run_cli("context").stdout)
        self.assertEqual(self.log_lines()[-1]["id"], "freshau1", "staleness is derived, never written")
        self.run_cli("reopen", "oldauto1")
        self.assertEqual(self.listing("--status", "stale"), [], "a touch makes it fresh again")
        env_days = {**self.env, "REFLECTIONS_STALE_DAYS": "0.5"}
        r = subprocess.run([str(CLI), "list", "--json"], cwd=self.repo, env=env_days, capture_output=True,
                           text=True, timeout=60)
        self.assertNotIn("freshau1", r.stdout, "REFLECTIONS_STALE_DAYS moves the cutoff")

    def test_adding_a_stale_title_again_reopens_it(self):
        self.seed("oldauto2", "Rotate the relay key", 12)
        out = json.loads(self.run_cli("add", "--title", "rotate the relay KEY", "--kind", "action",
                                      "--origin", "stage", "--json").stdout)["items"][0]
        self.assertEqual((out["id"], out.get("reopened")), ("oldauto2", True))
        self.assertEqual([i["id"] for i in self.listing()], ["oldauto2"])
        self.assertIn("raised again (stage)", self.listing()[0]["notes"])

    def test_apply_validates_ids_repo_and_transitions(self):
        a = self.add("Ship the reflector", "--kind", "action")
        b = self.add("Retire the old hook", "--kind", "action")
        c = self.add("Check the sync peers", "--kind", "action")
        n = self.add("Staging has no Redis", "--kind", "gotcha")
        shop = self.add("Shop-only", "--kind", "action", cwd=self.other)
        self.run_cli("done", c)
        ops = [{"op": "done", "id": a, "note": "commit abc123 shipped it"},
               {"op": "drop", "id": b, "note": "superseded"},
               {"op": "reopen", "id": c, "note": "regressed"},
               {"op": "edit", "id": n, "title": "Staging has no Redis (prod does)"},
               {"op": "done", "id": a},                      # already done after the first op
               {"op": "done", "id": "nosuchid"},
               {"op": "done", "id": shop},                   # another repo
               {"op": "done", "id": n},                      # a note cannot be "done"
               {"op": "explode", "id": a}]
        out = json.loads(self.run_cli("apply", "--batch", "-", "--json", stdin=json.dumps(ops)).stdout)
        self.assertEqual([(x["id"], x["op"]) for x in out["applied"]],
                         [(a, "done"), (b, "drop"), (c, "reopen"), (n, "edit")])
        self.assertEqual([s["reason"] for s in out["skipped"]],
                         ["is done", "unknown id", "belongs to repo shop", "is note", "unknown op 'explode'"])
        self.assertEqual({i["id"] for i in self.listing()}, {c})
        done = self.listing("--status", "done")
        self.assertIn("commit abc123 shipped it", done[0]["notes"])
        self.assertEqual(self.listing("--status", "note")[0]["title"], "Staging has no Redis (prod does)")
        self.assertEqual(self.listing(cwd=self.other)[0]["status"], "open", "the other repo is untouched")

    def test_candidates_put_this_session_first_and_include_matches_and_closed(self):
        mine = self.seed("mine0001", "Wire the stage trigger", 1, session="sess-1")
        old_mine = self.seed("mine0002", "Old stage leftover", 20, session="sess-1")
        match = self.seed("other001", "Gondola deploy lane flakes", 2)
        unrelated = self.seed("other002", "Unrelated chore", 2)
        closed = self.seed("closed01", "Gondola lane was fixed", 3)
        self.run_cli("done", closed)
        note = self.seed("note0001", "Gondola blue lane quirk", 3, kind="gotcha", status="note")
        out = json.loads(self.run_cli("candidates", "--session", "sess-1", "gondola", "deploy", "lane",
                                      "--json").stdout)
        ids = [i["id"] for i in out["items"]]
        self.assertEqual(ids[:2], [mine, old_mine], "this session's own items lead, stale included")
        self.assertIn(match, ids)
        self.assertIn(note, ids)
        self.assertIn(closed, ids, "recently closed matches are offered so they can be reopened")
        self.assertIn(unrelated, ids, "the freshest open items fill the rest")
        by_id = {i["id"]: i for i in out["items"]}
        self.assertEqual(by_id[old_mine]["status"], "stale")
        self.assertTrue(by_id[mine]["this_session"])
        tight = json.loads(self.run_cli("candidates", "gondola", "--limit", "1", "--notes", "0",
                                        "--closed", "0", "--json").stdout)
        self.assertEqual([i["id"] for i in tight["items"]], [match])

    def test_export_is_jsonl_of_every_reflection(self):
        a = self.add("Exported action", "--kind", "action")
        self.run_cli("done", a, "--note", "finished")
        self.add("Exported note", "--kind", "learning")
        rows = [json.loads(x) for x in self.run_cli("export").stdout.splitlines()]
        self.assertEqual({(r["title"], r["status"]) for r in rows},
                         {("Exported action", "done"), ("Exported note", "note")})
        self.assertTrue(any("finished" in n for r in rows for n in r["notes"]))
        self.assertEqual(self.run_cli("export", "--since", "2999-01-01T00:00:00Z").stdout, "")


    def test_the_other_identitys_items_stay_out_of_hooks_reflectors_and_default_lists(self):
        """A repo key can hold logs from both identities; a personal box must not hand work items to
        its sessions or models (nor a work box personal ones) unless asked with --any-identity."""
        mine = self.add("Personal follow-up on gondola", "--kind", "action")
        work_log = self.dot / "identities/work/claude/memory/webapp/reflections/work-box.jsonl"
        work_log.parent.mkdir(parents=True)
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")  # fresh, or it would read as stale
        work_log.write_text(json.dumps({"v": 1, "ts": now, "op": "add", "id": "workonly",
                                        "repo": "webapp", "kind": "action", "status": "open",
                                        "title": "Work follow-up on gondola", "host": "work-box"}) + "\n")
        self.assertEqual([i["id"] for i in self.listing()], [mine])
        self.assertEqual({i["id"] for i in self.listing("--any-identity")}, {mine, "workonly"})
        self.assertNotIn("Work follow-up", self.run_cli("context").stdout)
        cands = json.loads(self.run_cli("candidates", "gondola", "--json").stdout)["items"]
        self.assertEqual([c["id"] for c in cands], [mine])
        hits = json.loads(self.run_cli("search", "gondola", "--json").stdout)
        self.assertNotIn("workonly", [h["id"] for h in hits])
        exported = [json.loads(x)["id"] for x in self.run_cli("export").stdout.splitlines()]
        self.assertEqual(exported, [mine])
        work_env = {**self.env, "DF_IDENTITY": "work"}
        r = subprocess.run([str(CLI), "list", "--json"], cwd=self.repo, env=work_env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual([i["id"] for i in json.loads(r.stdout)], ["workonly"], "and the other way round")
        before = work_log.read_text()
        out = json.loads(self.run_cli("add", "--title", "Work follow-up on gondola", "--kind", "action",
                                      "--json").stdout)["items"][0]
        self.assertFalse(out.get("duplicate"), "the other identity's title does not suppress this one")
        self.assertEqual(work_log.read_text(), before, "nothing is written into the other identity's log")

if __name__ == "__main__":
    unittest.main(verbosity=2)
