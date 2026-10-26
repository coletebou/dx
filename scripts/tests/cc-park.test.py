#!/usr/bin/env python3
"""Offline checks for cc-park: launch-flag replay, screen and shell-prompt classification, schedules,
what a parked pane shows, which panes bulk parking leaves alone, the park lock and the autopark switch,
the 6 h default, and when a finished session's window is closed (its last turn, Drover's verdict, the
window and pane checks, the kill itself, and what list, park and status report)."""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'plugins/session/skills/cc-park/bin/cc-park'
LOADER = importlib.machinery.SourceFileLoader('cc_park', str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
park = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(park)

RULE = '─' * 120
FOOTER = '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 2 agents'
STATUS = '  Mb:87c43 webapp:main*55↑18 | opus5.5·hi | 33% | ⚡99% | ✎00:38Z | 🟢 9 | 2h'


def claude_screen(body, box=('❯',)):
    return '\n'.join([*body, RULE, *box, RULE, STATUS, FOOTER, ''])


IDLE = claude_screen(['✻ Churned for 1h 1m 20s · done 7:39 PM', '',
                      '  7. Audio: I checked its format and duration only.', 'new task? /clear to save 330.7k tokens'])
DIALOG = claude_screen(['Do you want to proceed?', '❯ 1. Yes', '  2. No', '', 'Esc to cancel'])
BUSY = claude_screen(['✻ Thinking… (12s · esc to interrupt)'])
TYPED = claude_screen(['done'], box=('❯ half a thought',))
HELD = claude_screen(['Held message from another session', 'Another Claude session sent a message: from webapp-f8'])
ZSH_AFTER_EXIT = IDLE + '\n[work] @laptop code/webapp on ☁ (us-east-1) took 2s\n❯\n'


class LaunchFlags(unittest.TestCase):
    def test_plain_launch(self):
        self.assertEqual(park.parse_launch('claude --dangerously-skip-permissions'),
                         (['--dangerously-skip-permissions'], []))

    def test_model_with_brackets_is_quoted_for_zsh(self):
        kept, _ = park.parse_launch('claude --dangerously-skip-permissions --model us.anthropic.claude-opus-5-5[1m] --effort high')
        cmd = park.resume_command(kept, 'abc-123', '/home/x/code/webapp')
        self.assertIn("--model 'us.anthropic.claude-opus-5-5[1m]'", cmd)
        self.assertTrue(cmd.startswith('cd /home/x/code/webapp && claude '))
        self.assertTrue(cmd.endswith('--resume abc-123'))

    def test_initial_prompt_is_dropped_not_replayed(self):
        kept, notes = park.parse_launch('claude --dangerously-skip-permissions --model opus You are the Opus 5.5 orchestrator for window 05')
        self.assertEqual(kept, ['--dangerously-skip-permissions', '--model', 'opus'])
        self.assertEqual(notes, ['initial prompt dropped'])

    def test_settings_and_effort_kept(self):
        kept, _ = park.parse_launch('claude --dangerously-skip-permissions --settings /home/x/.claude/route.settings.json --model m --effort xhigh')
        self.assertEqual(kept[-4:], ['--model', 'm', '--effort', 'xhigh'])
        self.assertIn('--settings', kept)

    def test_inline_json_settings_replay_quoted(self):
        inline = '{"env":{"CLAUDE_CODE_USE_MANTLE":"1","AWS_REGION":"us-east-1"}}'
        kept, _ = park.parse_launch(f'claude --dangerously-skip-permissions --settings {inline} --model opus --effort max')
        self.assertEqual(park.settings_problem(inline, '/nonexistent'), '')
        cmd = park.resume_command(kept, 'abc-123', '/home/x/code')
        self.assertIn(shlex.quote(inline), cmd)
        replayed = shlex.split(cmd.split(' && ', 1)[1])
        self.assertEqual(replayed[replayed.index('--settings') + 1], inline)

    def test_inline_settings_with_equals_form(self):
        inline = '{"env":{"A":"1"}}'
        kept, _ = park.parse_launch(f'claude --settings={inline} --model opus')
        self.assertEqual(kept[:2], ['--settings', inline])
        self.assertEqual(park.settings_problem(inline, '/nonexistent'), '')

    def test_split_inline_settings_are_refused(self):
        # ps splits JSON that contained spaces; the first fragment does not parse.
        kept, _ = park.parse_launch('claude --settings {"env": --model opus')
        self.assertIn('not one JSON object', park.settings_problem(kept[1], '/'))
        self.assertIn('not one JSON object', park.settings_problem('{"a":1', '/'))

    def test_settings_files_resolve_against_the_session_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'route.settings.json').write_text('{}')
            self.assertEqual(park.settings_problem('route.settings.json', tmp), '')
            self.assertEqual(park.settings_problem(str(Path(tmp) / 'route.settings.json'), '/'), '')
            self.assertEqual(park.settings_problem('missing.json', tmp), 'its --settings file no longer exists')

    def test_old_resume_and_continue_are_replaced(self):
        kept, notes = park.parse_launch('claude --resume 0f3c2a1e-1111-4222-8333-944455556666 -c --model opus')
        self.assertEqual(kept, ['--model', 'opus'])
        self.assertEqual(notes, ['old --resume dropped', '-c dropped'])

    def test_name_and_session_id(self):
        kept, notes = park.parse_launch('claude --session-id 7176cf8f-84fe-4ce3-9dbd-2f4fa3792293 --name opus55-4314-repair --model m')
        self.assertEqual(kept, ['--name', 'opus55-4314-repair', '--model', 'm'])
        self.assertEqual(notes, ['--session-id dropped'])

    def test_unknown_flag_refuses(self):
        with self.assertRaises(ValueError):
            park.parse_launch('claude --add-dir /tmp /var --model opus')

    def test_flag_after_prompt_refuses(self):
        with self.assertRaises(ValueError):
            park.parse_launch('claude do the thing --model opus')

    def test_non_claude_refuses(self):
        with self.assertRaises(ValueError):
            park.parse_launch('node server.js')


