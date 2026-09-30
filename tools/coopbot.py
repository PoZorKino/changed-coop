"""Headless test client for Changed Co-op.

Joins a room through the relay (or a direct host), speaks the mod's protocol (Coop::Pack framing), and
walks next to the host so the host sees a remote player. Every message from the host is recorded to a
.jsonl file (for replay / inspection).

  python coopbot.py --room ABCDE [--relay coop.dexx.moe] [--name Bot] [--mode follow|idle|wander|enemy]
  python coopbot.py --direct 127.0.0.1:27500 ...
"""
import argparse, json, random, socket, struct, sys, time, zlib

VERSION = "0.1.0"


# ---- Coop::Pack --------------------------------------------------------------
class Sym(str):
    pass


def dump(o, out):
    if o is None: out += b"n"
    elif o is True: out += b"t"
    elif o is False: out += b"f"
    elif isinstance(o, int):
        if -2147483648 <= o <= 2147483647: out += b"i" + struct.pack("<l", o)
        else:
            s = str(o).encode(); out += b"I" + struct.pack("<L", len(s)) + s
    elif isinstance(o, float): out += b"d" + struct.pack("<d", o)
    elif isinstance(o, Sym):
        s = o.encode(); out += b"y" + struct.pack("<L", len(s)) + s
    elif isinstance(o, (bytes, str)):
        s = o.encode("utf-8") if isinstance(o, str) else o
        out += b"s" + struct.pack("<L", len(s)) + s
    elif isinstance(o, (list, tuple)):
        out += b"a" + struct.pack("<L", len(o))
        for e in o: dump(e, out)
    elif isinstance(o, dict):
        out += b"h" + struct.pack("<L", len(o))
        for k, v in o.items(): dump(k, out); dump(v, out)
    else:
        out += b"n"
    return out


def load(b, p=0):
    t = b[p:p + 1]; p += 1
    if t == b"n": return None, p
    if t == b"t": return True, p
    if t == b"f": return False, p
    if t == b"i": return struct.unpack_from("<l", b, p)[0], p + 4
    if t == b"d": return struct.unpack_from("<d", b, p)[0], p + 8
    if t in (b"s", b"y", b"I"):
        n = struct.unpack_from("<L", b, p)[0]; p += 4
        s = b[p:p + n]; p += n
        if t == b"y": return Sym(s.decode()), p
        if t == b"I": return int(s), p
        return s.decode("utf-8", "replace"), p
    if t == b"a":
        n = struct.unpack_from("<L", b, p)[0]; p += 4
        a = []
        for _ in range(n):
            v, p = load(b, p); a.append(v)
        return a, p
    if t == b"h":
        n = struct.unpack_from("<L", b, p)[0]; p += 4
        h = {}
        for _ in range(n):
            k, p = load(b, p); v, p = load(b, p)
            h[tuple(k) if isinstance(k, list) else k] = v
        return h, p
    raise ValueError("bad tag %r at %d" % (t, p - 1))


def frame(msg):
    data = bytes(dump(msg, bytearray()))
    flag = 0
    if len(data) > 512:
        z = zlib.compress(data)
        if len(z) < len(data): data, flag = z, 1
    return struct.pack(">I", len(data) + 1) + bytes([flag]) + data


class Conn:
    def __init__(self, sock):
        self.s = sock; self.s.setblocking(False); self.buf = b""

    def send(self, msg):
        self.s.setblocking(True); self.s.sendall(frame(msg)); self.s.setblocking(False)

    def poll(self):
        out = []
        try:
            while True:
                d = self.s.recv(65536)
                if not d: raise ConnectionError("closed")
                self.buf += d
        except BlockingIOError:
            pass
        while len(self.buf) >= 4:
            n = struct.unpack(">I", self.buf[:4])[0]
            if len(self.buf) < 4 + n: break
            flag, data = self.buf[4], self.buf[5:4 + n]
            self.buf = self.buf[4 + n:]
            if flag == 1: data = zlib.decompress(data)
            out.append(load(data)[0])
        return out


def jsonable(o):
    if isinstance(o, dict): return {str(k): jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)): return [jsonable(v) for v in o]
    return o


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--room"); ap.add_argument("--relay", default="coop.dexx.moe")
    ap.add_argument("--port", type=int, default=27500); ap.add_argument("--direct")
    ap.add_argument("--name", default="Bot"); ap.add_argument("--mode", default="follow")
    ap.add_argument("--seconds", type=float, default=120); ap.add_argument("--record", default="coopbot.jsonl")
    a = ap.parse_args()

    if a.direct:
        h, p = a.direct.split(":"); sock = socket.create_connection((h, int(p)), 10)
    else:
        sock = socket.create_connection((a.relay, a.port), 10)
        sock.sendall(("JOIN %s\n" % a.room.upper()).encode())
    c = Conn(sock)
    c.send([Sym("hello"), a.name, VERSION])
    rec = open(a.record, "w", encoding="utf-8")
    me, world, pstates, downed, events = None, None, {}, {}, {}
    my = None  # [map, x, y, dir]
    t0 = time.time(); last_step = 0; counts = {}
    while time.time() - t0 < a.seconds:
        try:
            msgs = c.poll()
        except ConnectionError:
            print("disconnected"); break
        for m in msgs:
            k = str(m[0]); counts[k] = counts.get(k, 0) + 1
            rec.write(json.dumps({"t": round(time.time() - t0, 3), "m": jsonable(m)}) + "\n")
            if k == "welcome":
                me = m[1]; print("welcome: I am P%d, players %s" % (me + 1, m[2]))
            elif k == "reject":
                print("REJECTED:", m[1]); return
            elif k == "world":
                world = m[1]; my = [world["map"], world["x"], world["y"], world["dir"]]
                print("world: map %s at %s,%s  players=%s" % (world["map"], world["x"], world["y"], world["names"]))
            elif k == "ps":
                pstates = m[1]
            elif k == "down":
                downed = m[1]; print("downed:", downed)
            elif k == "toast":
                print("toast:", m[1])
            elif k == "map":
                my = [m[1], m[2], m[3], m[4]]; print("host transferred to map", m[1])
            elif k == "ev":
                for s in m[2]: events[s[0]] = s
            elif k == "msg":
                print("msg:", " / ".join(m[2]))
        # act
        if my and time.time() - last_step > 0.3:
            last_step = time.time()
            host = pstates.get(0)
            if a.mode == "follow" and host and host[0] == my[0]:
                hx, hy = host[1], host[2]
                tx, ty = hx + (1 if host[3] != 6 else -1), hy  # stand beside the host
                if (my[1], my[2]) != (tx, ty):
                    my[1] += (tx > my[1]) - (tx < my[1]) if my[1] != tx else 0
                    if my[1] == tx: my[2] += (ty > my[2]) - (ty < my[2])
            elif a.mode == "wander":
                d = random.choice([(1, 0), (-1, 0), (0, 1), (0, -1)]); my[1] += d[0]; my[2] += d[1]
            elif a.mode == "enemy" and events:
                # walk toward the nearest chasing enemy (move type unknown client side: nearest visible event)
                pass
            st = [my[0], my[1], my[2], my[3], 0, 4, False, "$Colin", 0, False, 255, False]
            if host:
                st[7], st[8] = host[7], host[8]
            c.send([Sym("me"), st])
        time.sleep(0.03)
    print("message counts:", counts)
    c.send([Sym("bye")])


if __name__ == "__main__":
    main()
