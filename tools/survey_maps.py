"""Survey map events: triggers, move types, and interesting event commands."""
import sys, glob, os, collections
from rubymarshal.reader import load
from rubymarshal.classes import RubyObject

def attr(o, k, d=None):
    return o.attributes.get('@' + k, d) if isinstance(o, RubyObject) else d

stats = collections.Counter()
chasers = []
cmds = collections.Counter()
for path in sorted(glob.glob(os.path.join(sys.argv[1], 'Map*.rvdata'))):
    with open(path, 'rb') as f:
        m = load(f)
    events = attr(m, 'events') or {}
    for eid, ev in events.items():
        for pi, pg in enumerate(attr(ev, 'pages') or []):
            trig = attr(pg, 'trigger'); mt = attr(pg, 'move_type')
            stats[(trig, mt)] += 1
            route = attr(pg, 'move_route')
            codes = [attr(c, 'code') for c in (attr(route, 'list') or [])]
            for c in attr(pg, 'list') or []:
                cmds[attr(c, 'code')] += 1
            if mt == 2 or 10 in codes:
                chasers.append((os.path.basename(path), eid, pi, trig, mt, attr(pg, 'move_speed'), codes[:8], [attr(c,'code') for c in attr(pg,'list')][:15]))
print('trigger,move_type counts:', stats.most_common(20))
print('command codes:', cmds.most_common(40))
print('chasers:', len(chasers))
for c in chasers[:40]: print(c)