class Screens(unittest.TestCase):
    def test_idle_empty_even_with_numbered_prose(self):
        self.assertEqual(park.screen_state(IDLE)[0], 'idle-empty')

    def test_named_session_border(self):
        named = IDLE.replace(RULE, RULE + ' worker-spaces-cleanup ─', 1)
        self.assertEqual(park.screen_state(named)[0], 'idle-empty')

    def test_dialog(self):
        self.assertEqual(park.screen_state(DIALOG)[0], 'dialog')

    def test_held_peer_message(self):
        self.assertEqual(park.screen_state(HELD)[0], 'dialog')

    def test_busy(self):
        self.assertEqual(park.screen_state(BUSY)[0], 'busy')

    def test_waiting_on_a_background_agent_is_busy(self):
        # The turn ended and the main transcript went quiet, but /exit would only background it.
        waiting = claude_screen(['⏺ Waiting on the importer fix.', '', '✻ Waiting for 1 background agent to finish'])
        self.assertEqual(park.screen_state(waiting), ('busy', 'a background agent is still running'))

    def test_unsent_text(self):
        self.assertEqual(park.screen_state(TYPED)[0], 'typed')

    def test_plain_shell_is_not_claude(self):
        self.assertEqual(park.screen_state('[work] @macbook ~\n❯\n')[0], 'unknown')

    def test_typed_command_survives_shell_wrapping(self):
        cmd = 'cd /home/x/film-b && claude --model m --resume 2bb2-efb591e8bf70'
        wrapped = ZSH_AFTER_EXIT.rstrip('❯\n') + '❯ ' + cmd[:30] + '\n' + cmd[30:] + '\n'
        self.assertTrue(park.typed_at_prompt(wrapped, cmd))
        self.assertFalse(park.typed_at_prompt(ZSH_AFTER_EXIT, cmd))
        # A break on the space before the id leaves it as trailing blank, which capture trims (2026-10-22).
        at_space = cmd.index(' 2bb2')
        on_space = ZSH_AFTER_EXIT.rstrip('❯\n') + '❯ ' + cmd[:at_space] + '\n' + cmd[at_space + 1:] + '\n'
        self.assertTrue(park.typed_at_prompt(on_space, cmd))
        self.assertFalse(park.typed_at_prompt(on_space.replace('2bb2', '9bb2'), cmd))

    def test_wrapper_shells_die_with_claude(self):
        self.assertTrue(park.WRAPPER_SHELL.match('zsh -lic "CLAUDE_CODE_EFFORT_LEVEL=high claude --model x"'))
        self.assertTrue(park.WRAPPER_SHELL.match('/bin/bash -c claude'))
        self.assertFalse(park.WRAPPER_SHELL.match('-zsh'))
        self.assertFalse(park.WRAPPER_SHELL.match('/bin/zsh -l'))

    def test_shell_ready_only_below_claude_frame(self):
        self.assertFalse(park.shell_ready(IDLE))
        self.assertTrue(park.shell_ready(ZSH_AFTER_EXIT))
        self.assertTrue(park.shell_ready('bash-5.2$ \n'))


class Schedules(unittest.TestCase):
    def transcript(self, *tool_uses):
        tmp = tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False)
        for ts, name, args in tool_uses:
            tmp.write(json.dumps({'timestamp': ts, 'message': {'content': [
                {'type': 'tool_use', 'id': 'x', 'name': name, 'input': args}]}}) + '\n')
        tmp.close()
        self.addCleanup(Path(tmp.name).unlink)
        return [Path(tmp.name)]

    def iso(self, offset):
        return time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime(time.time() + offset))

    def test_cron_without_delete_is_live(self):
        paths = self.transcript((self.iso(-90000), 'CronCreate', {'cron': '7,37 * * * *'}))
        self.assertEqual(park.live_schedule(paths, time.time()), 'it has a cron job')

    def test_deleted_cron_is_not(self):
        paths = self.transcript((self.iso(-90000), 'CronCreate', {}), (self.iso(-80000), 'CronDelete', {}))
        self.assertEqual(park.live_schedule(paths, time.time()), '')

    def test_pending_and_expired_wakeups(self):
        pending = self.transcript((self.iso(-60), 'ScheduleWakeup', {'delaySeconds': 3600}))
        expired = self.transcript((self.iso(-90000), 'ScheduleWakeup', {'delaySeconds': 3000}))
        stopped = self.transcript((self.iso(-60), 'ScheduleWakeup', {'delaySeconds': 3600}),
                                  (self.iso(-30), 'ScheduleWakeup', {'stop': True}))
        self.assertEqual(park.live_schedule(pending, time.time()), 'it has a pending wakeup')
        self.assertEqual(park.live_schedule(expired, time.time()), '')
        self.assertEqual(park.live_schedule(stopped, time.time()), '')

    def test_timestamps_are_utc(self):
        self.assertEqual(park.parse_ts('1970-01-02T00:00:00.000Z'), 86400.0)

    def test_activity_comes_from_entries_not_mtime(self):
        tmp = tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False)
        tmp.write(json.dumps({'timestamp': '1970-01-02T00:00:00.000Z', 'type': 'user'}) + '\n')
        tmp.write(json.dumps({'type': 'summary', 'summary': 'no timestamp'}) + '\n')
        tmp.close()
        self.addCleanup(Path(tmp.name).unlink)
        self.assertEqual(park.last_entry_ts(Path(tmp.name)), 86400.0)

    def test_session_folder_without_transcript_has_nothing_to_resume(self):
        # The shape an unused session leaves: its folder, hook output, no <id>.jsonl.
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        sid = '7ca53d3c-f8b5-46b8-bc1a-f3488220ab29'
        (root / '-home-x-code-webapp' / sid / 'tool-results').mkdir(parents=True)
        (root / '-home-x-code-webapp' / sid / 'tool-results' / 'hook-stdout.txt').write_text('ok')
        self.addCleanup(setattr, park, 'PROJECTS_DIR', getattr(park, 'PROJECTS_DIR'))
        setattr(park, 'PROJECTS_DIR', root)
        self.assertEqual(park.transcript_paths(sid), ([], []))
        (root / '-home-x-code-webapp' / f'{sid}.jsonl').write_text('{}\n')
        self.assertEqual(len(park.transcript_paths(sid)[0]), 1)

    def test_tool_names_in_prose_do_not_count(self):
        tmp = tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False)
        tmp.write(json.dumps({'timestamp': self.iso(-60), 'message': {'content': [
            {'type': 'text', 'text': 'tools: CronCreate ScheduleWakeup "tool_use"'}]}}) + '\n')
        tmp.close()
        self.addCleanup(Path(tmp.name).unlink)
        self.assertEqual(park.live_schedule([Path(tmp.name)], time.time()), '')


