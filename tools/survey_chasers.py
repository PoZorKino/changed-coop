import sys, glob, os, collections
from rubymarshal.reader import load
from rubymarshal.classes import RubyObject
def a(o, k, d=None): return o.attributes.get('@' + k, d) if isinstance(o, RubyObject) else d
lists = collections.Counter(); names = collections.Counter(); nextpages = collections.Counter()
for path in sorted(glob.glob(os.path.join(sys.argv[1], 'Map*.rvdata'))):
    m = load(open(path, 'rb'))
    for eid, ev in (a(m, 'events') or {}).items():
        pages = a(ev, 'pages') or []
        for pi, pg in enumerate(pages):
            mt = a(pg, 'move_type'); trig = a(pg, 'trigger')
            codes = [a(c, 'code') for c in (a(a(pg, 'move_route'), 'list') or [])]
            if trig in (1, 2) and (mt == 2 or 10 in codes):
                lst = tuple(a(c, 'code') for c in a(pg, 'list'))
                lists[lst] += 1
                g = a(pg, 'graphic'); names[a(g, 'character_name')] += 1
                if pi + 1 < len(pages):
                    nxt = pages[pi + 1]
                    nextpages[(a(nxt, 'trigger'), tuple(a(c, 'code') for c in a(nxt, 'list'))[:12])] += 1
print('lists', lists.most_common(15)); print('graphics', names.most_common(30)); print('next pages', nextpages.most_common(8))
