#!/usr/bin/env python3
"""memory-canary.test.py: scripts/memory-canary on synthetic memory directories.

Capacity is counted the way Claude Code counts (trimmed lines and characters, against 200 and
25,000, warnings from 90%); dangling index links, case collisions, reserved-name variants and
real conflict markers are problems; wiki-links resolve through file names and `name:` fields in
both spellings and ignore code; the wiki-dangle-baseline ratchet turns only a NEW dangle into a
problem, also when the checker is run through a link; which directories it checks (--dir, the
memory-homes.conf rows, then the Claude Code memory dir of the current directory); usage errors;
the shipped baseline is an empty template; every bash present parses the script (macOS /bin/bash
is 3.2). HOME, the configuration and the repositories live in a temp dir.

    python3 scripts/tests/memory-canary.test.py      (CANARY_BASH=/bin/bash to run another bash)
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CANARY = ROOT / 'scripts/memory-canary'
BASELINE = ROOT / 'scripts/wiki-dangle-baseline'
BASH = os.environ.get('CANARY_BASH', 'bash')


def encode(path):
    return re.sub(r'[^A-Za-z0-9]', '-', str(path))


class CanaryTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = pathlib.Path(temp.name).resolve()
        self.home = self.tmp / 'home'
        self.home.mkdir()
        self.env = {'HOME': str(self.home), 'PATH': os.environ['PATH'], 'LC_ALL': 'C.UTF-8',
                    'GIT_CONFIG_NOSYSTEM': '1', 'DOTFILES_DIR': str(self.tmp / 'dotfiles')}

    def canary(self, *args, cwd=None, env=None, script=CANARY):
        return subprocess.run([BASH, str(script), *args], cwd=cwd or self.tmp, env={**self.env, **(env or {})},
                              capture_output=True, text=True, timeout=60)

    def memory(self, name='notes', index='# Index\n', files=None, parent=None):
        d = (parent or self.tmp / 'mem') / name
        d.mkdir(parents=True, exist_ok=True)
        (d / 'MEMORY.md').write_text(index)
        for file, text in (files or {}).items():
            (d / file).write_text(text)
        return d

    def check(self, d, *args, **kw):
        return self.canary('--dir', str(d), *args, **kw)

    # ── capacity ──────────────────────────────────────────────────────────

    def test_line_cap_counts_trimmed_lines_like_claude_code(self):
        lines = ''.join(f'- entry {i}\n' for i in range(200))
        r = self.check(self.memory(index='\n\n' + lines + '\n\n\n'))  # wc -l would say 204
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn('index 200/200 lines', r.stdout)
        self.assertNotIn('OVER LINE CAP', r.stdout)
        r = self.check(self.memory(index=lines + '- entry 200\n'))
        self.assertEqual(r.returncode, 1)
        self.assertIn('OVER LINE CAP: 201 > 200', r.stdout)
        self.assertIn('DISCARDS the newest 1', r.stdout)

    def test_byte_cap_and_warning_levels(self):
        r = self.check(self.memory(index='x' * 25001))
        self.assertEqual(r.returncode, 1)
        self.assertIn('OVER BYTE CAP: 25001 > 25000', r.stdout)
        for index, warning in (('x' * 22500, 'approaching byte cap: 22500/25000'),
                               (''.join(f'- {i}\n' for i in range(180)), 'approaching line cap: 180/200')):
            with self.subTest(warning=warning):
                d = self.memory(index=index)
                r = self.check(d)
                self.assertEqual(r.returncode, 0, r.stdout)
                self.assertIn(warning, r.stdout)
                self.assertEqual(self.check(d, '--strict').returncode, 1)  # past 90%, a hook blocks
        r = self.check(self.memory(index=''.join(f'- {i}\n' for i in range(179))), '--strict')
        self.assertEqual((r.returncode, r.stdout.count('WARN')), (0, 0), r.stdout)

    # ── index links, collisions, markers ─────────────────────────────────

    def test_dangling_index_links(self):
        d = self.memory(index='- [a](a.md)\n- [b](./b.md)\n- [c](gone.md)\n', files={'a.md': 'a', 'b.md': 'b'})
        r = self.check(d)
        self.assertEqual(r.returncode, 1)
        self.assertIn('1 DANGLING link(s): gone.md', r.stdout)
        (d / 'gone.md').write_text('back')
        self.assertEqual(self.check(d, '--strict').returncode, 0)

    def test_case_variants(self):
        d = self.memory(files={'Dreams.md': 'diary'})
        r = self.check(d)
        self.assertEqual(r.returncode, 1)
        self.assertIn('RESERVED-NAME case variant present: Dreams.md', r.stdout)
        d = self.memory('other', files={'Topic.md': 'one'})
        (d / 'topic.md').write_text('two')
        if sorted(p.name for p in d.iterdir()) != ['MEMORY.md', 'Topic.md', 'topic.md']:
            self.skipTest('this filesystem folds case: it cannot hold the collision')
        r = self.check(d)
        self.assertEqual(r.returncode, 1)
        self.assertIn("CASE COLLISION", r.stdout)
        self.assertIn("topic.md -> ['Topic.md', 'topic.md']", r.stdout)

    def test_conflict_markers_only_when_real(self):
        conflict = '<<<<<<< Updated upstream\nmine\n=======\ntheirs\n>>>>>>> Stashed changes\n'
        r = self.check(self.memory(index=conflict))
        self.assertEqual(r.returncode, 1)
        self.assertIn('CONFLICT MARKERS present in MEMORY.md', r.stdout)
        r = self.check(self.memory('detail', files={'topic.md': conflict}))
        self.assertEqual(r.returncode, 1)
        self.assertIn('CONFLICT MARKERS in 1 detail file(s): topic.md', r.stdout)
        documented = ('An autostash conflict leaves `<<<<<<< Updated upstream` in the file.\n'
                      '<<<<<<< an opening marker alone is not a conflict\n')
        r = self.check(self.memory('documented', index=documented, files={'topic.md': documented}), '--strict')
        self.assertEqual(r.returncode, 0, r.stdout)

    # ── wiki-links and the ratchet ────────────────────────────────────────

    def test_wiki_links_resolve_through_names_and_both_spellings(self):
        files = {
            'reference_build_cache.md': '---\nname: reference-build-cache\n---\n',
            'odd-file.md': '---\nname: "renamed_note"\n---\n',
            'links.md': ('[[reference-build-cache]] [[reference_build_cache]] [[odd_file]] [[renamed-note]]\n'
                         '[[odd-file.md]] [[links]]\n'
                         '`[[inline-code-link]]` and [[ -f /etc/x ]] and [[ -n "$x" ]]\n'
                         '```\n[[fenced-link]]\n```\n'),
        }
        r = self.check(self.memory(files=files), '--strict')
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertNotIn('wiki-link', r.stdout)

    def test_dangling_wiki_links_warn_without_a_baseline(self):
        d = self.memory(files={'a.md': 'see [[feedback-missing]] and [[other_missing]]\n'})
        r = self.check(d, '--strict')
        # Inherited rot is visible but never blocks, not even under --strict.
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn('WARN:    2 dangling [[wiki-link]] target(s): feedback-missing (in a.md), other_missing (in a.md)',
                      r.stdout)

    def ratcheted_copy(self, baseline):
        """The checker in a directory of its own, next to a baseline, and a link to it in a bin dir."""
        real = self.tmp / 'checkout/scripts'
        real.mkdir(parents=True)
        shutil.copy2(CANARY, real / 'memory-canary')
        (real / 'wiki-dangle-baseline').write_text(baseline)
        link = self.tmp / 'bin/memory-canary'
        link.parent.mkdir()
        link.symlink_to(os.path.relpath(real / 'memory-canary', link.parent))
        return real / 'memory-canary', link

    def test_baseline_ratchet_blocks_only_new_dangles(self):
        real, link = self.ratcheted_copy('# comment\nother=5\nnotes = 1  # one inherited\n')
        d = self.memory(files={'a.md': 'see [[missing-one]]\n'})
        for script in (real, link):  # install.sh links the checker into ~/.local/bin
            with self.subTest(script=script):
                r = self.check(d, '--strict', script=script)
                self.assertEqual(r.returncode, 0, r.stdout)
                self.assertIn('(baseline 1; not increased)', r.stdout)
        (d / 'b.md').write_text('and [[missing-two]]\n')
        for script in (real, link):
            with self.subTest(script=script):
                r = self.check(d, script=script)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn('[NEW: baseline is 1]', r.stdout)

    def test_shipped_baseline_is_an_empty_template(self):
        rows = [line.split('#')[0].strip() for line in BASELINE.read_text().splitlines()]
        self.assertEqual([row for row in rows if row], [], 'the shipped baseline names no memory home')
        examples = [line for line in BASELINE.read_text().splitlines() if re.fullmatch(r'#\s*[\w.-]+=\d+', line)]
        self.assertTrue(examples, 'the template shows the <home>=<count> format')

    # ── DREAMS.md and output ──────────────────────────────────────────────

    def test_dreams_diary(self):
        d = self.memory(files={'DREAMS.md': '## night\n'})
        r = self.check(d)
        self.assertIn('info:    DREAMS.md 1 lines', r.stdout)
        (d / 'DREAMS.md').write_text(''.join(f'line {i}\n' for i in range(201)))
        r = self.check(d)
        self.assertEqual(r.returncode, 0)
        self.assertIn('rotation should have run', r.stdout)
        self.assertEqual(self.check(d, '--strict').returncode, 1)

    def test_json_and_quiet(self):
        d = self.memory(index='- [gone](gone.md)\n')
        r = self.check(d, '--json')
        self.assertEqual(r.returncode, 1)
        result = json.loads(r.stdout)
        self.assertEqual((result['dir'], result['ok'], result['cap_lines'], result['cap_bytes']),
                         (str(d), False, 200, 25000))
        self.assertIn('1 DANGLING link(s): gone.md', result['problems'])
        healthy = self.memory('healthy')
        self.assertEqual(self.check(healthy, '--quiet').stdout, '')
        self.assertIn('✓ memory-canary', self.check(healthy).stdout)

    # ── which directories ─────────────────────────────────────────────────

    def test_configured_homes(self):
        repo = self.tmp / 'private-dotfiles'
        conf = repo / 'claude/memory-homes.conf'
        conf.parent.mkdir(parents=True)
        absolute = self.memory('absolute')
        self.memory('tilde', parent=self.home / 'mem')
        self.memory('dollar', parent=self.home / 'mem')
        relative = self.memory('relative', parent=repo / 'identities/you/claude/memory')
        broken = self.memory('broken', index='[gone](gone.md)\n', parent=repo / 'memory')
        conf.write_text(f'# repo   memory dir\n\na {absolute}\nb ~/mem/tilde\nc $HOME/mem/dollar\n'
                        f'd identities/you/claude/memory/relative\ne {self.tmp}/not-created-yet\n')
        r = self.canary(env={'MEMORY_HOMES_CONF': str(conf)})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        checked = re.findall(r'^✓ memory-canary (.+)$', r.stdout, re.M)
        self.assertEqual(checked, [str(absolute), '~/mem/tilde', '~/mem/dollar', str(relative)])
        conf.write_text(conf.read_text() + 'f memory/broken\n')
        r = self.canary(env={'MEMORY_HOMES_CONF': str(conf)})
        self.assertEqual(r.returncode, 1)
        self.assertIn(f'✗ memory-canary {broken}', r.stdout)
        # --dir checks only the directory it names.
        r = self.canary('--dir', str(absolute), env={'MEMORY_HOMES_CONF': str(conf)})
        self.assertEqual((r.returncode, re.findall(r'^. memory-canary (.+)$', r.stdout, re.M)), (0, [str(absolute)]))

    def test_default_configuration_locations(self):
        for dotfiles in (self.tmp / 'dotfiles', self.home / '.dotfiles'):
            with self.subTest(dotfiles=dotfiles):
                d = self.memory('webapp', parent=dotfiles / 'identities/you/claude/memory')
                conf = dotfiles / 'claude/memory-homes.conf'
                conf.parent.mkdir(parents=True)
                conf.write_text('webapp identities/you/claude/memory/webapp\n')
                env = {} if dotfiles == self.tmp / 'dotfiles' else {'DOTFILES_DIR': ''}
                r = self.canary(env=env)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn(f'memory-canary {d}'.replace(str(self.home), '~'), r.stdout)
                shutil.rmtree(dotfiles)

    def git_repo(self, path):
        path.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(path)], check=True, env=self.env)
        return path

    def test_falls_back_to_the_memory_dir_claude_code_uses_here(self):
        repo = self.git_repo(self.tmp / 'work/my.repo_x')
        (repo / 'sub').mkdir()
        d = self.memory('memory', parent=self.home / '.claude/projects' / encode(repo))
        for cwd in (repo, repo / 'sub'):
            with self.subTest(cwd=cwd):
                r = self.canary(cwd=cwd)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn('✓ memory-canary ' + str(d).replace(str(self.home), '~'), r.stdout)
        # An autoMemoryDirectory setting wins, as it does for Claude Code; a broken settings
        # file is skipped. The local settings are read at the main checkout's root.
        self.memory('override', index='[gone](gone.md)\n', parent=self.home)
        (repo / '.claude').mkdir()
        (repo / '.claude/settings.local.json').write_text('{"autoMemoryDirectory": ')
        (repo / '.claude/settings.json').write_text('{"autoMemoryDirectory": "~/override"}')
        r = self.canary(cwd=repo)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('✗ memory-canary ~/override', r.stdout)
        (repo / '.claude/settings.json').unlink()
        (repo / '.claude/settings.local.json').write_text(f'{{"autoMemoryDirectory": "{self.home}/override"}}')
        r = self.canary(cwd=repo / 'sub')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('✗ memory-canary ~/override', r.stdout)
        # A configured home comes first.
        conf = self.tmp / 'dotfiles/claude/memory-homes.conf'
        conf.parent.mkdir(parents=True)
        conf.write_text(f'notes {self.memory()}\n')
        r = self.canary(cwd=repo)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn('override', r.stdout)

    def test_nothing_to_check_is_an_environment_error(self):
        plain = self.tmp / 'plain'
        plain.mkdir()
        r = self.canary(cwd=plain)
        self.assertEqual(r.returncode, 2)
        self.assertIn('no memory home with a MEMORY.md found', r.stderr)
        self.assertIn(str(self.tmp / 'dotfiles/claude/memory-homes.conf'), r.stderr)
        self.assertIn(str(self.home / '.claude/projects' / encode(plain) / 'memory'), r.stderr)
        self.assertIn('pass --dir', r.stderr)
        self.assertNotIn('identities/', r.stderr)  # no fallback into someone's own layout

    def test_usage_errors(self):
        for args in (['--dir'], ['--dir', '--strict'], ['--dir', str(self.tmp / 'absent')], ['--bogus']):
            with self.subTest(args=args):
                self.assertEqual(self.canary(*args).returncode, 2)
        r = self.canary('--help')
        self.assertEqual(r.returncode, 0)
        self.assertIn('first 200 lines', r.stdout)
        self.assertIn('25,000 characters', r.stdout)
        self.assertIn('memory-canary --dir <path>', r.stdout)

    def test_every_bash_here_parses_it(self):
        # macOS /bin/bash is 3.2, which once could not parse this script at all.
        shells = dict.fromkeys(s for s in (BASH, 'bash', '/bin/bash') if shutil.which(s))
        for shell in shells:
            with self.subTest(shell=shell):
                r = subprocess.run([shell, '-n', str(CANARY)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
