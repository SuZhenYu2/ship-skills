import hashlib
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


DUEL = pathlib.Path(__file__).resolve().parents[1]


class DuelRunTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = pathlib.Path(temp.name)
        self.root = self.tmp / 'run'
        self.user_home = self.tmp / 'user-codex'
        self.user_home.mkdir()
        catalog = self.user_home / 'catalog.json'
        catalog.write_text('{"models": []}')
        (self.user_home / 'config.toml').write_text(
            f'model = "offline-test"\nmodel_catalog_json = "{catalog}"\n')
        (self.user_home / 'auth.json').write_text('{}')
        self.dev_src = self.tmp / 'dev'
        for name in ('dev-grill-docs', 'dev-fix', 'dev-code-review', 'dev-verify', 'dev-commit'):
            d = self.dev_src / name
            d.mkdir(parents=True)
            (d / 'SKILL.md').write_text(f'---\nname: {name}\ndescription: fixture\n---\n')
        self.bin = self.tmp / 'bin'
        self.bin.mkdir()
        # No real codex is reachable on PATH, even if a stub fails to launch.
        for name in ('bash', 'git', 'dirname', 'basename', 'mkdir', 'cp', 'chmod',
                     'head', 'rm', 'mv', 'mktemp', 'cat', 'sed'):
            (self.bin / name).symlink_to(shutil.which(name))
        (self.bin / 'python3').symlink_to(sys.executable)
        # OS isolation is exercised separately by test_read_sandbox.py.
        for name, script in {
            'sandbox-exec': '#!/bin/sh\nshift 2\nexec "$@"\n',
            'bwrap': '#!/bin/sh\nwhile [ "$1" != "--" ]; do shift; done\nshift\nexec "$@"\n',
        }.items():
            shim = self.bin / name
            shim.write_text(script)
            shim.chmod(0o755)
        fake = self.bin / 'codex'
        fake.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' - "$@" <<\'PY\'\n' + '''
import hashlib, json, os, pathlib, subprocess, sys, time
if sys.argv[1:] == ['--version']:
    print('codex offline stub')
    sys.exit(0)
home = pathlib.Path(os.environ['CODEX_HOME'])
repo = pathlib.Path(sys.argv[sys.argv.index('--cd') + 1])
rd = repo.parent
names = sorted(p.parent.name for p in (home / 'skills').glob('*/SKILL.md')
               if not p.parent.name.startswith(('.', '_')))
(rd / 'observed.json').write_text(json.dumps({'home': str(home), 'names': names,
    'user_home': os.environ['HOME'], 'dirty_history': (home / 'history.jsonl').exists(),
    'config': (home / 'config.toml').read_text(), 'sandbox': sys.argv[sys.argv.index('--sandbox') + 1],
    'dirty_home': (home / 'sessions').exists(), 'prompt': sys.argv[-1], 'start': time.time()}))
(home / 'sessions').mkdir(exist_ok=True)
(home / 'sessions' / 'log.jsonl').write_text(json.dumps({'type': 'skill.invoked', 'name': 'ship-grill'}))
(home / 'history.jsonl').write_text('old history')
if os.getenv('OFFLINE_TIMEOUT'):
    child = 'import pathlib,sys,time; time.sleep(2); pathlib.Path(sys.argv[1]).touch()'
    subprocess.Popen([sys.executable, '-c', child, str(rd / 'late-child')])
    pathlib.Path(sys.argv[sys.argv.index('--output-last-message') + 1]).write_text('stale partial answer')
    (repo / 'stale.txt').write_text('partial work')
    print(json.dumps({'type': 'skill.invoked', 'name': names[0] if names else 'not-installed'}), flush=True)
    time.sleep(20)
time.sleep(0.15)
if os.getenv('OFFLINE_FAIL') == rd.name:
    sys.exit(7)
if os.getenv('OFFLINE_EDIT'):
    (repo / 'committed.txt').write_text('committed change\\n')
    subprocess.run(['git', '-C', str(repo), 'add', 'committed.txt'], check=True)
    subprocess.run(['git', '-C', str(repo), 'commit', '-qm', 'offline edit'], check=True)
    (repo / 'staged.txt').write_text('staged change\\n')
    subprocess.run(['git', '-C', str(repo), 'add', 'staged.txt'], check=True)
    (repo / 'staged.txt').write_text('final working change\\n')
    (repo / 'new file.bin').write_bytes(b'\\x00\\x01')
    (repo / '.gitignore').write_text('ignored.txt\\n')
    (repo / 'ignored.txt').write_text('ignored change\\n')
    (repo / 'orders.py').write_text('final orders change\\n')
    (repo / 'test_orders.py').unlink()
print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message',
    'text': 'ship-grill dev-grill-docs $ship-grill SKILL.md'}}))
if names:
    print(json.dumps({'type': 'agent_message', 'text': {'type': 'skill.invoked', 'name': names[0]}}))
    print(json.dumps({'type': 'skill.discovered', 'name': names[0]}))
print(json.dumps({'type': 'skill.invoked', 'name': 'not-installed'}))
print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 12, 'output_tokens': 3}}))
if names and os.getenv('OFFLINE_EVENT'):
    print(json.dumps({'type': 'skill.invoked', 'name': names[0]}))
index = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--git-path', 'index'], text=True).strip()
index = pathlib.Path(index) if pathlib.Path(index).is_absolute() else repo / index
(rd / 'index-before-capture').write_text(hashlib.sha256(index.read_bytes()).hexdigest())
(rd / 'end').write_text(str(time.time()))
PY
''')
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin),
                        HOME=str(self.tmp), CODEX_HOME=str(self.user_home),
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        self.ok(self.command('setup', '--dev-src', self.dev_src, '--seed', '1'))

    def command(self, script, *args, **env):
        return subprocess.run(['bash', str(DUEL / 'bin' / (script + '.sh')),
                               '--run-root', str(self.root), *map(str, args)],
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=30)

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def read(self, path):
        return json.loads((self.root / path).read_text())

    def freeze(self, *args):
        self.ok(self.command('run', '--tasks', 'T01', '--repeats', '2', '--dry-run', *args))
        return self.read('sealed/allocation.json')

    def test_frozen_matrix_rejects_changed_parameters_and_setup(self):
        matrix = self.freeze()
        self.assertEqual(matrix.get('raters'), ['r1'])
        self.assertEqual(matrix.get('activation_mode'), 'natural')
        for args in (('--tasks', 'T02'), ('--repeats', '1'), ('--raters', 'r2'),
                     ('--activation-mode', 'explicit'), ('--only-code', 'not-allocated')):
            with self.subTest(args=args):
                self.assertNotEqual(self.command('run', '--dry-run', *args).returncode, 0)
        self.assertNotEqual(self.command('setup', '--dev-src', self.dev_src, '--seed', '2').returncode, 0)
        self.ok(self.command('run', '--dry-run'))
        self.assertEqual(self.read('sealed/allocation.json'), matrix)

    def test_parallel_cells_are_isolated_and_worker_failure_is_nonzero(self):
        rows = self.freeze()['runs']
        failed = rows[0]['code']
        arm = rows[0]['arm']
        template = self.root / f'arms/{arm}/home'
        (template / 'sessions').mkdir()
        (template / 'sessions/old.jsonl').write_text('{"type":"skill.invoked","name":"ship-grill"}')
        (template / 'history.jsonl').write_text('old history')
        result = self.command('run', '--jobs', '2', OFFLINE_FAIL=failed)
        self.assertNotEqual(result.returncode, 0)
        seen = [self.read(f'runs/{row["code"]}/observed.json') for row in rows]
        self.assertEqual(len({s['home'] for s in seen}), len(rows))
        self.assertTrue(all(not s['dirty_home'] and not s['dirty_history'] for s in seen))
        self.assertTrue(all(s['user_home'] == s['home'] for s in seen))
        self.assertTrue(all(s['sandbox'] == 'workspace-write' for s in seen))
        self.assertTrue(all(str(pathlib.Path(s['home']) / 'models.json') in s['config'] for s in seen))
        self.assertFalse((self.root / f'runs/{failed}/done').exists())
        self.assertEqual(self.read(f'runs/{failed}/execution.json')['exit_code'], 7)
        self.assertEqual(self.read(f'runs/{failed}/execution.json')['status'], 'failed')
        completed_starts = {row['code']: seen[i]['start'] for i, row in enumerate(rows) if row['code'] != failed}
        self.assertTrue(any(seen[i]['start'] < float((self.root / f'runs/{rows[j]["code"]}/end').read_text())
                            for i in range(1, len(rows)) for j in range(1, i)))
        self.ok(self.command('run', '--jobs', '2'))
        self.assertFalse(self.read(f'runs/{failed}/observed.json')['dirty_home'])
        self.assertTrue((self.root / f'runs/{failed}/done').exists())
        for code, start in completed_starts.items():
            self.assertEqual(self.read(f'runs/{code}/observed.json')['start'], start)

    def test_diff_contains_committed_worktree_and_untracked_binary_without_staging(self):
        code = self.freeze()['runs'][0]['code']
        self.ok(self.command('run', '--only-code', code, OFFLINE_EDIT='1'))
        rd = self.root / 'runs' / code
        patch = (rd / 'diff_after.patch').read_text()
        for expected in ('+committed change', '+final working change', 'new file.bin', 'GIT binary patch'):
            self.assertIn(expected, patch)
        self.assertNotIn('ignored.txt b/ignored.txt', patch)
        self.assertIn('AM staged.txt', (rd / 'git_status_after.txt').read_text())
        index = rd / 'repo/.git/index'
        self.assertEqual(hashlib.sha256(index.read_bytes()).hexdigest(), (rd / 'index-before-capture').read_text())
        status = subprocess.check_output(['git', '-C', str(rd / 'repo'), 'status', '--short'], text=True)
        self.assertIn('AM staged.txt', status)
        self.assertIn('?? "new file.bin"', status)
        # Prove the patch applies to the recorded baseline, not the agent's HEAD.
        applied = self.tmp / 'applied'
        subprocess.run(['git', 'clone', '-q', str(rd / 'repo'), str(applied)], check=True, env=self.env)
        subprocess.run(['git', '-C', str(applied), 'checkout', '-q', (rd / 'baseline_head').read_text().strip()],
                       check=True, env=self.env)
        subprocess.run(['git', '-C', str(applied), 'apply', str(rd / 'diff_after.patch')], check=True, env=self.env)
        self.assertEqual((applied / 'new file.bin').read_bytes(), b'\x00\x01')
        self.assertEqual((applied / 'staged.txt').read_text(), 'final working change\n')
        self.assertEqual((applied / 'orders.py').read_text(), 'final orders change\n')
        self.assertFalse((applied / 'test_orders.py').exists())
        self.assertFalse((applied / 'ignored.txt').exists())

    def test_explicit_prompt_and_structured_evidence_are_separate(self):
        matrix = self.freeze('--activation-mode', 'explicit', '--raters', 'r1,r2')
        self.assertEqual(matrix['raters'], ['r1', 'r2'])
        self.ok(self.command('run', '--jobs', '2'))
        mapping = self.read('sealed/arms.json')['mapping']
        expected = {'ship-skills': 'ship-grill', 'dev-skills': 'dev-grill-docs', 'bare-model': None}
        neutral = (DUEL / 'prompts/T01.md').read_text()
        for row in matrix['runs']:
            code = row['code']
            name = expected[mapping[row['arm']]]
            prompt = self.read(f'runs/{code}/observed.json')['prompt']
            record = self.read(f'runs/{code}/manipulation.json')
            self.assertTrue(record['discovery_ok'])
            self.assertEqual(record['requested_skill'], name)
            self.assertEqual(record['invocation_status'], 'unknown' if name else 'not_applicable')
            if name:
                self.assertIn('$' + name, prompt)
            else:
                self.assertEqual(prompt, neutral)

    def test_only_structured_event_can_confirm_invocation(self):
        self.ok(self.command('run', '--tasks', 'T01', '--repeats', '1', OFFLINE_EVENT='1'))
        for row in self.read('sealed/allocation.json')['runs']:
            code = row['code']
            seen = self.read(f'runs/{code}/observed.json')
            record = self.read(f'runs/{code}/manipulation.json')
            self.assertEqual(seen['prompt'], (DUEL / 'prompts/T01.md').read_text())
            self.assertEqual(record['invoked_skills'], seen['names'][:1])
            self.assertEqual(record['invocation_status'], 'confirmed' if seen['names'] else 'not_applicable')

    def test_changed_installation_template_fails_before_launch(self):
        mapping = self.read('sealed/arms.json')['mapping']
        row = next(row for row in self.freeze()['runs'] if mapping[row['arm']] == 'dev-skills')
        home = self.root / f'arms/{row["arm"]}/home'
        (home / 'skills/dev-grill-docs/SKILL.md').unlink()
        code = row['code']
        self.assertNotEqual(self.command('run', '--only-code', code).returncode, 0)
        self.assertFalse((self.root / f'runs/{code}/observed.json').exists())
        self.assertIs(self.read(f'runs/{code}/manipulation.json')['discovery_ok'], False)

    def test_invalid_parameters_do_not_change_frozen_allocation(self):
        self.freeze()
        frozen = (self.root / 'sealed/allocation.json').read_bytes()
        for args in (('--repeats', '0'), ('--repeats', '-1'), ('--tasks', 'T01,T01'),
                     ('--tasks', 'unknown'), ('--raters', 'r1,r1'), ('--raters', '../r1'),
                     ('--raters', ''), ('--activation-mode', 'other'), ('--jobs', '0'),
                     ('--timeout', '0'), ('--only-code', '../outside')):
            with self.subTest(args=args):
                self.assertNotEqual(self.command('run', '--dry-run', *args).returncode, 0)
                self.assertEqual((self.root / 'sealed/allocation.json').read_bytes(), frozen)
        self.assertEqual(list((self.root / 'runs').iterdir()), [])

    def test_setup_rejects_even_empty_or_symlink_run_root(self):
        original = self.root
        for kind in ('empty', 'symlink'):
            with self.subTest(kind=kind):
                self.root = self.tmp / kind
                if kind == 'empty':
                    self.root.mkdir()
                else:
                    self.root.symlink_to(self.tmp / 'missing')
                result = self.command('setup', '--dev-src', self.dev_src)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'sealed').exists())
        self.root = original

    def test_template_content_and_added_skills_are_preregistered(self):
        mapping = self.read('sealed/arms.json')['mapping']
        row = next(row for row in self.freeze()['runs'] if mapping[row['arm']] == 'dev-skills')
        home = self.root / f'arms/{row["arm"]}/home'
        code = row['code']
        for relative in ('config.toml', 'auth.json', 'models.json', 'skills/dev-fix/SKILL.md'):
            with self.subTest(relative=relative):
                path = home / relative
                original = path.read_bytes()
                path.write_bytes(original + b'\nchanged')
                result = self.command('run', '--only-code', code)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.read(f'runs/{code}/manipulation.json')['discovery_ok'])
                self.assertEqual(self.read(f'runs/{code}/execution.json')['status'], 'preflight_failed')
                self.assertFalse((self.root / f'runs/{code}/observed.json').exists())
                self.assertFalse((self.root / f'runs/{code}/done').exists())
                path.write_bytes(original)
        injected = home / 'skills/injected'
        injected.mkdir()
        (injected / 'SKILL.md').write_text('not registered')
        self.assertNotEqual(self.command('run', '--only-code', code).returncode, 0)
        self.assertFalse(self.read(f'runs/{code}/manipulation.json')['discovery_ok'])
        (injected / 'SKILL.md').unlink()
        injected.rmdir()
        self.ok(self.command('run', '--only-code', code))
        self.assertTrue(self.read(f'runs/{code}/manipulation.json')['discovery_ok'])

    def test_timeout_kills_descendants_and_retry_removes_stale_artifacts(self):
        mapping = self.read('sealed/arms.json')['mapping']
        row = next(row for row in self.freeze()['runs'] if mapping[row['arm']] == 'dev-skills')
        code = row['code']
        rd = self.root / 'runs' / code
        result = self.command('run', '--only-code', code, '--timeout', '1', OFFLINE_TIMEOUT='1')
        self.assertNotEqual(result.returncode, 0)
        record = self.read(f'runs/{code}/execution.json')
        self.assertEqual(record['status'], 'timeout')
        self.assertNotEqual(record['exit_code'], 0)
        self.assertFalse((rd / 'done').exists())
        self.assertTrue((rd / 'final_message.md').exists())
        self.assertEqual(self.read(f'runs/{code}/manipulation.json')['invocation_status'], 'confirmed')
        # Wait beyond the stub child's write deadline to detect orphan workers.
        time.sleep(1.3)
        self.assertFalse((rd / 'late-child').exists())
        self.ok(self.command('run', '--only-code', code))
        self.assertTrue((rd / 'done').exists())
        self.assertFalse((rd / 'final_message.md').exists())
        self.assertFalse((rd / 'repo/stale.txt').exists())
        self.assertFalse(self.read(f'runs/{code}/observed.json')['dirty_home'])
        self.assertEqual(self.read(f'runs/{code}/manipulation.json')['invoked_skills'], [])
        self.assertEqual(self.read(f'runs/{code}/manipulation.json')['invocation_status'], 'unknown')
        self.assertEqual(self.read(f'runs/{code}/execution.json')['token_usage']['total_tokens'], 15)

    def test_unlaunchable_executor_cannot_fall_through_to_another_codex(self):
        code = self.freeze()['runs'][0]['code']
        # An existing but unlaunchable stub must never fall back to a real codex.
        (self.bin / 'codex').write_text('#!/definitely-missing-offline-interpreter\n')
        fallback = self.tmp / 'fallback-bin'
        fallback.mkdir()
        (fallback / 'codex').write_text('#!/bin/sh\nexit 88\n')
        (fallback / 'codex').chmod(0o755)
        result = self.command('run', '--only-code', code, PATH=str(self.bin) + os.pathsep + str(fallback))
        self.assertNotEqual(result.returncode, 0)
        execution = self.read(f'runs/{code}/execution.json')
        self.assertIn(execution['status'], ('launch_failed', 'failed'))
        self.assertNotIn(execution['exit_code'], (0, 88))
        self.assertIn('definitely-missing-offline-interpreter',
                      (self.root / f'runs/{code}/stderr.txt').read_text())
        self.assertFalse((self.root / f'runs/{code}/observed.json').exists())
        self.assertFalse((self.root / f'runs/{code}/done').exists())

    def test_missing_read_sandbox_refuses_model_launch(self):
        code = self.freeze()['runs'][0]['code']
        for backend in ('sandbox-exec', 'bwrap'):
            (self.bin / backend).unlink()
        result = self.command('run', '--only-code', code)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read(f'runs/{code}/execution.json')['status'], 'launch_failed')
        self.assertFalse((self.root / f'runs/{code}/observed.json').exists())
        self.assertFalse((self.root / f'runs/{code}/done').exists())

    def test_explicit_task_mapping_preserves_oracles_and_historical_fixtures(self):
        fixtures = self.tmp / 'fixtures'
        historical = fixtures / 'H01'
        historical.mkdir(parents=True)
        subprocess.run(['git', '-C', str(historical), 'init', '-q'], check=True, env=self.env)
        (historical / 'fixture.txt').write_text('offline historical fixture\n')
        subprocess.run(['git', '-C', str(historical), 'add', 'fixture.txt'], check=True, env=self.env)
        env = dict(self.env, GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                   GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        subprocess.run(['git', '-C', str(historical), 'commit', '-qm', 'offline baseline'], check=True, env=env)
        self.ok(self.command('run', '--tasks', 'T02,T03,T04,T05,T06,H01', '--repeats', '1',
                             '--activation-mode', 'explicit', '--fixtures-dir', fixtures, '--jobs', '3'))
        expected = {
            'T02': ('ship-fix', 'dev-fix'), 'T03': ('ship-review', 'dev-code-review'),
            'T04': ('ship-review', 'dev-code-review'), 'T05': ('ship-commit', 'dev-commit'),
            'T06': ('ship-verify', 'dev-verify'), 'H01': ('ship-fix', 'dev-fix'),
        }
        mapping = self.read('sealed/arms.json')['mapping']
        for row in self.read('sealed/allocation.json')['runs']:
            code, task, suite = row['code'], row['task'], mapping[row['arm']]
            name = None if suite == 'bare-model' else expected[task][0 if suite == 'ship-skills' else 1]
            self.assertEqual(self.read(f'runs/{code}/manipulation.json')['requested_skill'], name)
            if name:
                self.assertIn('$' + name, self.read(f'runs/{code}/observed.json')['prompt'])
            rd = self.root / 'runs' / code
            for artifact in ('baseline_head', 'pre_tree_hash', 'git_status_before.txt', 'diff_before.patch',
                             'git_status_after.txt', 'diff_after.patch', 'git_log_after.txt', 'identity.tsv',
                             'transcript.txt', 'events.jsonl', 'stderr.txt', 'checks.json', 'done'):
                self.assertTrue((rd / artifact).is_file(), (code, artifact))
            checks = self.read(f'runs/{code}/checks.json')
            self.assertEqual(checks['task'], task)
            if task in ('T02', 'T04', 'T06'):
                self.assertTrue((rd / 'repo.oracle.py').is_file())
                self.assertEqual(checks['tests_pass_after'], task == 'T04')
            if task == 'H01':
                self.assertEqual((rd / 'repo/fixture.txt').read_text(), 'offline historical fixture\n')


if __name__ == '__main__':
    unittest.main()
