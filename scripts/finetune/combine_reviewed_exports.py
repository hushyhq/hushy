#!/usr/bin/env python3
"""Merge immutable reviewed runtime exports, removing exact conversation duplicates.
No prompt/target generation. Fail on source hash drift, split leaks or conflicting targets.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sealed_guard import assert_tuning_safe


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', action='append', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    output = Path(args.out).resolve()
    assert_tuning_safe(output, purpose='reviewed training merge output')
    allowed = (Path.cwd() / '.build/finetune').resolve()
    if not output.is_relative_to(allowed) or output.exists():
        raise ValueError('new output beneath .build/finetune required')
    inputs, seen, draft_split, answers, id_payloads = {}, {}, {}, {}, {}
    rows, duplicates = {'train': [], 'valid': []}, []
    for source in args.source:
        source = Path(source).resolve()
        manifest_path = source / 'export.json'
        assert_tuning_safe(manifest_path, purpose='reviewed export manifest')
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
        inputs[str(manifest_path)] = sha(manifest_bytes)
        for split in rows:
            path = source / (split + '.jsonl')
            assert_tuning_safe(path, purpose='reviewed export split')
            data = path.read_bytes()
            if manifest['outputsSHA256'][path.name] != sha(data):
                raise ValueError('reviewed split hash changed')
            inputs[str(path)] = sha(data)
            for line in data.decode().splitlines():
                row = json.loads(line)
                messages = row['messages']
                if [m['role'] for m in messages] != ['system', 'user', 'assistant']:
                    raise ValueError('reviewed runtime conversation required')
                key = json.dumps(messages, sort_keys=True, ensure_ascii=False)
                if not isinstance(row.get('id'), str) or not row['id']:
                    raise ValueError('nonempty reviewed row ID required')
                if row['id'] in id_payloads and id_payloads[row['id']] != key:
                    raise ValueError('one row ID names different conversations')
                id_payloads[row['id']] = key
                draft = json.dumps(messages[:-1], sort_keys=True, ensure_ascii=False)
                answer = messages[-1]['content']
                if draft in draft_split and draft_split[draft] != split:
                    raise ValueError('identical runtime prompt crosses split')
                if draft in answers and answers[draft] != answer:
                    raise ValueError('conflicting targets for identical runtime prompt')
                draft_split[draft], answers[draft] = split, answer
                if key in seen:
                    duplicates.append({'removed': row['id'], 'retained': seen[key]})
                else:
                    seen[key] = row['id']
                    rows[split].append(row)
    if not all(rows.values()):
        raise ValueError('nonempty splits required')
    output.mkdir(parents=True)
    for split, values in rows.items():
        (output / (split + '.jsonl')).write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in values))
    manifest = {'schemaVersion': 1, 'sourceManifestsAndSplitsSHA256': inputs,
                'outputSHA256': {s + '.jsonl': sha((output / (s + '.jsonl')).read_bytes()) for s in rows},
                'counts': {s: len(v) for s, v in rows.items()}, 'removedExactDuplicates': duplicates,
                'method': 'Merge reviewed runtime exports; retain first exact conversation; forbid split leakage and conflicting targets. Synthetic scaffolding remains; not population quality evidence.'}
    (output / 'derivation.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'counts': manifest['counts'], 'removedDuplicates': len(duplicates)}))


if __name__ == '__main__':
    main()
