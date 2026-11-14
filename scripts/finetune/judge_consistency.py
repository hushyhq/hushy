#!/usr/bin/env python3
"""Repeat Jev grading of identical dev outputs and measure rubric flips.

Use a fresh judge cache directory per repetition (Jev's normal cache would hide flips).
"""
import argparse
import json
import os
import subprocess
import tempfile
from collections import defaultdict
from pathlib import Path

from pathguard import check


def grade(rows, repetition, eval_bin, workdir):
    source = workdir / f'input-{repetition}.jsonl'
    output = workdir / f'output-{repetition}.jsonl'
    source.write_text(''.join(json.dumps(r) + '\n' for r in rows))
    subprocess.run([str(eval_bin), 'finetune', 'jev', '--in', str(source), '--out', str(output),
                    '--no-cache', '--max-calls', str(len(rows)), '--cap', str(len(rows)), '--spoken-key', 'spoken',
                    '--output-key', 'output', '--reference-key', 'reference', '--label', 'judge-consistency'],
                   check=True, stdout=subprocess.DEVNULL)
    return [json.loads(line) for line in output.read_text().splitlines()]


def agreement(repetitions, threshold=.6):
    if len(repetitions) < 2 or any(len(r) != len(repetitions[0]) for r in repetitions):
        raise ValueError('need at least two equally sized repetitions')
    items = defaultdict(lambda: [0, 0])
    keys = set().union(*(set((row.get('jevFaults') or {})) for run in repetitions for row in run))
    for key in keys:
        for index in range(len(repetitions[0])):
            flags = [float((r[index].get('jevFaults') or {}).get(key, 0)) >= threshold for r in repetitions]
            items[key][0] += int(all(f == flags[0] for f in flags))
            items[key][1] += 1
    return {key: {'agreement': same/total, 'flip_rate': 1-same/total, 'cases': total}
            for key, (same, total) in sorted(items.items())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--in', dest='source', type=Path, required=True, help='dev JSONL with spoken/output/reference/level')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--sample', type=int, default=20)
    parser.add_argument('--eval-bin', type=Path, default=Path('.build/release/murmur-eval'))
    args = parser.parse_args()
    if args.repeats < 2:
        parser.error('--repeats must be at least 2')
    rows = [json.loads(line) for line in check(args.source).read_text().splitlines() if line.strip()][:args.sample]
    if not rows:
        parser.error('empty sample')
    with tempfile.TemporaryDirectory(prefix='judge-consistency-') as directory:
        results = [grade(rows, i, args.eval_bin, Path(directory)) for i in range(args.repeats)]
    print(json.dumps({'sample': len(rows), 'repeats': args.repeats, 'rubric': agreement(results)}, indent=2))


if __name__ == '__main__':
    main()
