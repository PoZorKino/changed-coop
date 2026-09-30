"""Extract an RPG Maker VX .rgss2a archive (RGSSAD v1) from the user's own install."""
import struct, sys, os

def extract(src, dst):
    with open(src, 'rb') as f:
        data = f.read()
    assert data[:8] == b'RGSSAD\x00\x01', data[:8]
    pos, key = 8, 0xDEADCAFE
    adv = lambda k: (k * 7 + 3) & 0xFFFFFFFF
    n = 0
    while pos < len(data):
        ln = struct.unpack_from('<I', data, pos)[0] ^ key; pos += 4; key = adv(key)
        name = bytearray()
        for b in data[pos:pos + ln]:
            name.append(b ^ (key & 0xFF)); key = adv(key)
        pos += ln
        size = struct.unpack_from('<I', data, pos)[0] ^ key; pos += 4; key = adv(key)
        blob = bytearray(data[pos:pos + size]); pos += size
        dk = key
        for i in range(0, size, 4):
            kb = struct.pack('<I', dk)
            for j in range(min(4, size - i)):
                blob[i + j] ^= kb[j]
            dk = adv(dk)
        rel = name.decode('latin-1').replace(chr(92), '/')
        out = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'wb') as o:
            o.write(blob)
        n += 1
    print(f'extracted {n} files')

if __name__ == '__main__':
    extract(sys.argv[1], sys.argv[2])
