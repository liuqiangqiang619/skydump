# recv.py —— 接收 SkyDump.dylib 发回的页面结构与用户脚本
# 用法：python recv.py [端口]，默认 9805
# 输出：skydump.json（原始 JSON：href/title/html/styles）、userscript_*.css、html_*.html

import base64
import json
import os
import socket
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9805
OUT = os.path.dirname(os.path.abspath(__file__))


def now():
    return time.strftime("%H:%M:%S")


def handle(conn):
    buf = b""
    cur_tag = None
    cur_len = 0
    chunks = []
    while True:
        data = conn.recv(65536)
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                text = line.decode("utf-8", "ignore")
            except Exception:
                continue
            if text.startswith("BEGIN "):
                parts = text.split(" ")
                cur_tag = parts[1] if len(parts) > 1 else "DATA"
                cur_len = int(parts[2]) if len(parts) > 2 else 0
                chunks = []
                print(f"[{now()}] BEGIN {cur_tag} {cur_len}")
            elif text.startswith("D ") and cur_tag:
                chunks.append(text[2:])
            elif text == "END" and cur_tag:
                b64 = "".join(chunks)
                try:
                    raw = base64.b64decode(b64, validate=False)
                except Exception as e:
                    print(f"[{now()}] decode error {e}")
                    cur_tag = None
                    continue
                name = None
                if cur_tag == "SKYDUMP":
                    name = "skydump.json"
                elif cur_tag.startswith("HTMLSTRING"):
                    name = f"html_{int(time.time())}.html"
                elif cur_tag.startswith("USERSCRIPT"):
                    name = f"userscript_{int(time.time())}.css"
                if name:
                    path = os.path.join(OUT, name)
                    with open(path, "wb") as f:
                        f.write(raw)
                    print(f"[{now()}] saved {name} {len(raw)} bytes")
                    if name == "skydump.json":
                        try:
                            obj = json.loads(raw.decode("utf-8", "ignore"))
                            print(f"    href = {obj.get('href')}")
                            print(f"    title= {obj.get('title')}")
                            print(f"    html = {len(obj.get('html') or '')} chars")
                            print(f"    css  = {len(obj.get('styles') or '')} chars")
                        except Exception as e:
                            print(f"    (not json: {e})")
                cur_tag = None
            else:
                print(f"[{now()}] {text}")


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(4)
    print(f"[recv] listening {PORT}, saving to {OUT}")
    while True:
        conn, addr = srv.accept()
        print(f"[{now()}] connected {addr[0]}")
        try:
            handle(conn)
        except Exception as e:
            print(f"[{now()}] handler error {e}")
        finally:
            conn.close()
            print(f"[{now()}] closed")


if __name__ == "__main__":
    main()
