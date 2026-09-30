"""Dump Scripts.rvdata (Marshal array of [id, name, zlib(code)]) to individual .rb files."""
import sys, os, zlib, re
from rubymarshal.reader import load

def s(x):
    return x if isinstance(x, (bytes, bytearray)) else getattr(x, 'text', str(x)).encode('latin-1', 'replace') if not hasattr(x, 'encode') else x.encode('utf-8')

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
with open(src, 'rb') as f:
    scripts = load(f)
for i, (sid, name, code) in enumerate(scripts):
    name = name if isinstance(name, bytes) else bytes(str(name), 'utf-8') if isinstance(name, str) else name.text.encode('utf-8', 'replace') if hasattr(name, 'text') else bytes(name)
    code = code if isinstance(code, bytes) else code.text.encode('latin-1') if hasattr(code, 'text') else bytes(code)
    body = zlib.decompress(code)
    nm = name.decode('utf-8', 'replace')
    safe = re.sub(r'[^\w\- ]', '_', nm).strip() or 'blank'
    with open(os.path.join(dst, f'{i:03d}_{safe}.rb'), 'wb') as o:
        o.write(body)
    print(i, sid, nm, len(body))
