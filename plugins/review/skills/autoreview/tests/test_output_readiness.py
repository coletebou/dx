"""Report destinations must work before a reviewer can start."""
import argparse
import io
import contextlib
import errno
import os
from pathlib import Path
import stat
import sys
import tempfile
import types
import unittest
from unittest import mock


SUBJECT = Path(__file__).resolve().parents[1] / 'scripts/autoreview'


def load_subject():
    module = types.ModuleType('output_readiness_subject')
    module.__file__ = str(SUBJECT)
    sys.modules[module.__name__] = module
    exec(compile(SUBJECT.read_bytes(), str(SUBJECT), 'exec'), module.__dict__)
    return module


class OutputReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper = load_subject()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='autoreview-output-readiness-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / 'reviewed-repo'
        self.repo.mkdir()

    def arguments(self, output):
        return argparse.Namespace(json_output=str(output), output=None,
                                  status_output=None, engine_stage_dir=None,
                                  preflight_output=None, native_handoff=None,
                                  mode='uncommitted', base=None, dry_run=False)

    def test_unready_destination_stops_main_before_target_and_engine(self):
        real_fdopen = self.helper.os.fdopen

        class DiskFullWriter:
            def __init__(self, handle):
                self.handle = handle

            def __enter__(self):
                self.handle.__enter__()
                return self

            def write(self, content):
                raise OSError(errno.ENOSPC, 'private write diagnostic sentinel')

            def __exit__(self, *exc):
                return self.handle.__exit__(*exc)

        def full_writer(*args, **kwargs):
            return DiskFullWriter(real_fdopen(*args, **kwargs))

        tempfile_owner, os_owner = self.helper.tempfile, self.helper.os
        cases = (
            ('missing parent', True, contextlib.nullcontext),
            ('probe permission', False, lambda: mock.patch.object(
                tempfile_owner, 'NamedTemporaryFile', side_effect=PermissionError('private diagnostic sentinel'))),
            ('probe creation ENOSPC', False, lambda: mock.patch.object(
                tempfile_owner, 'NamedTemporaryFile', side_effect=OSError(errno.ENOSPC, 'private create diagnostic sentinel'))),
            ('probe write ENOSPC', False, lambda: mock.patch.object(os_owner, 'fdopen', side_effect=full_writer)),
            ('atomic replace ENOSPC', False, lambda: mock.patch.object(
                os_owner, 'replace', side_effect=OSError(errno.ENOSPC, 'private diagnostic sentinel'))),
        )
        for label, missing_parent, failure in cases:
            for dry_run in ((False, True) if missing_parent else (False,)):
                with self.subTest(case=label, dry_run=dry_run):
                    parent = self.root / ('missing-parent' if missing_parent else '')
                    destination = parent / f'{label.replace(" ", "-")}-{dry_run}.json'
                    args = self.arguments(destination)
                    args.dry_run = dry_run
                    names = {
                        'reviewer_args': mock.Mock(return_value=[]),
                        'preflight_git': mock.Mock(return_value=True),
                        'repo_root': mock.Mock(return_value=self.repo),
                        'choose_target': mock.Mock(side_effect=AssertionError('unready output reached target selection')),
                        'run_engine': mock.Mock(side_effect=AssertionError('engine forbidden')),
                    }
                    with failure(), mock.patch.dict(self.helper.main_with_args.__globals__, names), \
                            contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                        with self.assertRaisesRegex(SystemExit, 'output destination is not writable') as caught:
                            self.helper.main_with_args(args)
                    self.assertNotIn('diagnostic sentinel', str(caught.exception))
                    names['choose_target'].assert_not_called()
                    names['run_engine'].assert_not_called()
                    self.assertFalse(destination.exists())
                    self.assertEqual(parent.exists(), not missing_parent)

    def test_each_report_role_requires_a_ready_parent(self):
        for attribute in ('json_output', 'output', 'status_output', 'preflight_output'):
            with self.subTest(attribute=attribute):
                args = self.arguments(self.root / 'present.json')
                setattr(args, attribute, str(self.root / attribute / 'missing.json'))
                with self.assertRaisesRegex(SystemExit, 'output destination is not writable'):
                    self.helper.prepare_output_paths(args, self.repo)
                self.assertFalse((self.root / attribute).exists())

    def test_valid_parent_preserves_existing_reports_and_publishes_atomically(self):
        report = self.root / 'review.json'
        report.write_text('previous public report\n', encoding='utf-8')
        before = {p.name for p in self.root.iterdir()}
        args = self.arguments(report)
        self.helper.prepare_output_paths(args, self.repo)
        self.assertEqual(report.read_text(encoding='utf-8'), 'previous public report\n')
        self.assertEqual({p.name for p in self.root.iterdir()}, before)
        self.helper.atomic_write_text(Path(args.json_output), 'new public report\n')
        self.assertEqual(report.read_text(encoding='utf-8'), 'new public report\n')

    def test_parent_file_and_existing_directory_refuse_without_mutation(self):
        parent = self.root / 'not-a-directory'
        parent.write_text('retain parent bytes\n', encoding='utf-8')
        directory = self.root / 'directory-destination'
        directory.mkdir()
        for destination in (parent / 'report.json', directory):
            with self.subTest(destination=destination.name):
                with self.assertRaisesRegex(SystemExit, 'output destination is not writable'):
                    self.helper.prepare_output_paths(self.arguments(destination), self.repo)
        self.assertEqual(parent.read_text(encoding='utf-8'), 'retain parent bytes\n')
        self.assertTrue(directory.is_dir())

    def test_probe_requires_only_one_free_inode(self):
        report = self.root / 'review.json'
        report.write_text('previous report\n', encoding='utf-8')
        real_mkstemp = self.helper.tempfile.mkstemp

        def one_free_inode(*args, **kwargs):
            if list(self.root.glob('.autoreview-output-probe.*')):
                raise OSError(errno.ENOSPC, 'synthetic inode quota')
            return real_mkstemp(*args, **kwargs)

        with mock.patch.object(self.helper.tempfile, 'mkstemp', side_effect=one_free_inode):
            self.helper.prepare_output_paths(self.arguments(report), self.repo)
        self.assertEqual(report.read_text(encoding='utf-8'), 'previous report\n')
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['review.json', 'reviewed-repo'])

    def test_windows_readonly_attribute_refuses_before_probe(self):
        report = self.root / 'review.json'
        report.write_text('previous report\n', encoding='utf-8')
        metadata = types.SimpleNamespace(st_mode=report.lstat().st_mode,
                                         st_file_attributes=stat.FILE_ATTRIBUTE_READONLY)
        with mock.patch.object(Path, 'lstat', return_value=metadata), \
                mock.patch.object(self.helper.tempfile, 'NamedTemporaryFile') as probe:
            with self.assertRaisesRegex(SystemExit, 'output destination is not writable'):
                self.helper.require_output_ready(report, '--json-output')
        probe.assert_not_called()
        self.assertEqual(report.read_text(encoding='utf-8'), 'previous report\n')

    @unittest.skipUnless(os.name == 'nt', 'Windows read-only replacement semantics')
    def test_native_windows_readonly_report_refuses_without_mutation(self):
        report = self.root / 'review.json'
        report.write_text('previous report\n', encoding='utf-8')
        report.chmod(stat.S_IREAD)
        try:
            with self.assertRaises(PermissionError):
                self.helper.atomic_write_text(report, 'replacement\n')
            with self.assertRaisesRegex(SystemExit, 'output destination is not writable'):
                self.helper.prepare_output_paths(self.arguments(report), self.repo)
            self.assertEqual(report.read_text(encoding='utf-8'), 'previous report\n')
        finally:
            report.chmod(stat.S_IREAD | stat.S_IWRITE)

    def test_existing_status_survives_an_unready_report_parent(self):
        status = self.root / 'status.json'
        status.write_text('retain prior status\n', encoding='utf-8')
        args = self.arguments(self.root / 'missing-parent' / 'review.json')
        args.status_output = str(status)
        with self.assertRaisesRegex(SystemExit, 'output destination is not writable'):
            self.helper.prepare_output_paths(args, self.repo)
        self.assertEqual(status.read_text(encoding='utf-8'), 'retain prior status\n')

    def test_outside_hardlink_output_replaces_entry_without_touching_repo_source(self):
        source = self.repo / 'source.txt'
        source.write_text('retained source bytes\n', encoding='utf-8')
        report = self.root / 'report.json'
        os.link(source, report)
        args = self.arguments(report)
        self.helper.prepare_output_paths(args, self.repo)
        self.helper.atomic_write_text(Path(args.json_output), 'new public report\n')
        self.assertEqual(source.read_text(encoding='utf-8'), 'retained source bytes\n')
        self.assertEqual(report.read_text(encoding='utf-8'), 'new public report\n')

    def test_full_destination_validation_precedes_probe_writes(self):
        args = self.arguments(self.root / 'review.json')
        args.output = str(self.repo / 'forbidden.md')
        with mock.patch.object(self.helper.tempfile, 'NamedTemporaryFile') as probe:
            with self.assertRaisesRegex(SystemExit, 'must point outside the reviewed repository'):
                self.helper.prepare_output_paths(args, self.repo)
        probe.assert_not_called()
        self.assertEqual(list(self.repo.iterdir()), [])

    def symlink(self, link, target):
        try:
            link.symlink_to(target, target_is_directory=target.is_dir())
        except OSError:
            self.skipTest('host_only: symlink creation unavailable')

    def test_symlinked_parent_or_final_referent_inside_repo_remains_refused(self):
        parent_alias = self.root / 'repo-alias'
        self.symlink(parent_alias, self.repo)
        source = self.repo / 'source.txt'
        source.write_text('retained source\n', encoding='utf-8')
        final_alias = self.root / 'linked-report.json'
        self.symlink(final_alias, source)
        for destination in (parent_alias / 'new.json', final_alias):
            with self.subTest(destination=destination.name):
                with mock.patch.object(self.helper.tempfile, 'NamedTemporaryFile') as probe:
                    with self.assertRaisesRegex(SystemExit, 'must point outside the reviewed repository'):
                        self.helper.prepare_output_paths(self.arguments(destination), self.repo)
                probe.assert_not_called()
        self.assertEqual(source.read_text(encoding='utf-8'), 'retained source\n')

    def test_optional_stage_directory_keeps_its_existing_contract(self):
        args = self.arguments(self.root / 'unused.json')
        args.json_output = None
        args.engine_stage_dir = str(self.root / 'missing-stage')
        with mock.patch.object(self.helper.tempfile, 'NamedTemporaryFile') as probe:
            self.helper.prepare_output_paths(args, self.repo)
        probe.assert_not_called()
        self.assertFalse(Path(args.engine_stage_dir).exists())

    def test_native_handoff_keeps_its_fresh_directory_contract(self):
        args = self.arguments(self.root / 'report.json')
        args.native_handoff = str(self.root / 'fresh-handoff')
        self.helper.prepare_output_paths(args, self.repo)
        self.assertFalse(Path(args.native_handoff).exists())
        self.assertFalse(Path(args.json_output).exists())

    def test_preflight_stage_guard_finishes_before_any_probe(self):
        args = self.arguments(self.root / 'report.json')
        args.engine_stage_dir = str(self.root / 'stage')
        args.preflight_output = str(self.root / 'stage' / 'preflight.json')
        with mock.patch.object(self.helper.tempfile, 'NamedTemporaryFile') as probe:
            with self.assertRaisesRegex(SystemExit, 'must stay outside --engine-stage-dir'):
                self.helper.prepare_output_paths(args, self.repo)
        probe.assert_not_called()

    def test_handoff_output_guard_finishes_before_any_probe(self):
        args = self.arguments(self.root / 'report.json')
        args.native_handoff = str(self.root / 'fresh-handoff')
        args.output = str(self.root / 'fresh-handoff' / 'report.md')
        with mock.patch.object(self.helper.tempfile, 'NamedTemporaryFile') as probe:
            with self.assertRaisesRegex(SystemExit, 'review outputs must stay outside --native-handoff'):
                self.helper.prepare_output_paths(args, self.repo)
        probe.assert_not_called()


if __name__ == '__main__':
    unittest.main()
