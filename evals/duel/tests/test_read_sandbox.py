import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from read_sandbox import isolated_command


class ReadSandboxTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.parent = Path(tmp.name).resolve()
        self.root = self.parent / 'run'
        self.repo = self.root / 'repo'
        self.repo.mkdir(parents=True)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.env = dict(os.environ, CODEX_HOME=str(self.home))

    def test_unsupported_platform_fails_closed(self):
        with patch('read_sandbox.sys.platform', 'unsupported'):
            with self.assertRaisesRegex(ValueError, '禁止无隔离跑批'):
                isolated_command([sys.executable], self.root, self.env)

    def test_shared_home_is_rejected(self):
        with self.assertRaisesRegex(ValueError, '当前 run 内'):
            isolated_command([sys.executable], self.root, dict(self.env, CODEX_HOME=str(self.parent)))

    def test_child_cannot_read_gold_siblings_upstream_or_symlink_targets(self):
        backend = 'sandbox-exec' if sys.platform == 'darwin' else 'bwrap'
        if not shutil.which(backend):
            self.skipTest(f'{backend} unavailable; real runs fail closed')
        outside = []
        for name in ('gold/patch.diff', 'sibling/transcript.txt', 'upstream/source.py'):
            p = self.parent / name
            p.parent.mkdir(parents=True)
            p.write_text('private fixture')
            outside.append(p)
        (self.repo / 'allowed.txt').write_text('allowed fixture')
        (self.repo / 'link').symlink_to(outside[0])
        outside.append(self.repo / 'link')
        code = '''
from pathlib import Path
import os, subprocess, sys
assert Path('allowed.txt').read_text() == 'allowed fixture'
for name in sys.argv[1:]:
    try:
        Path(name).read_text()
    except OSError:
        pass
    else:
        raise AssertionError('outside file readable: ' + name)
    child = subprocess.run([sys.executable, '-I', '-c', 'from pathlib import Path; import sys; Path(sys.argv[1]).read_text()', name], capture_output=True)
    assert child.returncode != 0, 'descendant escaped read restriction'
Path('result.txt').write_text('verified')
assert Path(os.environ['HOME']).is_dir()
'''
        command, env, isolation = isolated_command(
            [sys.executable, '-I', '-c', code, *map(str, outside)], self.root, self.env)
        result = subprocess.run(command, env=env, cwd=self.repo, capture_output=True, text=True, timeout=15)
        if sys.platform.startswith('linux') and result.returncode and 'bwrap:' in result.stderr:
            self.skipTest('bubblewrap unavailable in this host namespace: ' + result.stderr.strip())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.repo / 'result.txt').read_text(), 'verified')
        self.assertEqual(env['HOME'], str(self.home))
        self.assertIn(isolation, ('seatbelt', 'bubblewrap'))


if __name__ == '__main__':
    unittest.main()
