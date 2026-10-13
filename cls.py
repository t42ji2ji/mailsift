import json, difflib, sys, collections
low=[]
for line in open(sys.argv[1]):
    d=json.loads(line); a,b=d['swift'],d['py']
    def grams(s): return set(s[i:i+3] for i in range(max(1,len(s)-2)))
    ga,gb=grams(a),grams(b); sim=len(ga&gb)/max(1,len(ga|gb))
    if sim>=0.9: continue
    if len(a)+len(b)>20000: 
        print(d['id'], 'BIG', len(a), len(b), round(sim,2)); continue
    sm=difflib.SequenceMatcher(None,a,b,autojunk=False)
    ops=[(o, a[i1:i2][:40], b[j1:j2][:40], i2-i1, j2-j1) for o,i1,i2,j1,j2 in sm.get_opcodes() if o!='equal']
    big=max(ops,key=lambda x:x[3]+x[4]) if ops else None
    print(d['id'], len(a), len(b), round(sim,2), big)
