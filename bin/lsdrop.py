#!/usr/bin/env python3
"""Minimal LocalSend v2 client for the bar widget.

  lsdrop.py discover [--timeout SECONDS]
      Prints one JSON object per line for every LocalSend device found:
      {"event":"device","alias":..,"ip":..,"port":..,"protocol":..,"deviceType":..,"deviceModel":..,"fingerprint":..}
      Finds devices two ways at once: the LocalSend multicast announcement
      (224.0.0.167:53317) and a direct /info probe of every host on the
      local /24, which still works when multicast is filtered.

  lsdrop.py send --ip IP --port PORT --protocol https|http FILE...
      Prints JSON lines: {"event":"waiting"} while the receiver decides,
      {"event":"progress","sent":N,"total":N} during upload, then
      {"event":"done"} or {"event":"error","message":..}.
"""

import argparse
import concurrent.futures
import hashlib
import http.client
import ipaddress
import json
import mimetypes
import os
import socket
import ssl
import subprocess
import struct
import sys
import threading
import time
import uuid

MULTICAST_GROUP = "224.0.0.167"
PORT = 53317
API = "/api/localsend/v2"

_print_lock = threading.Lock()


def emit(obj):
    with _print_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "lsdrop")
CERT = os.path.join(STATE_DIR, "cert.pem")
KEY = os.path.join(STATE_DIR, "key.pem")


def ensure_cert():
    # LocalSend 1.18+ requires the sender to present a client certificate,
    # and identifies devices by the SHA-256 of that certificate.
    if os.path.exists(CERT) and os.path.exists(KEY):
        return
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", KEY, "-out", CERT, "-days", "3650",
                    "-subj", "/CN=LocalSend User"],
                   check=True, capture_output=True)
    os.chmod(KEY, 0o600)


_fingerprint = None


def fingerprint():
    global _fingerprint
    if _fingerprint is None:
        ensure_cert()
        with open(CERT) as f:
            der = ssl.PEM_cert_to_DER_cert(f.read())
        _fingerprint = hashlib.sha256(der).hexdigest().upper()
    return _fingerprint


def own_info():
    return {
        "alias": socket.gethostname(),
        "version": "2.1",
        "deviceModel": "Linux",
        "deviceType": "desktop",
        "fingerprint": fingerprint(),
        "port": PORT,
        "protocol": "https",
        "download": False,
    }


_ctx = None


def ssl_context():
    # LocalSend devices use self-signed certificates.
    global _ctx
    if _ctx is not None:
        return _ctx
    ctx = _ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ensure_cert()
    ctx.load_cert_chain(CERT, KEY)
    return ctx


def connection(ip, port, protocol, timeout):
    if protocol == "https":
        return http.client.HTTPSConnection(ip, port, timeout=timeout, context=ssl_context())
    return http.client.HTTPConnection(ip, port, timeout=timeout)


def local_ipv4():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((MULTICAST_GROUP, PORT))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def own_ipv4s():
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True).stdout
    except OSError:
        return set()
    return {line.split()[3].split("/")[0] for line in out.splitlines() if len(line.split()) > 3}


# ---------------------------------------------------------------- discovery

class Discovery:
    def __init__(self):
        self.me = own_info()
        self.my_ip = local_ipv4()
        self.own_ips = own_ipv4s()
        self.seen = set()
        self.lock = threading.Lock()

    def report(self, ip, info, protocol=None):
        fp = info.get("fingerprint") or ip
        # Skip ourselves, including the LocalSend app running on this machine.
        if fp == self.me["fingerprint"] or ip in self.own_ips:
            return
        with self.lock:
            if fp in self.seen:
                return
            self.seen.add(fp)
        emit({
            "event": "device",
            "alias": info.get("alias") or ip,
            "ip": ip,
            "port": int(info.get("port") or PORT),
            "protocol": protocol or info.get("protocol") or "https",
            "deviceType": info.get("deviceType") or "",
            "deviceModel": info.get("deviceModel") or "",
            "fingerprint": fp,
        })

    def multicast(self, deadline):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except OSError:
                pass
        try:
            sock.bind(("", PORT))
            mreq = struct.pack("4s4s", socket.inet_aton(MULTICAST_GROUP),
                               socket.inet_aton(self.my_ip or "0.0.0.0"))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        except OSError:
            sock.close()
            return  # the /24 probe still runs
        announce = dict(self.me, announce=True)
        payload = json.dumps(announce).encode()
        try:
            sock.sendto(payload, (MULTICAST_GROUP, PORT))
        except OSError:
            pass
        next_announce = time.time() + 2
        sock.settimeout(0.5)
        while time.time() < deadline:
            if time.time() >= next_announce:
                try:
                    sock.sendto(payload, (MULTICAST_GROUP, PORT))
                except OSError:
                    pass
                next_announce = time.time() + 3
            try:
                data, (ip, _) = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            if ip == self.my_ip:
                continue
            try:
                info = json.loads(data.decode())
            except ValueError:
                continue
            if isinstance(info, dict) and info.get("fingerprint"):
                self.report(ip, info)
        sock.close()

    def probe(self, ip):
        for protocol in ("https", "http"):
            try:
                conn = connection(ip, PORT, protocol, 1.2)
                conn.request("GET", API + "/info")
                resp = conn.getresponse()
                body = resp.read()
                conn.close()
                if resp.status == 200:
                    info = json.loads(body.decode())
                    self.report(ip, info, protocol)
                return
            except (OSError, ValueError, http.client.HTTPException):
                continue

    def scan(self):
        if not self.my_ip:
            return
        net = ipaddress.ip_network(self.my_ip + "/24", strict=False)
        hosts = [str(h) for h in net.hosts() if str(h) != self.my_ip]
        with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
            list(pool.map(self.probe, hosts))

    def run(self, timeout):
        deadline = time.time() + timeout
        mc = threading.Thread(target=self.multicast, args=(deadline,), daemon=True)
        mc.start()
        threading.Thread(target=self.scan, daemon=True).start()
        mc.join(max(0, deadline - time.time()) + 1)
        emit({"event": "finished"})
        sys.stdout.flush()
        os._exit(0)  # don't wait on probes still in flight


