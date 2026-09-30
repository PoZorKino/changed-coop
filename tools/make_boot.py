"""Build Coop/Boot.rvdata: a one-section RGSS2 Scripts file (Ruby Marshal 4.8) holding src/boot.rb."""
import sys, zlib

def w_long(n):
    if n == 0: return b'\x00'
    if 0 < n < 123: return bytes([n + 5])
    if -124 < n < 0: return bytes([(n - 5) & 0xFF])
    out = bytearray()
    for i in range(1, 5):
        out.append(n & 0xFF); n >>= 8
        if n == 0 or n == -1:
            return bytes([i if n == 0 else 256 - i]) + bytes(out)
    raise ValueError

def m_int(n): return b'i' + w_long(n)
def m_str(b): return b'"' + w_long(len(b)) + b
def m_arr(items): return b'[' + w_long(len(items)) + b''.join(items)

src, dst = sys.argv[1], sys.argv[2]
code = open(src, 'rb').read().replace(b'\r\n', b'\n')
data = b'\x04\x08' + m_arr([m_arr([m_int(424242), m_str(b'CoopBoot'), m_str(zlib.compress(code))])])
open(dst, 'wb').write(data)
print('wrote', dst, len(data), 'bytes')
