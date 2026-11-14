#!/usr/bin/env python3
"""judge.py make <name> <sets,comma> <variant>...   -> judge/<name>-input.json (blind) + judge/<name>-key.json
   judge.py score <name>                           -> per variant: mean professional score, meaning-kept rate"""
import json,sys,os,random,collections,statistics
H=os.environ.get("PRO_WORK") or sys.exit("set PRO_WORK to the work folder (cases/, out/, labels.json)"); os.makedirs(f'{H}/judge',exist_ok=True)
def rows(v,s):
    c={json.loads(l)['id']:json.loads(l) for l in open(f'{H}/cases/{s}.jsonl')}
    return [(json.loads(l), c[json.loads(l)['id']]) for l in open(f'{H}/out/{v}/{s}.jsonl') if not l.startswith('{"warm')]
if sys.argv[1]=='make':
    name,sets,vs=sys.argv[2],sys.argv[3].split(','),sys.argv[4:]
    rnd=random.Random(20261028); items=[]; key={}
    for s in sets:
        per={v:{r['id']:(r,c) for r,c in rows(v,s)} for v in vs}
        for rid,(r0,c0) in per[vs[0]].items():
            if c0.get('bundle')!='com.apple.mail': continue
            texts=collections.OrderedDict()
            for v in vs:
                texts.setdefault(per[v][rid][0]['text'],[]).append(v)
            cand=list(texts.items()); rnd.shuffle(cand)
            labels='ABCDEFGHIJ'
            items.append({'id':rid,'said':c0['spoken'],'candidates':{labels[i]:t for i,(t,_) in enumerate(cand)}})
            key[rid]={labels[i]:vv for i,(_,vv) in enumerate(cand)}
    rnd.shuffle(items)
    json.dump(items,open(f'{H}/judge/{name}-input.json','w'),indent=1,ensure_ascii=False)
    json.dump(key,open(f'{H}/judge/{name}-key.json','w'),indent=1)
    print(len(items),'items', sum(len(i['candidates']) for i in items),'candidates')
else:
    name=sys.argv[2]; key=json.load(open(f'{H}/judge/{name}-key.json'))
    out=json.load(open(f'{H}/judge/{name}-output.json'))
    pro=collections.defaultdict(list); kept=collections.defaultdict(list); best=collections.Counter(); n=collections.Counter()
    for o in out:
        k=key[o['id']]
        for lab,g in o['ratings'].items():
            for v in k[lab]:
                pro[v].append(g['professional']); kept[v].append(g['meaning_kept'])
        for v in set(sum(k.values(),[])): n[v]+=1
        for lab in o.get('best',[]):
            for v in k.get(lab,[]): best[v]+=1
    for v in sorted(pro):
        print(f"| {v} | {len(pro[v])} | {statistics.mean(pro[v]):.2f} | {sum(x>=4 for x in pro[v])} | {sum(kept[v])}/{len(kept[v])} | {best[v]} |")