class Footprints(unittest.TestCase):
    def test_linux_counts_resident_plus_swapped(self):
        with tempfile.TemporaryDirectory() as d:
            proc = Path(d)
            for pid, status in {
                '123': 'Name:\tclaude\nVmRSS:\t    2048 kB\nVmSwap:\t    1024 kB\n',
                '7': 'Name:\tkthreadd\nState:\tS (sleeping)\n',
                '9': 'Name:\tbroken\nVmRSS:\tgarbage kB\n',
            }.items():
                (proc / pid).mkdir()
                (proc / pid / 'status').write_text(status)
            (proc / 'self').mkdir()
            (proc / 'self' / 'status').write_text('VmRSS:\t1 kB\n')
            self.assertEqual(park.linux_footprints(proc), {123: 3.0, 7: 0.0})

    def test_linux_dispatch(self):
        original = park.sys.platform
        self.addCleanup(setattr, park.sys, 'platform', original)
        park.sys.platform = 'linux'
        self.assertIsInstance(park.footprints(), dict)


def patch(test, **values):
    for name, value in values.items():
        test.addCleanup(setattr, park, name, getattr(park, name))
        setattr(park, name, value)


# Transcript entries in the shape Claude Code writes them (one content block per assistant entry).
TS = '2026-01-01T00:00:00.000Z'


def prompt(text, **extra):
    return {'type': 'user', 'timestamp': TS, **extra, 'message': {'role': 'user', 'content': text}}


def reply(text, stop='end_turn', **extra):
    return {'type': 'assistant', 'timestamp': TS, **extra,
            'message': {'role': 'assistant', 'stop_reason': stop, 'content': [{'type': 'text', 'text': text}]}}


def tool_call(name='Bash', **args):
    return {'type': 'assistant', 'timestamp': TS, 'message': {
        'role': 'assistant', 'stop_reason': 'tool_use', 'content': [{'type': 'tool_use', 'id': 't1', 'name': name, 'input': args}]}}


