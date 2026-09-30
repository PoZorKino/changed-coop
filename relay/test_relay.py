import asyncio, os, subprocess, sys, time
os.environ["PORT"] = "27599"
async def main():
    p = subprocess.Popen([sys.executable, "relay.py"], env=os.environ)
    await asyncio.sleep(1)
    try:
        cr, cw = await asyncio.open_connection("127.0.0.1", 27599)
        cw.write(b"HOST TEST1\n"); await cw.drain()
        assert (await cr.readline()) == b"OK\n"
        # unknown room -> framed reject
        jr, jw = await asyncio.open_connection("127.0.0.1", 27599)
        jw.write(b"JOIN NOPE\n"); await jw.drain()
        print("reject frame:", (await jr.read(200))[:60])
        jr, jw = await asyncio.open_connection("127.0.0.1", 27599)
        jw.write(b"JOIN test1\nHELLO-FROM-CLIENT"); await jw.drain()
        line = await cr.readline(); print("control:", line)
        cid = line.split()[1].decode()
        hr, hw = await asyncio.open_connection("127.0.0.1", 27599)
        hw.write(b"ACCEPT TEST1 " + cid.encode() + b"\n"); await hw.drain()
        print("host got:", await hr.read(100))
        hw.write(b"WELCOME-FROM-HOST"); await hw.drain()
        print("client got:", await jr.read(100))
        jw.close(); await asyncio.sleep(0.3)
        print("host sees close:", await hr.read(100) == b"")
    finally:
        p.terminate()
asyncio.run(main())
