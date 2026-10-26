#!/usr/bin/env python3
"""Merge GOLDENSKY Temp Mail gateway address DBs into one target DB.

Use when moving gateways from several VPSes onto one: every existing
address keeps its token hash and recovery-code hash, so app users'
saved addresses and recovery codes keep working after the DNS flip.

Usage (run on the NEW VPS, gsmail stopped):
    sudo systemctl stop gsmail
    sudo python3 merge-gateway-db.py /var/lib/gsmail/gateway.db /tmp/tokyo-gateway.db [/tmp/sg-gateway.db ...]
    sudo systemctl start gsmail

Safe: target is backed up to <target>.bak-<timestamp> first; rows are
INSERT OR IGNORE keyed on the address primary key, so nothing existing
is ever overwritten.
"""
import shutil, sqlite3, sys, time

COLS = "address, token_hash, created_at, recovery_hash, recovery_fails, recovery_lock"

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    target, sources = sys.argv[1], sys.argv[2:]
    bak = f"{target}.bak-{int(time.time())}"
    shutil.copy2(target, bak)
    print(f"backup: {bak}")
    dst = sqlite3.connect(target, timeout=15)
    dst.execute("PRAGMA journal_mode=WAL")
    dst.execute("PRAGMA busy_timeout=10000")
    total_before = dst.execute("SELECT COUNT(*) FROM addresses").fetchone()[0]
    for src_path in sources:
        src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
        scols = [r[1] for r in src.execute("PRAGMA table_info(addresses)").fetchall()]
        rows = src.execute(f"SELECT {', '.join(c for c in COLS.split(', ') if c in scols)} FROM addresses").fetchall()
        have = [c for c in COLS.split(", ") if c in scols]
        ph = ", ".join("?" for _ in have)
        n = 0
        for row in rows:
            cur = dst.execute(f"INSERT OR IGNORE INTO addresses({', '.join(have)}) VALUES({ph})", row)
            n += cur.rowcount
        dst.commit()
        print(f"{src_path}: {len(rows)} rows read, {n} new addresses merged")
        src.close()
    total_after = dst.execute("SELECT COUNT(*) FROM addresses").fetchone()[0]
    print(f"target addresses: {total_before} -> {total_after}")
    dst.close()

if __name__ == "__main__":
    main()
