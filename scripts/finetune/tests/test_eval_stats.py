import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compare_runs as stats
import judge_consistency
import split_dev
import split_report


class StatsTests(unittest.TestCase):
    def test_bootstrap_fixed_and_paired(self):
        self.assertEqual(stats.bootstrap([1] * 8), (100, 100))
        self.assertEqual(stats.bootstrap([0, 1, -1]), stats.bootstrap([0, 1, -1]))

    def test_sign_exact(self):
        self.assertEqual(stats.sign_p(8, 0), 2 / 256)
        self.assertEqual(stats.sign_p(0, 0), 1)
        self.assertEqual(stats.sign_p(3, 3), 1)

    def test_mdd_and_verdict(self):
        self.assertAlmostEqual(stats.mdd(100), 14.007925, places=4)
        self.assertEqual(stats.verdict(1, 4), 'better')
        self.assertEqual(stats.verdict(-1, 4), 'non-inferior')
        self.assertEqual(stats.verdict(-4, -3), 'worse')
        self.assertEqual(stats.verdict(-3, 2), 'inconclusive')

    def test_pooled_table_and_mismatch(self):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for name, a, b in [('one', [True, True], [False, True]), ('two', [False, True], [True, False])]:
                ca, ba = Path(d)/f'{name}-c.json', Path(d)/f'{name}-b.json'
                ca.write_text(json.dumps({'cases': [{'id': str(i), 'passed': v} for i, v in enumerate(a)]}))
                ba.write_text(json.dumps({'levels': [{'cases': [{'id': str(i), 'passed': v} for i, v in enumerate(b)]}]}))
                paths.append((name, ca, ba))
            result = stats.compare(paths)
            self.assertEqual(result['pooled']['n'], 4)
            self.assertAlmostEqual(result['pooled']['difference'], 25)
            self.assertIn('POOLED (primary)', stats.table(result))
            self.assertIn('one', stats.table(result))
            with self.assertRaises(ValueError):
                stats.paired({'a': 1}, {'b': 1})

    def test_split_stability_and_aggregate_only(self):
        rows = [{'id': str(i), 'category': 'x'} for i in range(40)]
        first = split_dev.partition(rows)
        second = split_dev.partition(rows + [{'id': 'new', 'category': 'x'}])
        for part in ('gate', 'diagnose'):
            self.assertEqual(first[part], [x for x in second[part] if x != 'new'])
        report = {'cases': [{'id': str(i), 'passed': True, 'input': 'secret'} for i in range(40)]}
        diagnose, gate = split_report.split_report(report, first)
        self.assertNotIn('cases', gate)
        self.assertNotIn('secret', json.dumps(gate))
        self.assertEqual(diagnose['total'] + gate['total'], 40)

    def test_judge_agreement_and_mocked_calls(self):
        rows = [[{'jevFaults': {'dropped_content': .7}}], [{'jevFaults': {'dropped_content': .1}}]]
        self.assertEqual(judge_consistency.agreement(rows)['dropped_content']['flip_rate'], 1)
        with patch.object(judge_consistency.subprocess, 'run') as call:
            with tempfile.TemporaryDirectory() as d:
                out = Path(d)/'output-0.jsonl'
                out.write_text(json.dumps(rows[0][0])+'\n')
                judged = judge_consistency.grade([{'spoken':'x'}], 0, Path('fake-eval'), Path(d))
                self.assertEqual(judged, rows[0])
                self.assertIn('--no-cache', call.call_args.args[0])


if __name__ == '__main__':
    unittest.main()
