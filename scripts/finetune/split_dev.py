#!/usr/bin/env python3
"""Stable, category-stratified dev split. Output contains IDs only."""
import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

from pathguard import check_dev_set, check


def partition(rows):
    groups = defaultdict(list)
    seen = set()
    for row in rows:
        ident = row['id']
        if ident in seen:
            raise ValueError(f'duplicate id {ident}')
        seen.add(ident)
        group = str(row.get('category', row.get('bucket', row.get('tag', row.get('group', 'all')))))
        groups[group].append(ident)
    diagnose, gate = [], []
    for group, ids in groups.items():
        for ident in ids:
            fraction = int.from_bytes(hashlib.sha256(ident.encode()).digest()[:8], 'big') / 2**64
            (gate if fraction < .30 else diagnose).append(ident)
    return {'diagnose': sorted(diagnose), 'gate': sorted(gate)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sets', nargs='+', type=Path, help='allowlisted dev JSON files')
    parser.add_argument('--out-dir', type=Path, default=Path('Evals/splits'))
    args = parser.parse_args()
    out = check(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for path in args.sets:
        rows = json.loads(check_dev_set(path).read_text())
        rows = rows['cases'] if isinstance(rows, dict) else rows
        split = partition(rows)
        target = check(out / path.name)
        target.write_text(json.dumps(split, indent=2) + '\n')
        print(f'{target}: diagnose={len(split["diagnose"])} gate={len(split["gate"])}')


if __name__ == '__main__':
    main()
