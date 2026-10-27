#!/usr/bin/env python3
"""pre-push-memory.test.py: scripts/pre-push-memory, the gate base/git/hooks/pre-push runs on each
outgoing ref, checks only the COMMITTED memory homes the push changes (never the working tree),
through scripts/memory-canary and its wiki-dangle-baseline. Every case builds a scratch repository
from synthetic memory files: ordinary repositories and this one (the checker without a committed
configuration) pass silently; broken, deleted, renamed, aliased, colliding, crafted and historical
homes block; a configuration can be retired; clean verdicts are cached by content.

    python3 scripts/tests/pre-push-memory.test.py
"""
import importlib.machinery
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / 'scripts/pre-push-memory'
CANARY = ROOT / 'scripts/memory-canary'
ZERO = '0' * 40
HEADER = 'pre-push: checking committed memory '


def reported_homes(stdout):
    return [line.rsplit(':', 1)[1] for line in stdout.splitlines() if line.startswith(HEADER)]


class MemoryGateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = pathlib.Path(self.temp.name)
        # Clean verdicts are cached per user; keep each test's to itself.
        verdicts = tempfile.TemporaryDirectory()
        self.addCleanup(verdicts.cleanup)
        self.verdicts = pathlib.Path(verdicts.name) / 'verdicts'
        environment = mock.patch.dict(os.environ, {'PRE_PUSH_MEMORY_CACHE': str(self.verdicts)})
        environment.start()
        self.addCleanup(environment.stop)
        self.git('init', '-q')
        self.git('config', 'core.hooksPath', '/dev/null')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args]).decode().strip()

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-qm', 'test: fixture')
        return self.git('rev-parse', 'HEAD')

    def check(self, tip, old=ZERO):
        return subprocess.run([str(HELPER), tip, old, 'origin'], cwd=self.repo,
                              capture_output=True, text=True).returncode

    def setup_memory(self, index='# Healthy\n'):
        self.write('claude/memory-homes.conf', 'test memory/test\n')
        self.write('memory/test/MEMORY.md', index)
        return self.commit()

    def gate(self, tip, old=ZERO):
        return subprocess.run([str(HELPER), tip, old, 'origin'], cwd=self.repo,
                              capture_output=True, text=True)

    def gate_module(self):
        """A fresh import of the gate (empty lookup caches), running git in the fixture."""
        previous = os.getcwd()
        os.chdir(self.repo)
        self.addCleanup(os.chdir, previous)
        sys.dont_write_bytecode = True
        loader = importlib.machinery.SourceFileLoader('pre_push_memory', str(HELPER))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(module)
        return module

    def raw_tree(self, entries):
        raw = b''.join(mode.encode() + b' ' + name.encode() + b'\0' + bytes.fromhex(oid)
                       for mode, name, oid in entries)
        return subprocess.check_output(
            ['git', '-C', str(self.repo), 'hash-object', '--literally', '-w', '-t', 'tree', '--stdin'],
            input=raw).decode().strip()

    def raw_commit(self, entries, parent):
        return self.git('commit-tree', self.raw_tree(entries), '-p', parent, '-m', 'test: crafted tree')

    def test_unrelated_repo(self):
        self.write('README.md', 'ordinary app')
        tip = self.commit()
        for old in (ZERO, tip):
            result = self.gate(tip, old)
            # The hook runs this on every push of every repository: silent when it has nothing to do.
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def test_repository_shipping_the_checker_without_a_configuration_passes_silently(self):
        # This repository and its forks: the gate, the checker, the baseline template and the
        # configuration template are committed, no configuration and no memory are.
        for name in ('scripts/pre-push-memory', 'scripts/memory-canary', 'scripts/wiki-dangle-baseline',
                     'claude/memory-homes.conf.example'):
            self.write(name, 'shipped\n')
        old = self.commit()
        self.write('README.md', 'documentation change')
        tip = self.commit()
        self.git('update-ref', 'refs/remotes/origin/existing', old)
        for args in ((tip, ZERO), (tip, old), (old, ZERO)):
            with self.subTest(args=args):
                result = self.gate(*args)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def test_wrong_arguments_are_a_usage_error(self):
        result = subprocess.run([str(HELPER)], cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('usage: pre-push-memory', result.stderr)

    def test_committed_good_ignores_dirty_bad(self):
        tip = self.setup_memory()
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        self.assertEqual(self.check(tip), 0)

    def test_committed_bad_ignores_dirty_good(self):
        tip = self.setup_memory('[broken](absent.md)')
        self.write('memory/test/MEMORY.md', '# Healthy')
        self.assertNotEqual(self.check(tip), 0)

    def test_unrelated_change_ignores_existing_failure(self):
        old = self.setup_memory('[broken](absent.md)')
        self.write('README.md', 'unrelated')
        self.assertEqual(self.check(self.commit(), old), 0)

    def test_deleted_target(self):
        self.write('memory/test/detail.md', 'detail')
        old = self.setup_memory('[detail](detail.md)')
        (self.repo / 'memory/test/detail.md').unlink()
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_missing_index(self):
        old = self.setup_memory()
        (self.repo / 'memory/test/MEMORY.md').unlink()
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_deleted_config_still_checks_the_homes_it_leaves(self):
        # Deleting the configuration retires it, but every home still committed is checked.
        old = self.setup_memory()
        (self.repo / 'claude/memory-homes.conf').unlink()
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_deleted_config_with_healthy_homes_passes(self):
        old = self.setup_memory()
        (self.repo / 'claude/memory-homes.conf').unlink()
        tip = self.commit()
        result = self.gate(tip, old)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reported_homes(result.stdout), ['memory/test'])
        # Later pushes of the retired repository are not blocked either.
        self.write('README.md', 'later work')
        self.assertEqual(self.check(self.commit(), tip), 0)

    def test_memory_can_be_retired_completely(self):
        old = self.setup_memory('[broken](absent.md)')
        (self.repo / 'claude/memory-homes.conf').unlink()
        (self.repo / 'memory/test/MEMORY.md').unlink()
        tip = self.commit()
        self.git('update-ref', 'refs/remotes/origin/existing', old)
        for args in ((tip, old), (tip, ZERO)):
            with self.subTest(args=args):
                result = self.gate(*args)
                self.assertEqual((result.returncode, reported_homes(result.stdout)), (0, []), result.stderr)

    def test_configuration_change_checks_all_homes(self):
        old = self.setup_memory('[broken](absent.md)')
        self.write('claude/memory-homes.conf', '# changed\ntest memory/test\n')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_checker_code_change_does_not_block_on_unchanged_memory(self):
        old = self.setup_memory('[broken](absent.md)')
        self.write('scripts/memory-canary', 'implementation change')
        self.write('scripts/pre-push-memory', 'implementation change')
        self.assertEqual(self.check(self.commit(), old), 0)

    def test_baseline_change_checks_all_homes(self):
        old = self.setup_memory('[broken](absent.md)')
        self.write('scripts/wiki-dangle-baseline', 'test=0')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_no_following_committed_symlinks(self):
        old = self.setup_memory()
        (self.repo / 'memory/test/linked.md').symlink_to('/etc/passwd')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_rewind_to_bad_snapshot_blocks(self):
        bad = self.setup_memory('[broken](absent.md)')
        self.write('memory/test/MEMORY.md', '# Healthy')
        good = self.commit()
        self.assertNotEqual(self.check(bad, good), 0)

    def test_rewind_to_healthy_snapshot_succeeds(self):
        good = self.setup_memory()
        self.write('memory/test/MEMORY.md', '# Healthy later revision')
        later = self.commit()
        self.assertEqual(self.check(good, later), 0)

    def test_new_ref_remote_known_bad_snapshot_blocks(self):
        bad = self.setup_memory('[broken](absent.md)')
        self.git('update-ref', 'refs/remotes/origin/existing', bad)
        self.assertNotEqual(self.check(bad), 0)

    def test_new_ref_remote_known_healthy_snapshot_succeeds(self):
        good = self.setup_memory()
        self.git('update-ref', 'refs/remotes/origin/existing', good)
        self.assertEqual(self.check(good), 0)

    def test_unknown_remote_tip_checks_snapshot(self):
        bad = self.setup_memory('[broken](absent.md)')
        self.assertNotEqual(self.check(bad, '1' * 40), 0)
        self.write('memory/test/MEMORY.md', '# Healthy')
        self.assertEqual(self.check(self.commit(), '1' * 40), 0)

    def test_partial_clone_never_fetches_an_absent_old_tip(self):
        # cat-file -e fetched an old tip that a partial clone lacks from its
        # promisor remote. The probe must not, and must check all of tip instead.
        self.setup_memory()
        branch = self.git('symbolic-ref', '--short', 'HEAD')
        self.git('switch', '-qc', 'other')
        self.write('README.md', 'not in the clone')
        absent = self.commit()
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        base = pathlib.Path(work.name)
        remote, clone, fetches = base / 'remote.git', base / 'clone', base / 'fetches'
        subprocess.run(['git', 'clone', '-q', '--bare', str(self.repo), str(remote)], check=True)
        for key in ('uploadpack.allowFilter', 'uploadpack.allowAnySHA1InWant'):
            subprocess.run(['git', '-C', str(remote), 'config', key, 'true'], check=True)
        subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', 'clone', '-q', '--filter=blob:none',
                        '--single-branch', '--branch', branch, f'file://{remote}', str(clone)], check=True)
        counter = base / 'upload-pack'
        counter.write_text(f'#!/bin/sh\necho fetch >> "{fetches}"\nexec git-upload-pack "$@"\n')
        counter.chmod(0o755)
        subprocess.run(['git', '-C', str(clone), 'config', 'remote.origin.uploadpack', str(counter)], check=True)
        for index, blocks in (('[broken](absent.md)', True), ('# Healthy later', False)):
            with self.subTest(index=index):
                (clone / 'memory/test/MEMORY.md').write_text(index)
                subprocess.run(['git', '-C', str(clone), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                                'commit', '-qam', 'test: partial clone'], check=True)
                tip = subprocess.check_output(['git', '-C', str(clone), 'rev-parse', 'HEAD'], text=True).strip()
                result = subprocess.run([str(HELPER), tip, absent, 'origin'], cwd=clone, capture_output=True, text=True)
                self.assertEqual(result.returncode != 0, blocks, result.stdout + result.stderr)
                self.assertFalse(fetches.exists(), 'the gate fetched from the promisor remote')
        subprocess.run(['git', '-C', str(clone), 'cat-file', '-e', absent], check=True)
        self.assertTrue(fetches.exists(), 'control: the counter missed a lazy fetch')

    def test_new_ref_cannot_hide_a_home_by_removing_the_configuration(self):
        for index, blocks in (('[broken](absent.md)', True), ('# Healthy, still checked', False)):
            with self.subTest(index=index):
                self.doCleanups()
                self.setUp()
                self.write('scripts/memory-canary', 'shipped checker')
                old = self.setup_memory()
                self.git('update-ref', 'refs/remotes/origin/existing', old)
                (self.repo / 'claude/memory-homes.conf').unlink()
                (self.repo / 'scripts/memory-canary').unlink()
                self.write('memory/test/MEMORY.md', index)
                result = self.gate(self.commit())
                self.assertEqual(result.returncode != 0, blocks, result.stderr)
                self.assertEqual(reported_homes(result.stdout), ['memory/test'])

    def test_remote_known_tip_cannot_hide_a_home_whose_configuration_was_removed_before(self):
        for index, blocks in (('[broken](absent.md)', True), ('# Healthy, still checked', False)):
            with self.subTest(index=index):
                self.doCleanups()
                self.setUp()
                self.setup_memory()
                (self.repo / 'claude/memory-homes.conf').unlink()
                self.write('memory/test/MEMORY.md', index)
                tip = self.commit()
                self.git('update-ref', 'refs/remotes/origin/existing', tip)
                result = self.gate(tip)
                self.assertEqual(result.returncode != 0, blocks, result.stderr)
                self.assertEqual(reported_homes(result.stdout), ['memory/test'])

    def test_removed_configuration_row_does_not_hide_retained_bad_home(self):
        self.write('memory/other/MEMORY.md', '# Healthy')
        old = self.setup_memory('[broken](absent.md)')
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_remote_known_new_ref_checks_retained_former_home(self):
        self.write('memory/other/MEMORY.md', '# Healthy')
        self.setup_memory('[broken](absent.md)')
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        tip = self.commit()
        self.git('update-ref', 'refs/remotes/origin/existing', tip)
        self.assertNotEqual(self.check(tip), 0)

    def test_whole_home_can_be_retired(self):
        self.write('memory/other/MEMORY.md', '# Healthy')
        old = self.setup_memory('[broken](absent.md)')
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        (self.repo / 'memory/test/MEMORY.md').unlink()
        self.assertEqual(self.check(self.commit(), old), 0)

    def test_rename_out_of_home_exposes_deleted_target(self):
        self.write('memory/test/detail.md', 'detail')
        old = self.setup_memory('[detail](detail.md)')
        self.git('mv', 'memory/test/detail.md', 'detail.md')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_git_case_collision_blocks_before_filesystem_overwrite(self):
        old = self.setup_memory()
        blob = self.git('rev-parse', old + ':memory/test/MEMORY.md')
        self.git('update-index', '--add', '--cacheinfo', '100644', blob, 'memory/test/memory.md')
        self.git('commit', '-qm', 'test: case collision in Git index')
        self.assertNotEqual(self.check(self.git('rev-parse', 'HEAD'), old), 0)

    def test_crafted_parent_component_is_rejected(self):
        old = self.setup_memory()
        blob = self.git('rev-parse', old + ':memory/test/MEMORY.md')

        def tree(entries):
            raw = b''.join(mode.encode() + b' ' + name.encode() + b'\0' + bytes.fromhex(oid)
                           for mode, name, oid in entries)
            return subprocess.check_output(
                ['git', '-C', str(self.repo), 'hash-object', '--literally', '-w', '-t', 'tree', '--stdin'],
                input=raw).decode().strip()

        escaped = tree([('100644', 'escape.md', blob)])
        home = tree([('40000', '..', escaped), ('100644', 'MEMORY.md', blob)])
        memory = tree([('40000', 'test', home)])
        root = tree([('40000', 'claude', self.git('rev-parse', old + ':claude')),
                     ('40000', 'memory', memory)])
        tip = self.git('commit-tree', root, '-p', old, '-m', 'test: crafted path')
        result = subprocess.run([str(HELPER), tip, old, 'origin'], cwd=self.repo,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unsafe memory tree path', result.stderr)

    def test_later_edit_to_omitted_historical_home_is_checked(self):
        self.write('memory/other/MEMORY.md', '# Healthy')
        self.setup_memory()
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        old = self.commit()
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_home_index_added_after_config_row_is_still_discovered(self):
        self.write('claude/memory-homes.conf', 'test memory/test\n')
        self.commit()
        self.write('memory/test/MEMORY.md', '# Healthy')
        self.commit()
        self.write('memory/other/MEMORY.md', '# Healthy')
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        old = self.commit()
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_homes_outside_the_repository_are_live_memory(self):
        # A setup can keep its memory tree outside this repository: nothing committed to check.
        self.write('claude/memory-homes.conf',
                   f'webapp ~/.agent-memory/webapp\nnotes $HOME/.agent-memory/notes\n'
                   f'other {self.repo.parent}/elsewhere/memory\n')
        self.write('README.md', 'no committed memory here')
        self.assertEqual(self.check(self.commit()), 0)

    def test_dotfiles_spelling_of_a_home_is_repository_relative(self):
        # The conf template spells homes from ~/.dotfiles, which install.sh links to the checkout
        # (a clone or worktree elsewhere included): they are checked as homes of this repository.
        self.write('claude/memory-homes.conf', 'test ~/.dotfiles/memory/test\n')
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        result = self.gate(self.commit())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(reported_homes(result.stdout), ['memory/test'])

    def test_moving_a_home_outside_does_not_hide_its_committed_index(self):
        old = self.setup_memory()
        self.write('claude/memory-homes.conf', 'test ~/.agent-memory/test\n')
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_absolute_spelling_of_an_in_repo_home_is_still_checked(self):
        self.write('claude/memory-homes.conf', f'test {self.repo}/memory/test\n')
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        self.assertNotEqual(self.check(self.commit()), 0)
        self.write('memory/test/MEMORY.md', '# Healthy\n')
        self.assertEqual(self.check(self.commit()), 0)

    def test_repaired_malformed_and_unsafe_historical_rows(self):
        self.write('claude/memory-homes.conf', 'incomplete\nunsafe ../../outside\n')
        old = self.commit()
        self.write('claude/memory-homes.conf', 'test memory/test\n')
        self.write('memory/test/MEMORY.md', '# Healthy')
        self.assertEqual(self.check(self.commit(), old), 0)

    def test_repaired_historical_typo_directory_is_not_a_former_home(self):
        self.write('ordinary/README.md', 'ordinary directory')
        self.write('claude/memory-homes.conf', 'typo ordinary\n')
        old = self.commit()
        self.write('claude/memory-homes.conf', 'test memory/test\n')
        self.write('memory/test/MEMORY.md', '# Healthy')
        self.assertEqual(self.check(self.commit(), old), 0)

    def test_valid_historical_home_with_deleted_index_still_blocks(self):
        self.write('memory/other/MEMORY.md', '# Healthy')
        self.write('memory/test/detail.md', 'retained')
        self.setup_memory()
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        old = self.commit()
        (self.repo / 'memory/test/MEMORY.md').unlink()
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_all_tree_paths_checked_before_markdown_filter(self):
        for original, collision in (('Foo.md', 'foo.MD'),
                                    ('Folder/a.md', 'folder/b.txt'),
                                    ('Foo.md', 'foo.md/a.bin')):
            with self.subTest(collision=collision):
                self.write('memory/test/' + original, 'detail')
                old = self.setup_memory()
                blob = self.git('rev-parse', old + ':memory/test/' + original)
                self.git('update-index', '--add', '--cacheinfo', '100644', blob,
                         'memory/test/' + collision)
                self.git('commit', '-qm', 'test: raw Git collision')
                self.assertNotEqual(self.check(self.git('rev-parse', 'HEAD'), old), 0)
                # Next fixture is independent, avoiding case-insensitive checkout.
                self.doCleanups()
                self.setUp()

    def test_merged_side_branch_former_home_remains_discoverable(self):
        self.setup_memory()
        main = self.git('branch', '--show-current')
        self.git('switch', '-qc', 'side')
        self.write('claude/memory-homes.conf', 'test memory/test\nsecond memory/second\n')
        self.write('memory/second/MEMORY.md', '# Healthy second home')
        self.commit()
        self.git('switch', '-q', main)
        self.write('README.md', 'main branch work')
        self.commit()
        self.git('merge', '--no-commit', '--no-ff', 'side')
        self.write('claude/memory-homes.conf', 'test memory/test\n')
        old = self.commit()
        self.write('memory/second/MEMORY.md', '[broken](absent.md)')
        self.assertNotEqual(self.check(self.commit(), old), 0)

    def test_transient_valid_home_cannot_be_hidden_by_removing_row(self):
        self.write('memory/other/MEMORY.md', '# Healthy')
        self.write('memory/test/detail.md', 'retained')
        self.write('claude/memory-homes.conf', 'test memory/test\nother memory/other\n')
        before = self.commit()  # A: configured, but index not created yet.
        self.write('memory/test/MEMORY.md', '# Healthy transient index')
        self.commit()  # B: row and index coexist.
        (self.repo / 'memory/test/MEMORY.md').unlink()
        self.commit()  # C: index disappears while row remains.
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        removed = self.commit()  # D: row disappears; other bytes remain.
        self.assertNotEqual(self.check(removed, before), 0)
        self.write('memory/test/detail.md', 'later edit to omitted former home')
        self.assertNotEqual(self.check(self.commit(), removed), 0)

    def test_rewind_discovers_home_from_old_tip_history(self):
        self.write('memory/other/MEMORY.md', '# Healthy')
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        bad = self.commit()
        self.write('claude/memory-homes.conf', 'other memory/other\ntest memory/test\n')
        self.write('memory/test/MEMORY.md', '# Healthy')
        self.commit()
        self.write('claude/memory-homes.conf', 'other memory/other\n')
        old = self.commit()
        self.assertNotEqual(self.check(bad, old), 0)

    def test_cross_home_and_ancestor_collisions(self):
        for first, second in (('memory/a', 'memory/A'), ('Library/a', 'library/b'),
                              ('caf\u00e9/a', 'cafe\u0301/b')):
            with self.subTest(homes=(first, second)):
                old = self.setup_memory()
                blob = self.git('rev-parse', old + ':memory/test/MEMORY.md')
                self.write('claude/memory-homes.conf', f'first {first}\nsecond {second}\n')
                self.git('add', 'claude/memory-homes.conf')
                for home in (first, second):
                    self.git('update-index', '--add', '--cacheinfo', '100644', blob, home + '/MEMORY.md')
                self.git('commit', '-qm', 'test: colliding raw Git home paths')
                self.assertNotEqual(self.check(self.git('rev-parse', 'HEAD'), old), 0)
                self.doCleanups()
                self.setUp()

    def test_repaired_historical_nul_path_is_ignored(self):
        self.write('claude/memory-homes.conf', 'bad memory/invalid\0path\n')
        old = self.commit()
        self.write('claude/memory-homes.conf', 'test memory/test\n')
        self.write('memory/test/MEMORY.md', '# Healthy')
        self.assertEqual(self.check(self.commit(), old), 0)

    def test_unconfigured_alias_of_home_boundary_blocks_update_and_new_ref(self):
        for configured, alias in (('memory/test', 'memory/TEST/MEMORY.md'),
                                   ('memory/test', 'Memory/unconfigured/detail.md'),
                                   ('caf\u00e9/test', 'cafe\u0301/test/MEMORY.md'),
                                   ('caf\u00e9/test', 'cafe\u0301/unconfigured/detail.md')):
            with self.subTest(configured=configured, alias=alias):
                self.doCleanups()
                self.setUp()
                self.git('config', 'core.precomposeUnicode', 'false')
                base = self.setup_memory()
                blob = self.git('rev-parse', base + ':memory/test/MEMORY.md')
                self.write('claude/memory-homes.conf', f'configured {configured}\n')
                self.git('add', 'claude/memory-homes.conf')
                self.git('update-index', '--add', '--cacheinfo', '100644', blob, configured + '/MEMORY.md')
                self.git('commit', '--allow-empty', '-qm', 'test: canonical configured home')
                old = self.git('rev-parse', 'HEAD')
                self.assertEqual(self.check(old, base), 0)
                self.git('update-index', '--add', '--cacheinfo', '100644', blob, alias)
                self.git('commit', '-qm', 'test: unconfigured Git alias of home')
                tip = self.git('rev-parse', 'HEAD')
                statuses = (self.check(tip, old), self.check(tip))
                self.assertTrue(all(status != 0 for status in statuses), statuses)
                self.doCleanups()
                self.setUp()

    def test_former_home_alias_is_not_complete_retirement(self):
        for original, alias in (('memory/test', 'memory/TEST'), ('caf\u00e9/test', 'cafe\u0301/test')):
            with self.subTest(original=original, alias=alias):
                self.doCleanups()
                self.setUp()
                self.git('config', 'core.precomposeUnicode', 'false')
                base = self.setup_memory()
                blob = self.git('rev-parse', base + ':memory/test/MEMORY.md')
                self.write('claude/memory-homes.conf', f'old {original}\nother memory/other\n')
                self.git('add', 'claude/memory-homes.conf')
                for home in (original, 'memory/other'):
                    self.git('update-index', '--add', '--cacheinfo', '100644', blob, home + '/MEMORY.md')
                self.git('commit', '-qm', 'test: former home established')
                old = self.git('rev-parse', 'HEAD')
                self.write('claude/memory-homes.conf', 'other memory/other\n')
                self.git('add', 'claude/memory-homes.conf')
                self.git('update-index', '--force-remove', original + '/MEMORY.md')
                self.git('update-index', '--add', '--cacheinfo', '100644', blob, alias + '/MEMORY.md')
                self.git('commit', '-qm', 'test: removed row but aliased home retained')
                tip = self.git('rev-parse', 'HEAD')
                statuses = (self.check(tip, old), self.check(tip))
                self.assertTrue(all(status != 0 for status in statuses), statuses)
                # Registering the renamed canonical home restores full validation.
                self.write('claude/memory-homes.conf', f'other memory/other\nrenamed {alias}\n')
                self.git('add', 'claude/memory-homes.conf')
                self.git('commit', '-qm', 'test: explicitly register canonical rename')
                registered = self.git('rev-parse', 'HEAD')
                self.assertEqual(self.check(registered, tip), 0)
                self.assertEqual(self.check(registered), 0)

    def test_greek_canonical_caseless_aliases(self):
        first, second = '\u0390', '\u03aa\u0301'
        for scenario in ('materialization', 'boundary', 'retirement'):
            with self.subTest(scenario=scenario):
                self.doCleanups()
                self.setUp()
                self.git('config', 'core.precomposeUnicode', 'false')
                base = self.setup_memory()
                blob = self.git('rev-parse', base + ':memory/test/MEMORY.md')
                if scenario == 'materialization':
                    for name in (first, second):
                        self.git('update-index', '--add', '--cacheinfo', '100644', blob,
                                 f'memory/test/{name}.md')
                    old = base
                else:
                    self.write('claude/memory-homes.conf', f'old memory/{first}\nother memory/test\n')
                    self.git('add', 'claude/memory-homes.conf')
                    self.git('update-index', '--add', '--cacheinfo', '100644', blob,
                             f'memory/{first}/MEMORY.md')
                    self.git('commit', '-qm', 'test: Greek canonical home')
                    old = self.git('rev-parse', 'HEAD')
                    if scenario == 'retirement':
                        self.write('claude/memory-homes.conf', 'other memory/test\n')
                        self.git('add', 'claude/memory-homes.conf')
                        self.git('update-index', '--force-remove', f'memory/{first}/MEMORY.md')
                    self.git('update-index', '--add', '--cacheinfo', '100644', blob,
                             f'memory/{second}/MEMORY.md')
                self.git('commit', '-qm', 'test: canonically caseless Greek alias')
                tip = self.git('rev-parse', 'HEAD')
                statuses = (self.check(tip, old), self.check(tip))
                self.assertTrue(all(status != 0 for status in statuses), statuses)

    def test_current_configuration_symlink_is_rejected(self):
        old = self.setup_memory()
        self.write('memory/bad/MEMORY.md', '[broken](absent.md)')
        self.write('config memory/test', 'bad memory/bad\n')
        config = self.repo / 'claude/memory-homes.conf'
        config.unlink()
        config.symlink_to('../config memory/test')
        tip = self.commit()
        statuses = (self.check(tip, old), self.check(tip))
        self.assertTrue(all(status != 0 for status in statuses), statuses)

    def test_historical_configuration_symlink_can_be_repaired(self):
        self.setup_memory()
        self.write('config memory/test', 'bad memory/bad\n')
        config = self.repo / 'claude/memory-homes.conf'
        config.unlink()
        config.symlink_to('../config memory/test')
        old = self.commit()
        config.unlink()
        self.write('claude/memory-homes.conf', 'test memory/test\n')
        self.assertEqual(self.check(self.commit(), old), 0)

    def test_checker_failure_blocks(self):
        tip = self.setup_memory()
        helper = self.repo / 'helper/pre-push-memory'
        helper.parent.mkdir()
        helper.write_bytes(HELPER.read_bytes())
        helper.chmod(0o755)
        result = subprocess.run([str(helper), tip, ZERO, 'origin'], cwd=self.repo,
                                capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_multi_ref_and_deletion_hook(self):
        good = self.setup_memory()
        self.write('memory/test/MEMORY.md', '[broken](absent.md)')
        bad = self.commit()
        scanner = self.repo / 'scanner'
        scanner.write_text('#!/bin/sh\nexit 0\n')
        scanner.chmod(0o755)
        import os
        env = dict(os.environ, GITLEAKS_BIN=str(scanner))
        hook = ROOT / 'base/git/hooks/pre-push'
        for refs, expected_success in ((f'refs/heads/good {good} refs/heads/good {ZERO}\n'
                                       f'refs/heads/bad {bad} refs/heads/bad {good}\n', False),
                                      (f'refs/heads/deleted {ZERO} refs/heads/deleted {bad}\n', True)):
            result = subprocess.run([str(hook), 'origin', 'unused'], input=refs, text=True,
                                    env=env, cwd=self.repo, capture_output=True)
            self.assertEqual(result.returncode == 0, expected_success)

    def test_batched_existence_matches_cat_file_e(self):
        tip = self.setup_memory()
        names = [f'{tip}:memory/test/MEMORY.md', f'{tip}:memory/test', f'{tip}:', f'{tip}^{{commit}}',
                 f'{tip}:memory/absent.md', f'{tip}:memory/test/MEMORY.md/below',
                 f'{"1" * 40}:memory/test/MEMORY.md', 'no-such-revision:memory/test/MEMORY.md']
        expected = [subprocess.run(['git', '-C', str(self.repo), 'cat-file', '-e', name],
                                   capture_output=True).returncode == 0 for name in names]
        self.assertEqual(expected, [True] * 4 + [False] * 4)
        self.assertEqual(self.gate_module().present(names), expected)

    def test_batched_existence_fails_closed_on_bad_answers(self):
        tip = self.setup_memory()
        query = f'{tip}:memory/test/MEMORY.md'
        for output in (b'', b'\n', f'{query} missing'.encode(), b'other missing\n',
                       b'garbage\n', f'{query} missing\n{query} missing\n'.encode()):
            with self.subTest(output=output):
                gate = self.gate_module()
                gate.git_stdin = lambda args, lines, output=output: output
                with self.assertRaises(ValueError):
                    gate.present([query])
        with self.assertRaisesRegex(ValueError, 'line break'):
            self.gate_module().present([f'{tip}:memory/test\nMEMORY.md'])

    def test_batched_object_reads_fail_closed(self):
        tip = self.setup_memory()
        gate = self.gate_module()
        blob = self.git('rev-parse', tip + ':memory/test/MEMORY.md')
        self.assertEqual(gate.blobs([blob, blob]), [b'# Healthy\n'] * 2)
        with self.assertRaisesRegex(ValueError, 'unreadable'):
            gate.blobs(['0' * 39 + '1'])  # missing object
        with self.assertRaisesRegex(ValueError, 'unreadable'):
            gate.blobs([self.git('rev-parse', tip + '^{tree}')])  # wrong type
        answer = subprocess.run(['git', '-C', str(self.repo), 'cat-file', '--batch'],
                                input=f'{blob}\n'.encode(), capture_output=True, check=True).stdout
        for output, message in ((b'', 'unreadable'), (answer[:-3], 'truncated'),
                                (answer + b'extra', 'unexpected'),
                                (answer.replace(blob.encode(), b'f' * 40), 'unreadable')):
            with self.subTest(output=output):
                gate.git_stdin = lambda args, lines, output=output: output
                with self.assertRaisesRegex(ValueError, message):
                    gate.blobs([blob])

    def test_batched_configuration_matches_ls_tree(self):
        base = self.setup_memory()
        conf = self.git('rev-parse', base + ':claude/memory-homes.conf')
        conf_dir = self.git('rev-parse', base + ':claude')
        memory = self.git('rev-parse', base + ':memory')
        shapes = {
            'regular': [('100644', 'memory-homes.conf', conf)],
            'executable': [('100755', 'memory-homes.conf', conf)],
            'noncanonical': [('100664', 'memory-homes.conf', conf)],
            'symlink': [('120000', 'memory-homes.conf', conf)],
            'directory': [('40000', 'memory-homes.conf', conf_dir)],
            'gitlink': [('160000', 'memory-homes.conf', base)],
            'duplicate': [('100644', 'memory-homes.conf', conf), ('100644', 'memory-homes.conf', conf)],
            'absent': [('100644', 'other.conf', conf)],
        }
        revisions = {shape: self.raw_commit([('40000', 'claude', self.raw_tree(entries)),
                                             ('40000', 'memory', memory)], base)
                     for shape, entries in shapes.items()}
        revisions['claude-file'] = self.raw_commit([('100644', 'claude', conf), ('40000', 'memory', memory)], base)
        gate = self.gate_module()
        gate.configurations(list(revisions.values()))
        for shape, rev in revisions.items():
            with self.subTest(shape=shape):
                # The sequential gate's test: one ls-tree record, regular mode, then `git show`.
                entry = subprocess.check_output(['git', '-C', str(self.repo), 'ls-tree', '-z', rev, '--',
                                                 'claude/memory-homes.conf']).rstrip(b'\0')
                metadata, _, name = entry.partition(b'\t')
                regular = name == b'claude/memory-homes.conf' and metadata.split()[:2] in (
                    [b'100644', b'blob'], [b'100755', b'blob'])
                expected = subprocess.check_output(['git', '-C', str(self.repo), 'show',
                                                    rev + ':claude/memory-homes.conf']) if regular else None
                self.assertEqual(gate._configurations[rev], expected)
        self.assertEqual([shape for shape, rev in revisions.items() if gate._configurations[rev] is not None],
                         ['regular', 'executable', 'noncanonical'])
        # Git's sorted-order lookup misses an entry placed after `zzz`; the walk
        # still finds it, and that disagreement is a malformed tree, not "absent".
        unsorted = self.raw_commit([('40000', 'claude', self.raw_tree(
            [('100644', 'zzz', conf), ('100644', 'memory-homes.conf', conf)])), ('40000', 'memory', memory)], base)
        with self.assertRaisesRegex(ValueError, 'unreadable memory configuration path'):
            gate.configurations([unsorted])

    def test_crafted_configuration_trees_fail_closed(self):
        base = self.setup_memory()
        claude = self.git('rev-parse', base + ':claude')
        memory = self.git('rev-parse', base + ':memory')
        conf = self.git('rev-parse', base + ':claude/memory-homes.conf')
        duplicate_file = self.raw_commit([('40000', 'claude', self.raw_tree(
            [('100644', 'memory-homes.conf', conf)] * 2)), ('40000', 'memory', memory)], base)
        duplicate_directory = self.raw_commit([('40000', 'claude', claude)] * 2 + [('40000', 'memory', memory)], base)
        for tip, message in ((duplicate_file, 'regular Git file'), (duplicate_directory, 'malformed Git tree')):
            with self.subTest(message=message):
                for result in (self.gate(tip, base), self.gate(tip)):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
        # A duplicated historical file entry is untrusted history, not a blocker.
        repaired = self.git('commit-tree', base + '^{tree}', '-p', duplicate_file, '-m', 'test: repaired')
        self.assertEqual(self.check(repaired, duplicate_file), 0)

    def test_malformed_tree_entries_are_rejected(self):
        gate = self.gate_module()
        oid = bytes(20)
        for tree in (b'100644 name', b'100644 name\0' + oid[:5], b'10x644 name\0' + oid,
                     b'100644 \0' + oid, b'100644name\0' + oid):
            with self.subTest(tree=tree):
                with self.assertRaisesRegex(ValueError, 'malformed'):
                    gate.tree_entries(tree, b'name', 20)
        self.assertEqual(gate.tree_entries(b'100644 a b\0' + oid + b'40000 a\0' + oid, b'a b', 20),
                         [(0o100644, oid.hex())])

    def test_concurrent_homes_report_in_order_and_any_failure_blocks(self):
        homes = ['memory/a', 'memory/b', 'memory/c']
        self.write('claude/memory-homes.conf', ''.join(f'{home[-1]} {home}\n' for home in homes))
        for home in homes:
            self.write(home + '/MEMORY.md', '# Healthy\n')
        result = self.gate(self.commit())  # A new ref checks every home at once.
        self.assertEqual((result.returncode, reported_homes(result.stdout)), (0, homes))
        for position, broken in enumerate(homes):
            with self.subTest(broken=broken):
                self.write(broken + '/MEMORY.md', '[broken](absent.md)\n')
                result = self.gate(self.commit())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('memory-canary', result.stderr)
                self.assertIn('DANGLING', result.stdout)
                # As in the sequential gate, homes after the first failure go unreported.
                self.assertEqual(reported_homes(result.stdout), homes[:position + 1])
                self.write(broken + '/MEMORY.md', '# Healthy\n')
                self.commit()

    def test_first_failure_in_home_order_wins(self):
        self.write('claude/memory-homes.conf', 'a memory/a\nb memory/b\n')
        self.write('memory/a/MEMORY.md', '[broken](absent.md)\n')
        self.write('memory/b/detail.md', 'no index')
        result = self.gate(self.commit())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('non-zero exit status', result.stderr)
        self.assertNotIn('index missing', result.stderr)
        self.write('memory/a/MEMORY.md', '# Healthy\n')
        result = self.gate(self.commit())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('committed memory index missing: memory/b/MEMORY.md', result.stderr)
        self.assertEqual(reported_homes(result.stdout), ['memory/a'])
        # A missing index stops the gate before any later home is checked.
        self.write('claude/memory-homes.conf', 'b memory/b\na memory/a\n')
        self.write('memory/a/MEMORY.md', '[broken](absent.md)\n')
        result = self.gate(self.commit())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('committed memory index missing: memory/b/MEMORY.md', result.stderr)
        self.assertEqual(reported_homes(result.stdout), [])

    def test_checker_start_failure_reports_its_home(self):
        tip = self.setup_memory()
        helper = self.repo / 'helper/pre-push-memory'
        helper.parent.mkdir()
        helper.write_bytes(HELPER.read_bytes())
        helper.chmod(0o755)
        result = subprocess.run([str(helper), tip, ZERO, 'origin'], cwd=self.repo,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(reported_homes(result.stdout), ['memory/test'])
        self.assertIn('memory-canary', result.stderr)

    def test_explicit_missing_directory_and_argument(self):
        for args in (['--dir'], ['--dir', '--strict'], ['--dir', str(self.repo / 'absent')]):
            result = subprocess.run([str(CANARY), *args], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)


    def counted_gate(self):
        """The gate module with a checker that records each run, then runs the real one."""
        gate = self.gate_module()
        runs = self.verdicts.parent / 'runs'
        stub = self.verdicts.parent / 'bin' / 'memory-canary'
        stub.parent.mkdir()
        stub.write_text(f'#!/bin/bash\necho run >> {runs}\nexec {CANARY} "$@"\n')
        stub.chmod(0o755)
        gate.CHECKER = stub
        return gate, lambda: len(runs.read_text().splitlines()) if runs.exists() else 0

    def test_clean_verdict_is_reused_only_for_the_same_markdown(self):
        tip = self.setup_memory()
        gate, runs = self.counted_gate()
        first = gate.check_home(tip, 'memory/test')
        self.assertEqual((first.returncode, runs()), (0, 1))
        again = gate.check_home(tip, 'memory/test')
        self.assertEqual((again.returncode, runs()), (0, 1))
        self.assertIn(b'same committed Markdown as an earlier clean check', again.stdout)
        # A non-Markdown change is invisible to the checker.
        self.write('memory/test/reflections/host.jsonl', '{}\n')
        self.assertEqual((gate.check_home(self.commit(), 'memory/test').returncode, runs()), (0, 1))
        # Any Markdown change, or a different checker, is checked again.
        self.write('memory/test/note.md', 'detail\n')
        tip = self.commit()
        self.assertEqual((gate.check_home(tip, 'memory/test').returncode, runs()), (0, 2))
        gate.CHECKER.write_text(gate.CHECKER.read_text() + '# revised\n')
        self.assertEqual((gate.check_home(tip, 'memory/test').returncode, runs()), (0, 3))

    def test_pruning_keeps_unrelated_files_and_a_checker_that_cannot_run_fails(self):
        tip = self.setup_memory()
        gate, runs = self.counted_gate()
        self.verdicts.mkdir(mode=0o700)
        unrelated = self.verdicts / 'notes.txt'
        unrelated.write_text('keep\n')
        with mock.patch.object(gate, 'VERDICTS_KEPT', 0):
            self.assertEqual(gate.check_home(tip, 'memory/test').returncode, 0)
        self.assertEqual([path.name for path in self.verdicts.iterdir()], ['notes.txt'])
        self.assertEqual(gate.check_home(tip, 'memory/test').returncode, 0)
        gate.CHECKER.chmod(0o644)
        self.assertIsInstance(gate.check_home(tip, 'memory/test'), OSError)

    def test_a_failing_verdict_is_never_reused(self):
        tip = self.setup_memory('[broken](absent.md)')
        gate, runs = self.counted_gate()
        for expected in (1, 2):
            self.assertNotEqual(gate.check_home(tip, 'memory/test').returncode, 0)
            self.assertEqual(runs(), expected)
        self.assertEqual(list(self.verdicts.iterdir()), [])

    def test_verdict_cache_off_or_unsafe_checks_every_time(self):
        tip = self.setup_memory()
        gate, runs = self.counted_gate()
        with mock.patch.dict(os.environ, {'PRE_PUSH_MEMORY_CACHE': '0'}):
            gate.check_home(tip, 'memory/test')
            gate.check_home(tip, 'memory/test')
        self.assertEqual(runs(), 2)
        self.verdicts.mkdir()
        self.verdicts.chmod(0o777)
        self.addCleanup(self.verdicts.chmod, 0o700)
        gate.check_home(tip, 'memory/test')
        gate.check_home(tip, 'memory/test')
        self.assertEqual(runs(), 4)
        self.assertEqual(list(self.verdicts.iterdir()), [])

    def test_gate_output_on_a_cached_clean_push(self):
        tip = self.setup_memory()
        self.assertEqual(self.gate(tip).returncode, 0)
        result = self.gate(tip)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reported_homes(result.stdout), ['memory/test'])
        self.assertIn('same committed Markdown as an earlier clean check', result.stdout)


if __name__ == '__main__':
    unittest.main()
