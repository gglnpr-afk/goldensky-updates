#!/usr/bin/env python3
"""GOLDENSKY Temp Mail gateway.

Public API in front of a LOCAL-ONLY Mailpit instance.
Each issued address gets its own bearer token; a token can only read
mail addressed to its own address. Mailpit itself is never exposed.

Config via env:
  GS_DOMAINS   comma-separated domains this server serves (required)
  GS_DB        sqlite path (default /var/lib/gsmail/gateway.db)
  GS_PORT      listen port on 127.0.0.1 (default 8090)
  MAILPIT_API  default http://127.0.0.1:8025
"""
import hashlib, json, os, re, secrets, sqlite3, string, threading, time
import urllib.request, urllib.parse, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB_LOCK = threading.Lock()  # serialize writes: sqlite + threads can hit "database is locked" (seen in local v2 test)

DOMAINS = [d.strip().lower() for d in os.environ.get("GS_DOMAINS", "").split(",") if d.strip()]
DB_PATH = os.environ.get("GS_DB", "/var/lib/gsmail/gateway.db")
PORT = int(os.environ.get("GS_PORT", "8090"))
MAILPIT = os.environ.get("MAILPIT_API", "http://127.0.0.1:8025").rstrip("/")

def db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    c = sqlite3.connect(DB_PATH, timeout=15)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA busy_timeout=10000")
    c.execute("CREATE TABLE IF NOT EXISTS addresses(address TEXT PRIMARY KEY, token_hash TEXT, created_at INTEGER)")
    return c

def h(tok): return hashlib.sha256(tok.encode()).hexdigest()

OTP_RE = re.compile(r"(?<!\d)(\d{4,8})(?!\d)")
def find_otp(*texts):
    for t in texts:
        if not t: continue
        m = OTP_RE.search(str(t))
        if m: return m.group(1)
    return None