def tool_result():
    return {'type': 'user', 'timestamp': TS, 'message': {
        'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'ok'}]}}


# What follows a finished turn: none of it is conversation.
TURN_END = [{'type': 'attachment', 'timestamp': TS}, {'type': 'system', 'subtype': 'stop_hook_summary', 'timestamp': TS},
            {'type': 'system', 'subtype': 'turn_duration', 'timestamp': TS}]
FINISHED = [prompt('ship it'), tool_call(), tool_result(), reply('Merged #12 and the deploy is green. Nothing is left.'),
            *TURN_END]


class FinishedTurn(unittest.TestCase):
    def pending(self, *entries, window=park.TURN_TAIL):
        tmp = tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False)
        tmp.write(''.join(json.dumps(e) + '\n' for e in entries))
        tmp.close()
        self.addCleanup(Path(tmp.name).unlink)
        return park.turn_pending(Path(tmp.name), window)

    def test_a_turn_that_ended_with_a_plain_report_is_finished(self):
        self.assertEqual(self.pending(*FINISHED), '')

    def test_drover_counts_this_as_finished_but_it_waits_on_the_owner(self):
        # A real reply's shape: no "?" at the end of its last line, so Drover said finished.
        text = ("Waiting on Alex. Everything left needs his yes: the release note wording, "
                "or both, and whether to open new PRs to make the retry actually stop.")
        self.assertIn('waits on something ("Waiting")', self.pending(prompt('go'), reply(text)))

    def test_handing_the_owner_something_keeps_the_window(self):
        for text in ('**Needs from Alex:** his line-26 answer, which repo-26 passes on to me.',
                     "It's a design call I'd want your read on before I spend another artifact.",
                     'The "merge landed" message has not arrived, so a fresh session will hold the same gate.',
                     'Done. If you want, I can also open the PR.', "Only your step is left: revoke the old key.",
                     "I'll commit the helper's log when it says it's ready."):
            with self.subTest(text=text):
                self.assertIn('waits on something', self.pending(prompt('go'), reply(text)))

    def test_naming_the_owner_keeps_the_window_when_cc_park_owner_is_set(self):
        text = 'Shipped. Alex has the release notes now.'
        self.assertEqual(self.pending(prompt('go'), reply(text)), '', 'no owner configured: finished')
        patch(self, OWNER=park.re.compile(r'\b(?:Alex)\b', park.re.I))
        self.assertEqual(self.pending(prompt('go'), reply(text)), 'its last reply waits on something ("Alex")')

    def test_any_question_mark_in_the_final_reply_keeps_the_window(self):
        self.assertEqual(self.pending(prompt('go'), reply('Should I push it? Otherwise all set.')),
                         'its last reply asks something')
        self.assertEqual(self.pending(prompt('go'), reply('¿Listo？')), 'its last reply asks something')

    def test_question_marks_in_code_and_links_ask_nothing(self):
        text = 'Fixed `a?.b ?? c` and the ```\nx = y ? 1 : 2\n``` branch; see https://x.test/p?q=1 for the run.'
        self.assertEqual(self.pending(prompt('go'), reply(text)), '')

    def test_only_the_reply_after_the_last_tool_result_is_read(self):
        # Narration while working ("Why did it fail? Let me wait for CI") asks the user nothing.
        entries = [prompt('fix CI'), reply('Why did it fail? Let me wait for CI.', stop='tool_use'), tool_call(),
                   tool_result(), reply('CI is green again; the flaky test is fixed.')]
        self.assertEqual(self.pending(*entries), '')
        # Every text block of that final reply counts, though.
        entries += [reply('Should I also bump the cache key?')]
        self.assertEqual(self.pending(*entries), 'its last reply asks something')

    def test_a_turn_that_did_not_end_with_a_finished_reply(self):
        unfinished = 'its last turn did not end with a finished reply'
        cases = {
            'interrupted': [*FINISHED, prompt([{'type': 'text', 'text': '[Request interrupted by user]'}])],
            'api error': [prompt('go'), reply('API Error: Could not load AWS credentials', stop='stop_sequence',
                                              isApiErrorMessage=True)],
            'question tool pending': [prompt('go'), tool_call('AskUserQuestion', questions=[{'question': 'A or B?'}])],
            'slash command after it': [*FINISHED, prompt('<local-command-stdout>Set effort level to max</local-command-stdout>')],
            'stop hook feedback': [*FINISHED, prompt('Stop hook feedback: keep going', isMeta=True)],
            'unanswered prompt': [*FINISHED, prompt('one more thing')],
            'no conversation': TURN_END,
        }
        for name, entries in cases.items():
            with self.subTest(name):
                self.assertEqual(self.pending(*entries), unfinished)

    def test_an_empty_reply_and_an_unreadable_transcript_are_not_finished(self):
        self.assertEqual(self.pending(prompt('go'), reply('  ')), 'its last reply has no text')
        self.assertEqual(park.turn_pending(Path('/nonexistent/x.jsonl')), 'its transcript could not be read')

    def test_reads_only_the_tail_of_a_long_transcript(self):
        # The window starts mid-line; that partial line is dropped, not parsed as garbage.
        filler = [prompt('x' * 500) for _ in range(40)]
        self.assertEqual(self.pending(*filler, *FINISHED, window=4096), '')


class DroverVerdict(unittest.TestCase):
    SID = '90e22d09-0e61-4a64-a623-85de14c88a8b'

    def verdict(self, stdout='', code=0, exe='/usr/local/bin/drover', error=None):
        calls = []

        def fake_run(cmd, **kw):
            calls.append((cmd, kw))
            if error:
                raise error
            return subprocess.CompletedProcess(cmd, code, stdout, '')
        patch(self, shutil=argparse.Namespace(which=lambda name: exe if name == 'drover' else None),
              subprocess=argparse.Namespace(run=fake_run, SubprocessError=subprocess.SubprocessError))
        why = park.drover_pending(self.SID)
        return why, calls

    def reply(self, kind='finished', label='finished, no question pending', text='All done.', sid=SID, engine='claude'):
        return json.dumps({'id': sid, 'name': 'x', 'engine': engine, 'text': text, 'line': text,
                           'ask': {'kind': kind, 'label': label, 'text': text, 'options': []}}, indent=2)

    def test_finished_for_this_session(self):
        why, calls = self.verdict(self.reply())
        self.assertEqual(why, '')
        [(cmd, kw)] = calls
        self.assertEqual(cmd, ['/usr/local/bin/drover', 'op', 'sessions.lastReply', json.dumps({'id': self.SID})])
        self.assertEqual(kw['timeout'], park.DROVER_TIMEOUT)

    def test_a_question_or_a_decision_is_not_finished(self):
        self.assertEqual(self.verdict(self.reply('question', 'asked you a question'))[0],
                         'drover says it asked you a question')
        self.assertEqual(self.verdict(self.reply('decision', 'needs a decision'))[0], 'drover says it needs a decision')
        self.assertEqual(self.verdict(self.reply('later', None))[0], 'drover says it later')

    def test_anything_uncertain_counts_as_not_finished(self):
        unread = 'drover could not read its last reply'
        cases = {
            # Drover answers "finished" even when it found no reply at all; that is not a yes.
            'no reply text': self.verdict(self.reply(text=None)),
            'another session': self.verdict(self.reply(sid='0f3c2a1e-1111-4222-8333-944455556666')),
            'a codex thread': self.verdict(self.reply(engine='codex')),
            'failed': self.verdict('Error: session not found', code=1),
            'not json': self.verdict('drover: deprecated\n{'),
            'timed out': self.verdict(error=subprocess.TimeoutExpired('drover', park.DROVER_TIMEOUT)),
            'cannot run': self.verdict(error=OSError('exec format error')),
        }
        for name, (why, _) in cases.items():
            with self.subTest(name):
                self.assertEqual(why, unread)

    def test_without_drover_nothing_confirms_it(self):
        why, calls = self.verdict(self.reply(), exe=None)
        self.assertEqual(why, 'drover is not installed, so nothing confirms it finished')
        self.assertEqual(calls, [])


class ParkedPane(unittest.TestCase):
    CLEAR = '\x1b[H\x1b[2J'

    def shown(self, text):
        self.assertTrue(text.startswith(self.CLEAR))
        return text[len(self.CLEAR):].split('\r\n')

    def test_body_is_the_conversation_above_the_input_box(self):
        # Claude's "new task? /clear to save" hint is interface, not conversation.
        expected = ['✻ Churned for 1h 1m 20s · done 7:39 PM', '', '  7. Audio: I checked its format and duration only.']
        self.assertEqual(park.screen_body(IDLE), expected)
        self.assertEqual(park.screen_body(IDLE.replace(RULE, RULE + ' worker-spaces-cleanup ─', 1)), expected)

    def test_body_without_an_input_box_is_the_trimmed_screen(self):
        self.assertEqual(park.screen_body('\n\n  hello\nworld  \n\n'), ['  hello', 'world'])

    def test_padding_rows_and_the_effort_indicator_are_dropped(self):
        # A short conversation, as Claude Code 2.1.308 draws it in a tall pane (2026-10-22).
        screen = claude_screen(['❯ Reply with one word', '', '⏺ ok', '', '', '', '✻ Brewed for 2s', '', '', '',
                                ' ' * 60 + '◐ medium · /effort'])
        self.assertEqual(park.screen_body(screen), ['❯ Reply with one word', '', '⏺ ok', '', '✻ Brewed for 2s'])

    def test_rows_count_wrapping_and_wide_characters(self):
        self.assertEqual([park.rows(s, 80) for s in ('', 'x' * 80, 'x' * 81, '🟢' * 40, '🟢' * 41)], [1, 1, 2, 1, 2])

    def test_fit_keeps_the_tail_that_fits(self):
        lines = [str(i) for i in range(50)]
        self.assertEqual(park.fit(lines, 10, 80), lines[-10:])
        self.assertEqual(park.fit(['x' * 200, 'tail'], 3, 80), ['tail'])

    def test_markers_and_line_endings(self):
        text = park.parked_screen(['⏺ done', '  ⎿  ok'], 0, 100, 30, 'cd /x && claude --resume abc', now=0)
        lines = self.shown(text)
        self.assertEqual(lines[1:-1], ['⏺ done', '  ⎿  ok'])
        self.assertNotIn('\n', text.replace('\r\n', ''))
        self.assertFalse(text.endswith('\r\n'))
        for marker in (lines[0], lines[-1]):
            self.assertIsNone(park.RULE.match(marker))
            self.assertFalse(marker.endswith(park.PROMPT_ENDS))
        # now=0 pins the clock (the epoch is falsy, so `now or time.time()` once ignored it).
        epoch = time.strftime('%a %H:%M', time.localtime(0))
        self.assertEqual(lines[-1], f'── parked {epoch}, last active {epoch} · press Enter to resume ──')

    def test_leaves_room_for_the_prompt_and_the_typed_command(self):
        command = 'cd /home/x/code && claude --resume ' + 'a' * 60  # 97 cells with '❯ ': two rows at 80
        lines = self.shown(park.parked_screen([f'line {i}' for i in range(100)], 0, 80, 30, command, now=0))
        self.assertEqual(len(lines), 2 + 30 - 6)
        self.assertEqual((lines[1], lines[-2]), ('line 76', 'line 99'))

    def test_a_pane_ending_in_the_footer_is_not_a_ready_shell(self):
        text = park.parked_screen(['⏺ last answer', '❯ an old prompt line'], 0, 100, 30, now=0).replace('\r\n', '\n')
        self.assertFalse(park.shell_ready(text))
        self.assertTrue(park.shell_ready(text + '\n\n@laptop webapp on  master\n❯\n'))

    def test_nothing_shown_without_a_body_or_a_tty(self):
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 0, '/dev/ttys999\t100\t30\n', ''))
        self.assertFalse(park.show_screen('%1', [], 0))
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 1, '', 'no such pane'))
        self.assertFalse(park.show_screen('%1', ['x'], 0))


