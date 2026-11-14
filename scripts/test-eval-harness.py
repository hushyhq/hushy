#!/usr/bin/env python3
"""Offline CLI contract checks; run after building murmur-eval in release mode."""
import os
import json
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
binary = root / '.build/release/murmur-eval'
with tempfile.TemporaryDirectory(prefix='murmur-eval-contract-') as folder:
    work = Path(folder)
    # Keep smoke-test result logging out of the repository's measured baseline.
    (work / 'Evals').mkdir()
    fixture = work / 'golden.json'
    report = work / 'report.json'

    def run(cases, *flags):
        fixture.write_text(json.dumps(cases))
        report.unlink(missing_ok=True)
        return subprocess.run(
            [str(binary), 'cleanup', '--strategy', 'rules', '--golden', str(fixture),
             '--report', str(report), *flags], cwd=root, capture_output=True, text=True,
            timeout=30, env={**os.environ, "MURMUR_EVAL_HOME": str(work / "Evals")},
        )

    good = dict(id='enter', tag='command', spoken='Sounds good. Press enter.',
                expected='Sounds good.', expectedPressEnter=True)
    # GoldenReport requires repository provenance; log assertions are synthetic contract checks.
    result = run([good], '--min-pass', '1', '--require-tags', 'command')
    assert result.returncode == 0, result.stderr
    assert json.loads(report.read_text())['passed'] == 1
    bad = dict(good, expectedPressEnter=False)
    result = run([bad], '--min-pass', '1')
    assert result.returncode != 0
    evidence = json.loads(report.read_text())
    assert evidence['passed'] == 0 and evidence['cases'][0]['pressEnter'] is True
    assert evidence['goldenSHA256'] and evidence['gitRevision']
    result = run([good], '--require-tags', 'safety')
    assert result.returncode != 0
    result = run([good], '--min-pass', 'bogus')
    assert result.returncode != 0
    result = run([])
    assert result.returncode != 0
    result = run([good, good])
    assert result.returncode != 0
    exact = dict(id='exact', tag='safety', spoken='hello world', expected='hello world', exactText=True)
    result = run([exact], '--min-pass', '1')
    assert result.returncode != 0  # Rules capitalize; exact spelling checks must catch that.
print('Eval CLI contract checks passed (including expected failure exits).')
