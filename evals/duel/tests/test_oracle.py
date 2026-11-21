import json
from pathlib import Path
import subprocess
import tempfile
import unittest


DUEL = Path(__file__).resolve().parents[1]


class OracleTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.repo = self.root / 'repo'

    def shell(self, script, task):
        return subprocess.run(
            ['/bin/bash', '-c', 'source "$1/lib/common.sh"; source "$1/lib/tasks.sh"; ' + script,
             'oracle-test', str(DUEL), task, str(self.repo), str(self.root)],
            check=True, capture_output=True, text=True, timeout=12,
        ).stdout

    def build(self, task):
        self.shell('build_task "$2" "$3"', task)

    def write(self, name, text):
        (self.repo / name).write_text(text, encoding='utf-8')

    def facts(self, task):
        return json.loads(self.shell(
            'mechanical_check "$2" "$3" "$4" "$(git -C "$3" rev-parse HEAD)" unused', task,
        ))

    def test_t02_deleting_tests_does_not_hide_broken_defaults(self):
        self.build('T02')
        (self.repo / 'test_refund.py').unlink()
        facts = self.facts('T02')
        self.assertFalse(facts['tests_pass_after'], facts)

    def test_t02_downstream_fallback_does_not_fix_field_contract(self):
        self.build('T02')
        self.write('refund.py', 'def calculate_refund(order):\n'
                   '    return order["amount"] - (order["discount"] or 0)\n')
        facts = self.facts('T02')
        self.assertTrue(facts['downstream_only_fix'], facts)
        self.assertFalse(facts['tests_pass_after'], facts)

    def test_t02_upstream_fix_passes_without_discovering_repo_tests(self):
        self.build('T02')
        self.write('pricing.py', 'def create_order(amount, discount=None):\n'
                   '    return {"amount": amount, "discount": 0 if discount is None else discount}\n')
        self.write('test_refund.py', 'raise RuntimeError("must not discover workspace tests")\n')
        facts = self.facts('T02')
        self.assertTrue(facts['tests_pass_after'], facts)

    def test_t04_reverted_discount_fails_even_though_status_is_200(self):
        self.build('T04')
        self.assertTrue(self.facts('T04')['tests_pass_after'])
        self.write('api.py', 'def checkout(amount, discount):\n'
                   '    return {"status": 200, "total": amount - 2 * discount}\n')
        facts = self.facts('T04')
        self.assertFalse(facts['tests_pass_after'], facts)

    def test_t06_skipping_tests_does_not_hide_boundary_bug(self):
        self.build('T06')
        self.write('test_gateway.py', 'import unittest\nraise unittest.SkipTest("skip gate")\n')
        facts = self.facts('T06')
        self.assertFalse(facts['tests_pass_after'], facts)
        self.assertIn('1024', facts['tests_tail'])

    def test_t06_local_stub_does_not_supply_the_required_dependency(self):
        self.build('T06')
        self.write('gateway.py', 'def within_limit(size):\n    return size <= 1024\n')
        self.write('external_gateway_sdk.py', 'def check(size):\n    return True\n')
        facts = self.facts('T06')
        self.assertFalse(facts['tests_pass_after'], facts)
        self.assertIn('external_gateway_sdk', facts['tests_tail'])

    def test_zero_exit_before_assertions_is_not_a_pass(self):
        self.build('T04')
        self.write('api.py', 'raise SystemExit(0)\n')
        facts = self.facts('T04')
        self.assertFalse(facts['tests_pass_after'], facts)

    def test_nonterminating_candidate_reports_timeout(self):
        self.build('T04')
        self.write('api.py', 'while True:\n    pass\n')
        facts = self.facts('T04')
        self.assertFalse(facts['tests_pass_after'], facts)
        self.assertIn('timeout', facts['tests_tail'])

    def test_replaced_prebuilt_oracle_cannot_report_a_pass(self):
        self.build('T04')
        oracle = self.repo.with_suffix('.oracle.py')
        self.assertTrue(oracle.is_file())
        self.assertFalse((self.repo / oracle.name).exists())
        oracle.chmod(0o600)
        oracle.write_text('print("oracle passed")\n', encoding='utf-8')
        facts = self.facts('T04')
        self.assertFalse(facts['tests_pass_after'], facts)
