#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ship-arena-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
import json
import pathlib
import subprocess
import sys
import unittest

root, temp = map(pathlib.Path, sys.argv[1:])

class ArenaTests(unittest.TestCase):
    def setUp(self):
        self.repo = temp / self._testMethodName
        self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.script = root / 'scripts/arena-state.sh'

    def run_state(self, *args, ok=True):
        result = subprocess.run(['bash', str(self.script), '--repo', str(self.repo), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_default_off_without_writing(self):
        self.assertIn('OFF', self.run_state('--task', 'order-cancel', 'status'))
        self.assertFalse((self.repo / '.ship').exists())

    def test_on_off_roundtrip_and_isolation(self):
        self.assertIn('ON', self.run_state('--task', 'order-cancel', 'on'))
        path = self.repo / '.ship/tasks/order-cancel/arena.json'
        self.assertEqual(json.loads(path.read_text()), dict(version=1, enabled=True, policy='selective', candidates=2))
        self.assertIn('OFF', self.run_state('--task', 'other', 'status'))
        self.assertIn('OFF', self.run_state('--task', 'order-cancel', 'off'))
        self.assertFalse(json.loads(path.read_text())['enabled'])
        status = subprocess.run(['git', '-C', str(self.repo), 'status', '--porcelain'], capture_output=True, text=True, check=True).stdout
        self.assertEqual(status, '')

    def test_missing_or_unsafe_task_rejected(self):
        self.run_state('on', ok=False)
        for task in ['../escape', '/tmp/escape', 'Upper', '.', '']:
            self.run_state('--task', task, 'on', ok=False)
        self.assertFalse((self.repo / '.ship').exists())

    def test_invalid_config_is_not_silent_off(self):
        self.run_state('--task', 'test', 'on')
        path = self.repo / '.ship/tasks/test/arena.json'
        for content in ['{', 'null', '[]', '{"version":1,"enabled":"false","policy":"selective","candidates":2}', '{"version":2,"enabled":true,"policy":"selective","candidates":2}']:
            path.write_text(content)
            self.run_state('--task', 'test', 'status', ok=False)
            self.run_state('--task', 'test', 'on', ok=False)
            self.assertEqual(path.read_text(), content)

    def test_stage_banner_is_plan_not_execution_claim(self):
        self.run_state('--task', 'test', 'on')
        out = self.run_state('--task', 'test', 'status', '--stage', 'ship-plan')
        self.assertIn('ship-plan', out)
        self.assertIn('ON', out)
        self.assertIn('计划策略', out)
        self.assertIn('双候选', out)
        out = self.run_state('--task', 'test', 'status', '--stage', 'ship-commit')
        self.assertIn('Lead', out)
        self.run_state('--task', 'test', 'status', '--stage', 'unknown', ok=False)

    def test_symlink_escape_rejected(self):
        outside = temp / (self._testMethodName + '-outside')
        outside.mkdir()
        (self.repo / '.ship').symlink_to(outside, target_is_directory=True)
        self.run_state('--task', 'test', 'on', ok=False)
        self.assertEqual(list(outside.iterdir()), [])

    def test_installed_script_and_stage_hooks(self):
        installed = temp / 'installed'
        subprocess.run(['bash', str(root / 'scripts/install.sh'), '--target', 'codex', '--codex-dir', str(installed)], check=True, capture_output=True)
        skills = list(installed.glob('ship-*'))
        self.assertEqual(len(skills), 11)
        for skill in skills:
            text = (skill / 'SKILL.md').read_text()
            self.assertIn('references/arena-policy.md', text)
            self.assertIn('scripts/arena-state.sh', text)
            self.assertTrue((skill / 'references/arena-policy.md').is_file())
        self.script = installed / 'ship-arena/scripts/arena-state.sh'
        self.assertIn('ON', self.run_state('--task', 'installed', 'on'))
        self.assertIn('OFF', self.run_state('--task', 'other', 'status'))

    def test_worktree_supported(self):
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'baseline'], check=True)
        worktree = temp / 'linked-worktree'
        subprocess.run(['git', '-C', str(self.repo), 'worktree', 'add', '-qb', 'test-arena', str(worktree)], check=True, capture_output=True)
        self.repo = worktree
        self.assertIn('ON', self.run_state('--task', 'linked', 'on'))
        self.assertIn('ON', self.run_state('--task', 'linked', 'status'))

    def test_non_git_target_rejected(self):
        other = temp / 'non-git'
        other.mkdir()
        result = subprocess.run(['bash', str(self.script), '--repo', str(other), '--task', 'test', 'on'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((other / '.ship').exists())

unittest.main(argv=['arena-state'], verbosity=2)
PY
