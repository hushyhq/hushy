#!/usr/bin/env python3
"""score.py todo <variant> <set> [regex]   unlabeled (spoken, answer) pairs, numbered
   score.py label <variant> <set> 'M:1-3,5' 'V:4' [D:F]   label the todo list (F fine, M meaning, V name/number)
   score.py table <set> <variant>...     one table row per variant
   score.py diff <set> <va> <vb>         pasted text that differs"""
import json,sys,re,os,statistics
H=os.environ.get("PRO_WORK") or sys.exit("set PRO_WORK to the work folder (cases/, out/, labels.json)")
LP=f'{H}/labels.json'
def store(): return json.load(open(LP))
def norm(t): return re.sub(r'[^a-z0-9 ]','',t.lower()).split()
def rows(v,s):
    c={json.loads(l)['id']:json.loads(l) for l in open(f'{H}/cases/{s}.jsonl')}
    out=[]
    for l in open(f'{H}/out/{v}/{s}.jsonl'):
        r=json.loads(l)
        if r['id'].startswith('warm-'): continue
        r['case']=c[r['id']]
        ans=[]
        for a in r['modelAnswers']:
            try: ans.append(json.loads(a)['text'])
            except Exception: ans.append(a)
        r['first']=ans[0] if ans else r['text']
        r['refused']=any(g['registerDropped'] or g['outcome']!='used' for g in r['stages'])
        r['drafted']=any(g['outcome']!='used' for g in r['stages'])
        r['second']=len(r['modelAnswers'])>=2
        out.append(r)
    return out
def key(r,t): return r['case']['spoken']+'\t'+t
def label(L,r,t):
    if norm(t)==norm(r['case']['spoken']): return 'fine'
    return L.get(key(r,t))
def todo_pairs(v,s,rx=None):
    L=store(); seen=[]; 
    for r in rows(v,s):
        if rx and not re.search(rx,r['id']): continue
        for t in ([r['first']] + ([r['text']] if r['refused'] else [])):
            if label(L,r,t) is None and (r['case']['spoken'],t) not in [(a['case']['spoken'],b) for a,b in seen]:
                seen.append((r,t))
    return seen
def main():
    cmd=sys.argv[1]
    if cmd=='todo':
        pairs=todo_pairs(sys.argv[2],sys.argv[3],sys.argv[4] if len(sys.argv)>4 else None)
        json.dump([key(r,t) for r,t in pairs],open(f'{H}/todo-{sys.argv[2]}-{sys.argv[3]}.json','w'))
        for n,(r,t) in enumerate(pairs,1):
            print(f"{n}|{r['id'].split('@')[0]}|S: {r['case']['spoken']}|F: {t}".replace('\n','⏎'))
    elif cmd=='label':
        v,s=sys.argv[2],sys.argv[3]; keys=json.load(open(f'{H}/todo-{v}-{s}.json')); spec={}; d='meaning'
        for arg in sys.argv[4:]:
            k,_,rg=arg.partition(':')
            if k=='D': d={'F':'fine','M':'meaning','V':'value'}[rg]; continue
            for part in filter(None,rg.split(',')):
                a,_,b=part.partition('-'); b=b or a
                for n in range(int(a),int(b)+1): spec[n]={'F':'fine','M':'meaning','V':'value'}[k]
        L=store()
        for n,k in enumerate(keys,1): L[k]=spec.get(n,d)
        json.dump(L,open(LP,'w'),indent=0,ensure_ascii=False); print(len(keys),'labelled')
    elif cmd=='table':
        s=sys.argv[2]; L=store()
        print(f"| {s} | rows | first answer meaning changed | refused (register dropped / rules draft) | second asks | pasted meaning changed | pasted with register | words out/in | unlabelled |")
        print("|---|---|---|---|---|---|---|---|---|")
        for v in sys.argv[3:]:
            R=rows(v,s); fm=pm=unl=0; ratio=[]
            for r in R:
                lf=label(L,r,r['first'])
                if lf is None: unl+=1
                if lf in('meaning','value'): fm+=1
                if r['refused']:
                    lp=label(L,r,r['text']) or 'fine'   # plain or rules fallback: safe unless labelled
                else: lp=lf
                if lp in('meaning','value'): pm+=1
                ratio.append(len(r['text'].split())/max(1,len(r['case']['spoken'].split())))
            ref=sum(r['refused'] for r in R); dr=sum(r['drafted'] for r in R)
            print(f"| {v} | {len(R)} | {fm} | {ref} ({ref-dr}/{dr}) | {sum(r['second'] for r in R)} | {pm} | {sum(not r['refused'] for r in R)} | {statistics.mean(ratio):.2f} | {unl} |")
    elif cmd=='diff':
        s,a,b=sys.argv[2:5]; A={r['id']:r for r in rows(a,s)}
        for r in rows(b,s):
            if A[r['id']]['text']!=r['text']:
                print(f"{r['id']}|S: {r['case']['spoken']}\n   {a}: {A[r['id']]['text']}\n   {b}: {r['text']}{'  [refused]' if r['refused'] else ''}".replace('\n\n','\n'))
main()