def mailpit(path, method="GET", body=None):
    req = urllib.request.Request(MAILPIT + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        raw = r.read().decode("utf-8", "replace")
        return json.loads(raw) if raw.strip() else {}

def msg_to_list(m):
    tos = []
    for t in (m.get("To") or []):
        tos.append(t.get("Address", "") if isinstance(t, dict) else str(t))
    frm = m.get("From") or {}
    return {
        "id": m.get("ID"), "from": frm.get("Address", "") if isinstance(frm, dict) else str(frm),
        "from_name": frm.get("Name", "") if isinstance(frm, dict) else "",
        "to": tos, "subject": m.get("Subject", ""), "date": m.get("Created", ""),
        "snippet": m.get("Snippet", ""), "attachments": m.get("Attachments", 0),
        "otp": find_otp(m.get("Subject", ""), m.get("Snippet", "")),
    }

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def sendj(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def bodyj(self):
        n = int(self.headers.get("Content-Length") or 0)
        try: return json.loads(self.rfile.read(n) or b"{}")
        except Exception: return {}
    def auth(self):
        a = self.headers.get("Authorization", "")
        if not a.startswith("Bearer "): return None
        c = db(); row = c.execute("SELECT address FROM addresses WHERE token_hash=?", (h(a[7:].strip()),)).fetchone(); c.close()
        return row[0] if row else None

    def do_GET(self):
        if self.path == "/health":
            c = db(); n = c.execute("SELECT COUNT(*) FROM addresses").fetchone()[0]; c.close()
            return self.sendj(200, {"ok": True, "v": 2, "domains": DOMAINS, "addresses": n})
        addr = self.auth()
        if not addr: return self.sendj(401, {"error": "bad token"})
        if self.path.startswith("/messages/"):
            mid = urllib.parse.unquote(self.path[len("/messages/"):])
            try: m = mailpit(f"/api/v1/message/{urllib.parse.quote(mid, safe='')}")
            except Exception: return self.sendj(404, {"error": "not found"})
            tos = [t.get("Address", "").lower() for t in (m.get("To") or []) if isinstance(t, dict)]
            if addr.lower() not in tos: return self.sendj(404, {"error": "not found"})
            out = msg_to_list(m); out["text"] = m.get("Text", ""); out["html"] = m.get("HTML", "")
            out["otp"] = find_otp(m.get("Subject", ""), m.get("Text", "")) or out["otp"]
            return self.sendj(200, out)
        if self.path.startswith("/messages"):
            q = urllib.parse.urlencode({"query": f"to:{addr}", "limit": 50})
            try: r = mailpit(f"/api/v1/search?{q}")
            except Exception as e: return self.sendj(502, {"error": f"mail store unavailable: {e}"})
            return self.sendj(200, {"address": addr, "total": r.get("total", 0),
                                     "messages": [msg_to_list(m) for m in r.get("messages", [])]})
        return self.sendj(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/address": return self.sendj(404, {"error": "not found"})
        body = self.bodyj()
        dom = str(body.get("domain", "")).lower().strip()
        if dom not in DOMAINS: return self.sendj(400, {"error": "domain not served here", "domains": DOMAINS})
        name = str(body.get("name", "")).lower().strip()
        if name:
            # custom username (v2): 2-64 chars, alnum segments split by single . _ -
            if not (2 <= len(name) <= 64) or not re.fullmatch(r"[a-z0-9]+([._-][a-z0-9]+)*", name):
                return self.sendj(400, {"error": "bad name"})
            address = f"{name}@{dom}"; tok = secrets.token_urlsafe(24)
            c = db()
            try:
                with DB_LOCK:
                    c.execute("INSERT INTO addresses VALUES(?,?,?)", (address, h(tok), int(time.time()))); c.commit()
                return self.sendj(200, {"address": address, "token": tok, "domain": dom})
            except sqlite3.IntegrityError:
                return self.sendj(409, {"error": "taken"})
            finally:
                c.close()
        alpha = string.ascii_lowercase + string.digits
        for _ in range(20):
            local = "gs" + "".join(secrets.choice(alpha) for _ in range(9))
            address = f"{local}@{dom}"; tok = secrets.token_urlsafe(24)
            c = db()
            try:
                with DB_LOCK:
                    c.execute("INSERT INTO addresses VALUES(?,?,?)", (address, h(tok), int(time.time()))); c.commit()
                return self.sendj(200, {"address": address, "token": tok, "domain": dom})
            except sqlite3.IntegrityError: continue
            finally: c.close()
        return self.sendj(500, {"error": "try again"})

    def do_DELETE(self):
        addr = self.auth()
        if not addr: return self.sendj(401, {"error": "bad token"})
        if self.path.startswith("/messages/"):
            mid = urllib.parse.unquote(self.path[len("/messages/"):])
            try:
                m = mailpit(f"/api/v1/message/{urllib.parse.quote(mid, safe='')}")
                tos = [t.get("Address", "").lower() for t in (m.get("To") or []) if isinstance(t, dict)]
                if addr.lower() not in tos: return self.sendj(404, {"error": "not found"})
                mailpit("/api/v1/messages", method="DELETE", body={"ids": [mid]})
            except Exception: return self.sendj(404, {"error": "not found"})
            return self.sendj(200, {"ok": True})
        if self.path == "/address":
            try:
                q = urllib.parse.urlencode({"query": f"to:{addr}", "limit": 200})
                r = mailpit(f"/api/v1/search?{q}")
                ids = [m.get("ID") for m in r.get("messages", [])]
                if ids: mailpit("/api/v1/messages", method="DELETE", body={"ids": ids})
            except Exception: pass
            c = db()
            try:
                with DB_LOCK:
                    c.execute("DELETE FROM addresses WHERE address=?", (addr,)); c.commit()
            finally: c.close()
            return self.sendj(200, {"ok": True})
        return self.sendj(404, {"error": "not found"})

if __name__ == "__main__":
    if not DOMAINS: raise SystemExit("GS_DOMAINS is required")
    db().close()
    print(f"gsmail gateway on 127.0.0.1:{PORT} domains={DOMAINS}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