class BulkSelection(unittest.TestCase):
    SID = '0f3c2a1e-1111-4222-8333-944455556666'
    TABLE = {4242: (100, 'claude --dangerously-skip-permissions'), 100: (1, '-zsh')}
    PANE = dict(pane_id='%9', target='work:1.1', window='w', auto=False, on_screen=False, in_mode=False,
                synchronized=False, keep=False, panes=1, linked=False, session_windows=3, close_off=False)

    def gather(self, only=None, table=None, transcript=None, close=True, **pane):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / 'sessions').mkdir()
        (root / 'projects' / '-tmp-x').mkdir(parents=True)
        (root / 'sessions' / '4242.json').write_text(json.dumps(
            {'pid': 4242, 'sessionId': self.SID, 'cwd': '/tmp/x', 'status': 'idle', 'kind': 'interactive'}))
        self.transcript = root / 'projects' / '-tmp-x' / f'{self.SID}.jsonl'
        entries = transcript or [{'timestamp': '2026-01-01T00:00:00.000Z', 'type': 'user'}]
        self.transcript.write_text(''.join(json.dumps(e) + '\n' for e in entries))
        info = dict(self.PANE)
        table = table or self.TABLE
        patch(self, SESSIONS_DIR=root / 'sessions', PROJECTS_DIR=root / 'projects', footprints=lambda: {},
              process_table=lambda: table, tmux_panes=lambda: {100: {**info, **pane}}, capture=lambda *a, **k: IDLE)
        if not hasattr(self, 'drover_calls'):
            self.drover(finished=True)
        [s] = park.gather(1, only, close)
        return s

    def drover(self, finished):
        """Stand in for `drover op sessions.lastReply`, recording which sessions it was asked about."""
        self.drover_calls = []
        patch(self, drover_pending=lambda sid: self.drover_calls.append(sid) or
              ('' if finished else 'drover says it asked you a question'))

    def test_an_idle_session_is_parked(self):
        s = self.gather()
        self.assertEqual(s.skip, '')
        self.assertEqual(s.resume, f'cd /tmp/x && claude --dangerously-skip-permissions --resume {self.SID}')

    def test_claude_caffeinate_is_a_helper_but_a_command_under_a_shell_is_work(self):
        # Claude Code keeps the Mac awake for five minutes after a turn (seen 2026-10-22).
        base = {**self.TABLE,
                4300: (4242, 'caffeinate -i -t 300'), 4301: (4242, 'node /home/x/.local/bin/drover mcp')}
        self.assertEqual(self.gather(table=base).skip, '')
        shell = {**base, 4400: (4242, '/bin/zsh -c caffeinate -i -t 900 make'), 4401: (4400, 'caffeinate -i -t 900 make')}
        self.assertEqual(self.gather(table=shell).skip, 'has a running child: zsh')
        bare = {**base, 4500: (4242, 'caffeinate -i -t 900 make')}
        self.assertEqual(self.gather(table=bare).skip, 'has a running child: caffeinate')

    def test_keep_option_skips_bulk_parking_but_not_a_named_pane(self):
        self.assertIn('@cc-park-keep', self.gather(keep=True).skip)
        self.assertEqual(self.gather(only={'%9'}, keep=True).skip, '')

    def test_copy_mode_is_skipped(self):
        self.assertEqual(self.gather(in_mode=True).skip, 'its pane is in copy mode')

    def test_synchronized_window_is_skipped(self):
        # tmux would copy /exit, Ctrl-C and the resume command into every pane of the window.
        self.assertIn('synchronize-panes', self.gather(synchronized=True).skip)
        self.assertIn('synchronize-panes', self.gather(only={'%9'}, synchronized=True).skip)

    def test_pane_listing_reads_copy_mode_sync_and_the_keep_option(self):
        rows = ('100\t%9\twork:1.1\tw\t1\t11\t1\t0\t0\ton\t1\t0\t4\t\n'
                '200\t%7\twork:2.1\tv\t0\t10\t0\t1\t1\t\t2\t1\t1\toff\n')
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 0, rows, ''))
        panes = park.tmux_panes()
        fields = ('keep', 'in_mode', 'on_screen', 'synchronized', 'panes', 'linked', 'session_windows', 'close_off')
        self.assertEqual([panes[100][f] for f in fields], [True, False, True, False, 1, False, 4, False])
        self.assertEqual([panes[200][f] for f in fields], [False, True, False, True, 2, True, 1, True])
        # The format and the parser have to agree on every field.
        self.assertEqual(len(park.PANE_FORMAT.split('\t')), len(rows.split('\n')[0].split('\t')))

    def test_park_rechecks_the_pane_before_sending_any_key(self):
        sent = []
        patch(self, tmux=lambda *a: sent.append(a) or subprocess.CompletedProcess(a, 0, '', ''))
        s = self.gather()
        self.assertEqual(s.skip, '')
        for change, result in ((dict(on_screen=True), 'pane changed: its pane is on screen right now'),
                               (dict(in_mode=True), 'pane changed: its pane is in copy mode'),
                               (dict(keep=True), 'pane changed: kept: @cc-park-keep is set on its pane or window')):
            patch(self, pane_now=lambda pane_id, c=change: {**self.PANE, **c})
            self.assertEqual(park.park(s, {}), (False, result))
        patch(self, pane_now=lambda pane_id: None)
        self.assertEqual(park.park(s, {}), (False, 'its pane is gone'))
        self.assertFalse([a for a in sent if a[:1] == ('send-keys',)])

    def test_a_pane_named_with_only_is_still_parked_when_kept_mid_run(self):
        s = self.gather(only={'%9'})
        patch(self, pane_now=lambda pane_id: {**self.PANE, 'keep': True})
        self.assertEqual(park.pane_skip(park.pane_now(s.pane_id), s.named), '')

    def test_a_finished_session_alone_in_its_window_closes_it(self):
        s = self.gather(transcript=FINISHED)
        self.assertEqual((s.skip, s.close, s.close_why), ('', True, ''))
        self.assertEqual(self.drover_calls, [self.SID])

    def test_the_window_stays_unless_the_pane_is_all_it_holds(self):
        cases = {
            'its window has other panes': dict(panes=2),
            'its window is also in another tmux session': dict(linked=True),
            'it is the last window of its tmux session': dict(session_windows=1),
            '@cc-park-close is off on its pane or window': dict(close_off=True),
        }
        for why, pane in cases.items():
            with self.subTest(why):
                s = self.gather(transcript=FINISHED, **pane)
                # Still parked, as today: only the window decision changes.
                self.assertEqual((s.skip, s.close, s.close_why), ('', False, why))

    def test_a_kept_pane_named_with_only_is_parked_but_keeps_its_window(self):
        s = self.gather(only={'%9'}, transcript=FINISHED, keep=True)
        self.assertEqual((s.skip, s.close, s.close_why), ('', False, '@cc-park-keep is set on its pane or window'))

    def test_other_processes_in_the_pane_keep_the_window(self):
        # A job the pane's shell runs besides claude would die with the window.
        table = {**self.TABLE, 4600: (100, 'sleep 1000')}
        s = self.gather(table=table, transcript=FINISHED)
        self.assertEqual((s.skip, s.close_why), ('', 'its pane runs other processes'))
        # The wrappers between the shell and claude (a launcher script, zsh -c) are not other work.
        wrapped = {4242: (4100, 'claude --dangerously-skip-permissions'), 4100: (100, 'bash /home/x/bin/launch-claude'), 100: (1, '-zsh')}
        self.assertTrue(self.gather(table=wrapped, transcript=FINISHED).close)

    def test_drover_has_the_last_word_and_is_asked_last(self):
        self.drover(finished=False)
        s = self.gather(transcript=FINISHED)
        self.assertEqual((s.skip, s.close, s.close_why), ('', False, 'drover says it asked you a question'))
        # A turn cc-park already reads as unfinished never reaches Drover.
        self.drover(finished=True)
        s = self.gather(transcript=[*FINISHED[:-3], reply('Want me to merge it?'), *TURN_END])
        self.assertEqual((s.close, s.close_why, self.drover_calls), (False, 'its last reply asks something', []))
        s = self.gather(transcript=FINISHED, panes=2)
        self.assertEqual(self.drover_calls, [])

    def test_no_close_parks_finished_sessions_in_place(self):
        s = self.gather(transcript=FINISHED, close=False)
        self.assertEqual((s.skip, s.close, s.close_why, self.drover_calls), ('', False, '', []))

    def test_park_refuses_a_session_that_was_active_again_since_gather(self):
        sent = []
        patch(self, tmux=lambda *a: sent.append(a) or subprocess.CompletedProcess(a, 0, '', ''))
        s = self.gather(transcript=FINISHED)
        patch(self, pane_now=lambda pane_id: dict(self.PANE))
        with open(self.transcript, 'a') as handle:
            handle.write(json.dumps(prompt('one more thing', timestamp=time.strftime('%Y-%m-%dT%H:%M:%S.000Z',
                                                                                      time.gmtime()))) + '\n')
        self.assertEqual(park.park(s, {}), (False, 'it was active again after this run started'))
        self.assertFalse([a for a in sent if a[:1] == ('send-keys',)])


