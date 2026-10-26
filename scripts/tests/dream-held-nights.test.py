#!/usr/bin/env python3
"""Offline checks for dream-held-nights: Rejected-section parsing, cross-night grouping, window, output."""
import datetime
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout

SCRIPT = Path(__file__).resolve().parents[1] / 'dream-held-nights'
LOADER = importlib.machinery.SourceFileLoader('dream_held_nights', str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
dhn = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(dhn)

D = datetime.date


def report(rejected, promoted=0):
    lines = ['# Deep — x', '', '## Promoted (%d)' % promoted, 'None today. Nothing met the threshold.', '',
             '## Rejected (reasons)']
    lines += ['- ' + r for r in rejected]
    lines += ['', '## Dream fragment (Deep)', '- not a candidate: prose that happens to start with a dash', '']
    return '\n'.join(lines)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.deep = os.path.join(self.tmp.name, 'dreaming', 'deep')
        os.makedirs(self.deep)

    def write(self, date, rejected):
        with open(os.path.join(self.deep, '%s.md' % date), 'w', encoding='utf-8') as fh:
            fh.write(report(rejected))

    def run_cli(self, today, lookback=14):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = dhn.main(['--memdir', self.tmp.name, '--today', today, '--lookback-days', str(lookback)])
        self.assertEqual(rc, 0)
        return buf.getvalue()


class TestParsing(Base):
    def test_bold_plain_and_none_bullets(self):
        self.write('2026-10-10', ['**Codex CLI EMFILE via sshd → zsh → tmux (256-file limit):** held, first sighting',
                                  'Plain title: work-state', 'None — nothing was even a candidate.'])
        got = dhn.rejected_candidates(os.path.join(self.deep, '2026-10-10.md'))
        self.assertEqual(got, [('Codex CLI EMFILE via sshd → zsh → tmux (256-file limit)', 'held, first sighting'),
                               ('Plain title', 'work-state')])

    def test_only_the_rejected_section_counts(self):
        self.write('2026-10-10', ['**A thing about tailscale acl tags**: held'])
        got = dhn.rejected_candidates(os.path.join(self.deep, '2026-10-10.md'))
        self.assertEqual([t for t, _ in got], ['A thing about tailscale acl tags'])  # the fragment's dash line is ignored


class TestGrouping(Base):
    def test_reworded_titles_group_across_nights(self):
        # wordings a real model produced on three nights in a row
        self.write('2026-10-10', ['**Codex CLI EMFILE through sshd → zsh → tmux (256-file soft limit)**: held'])
        self.write('2026-10-11', ['**Codex CLI via sshd→zsh→tmux inherits the 256-file limit (EMFILE)**: held'])
        self.write('2026-10-12', ["**Codex CLI over `sshd → zsh → tmux` hits macOS's 256-file limit (EMFILE)**: held"])
        clusters, dates = dhn.collect(self.tmp.name, D(2026, 10, 13), 14)
        self.assertEqual(len(clusters), 1)
        self.assertEqual(len(clusters[0]['nights']), 3)
        self.assertEqual(dhn.consecutive_tail(clusters[0]['nights'], dates), 3)

    def test_unrelated_titles_stay_apart_and_one_count_per_night(self):
        self.write('2026-10-10', ['**Approval policy never auto-declines MCP elicitation forms**: held',
                                  '**approval_policy=never auto-declines MCP elicitation forms (reference)**: dup wording',
                                  '**README line 27 says Lightsail**: one-line fix'])
        clusters, _ = dhn.collect(self.tmp.name, D(2026, 10, 11), 14)
        by_title = {c['title']: len(c['nights']) for c in clusters}
        self.assertEqual(len(clusters), 2)
        self.assertEqual(sorted(by_title.values()), [1, 1])  # the duplicate wording does not count the night twice

    def test_window_and_today_excluded(self):
        self.write('2026-09-01', ['**Old gotcha about zsh limits**: held'])   # outside the window
        self.write('2026-10-12', ['**Old gotcha about zsh limits**: held'])
        self.write('2026-10-13', ['**Old gotcha about zsh limits**: held'])   # today's own report (rerun)
        clusters, dates = dhn.collect(self.tmp.name, D(2026, 10, 13), 14)
        self.assertEqual(dates, [D(2026, 10, 12)])
        self.assertEqual(len(clusters[0]['nights']), 1)

    def test_gap_breaks_the_consecutive_run_but_not_the_total(self):
        for d in ('2026-10-10', '2026-10-11', '2026-10-13'):
            self.write(d, ['**Capability tier ladder unverified attested basic depth lidar**: held'])
        self.write('2026-10-12', ['**Something else entirely here**: held'])
        clusters, dates = dhn.collect(self.tmp.name, D(2026, 10, 14), 14)
        ladder = [c for c in clusters if 'ladder' in c['title']][0]
        self.assertEqual(len(ladder['nights']), 3)
        self.assertEqual(dhn.consecutive_tail(ladder['nights'], dates), 1)


class TestIdentity(Base):
    def test_shared_vocabulary_does_not_hand_one_fact_anothers_nights(self):
        # review counterexample: four EMFILE nights, then a different fact about the same shell chain
        for d in ('2026-10-10', '2026-10-11', '2026-10-12', '2026-10-13'):
            self.write(d, ['**Codex CLI EMFILE via sshd zsh tmux 256 limit**: held'])
        self.write('2026-10-14', ['**Codex CLI sshd zsh tmux PATH inheritance**: held'])
        clusters, _ = dhn.collect(self.tmp.name, D(2026, 10, 15), 14)
        nights = {c['first_title']: len(c['nights']) for c in clusters}
        self.assertEqual(nights, {'Codex CLI EMFILE via sshd zsh tmux 256 limit': 4,
                                  'Codex CLI sshd zsh tmux PATH inheritance': 1})

    def test_rows_match_their_first_wording_not_the_latest_member(self):
        # A~B and B~C but A!~C: without an anchor, C would chain onto A's row through B
        self.write('2026-10-10', ['**alpha bravo charlie delta echo**: held'])
        self.write('2026-10-11', ['**alpha bravo charlie delta foxtrot golf**: held'])
        self.write('2026-10-12', ['**charlie delta foxtrot golf hotel india**: held'])
        clusters, _ = dhn.collect(self.tmp.name, D(2026, 10, 13), 14)
        self.assertEqual(sorted(len(c['nights']) for c in clusters), [1, 2])

    def test_ledger_exposes_a_different_fact_inside_a_row(self):
        # review round 2: these two titles overlap 6/11 and do merge, so the row's endpoints alone
        # (EMFILE first and last) would credit EMFILE with the PATH nights in between
        em = '**Codex CLI via sshd→zsh→tmux inherits the 256-file limit (EMFILE)**: held'
        pa = '**Codex CLI via sshd→zsh→tmux inherits PATH**: held'
        for d, t in (('2026-10-10', em), ('2026-10-11', pa), ('2026-10-12', pa), ('2026-10-13', pa), ('2026-10-14', em)):
            self.write(d, [t])
        out = self.run_cli('2026-10-15')
        ledger = out.split('## Wordings behind rows held 5+ nights', 1)[1]
        self.assertIn('### H1 (5 nights)', ledger)
        self.assertIn('- 2026-10-10, 2026-10-14: Codex CLI via sshd→zsh→tmux inherits the 256-file limit (EMFILE)', ledger)
        self.assertIn('- 2026-10-11, 2026-10-12, 2026-10-13: Codex CLI via sshd→zsh→tmux inherits PATH', ledger)

    def test_ledger_only_for_rows_that_can_qualify(self):
        for d in ('2026-10-10', '2026-10-11'):
            self.write(d, ['**Two-night candidate about tmux limits**: held'])
        self.assertNotIn('## Wordings behind rows', self.run_cli('2026-10-12'))
        buf = io.StringIO()
        with redirect_stdout(buf):
            dhn.main(['--memdir', self.tmp.name, '--today', '2026-10-12', '--min-nights', '2'])
        self.assertIn('### H1 (2 nights)', buf.getvalue())

    def test_row_shows_first_and_latest_wording(self):
        self.write('2026-10-10', ['**Raw candidate: Codex CLI EMFILE from the 256-file limit via sshd zsh tmux**: held'])
        self.write('2026-10-11', ['**Codex CLI EMFILE via sshd zsh tmux 256-file limit (fix in zshenv)**: held'])
        out = self.run_cli('2026-10-12')
        row = [l for l in out.splitlines() if l.startswith('| H1 ')][0]
        self.assertIn('| Raw candidate: Codex CLI EMFILE from the 256-file limit via sshd zsh tmux | '
                      'Codex CLI EMFILE via sshd zsh tmux 256-file limit (fix in zshenv) |', row)


class TestOutput(Base):
    def test_table_lists_only_repeats_sorted_by_nights(self):
        for d in ('2026-10-10', '2026-10-11', '2026-10-12'):
            self.write(d, ['**Codex CLI EMFILE via sshd zsh tmux 256 limit**: durable-shaped, first sighting'])
        self.write('2026-10-12', ['**Codex CLI EMFILE via sshd zsh tmux 256 limit**: durable | held',
                                  '**Approval policy never declines elicitation**: held'])
        self.write('2026-10-11', ['**Codex CLI EMFILE via sshd zsh tmux 256 limit**: held',
                                  '**Approval policy never declines elicitation**: held'])
        out = self.run_cli('2026-10-13')
        rows = [l for l in out.splitlines() if l.startswith('| H')]
        self.assertEqual(len(rows), 2)
        self.assertTrue(rows[0].startswith('| H1 | 3 | 3 | 2026-10-10 | 2026-10-12 | Codex CLI EMFILE via sshd zsh tmux 256 limit | (same) |'))
        self.assertTrue(rows[1].startswith('| H2 | 2 | 2 | 2026-10-11 | 2026-10-12 | Approval policy'))
        self.assertIn('durable / held', rows[0])  # a pipe in a reason never breaks the table
        self.assertIn('Latest prior report: 2026-10-12', out)

    def test_no_reports_and_bad_date(self):
        out = self.run_cli('2026-10-13')
        self.assertIn('0 prior Deep report(s) read', out)
        self.assertIn('No candidate has been held on 2 or more prior nights.', out)
        self.assertEqual(dhn.main(['--memdir', self.tmp.name, '--today', '10/13/2026']), 2)

    def test_bad_calendar_date_and_nothing_bullets_are_skipped(self):
        with open(os.path.join(self.deep, '2026-02-30.md'), 'w', encoding='utf-8') as fh:
            fh.write(report(['**Should not count**: held']))
        self.write('2026-10-10', ['Nothing rejected.', '**Real candidate about zsh limits**: held'])
        clusters, dates = dhn.collect(self.tmp.name, D(2026, 10, 11), 400)
        self.assertEqual(dates, [D(2026, 10, 10)])
        self.assertEqual([c['first_title'] for c in clusters], ['Real candidate about zsh limits'])

    def test_missing_deep_dir_is_not_an_error(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = dhn.main(['--memdir', os.path.join(self.tmp.name, 'nope'), '--today', '2026-10-13'])
        self.assertEqual(rc, 0)
        self.assertIn('0 prior Deep report(s) read', buf.getvalue())


if __name__ == '__main__':
    unittest.main()