# ---------------------------------------------------------------- sending

def send(ip, port, protocol, paths):
    files = {}
    by_id = {}
    for path in paths:
        if not os.path.isfile(path):
            emit({"event": "error", "message": "Not a file: " + os.path.basename(path)})
            return 1
        fid = uuid.uuid4().hex
        size = os.path.getsize(path)
        files[fid] = {
            "id": fid,
            "fileName": os.path.basename(path),
            "size": size,
            "fileType": mimetypes.guess_type(path)[0] or "application/octet-stream",
        }
        by_id[fid] = path

    body = json.dumps({"info": own_info(), "files": files})
    emit({"event": "waiting"})
    try:
        # The receiver may take a while to tap Accept.
        conn = connection(ip, port, protocol, 300)
        conn.request("POST", API + "/prepare-upload", body=body,
                     headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
    except (OSError, http.client.HTTPException) as e:
        emit({"event": "error", "message": "Could not reach device: %s" % e})
        return 1

    if resp.status == 204:
        emit({"event": "done"})
        return 0
    if resp.status != 200:
        msg = {403: "Declined by receiver", 409: "Receiver is busy with another transfer",
               429: "Too many requests, try again shortly"}.get(resp.status, "Receiver answered HTTP %d" % resp.status)
        emit({"event": "error", "message": msg})
        return 1

    try:
        session = json.loads(raw.decode())
        session_id = session["sessionId"]
        tokens = session.get("files", {})
    except (ValueError, KeyError):
        emit({"event": "error", "message": "Unexpected reply from receiver"})
        return 1

    total = sum(files[f]["size"] for f in tokens if f in files)
    sent = 0
    emit({"event": "progress", "sent": 0, "total": total})
    last_emit = 0.0
    for fid, token in tokens.items():
        path = by_id.get(fid)
        if not path:
            continue
        query = "?sessionId=%s&fileId=%s&token=%s" % (session_id, fid, token)
        try:
            conn = connection(ip, port, protocol, 60)
            conn.putrequest("POST", API + "/upload" + query)
            conn.putheader("Content-Type", "application/octet-stream")
            conn.putheader("Content-Length", str(files[fid]["size"]))
            conn.endheaders()
            with open(path, "rb") as f:
                while True:
                    chunk = f.read(256 * 1024)
                    if not chunk:
                        break
                    conn.send(chunk)
                    sent += len(chunk)
                    now = time.time()
                    if now - last_emit > 0.2:
                        emit({"event": "progress", "sent": sent, "total": total})
                        last_emit = now
            resp = conn.getresponse()
            resp.read()
            conn.close()
        except (OSError, http.client.HTTPException) as e:
            emit({"event": "error", "message": "Transfer failed: %s" % e})
            return 1
        if resp.status != 200:
            emit({"event": "error", "message": "Upload rejected (HTTP %d)" % resp.status})
            return 1

    emit({"event": "progress", "sent": total, "total": total})
    emit({"event": "done"})
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("discover")
    d.add_argument("--timeout", type=float, default=6)
    s = sub.add_parser("send")
    s.add_argument("--ip", required=True)
    s.add_argument("--port", type=int, default=PORT)
    s.add_argument("--protocol", default="https")
    s.add_argument("files", nargs="+")
    args = ap.parse_args()

    if args.cmd == "discover":
        Discovery().run(args.timeout)
        return 0
    return send(args.ip, args.port, args.protocol, args.files)


if __name__ == "__main__":
    sys.exit(main())
