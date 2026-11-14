#!/usr/bin/env python3
"""Partition a dev report; gate output contains aggregates only."""
import argparse
import json
from pathlib import Path
from pathguard import check


def split_report(report, split):
    def section(rows, selected, include_cases):
        kept = [c for c in rows if c['id'] in selected]
        result = {'total': len(kept), 'passed': sum(bool(c.get('passed')) for c in kept)}
        if include_cases:
            result['cases'] = kept
        return result
    rows = [c for level in report.get('levels', []) for c in level['cases']] if 'levels' in report else report['cases']
    if {c['id'] for c in rows} != set(split['diagnose']) | set(split['gate']):
        raise ValueError('report and split IDs differ')
    return section(rows, set(split['diagnose']), True), section(rows, set(split['gate']), False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    parser.add_argument('split', type=Path)
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    diagnose, gate = split_report(json.loads(check(args.report).read_text()), json.loads(check(args.split).read_text()))
    out = check(args.out)
    (out / 'diagnose').mkdir(parents=True, exist_ok=True)
    (out / 'gate').mkdir(parents=True, exist_ok=True)
    (out / 'diagnose' / args.report.name).write_text(json.dumps(diagnose, indent=2) + '\n')
    (out / 'gate' / args.report.name).write_text(json.dumps(gate, indent=2) + '\n')
    print(f'{args.report.stem}: diagnose {diagnose["passed"]}/{diagnose["total"]}; gate {gate["passed"]}/{gate["total"]}')


if __name__ == '__main__':
    main()
