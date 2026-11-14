import json,sys,os
H=os.environ.get("PRO_WORK") or sys.exit("set PRO_WORK to the work folder (cases/, out/, labels.json)")
src=sys.argv[1]  # combined set name
for v in sys.argv[2:]:
    rows=[json.loads(l) for l in open(f'{H}/out/{v}/{src}.jsonl')]
    by={r['id']:r for r in rows}
    for s in ['never-professional','tones','refusals','founder','heldout60','never-casual','never-prompt','pub','never-default']:
        ids=[json.loads(l)['id'] for l in open(f'{H}/cases/{s}.jsonl')]
        if not all(i in by for i in ids): continue
        open(f'{H}/out/{v}/{s}.jsonl','w').write(''.join(json.dumps(by[i])+'\n' for i in ids))