class ClosingTheWindow(unittest.TestCase):
    PANE = BulkSelection.PANE

    def setUp(self):
        self.sent = []
        self.s = park.Session(pid=4242, session_id='x', cwd='/tmp/x', name='', status='idle', args='claude',
                              last_active=0, pane_id='%9', target='work:1.1', close=True)
        patch(self, tmux=lambda *a: self.sent.append(a) or subprocess.CompletedProcess(a, 0, '', ''),
              wait=lambda predicate, seconds, step=0.25: predicate())

    def close(self, states, processes=()):
        states = list(states)
        patch(self, pane_now=lambda pane_id: states.pop(0) if len(states) > 1 else states[0],
              pane_processes=lambda pane_id: list(processes))
        return park.close_window(self.s)

    def kills(self):
        return [a for a in self.sent if a[:1] == ('kill-pane',)]

    def test_kills_the_pane_alone_in_its_window(self):
        self.assertEqual(self.close([dict(self.PANE), None]), '')
        self.assertEqual(self.kills(), [('kill-pane', '-t', '%9')])

    def test_rechecks_the_window_after_claude_exited(self):
        # Between gather() and now the user may look at it, split it, or mark it.
        for change, why in ((dict(on_screen=True), 'its pane is on screen right now'),
                            (dict(in_mode=True), 'its pane is in copy mode'),
                            (dict(panes=2), 'its window has other panes'),
                            (dict(close_off=True), '@cc-park-close is off on its pane or window'),
                            (dict(keep=True), 'kept: @cc-park-keep is set on its pane or window')):
            with self.subTest(why):
                self.assertEqual(self.close([{**self.PANE, **change}]), why)
        self.assertEqual(self.close([None]), 'its pane is gone')
        self.assertEqual(self.kills(), [])

    def test_a_process_left_in_the_pane_keeps_it(self):
        self.assertEqual(self.close([dict(self.PANE)], processes=[4600]), 'its pane still runs other processes')
        self.assertEqual(self.kills(), [])

    def test_reports_a_pane_tmux_did_not_close(self):
        self.assertEqual(self.close([dict(self.PANE)]), 'tmux did not close it')

    def test_pane_processes_counts_the_tree_under_the_shell_and_the_terminal(self):
        ps = []
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 0, '0\t100\t/dev/ttys004\n', ''),
              process_table=lambda: {100: (1, '-zsh'), 200: (100, 'sleep 9'), 300: (200, 'cat')},
              run=lambda cmd: ps.append(cmd) or subprocess.CompletedProcess(cmd, 0, '  100\n  400\n', ''))
        # 400 is not under the shell but still on its terminal (a job that lost its parent).
        self.assertEqual(park.pane_processes('%9'), [200, 300, 400])
        self.assertEqual(ps, [['ps', '-t', 'ttys004', '-o', 'pid=']])
        patch(self, run=lambda cmd: subprocess.CompletedProcess(cmd, 1, '', ''), process_table=lambda: {100: (1, '-zsh')})
        self.assertEqual(park.pane_processes('%9'), [])

    def test_a_dead_pane_holds_no_process_and_an_unreadable_one_is_unknown(self):
        # tmux 3.8 prints an empty #{pane_pid} for a dead pane (remain-on-exit).
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 0, '1\t\t/dev/ttys049\n', ''))
        self.assertEqual(park.pane_processes('%9'), [])
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 1, '', 'no such pane'))
        self.assertEqual(park.pane_processes('%9'), ['unknown'])
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 0, '0\t\t\n', ''))
        self.assertEqual(park.pane_processes('%9'), ['unknown'])

    def test_a_dead_pane_does_not_break_the_pane_listing(self):
        # A dead pane anywhere on the server once made every gather() raise on int('').
        rows = ('\t%3\tw:1.0\tdead\t0\t10\t0\t0\t0\t\t1\t0\t2\t\n'
                '100\t%9\twork:1.1\tw\t1\t11\t1\t0\t0\t\t1\t0\t4\t\n')
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 0, rows, ''))
        self.assertEqual(sorted(park.tmux_panes()), [0, 100])
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 0, rows.split('\n')[0] + '\n', ''))
        self.assertEqual(park.pane_now('%3')['pane_id'], '%3')

    def test_a_pane_that_is_gone_reads_as_gone(self):
        # tmux 3.8: `display -p -t %1` after kill-pane exits 0 and prints every field empty.
        gone = '\t'.join([''] * len(park.PANE_FORMAT.split('\t'))) + '\n'
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 0, gone, ''))
        self.assertIsNone(park.pane_now('%1'))
        patch(self, tmux=lambda *a: subprocess.CompletedProcess(a, 1, '', "can't find pane: %1"))
        self.assertIsNone(park.pane_now('%1'))


