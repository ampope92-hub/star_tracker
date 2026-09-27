#!/usr/bin/env python3
"""The star camera head: streams one recorded pass over TCP, a line protocol.

  python3 camera.py --data pass.txt --host H --port P [--link N] [--first-link N]
                    [--idle S] [--ready-file F] [--log F]

Protocol (README.md in the tracker's directory is the contract; this follows it):
  greeting      STC1 <unit> f=<focal px> size=<pixels> link=<n>
  START <c>     the frames numbered c and later, in order, each as
                FRAME <counter> <exposure ms> <vx> <vy> <vz> <spots> then one line per spot
  after n frames on one connection: LINK DOWN, then the camera head closes
  after the last frame of the pass: EOS, then the camera head closes
  ERR <text>    anything but START
A connection that sends no START within --idle seconds is closed without a word.
"""
import argparse
import socket
import threading
import time


class Camera:
    def __init__(self, a):
        self.frames = []          # (counter, bytes)
        with open(a.data, "rb") as fh:
            head = fh.readline().decode().split()
            unit, f0, size = head[1], head[2], head[3]
            cur_c, cur = None, []
            for raw in fh:
                if raw.startswith(b"FRAME "):
                    if cur_c is not None:
                        self.frames.append((cur_c, b"".join(cur)))
                    cur_c, cur = int(raw.split()[1]), [raw]
                else:
                    cur.append(raw)
            if cur_c is not None:
                self.frames.append((cur_c, b"".join(cur)))
        self.greeting = f"STC1 {unit} f={f0} size={size}"
        self.counters = [c for c, _ in self.frames]
        self.link, self.first_link, self.idle = a.link, a.first_link, a.idle
        self.logpath = a.log
        self.lock = threading.Lock()
        self.conn_no = 0

    def log(self, msg):
        if self.logpath:
            with self.lock, open(self.logpath, "a") as fh:
                fh.write(f"{time.monotonic():.3f} {msg}\n")

    def first_at_or_after(self, c):
        lo, hi = 0, len(self.counters)
        while lo < hi:
            m = (lo + hi) // 2
            if self.counters[m] < c:
                lo = m + 1
            else:
                hi = m
        return lo

    def serve(self, conn):
        with self.lock:
            self.conn_no += 1
            cno = self.conn_no
        n_link = self.first_link if cno == 1 else self.link
        conn.settimeout(self.idle)
        self.log(f"c{cno} OPEN link={n_link}")
        rfile = conn.makefile("rb")
        try:
            conn.sendall(f"{self.greeting} link={n_link}\n".encode())
            while True:
                raw = rfile.readline(256)
                if not raw:
                    self.log(f"c{cno} CLOSED by client")
                    return
                f = raw.decode("ascii", "replace").split()
                if len(f) == 2 and f[0] == "START" and f[1].lstrip("-").isdigit():
                    break
                conn.sendall(b"ERR expected START <counter>\n")
            i = self.first_at_or_after(int(f[1]))
            self.log(f"c{cno} START {f[1]} from index {i}")
            conn.settimeout(60.0)
            sent = 0
            while i < len(self.frames) and sent < n_link:
                conn.sendall(self.frames[i][1])
                i += 1
                sent += 1
            if i >= len(self.frames):
                conn.sendall(b"EOS\n")
                self.log(f"c{cno} EOS after {sent} frames, last {self.counters[-1]}")
            else:
                conn.sendall(b"LINK DOWN\n")
                self.log(f"c{cno} LINK DOWN after {sent} frames, next {self.counters[i]}")
        except TimeoutError:
            self.log(f"c{cno} IDLE closed")
        except OSError:
            self.log(f"c{cno} RESET")
        finally:
            try:
                conn.close()
            except OSError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7400)
    ap.add_argument("--link", type=int, default=1500)
    ap.add_argument("--first-link", type=int, default=40)
    ap.add_argument("--idle", type=float, default=10.0)
    ap.add_argument("--ready-file")
    ap.add_argument("--log")
    a = ap.parse_args()
    cam = Camera(a)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.host, a.port))
    srv.listen(16)
    if a.ready_file:
        with open(a.ready_file, "w") as fh:
            fh.write("ready\n")
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=cam.serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
