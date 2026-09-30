"""Changed Co-op relay ("bridge").

Everybody connects OUT to this server, so nobody needs port forwarding.

  host control:  "HOST <room>\n"          -> "OK\n" | "ERR <reason>\n", then "CONN <id>\n" per joiner, "PING\n"
  joiner:        "JOIN <room>\n"          -> spliced to a fresh host data connection
  host data:     "ACCEPT <room> <id>\n"   -> spliced to joiner <id>

After the splice the relay just copies bytes both ways; the game protocol is end-to-end.
"""
import asyncio, os, re, struct, logging

PORT = int(os.environ.get("PORT", "27500"))
MAX_ROOMS = 200
MAX_PLAYERS_PER_ROOM = 16
MAX_CONNS_PER_IP = 24
ROOM_RE = re.compile(r"^[A-Za-z0-9_-]{1,16}$")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("relay")

rooms = {}          # room -> Room
per_ip = {}         # ip -> open connection count


class Room:
    def __init__(self, name, writer):
        self.name = name
        self.control = writer
        self.next_id = 1
        self.pending = {}   # id -> (reader, writer, future)
        self.players = 0


def game_reject(msg):
    """A frame in the game's own protocol: [:reject, msg] (see Coop::Pack)."""
    m = msg.encode("utf-8")
    payload = (b"a" + struct.pack("<L", 2) + b"y" + struct.pack("<L", 6) + b"reject"
               + b"s" + struct.pack("<L", len(m)) + m)
    return struct.pack(">I", len(payload) + 1) + b"\x00" + payload


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError, OSError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def splice(r1, w1, r2, w2):
    await asyncio.gather(pipe(r1, w2), pipe(r2, w1))


async def handle(reader, writer):
    ip = (writer.get_extra_info("peername") or ("?",))[0]
    if per_ip.get(ip, 0) >= MAX_CONNS_PER_IP:
        writer.close()
        return
    per_ip[ip] = per_ip.get(ip, 0) + 1
    try:
        try:
            line = await asyncio.wait_for(reader.readline(), 15)
        except asyncio.TimeoutError:
            return
        parts = line.decode("utf-8", "replace").strip().split()
        if not parts:
            return
        cmd = parts[0].upper()
        if cmd == "HOST" and len(parts) == 2:
            await host_control(parts[1].upper(), reader, writer, ip)
        elif cmd == "JOIN" and len(parts) == 2:
            await joiner(parts[1].upper(), reader, writer, ip)
        elif cmd == "ACCEPT" and len(parts) == 3:
            await accept(parts[1].upper(), parts[2], reader, writer)
    except Exception as e:
        log.info("error from %s: %r", ip, e)
    finally:
        per_ip[ip] -= 1
        if per_ip[ip] <= 0:
            per_ip.pop(ip, None)
        try:
            writer.close()
        except Exception:
            pass


async def host_control(name, reader, writer, ip):
    if not ROOM_RE.match(name):
        writer.write(b"ERR bad room name\n")
        return
    if name in rooms:
        writer.write(b"ERR room already hosted - pick another room code\n")
        await writer.drain()
        return
    if len(rooms) >= MAX_ROOMS:
        writer.write(b"ERR relay full\n")
        await writer.drain()
        return
    room = Room(name, writer)
    rooms[name] = room
    log.info("room %s opened by %s", name, ip)
    writer.write(b"OK\n")
    await writer.drain()

    async def pinger():
        while True:
            await asyncio.sleep(20)
            writer.write(b"PING\n")
            await writer.drain()

    ping_task = asyncio.ensure_future(pinger())
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
    except (ConnectionError, OSError):
        pass
    finally:
        ping_task.cancel()
        rooms.pop(name, None)
        for (_, w, fut) in room.pending.values():
            if not fut.done():
                fut.cancel()
            w.close()
        log.info("room %s closed", name)


async def joiner(name, reader, writer, ip):
    room = rooms.get(name)
    if room is None:
        writer.write(game_reject("Room %s not found on the relay (is the host online?)" % name))
        await writer.drain()
        return
    if room.players >= MAX_PLAYERS_PER_ROOM:
        writer.write(game_reject("Room %s is full" % name))
        await writer.drain()
        return
    cid = str(room.next_id)
    room.next_id += 1
    fut = asyncio.get_event_loop().create_future()
    room.pending[cid] = (reader, writer, fut)
    room.control.write(("CONN %s\n" % cid).encode())
    await room.control.drain()
    try:
        hr, hw = await asyncio.wait_for(fut, 20)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        room.pending.pop(cid, None)
        writer.write(game_reject("The host did not answer"))
        await writer.drain()
        return
    room.players += 1
    log.info("room %s: player %s (%s) connected", name, cid, ip)
    try:
        await splice(reader, writer, hr, hw)
    finally:
        room.players -= 1
        log.info("room %s: player %s left", name, cid)


async def accept(name, cid, reader, writer):
    room = rooms.get(name)
    if room is None or cid not in room.pending:
        return
    _, _, fut = room.pending.pop(cid)
    if fut.done():
        return
    fut.set_result((reader, writer))
    # keep this handler (and its socket) alive until the joiner side finishes the splice
    while not writer.is_closing():
        await asyncio.sleep(1)


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", PORT)
    log.info("Changed Co-op relay listening on %d", PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