class Scheduling(unittest.TestCase):
    def setUp(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        patch(self, STATE_DIR=root, LOCK=root / 'park.lock', AUTO_OFF=root / 'auto.off')

    def test_one_park_run_at_a_time(self):
        held = park.park_lock()
        self.assertIsNotNone(held)
        self.assertIsNone(park.park_lock())
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(park.cmd_park(argparse.Namespace(idle=1, only=None, limit=0)), 75)
        self.assertIn('another cc-park park is running', err.getvalue())
        held.close()
        again = park.park_lock()
        self.assertIsNotNone(again)
        again.close()

    def test_auto_pause_switch(self):
        runs = []
        patch(self, cmd_park=lambda opts: runs.append(opts) or 0,
              tmux=lambda *a: subprocess.CompletedProcess(a, 0, '', ''))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            park.main(['auto', 'off'])
            self.assertTrue(park.AUTO_OFF.exists())
            self.assertEqual(park.main(['auto']), 0)
            park.main(['auto', 'on'])
            self.assertFalse(park.AUTO_OFF.exists())
            self.assertEqual(park.main(['auto', '--idle', '3']), 0)
        self.assertEqual(len(runs), 1)
        self.assertEqual((runs[0].idle, runs[0].only, runs[0].limit), (3.0, None, 0))
        self.assertIn('paused', out.getvalue())

    def test_list_and_park_default_to_the_scheduled_runs_six_hours(self):
        seen = []
        patch(self, cmd_list=lambda opts: seen.append(opts) or 0, cmd_park=lambda opts: seen.append(opts) or 0,
              tmux=lambda *a: subprocess.CompletedProcess(a, 0, '', ''))
        with contextlib.redirect_stdout(io.StringIO()):
            for argv in (['list'], ['park'], ['auto'], ['park', '--no-close'], ['auto', '--no-close', '--idle', '2']):
                self.assertEqual(park.main(argv), 0)
        self.assertEqual(park.IDLE_HOURS, 6.0)
        self.assertEqual([(o.idle, o.close) for o in seen],
                         [(6.0, True), (6.0, True), (6.0, True), (6.0, False), (2.0, False)])

    def test_auto_defaults_to_six_hours_and_tolerates_no_tmux(self):
        runs = []
        patch(self, cmd_park=lambda opts: runs.append(opts) or 0,
              tmux=lambda *a: subprocess.CompletedProcess(a, 1, '', 'no server running'))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(park.main(['auto']), 0)
        self.assertEqual(runs, [])
        self.assertIn('parking sessions idle 6 h or more', out.getvalue())
        self.assertIn('no tmux server', out.getvalue())


class Reporting(unittest.TestCase):
    def setUp(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / 'sessions').mkdir()
        patch(self, STATE_DIR=root, LOCK=root / 'park.lock', LEDGER=root / 'parked.jsonl', SCREENS_DIR=root / 'screens',
              SESSIONS_DIR=root / 'sessions')
        self.root = root

    def session(self, sid, **kw):
        return park.Session(pid=kw.pop('pid', 1), session_id=sid, cwd='/tmp/x', name='', status='idle', args='claude',
                            last_active=time.time() - 7 * 3600, pane_id=kw.pop('pane_id', '%1'), target=kw.pop('target', 'w:1.1'),
                            window='win', resume=f'cd /tmp/x && claude --resume {sid}', **kw)

    def test_park_records_which_windows_it_closed(self):
        done, other = self.session('aaa', close=True), self.session('bbb', close_why='its last reply asks something')

        def fake_park(s, table):
            s.closed = s.close
            return True, 'its helpers exited with it' + ('; closed its window, as it had finished' if s.close else '')
        patch(self, gather=lambda idle, only, close: [done, other], park=fake_park, process_table=lambda: {})
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(park.cmd_park(argparse.Namespace(idle=6, only=None, limit=0, close=True)), 0)
        lines = out.getvalue().splitlines()
        self.assertTrue(lines[0].startswith('closed  w:1.1'))
        self.assertTrue(lines[1].startswith('parked  w:1.1'))
        self.assertIn('parked 2 (1 of them closed), failed 0', out.getvalue())
        ledger = [json.loads(line) for line in park.LEDGER.read_text().splitlines()]
        self.assertEqual([(r['sessionId'], r['closed'], r['resume']) for r in ledger],
                         [('aaa', True, done.resume), ('bbb', False, other.resume)])

    def test_status_shows_closed_sessions_with_their_resume_command(self):
        records = [dict(sessionId='aaa', ok=True, closed=True, pane='%1', target='h:1.1', window='done-one'),
                   dict(sessionId='bbb', ok=True, closed=False, pane='%2', target='h:2.1', window='parked-one'),
                   dict(sessionId='ccc', ok=True, closed=True, pane='%3', target='h:3.1', window='back-again'),
                   dict(sessionId='ddd', ok=True, pane='%4', target='h:4.1', window='old-record')]
        park.LEDGER.write_text(''.join(json.dumps({**r, 'ts': TS, 'resume': f"claude --resume {r['sessionId']}"}) + '\n'
                                       for r in records))
        # ccc was resumed after its window closed: its claude is alive again.
        (self.root / 'sessions' / 'x.json').write_text(json.dumps({'pid': os.getpid(), 'sessionId': 'ccc'}))
        patch(self, tmux_panes=lambda: {10: {'pane_id': '%2'}})
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(park.cmd_status(None), 0)
        lines = out.getvalue().splitlines()
        self.assertTrue(lines[0].startswith('closed (done) h:1.1') and lines[0].endswith('claude --resume aaa'))
        self.assertEqual(lines[1].split(), ['last', 'screen:', str(park.SCREENS_DIR / 'aaa.txt')])
        self.assertTrue(lines[2].startswith('parked        h:2.1') and lines[2].endswith('claude --resume bbb'))
        self.assertTrue(lines[3].startswith('resumed       h:3.1'))
        self.assertTrue(lines[4].startswith('pane gone     h:4.1'))
        self.assertEqual(len(lines), 5)

    def test_list_says_which_windows_close_and_why_the_others_stay(self):
        sessions = [self.session('aaa', close=True, target='a:1.1'),
                    self.session('bbb', close_why='its window has other panes', target='b:1.1'),
                    self.session('ccc', target='c:1.1'),
                    self.session('ddd', skip='status is busy', target='d:1.1')]
        with contextlib.redirect_stdout(io.StringIO()) as out:
            park.print_table(sessions)
        text = out.getvalue()
        self.assertIn('park, then close its window: finished', text)
        self.assertIn('park; window stays: its window has other panes', text)
        self.assertRegex(text, r'c:1\.1 win\s+7\.0\s+0  park\n')
        self.assertIn('skip: status is busy', text)
        self.assertIn('3 to park (1 of them closing their windows)', text)


if __name__ == '__main__':
    unittest.main()
