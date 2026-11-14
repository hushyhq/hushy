#!/usr/bin/env python3
"""Paired dev-report comparison. Differences and confidence limits are percentage points."""
import argparse
import json
import math
import random
from pathlib import Path

from pathguard import check


def cases(path):
    report = json.loads(check(path).read_text())
    rows = [c for level in report.get('levels', []) for c in level['cases']] if 'levels' in report else report['cases']
    result = {}
    for row in rows:
        ident = row['id']
        if ident in result:
            raise ValueError(f'duplicate id {ident} in {path}')
        value = row.get('passed', row.get('score'))
        if isinstance(value, bool):
            value = float(value)
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f'case {ident} has no finite passed/score')
        result[ident] = float(value)
    if not result:
        raise ValueError(f'empty report: {path}')
    return result


def paired(candidate, baseline):
    if candidate.keys() != baseline.keys():
        raise ValueError(f'case ids differ: candidate-only {sorted(candidate.keys()-baseline.keys())}; baseline-only {sorted(baseline.keys()-candidate.keys())}')
    return [candidate[k] - baseline[k] for k in sorted(candidate)]


def bootstrap(differences, samples=10000, seed=20260928):
    rng = random.Random(seed)
    n = len(differences)
    means = sorted(sum(differences[rng.randrange(n)] for _ in range(n)) * 100 / n for _ in range(samples))
    return means[int(.025 * samples)], means[min(samples-1, math.ceil(.975 * samples)-1)]


def sign_p(wins, losses):
    n = wins + losses
    if not n:
        return 1.0
    return min(1.0, 2 * sum(math.comb(n, k) for k in range(min(wins, losses)+1)) / 2**n)


def mdd(n, standard_deviation=.5):
    """Approximate 80% two-sided detectable paired mean, pp; conservative Bernoulli SD default."""
    return (1.959964 + .841621) * standard_deviation * 100 / math.sqrt(n)


def verdict(low, high, margin=-2):
    if low > 0:
        return 'better'
    if low > margin:
        return 'non-inferior'
    if high < margin:
        return 'worse'
    return 'inconclusive'


def summarize(differences, margin=-2):
    n = len(differences)
    low, high = bootstrap(differences)
    wins = sum(d > 0 for d in differences)
    losses = sum(d < 0 for d in differences)
    return dict(n=n, wins=wins, losses=losses, ties=n-wins-losses,
                difference=sum(differences)*100/n, ci95=[low, high],
                p_sign=sign_p(wins, losses), mdd80=mdd(n),
                verdict=verdict(low, high, margin), superiority=low > 0)


def compare(pairs, margin=-2):
    results, pooled = {}, []
    for name, candidate, baseline in pairs:
        if name in results:
            raise ValueError(f'duplicate set {name}')
        differences = paired(cases(candidate), cases(baseline))
        results[name] = summarize(differences, margin)
        pooled.extend(differences)
    return {'primary': 'pooled', 'margin_points': margin, 'pooled': summarize(pooled, margin),
            'sets': results, 'note': 'Pooled verdict is primary; per-set verdicts are secondary. Multiple per-set checks increase false discoveries.'}


def table(result):
    lines = ['Set | n | W/L/T | Δ pp | 95% paired CI | sign p | MDD80 pp | verdict',
             '--- | ---: | ---: | ---: | ---: | ---: | ---: | ---']
    for name, row in [('POOLED (primary)', result['pooled']), *result['sets'].items()]:
        lines.append(f"{name} | {row['n']} | {row['wins']}/{row['losses']}/{row['ties']} | {row['difference']:+.2f} | [{row['ci95'][0]:+.2f}, {row['ci95'][1]:+.2f}] | {row['p_sign']:.4g} | {row['mdd80']:.1f} | {row['verdict']}")
    return '\n'.join(lines) + '\n' + result['note']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pair', nargs=3, action='append', metavar=('SET', 'CANDIDATE', 'BASELINE'), required=True)
    parser.add_argument('--margin', type=float, default=-2, help='non-inferiority margin in percentage points')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    result = compare(args.pair, args.margin)
    print(json.dumps(result, indent=2) if args.json else table(result))


if __name__ == '__main__':
    main()
