import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BIN = Path(__file__).resolve().parents[1] / 'bin'
IDS = 'G1 G2 G3 G4 A1 A2 A3'.split()
QUOTE = '执行记录：已记录检查结果。'


class IntegrityTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / 'rater/home').mkdir(parents=True)
        self.runs = [{'code': 'R1', 'arm': 'A', 'task': 'T01', 'repeat': 1}]
        self.allocate()
        self.put('sealed/arms.json', {'mapping': {'A': 'suite-a'}})
        self.run_artifacts('R1')
        self.blind_key()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
        return path

    def put(self, name, value):
        return self.write(name, json.dumps(value, ensure_ascii=False))

    def allocate(self, **fields):
        self.put('sealed/allocation.json', {'runs': self.runs, **fields})

    def run_artifacts(self, code, status='ok', exit_code=0, discovery=True):
        self.write(f'runs/{code}/done', '')
        self.put(f'runs/{code}/execution.json', {'status': status, 'exit_code': exit_code,
                                                  'wall_seconds': 1, 'token_usage': {'total_tokens': 2}})
        self.put(f'runs/{code}/manipulation.json', {'discovery_ok': discovery})
        self.write(f'blind/{code}/packet.md', f'# 匿名材料\n\n{QUOTE}\n')

    def blind_key(self):
        self.write('sealed/blind_key.jsonl', ''.join(
            json.dumps({k: row[k] for k in ('code', 'arm', 'task')}) + '\n' for row in self.runs
        ))

    def rating(self, value=1):
        return {'outcome': 'completed', 'summary': '', 'items': [
            {'id': i, 'score': value, 'evidence': QUOTE if value else ''} for i in IDS
        ]}

    def cli(self, script, *args, **kwargs):
        return subprocess.run(['bash', str(BIN / script), '--run-root', str(self.root), *args],
                              capture_output=True, text=True, timeout=10, **kwargs)

    def reject_lock(self, message):
        result = self.cli('summarize.sh', '--lock')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertNotIn('suite-a', result.stdout + result.stderr)
        self.assertFalse((self.root / 'sealed/scores.lock').exists())
        self.assertFalse((self.root / 'report.md').exists())

    def test_missing_packet_does_not_shrink_allocation(self):
        (self.root / 'blind/R1/packet.md').unlink()
        self.reject_lock('packet.md')

    def test_unfinished_allocation_requires_explicit_exclusion(self):
        (self.root / 'runs/R1/done').unlink()
        self.reject_lock('done')

    def test_all_declared_raters_must_score(self):
        self.allocate(raters=['r1', 'r2'])
        self.put('scores/r1/R1.json', self.rating())
        self.reject_lock('r2')

    def test_undeclared_rating_is_rejected(self):
        for rater in ('r1', 'r2'):
            self.put(f'scores/{rater}/R1.json', self.rating())
        self.reject_lock('r2')

    def test_extra_packet_is_rejected(self):
        self.write('blind/OTHER/packet.md', QUOTE)
        self.put('scores/r1/R1.json', self.rating())
        self.put('scores/r1/OTHER.json', self.rating())
        self.reject_lock('OTHER')

    def test_unallocated_run_directory_is_rejected(self):
        self.write('runs/OTHER/done', '')
        self.put('scores/r1/R1.json', self.rating())
        self.reject_lock('OTHER')

    def test_duplicate_or_mismatched_blind_key_is_rejected(self):
        self.put('scores/r1/R1.json', self.rating())
        for rows in ([self.runs[0], self.runs[0]], [{**self.runs[0], 'task': 'T02'}]):
            with self.subTest(rows=rows):
                self.write('sealed/blind_key.jsonl', '\n'.join(map(json.dumps, rows)))
                self.reject_lock('blind_key')

    def test_invalid_scores_are_rejected_even_if_written_by_hand(self):
        for change in ({'id': 'G2'}, {'id': 'B1'}, {'score': True}, {'evidence': '改写的引文'},
                       {'evidence': ' '}, {'score': 0, 'evidence': '改写的引文'}):
            with self.subTest(change=change):
                data = self.rating()
                data['items'][0].update(change)
                self.put('scores/r1/R1.json', data)
                self.reject_lock('r1/R1.json')

    def test_excluded_run_cannot_contribute_a_score(self):
        self.run_artifacts('R1', exit_code=2)
        self.put('scores/r1/R1.json', self.rating())
        self.reject_lock('r1/R1.json')

    def test_scorer_only_calls_model_for_eligible_runs_and_checks_output(self):
        for code, fields in [('R2', {'exit_code': 7}), ('R3', {'status': 'timeout'}),
                             ('R4', {'discovery': 1}), ('R5', {})]:
            self.runs.append({'code': code, 'arm': 'A', 'task': 'T01', 'repeat': len(self.runs) + 1})
            self.run_artifacts(code, **fields)
        (self.root / 'runs/R5/done').unlink()
        self.allocate()
        data = self.rating()
        data['items'].pop()
        self.put('bad-rating.json', data)
        fake = self.write('mock-bin/codex', f'#!{sys.executable}\n' +
                          'import os, pathlib, sys\n'
                          'args = sys.argv\n'
                          'code = pathlib.Path(args[args.index("--cd") + 1]).name\n'
                          'root = pathlib.Path(os.environ["CODEX_HOME"]).parents[1]\n'
                          'with (root / "calls").open("a") as f: f.write(code + "\\n")\n'
                          'pathlib.Path(args[args.index("--output-last-message") + 1]).write_bytes('
                          '(root / "bad-rating.json").read_bytes())\n')
        fake.chmod(0o755)
        env = dict(os.environ, PATH=f'{fake.parent}{os.pathsep}{os.environ["PATH"]}')
        (self.root / 'sealed/arms.json').unlink()
        (self.root / 'sealed/blind_key.jsonl').unlink()
        result = self.cli('score.sh', env=env)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['R1'])
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / 'scores/r1/R1.json').exists())
        self.put('bad-rating.json', self.rating())
        result = self.cli('score.sh', env=env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue((self.root / 'scores/r1/R1.json').is_file())

    def test_report_discloses_invalid_runs_and_counts_runs_not_raters(self):
        for code, repeat in [('R2', 2), ('R3', 3)]:
            self.runs.append({'code': code, 'arm': 'A', 'task': 'T01', 'repeat': repeat})
            self.run_artifacts(code, discovery=code != 'R3')
        self.allocate(raters=['r1', 'r2'])
        self.blind_key()
        for rater in ('r1', 'r2'):
            self.put(f'scores/{rater}/R1.json', self.rating(value=int(rater == 'r1')))
            self.put(f'scores/{rater}/R2.json', self.rating())
        result = self.cli('summarize.sh', '--lock')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.root / 'report.md').read_text(encoding='utf-8')
        self.assertIn('0.75（n=2/3）', report)
        self.assertIn('R3', report)
        self.assertIn('discovery_ok', report)

    def test_lock_detects_changes_and_cannot_be_replaced_with_lock_flag(self):
        self.put('scores/r1/R1.json', self.rating())
        result = self.cli('summarize.sh', '--lock')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.cli('summarize.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.root / 'report.md').read_bytes()
        lock = (self.root / 'sealed/scores.lock').read_bytes()
        for name in ('blind/R1/packet.md', 'scores/r1/R1.json', 'sealed/allocation.json',
                     'sealed/arms.json', 'sealed/blind_key.jsonl', 'runs/R1/manipulation.json'):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(original + b'\n')
                for args in ((), ('--lock',)):
                    result = self.cli('summarize.sh', *args)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('摘要', result.stderr)
                    self.assertNotIn('suite-a', result.stdout + result.stderr)
                    self.assertEqual((self.root / 'report.md').read_bytes(), report)
                    self.assertEqual((self.root / 'sealed/scores.lock').read_bytes(), lock)
                path.write_bytes(original)

    def test_all_invalid_can_lock_without_blind_packets_or_scores(self):
        self.put('runs/R1/manipulation.json', {'treatment_applied': True})
        (self.root / 'blind/R1/packet.md').unlink()
        (self.root / 'sealed/blind_key.jsonl').unlink()
        result = self.cli('summarize.sh', '--lock')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('—（n=0/1）', result.stdout)
        self.assertIn('manipulation.discovery_ok 非 true', result.stdout)


if __name__ == '__main__':
    unittest.main()
