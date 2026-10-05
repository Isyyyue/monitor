#!/usr/bin/env python3
"""Probe proxy latency through sing-box client inbounds, record to monitor DB.

Each proxy is tested end-to-end: curl fetches a test URL through the local
HTTP inbound that sing-box routes to the real proxy outbound. The total time
is written to the monitor hub's ping_record table, where the panel draws the
latency graph.

Configuration is via environment variables so no secrets live in the file:

    PROBE_DB        path to monitor.db (default: /opt/monitor/data/monitor.db)
    PROBE_INTERVAL  seconds between rounds (default: 60)
    PROBE_TEST_URL  URL to fetch through each proxy
                    (default: https://www.google.com/generate_204)
    PROBE_TARGETS   comma-separated tag:port:node_id:task_id entries, e.g.
                    "vless:18083:1:1,hy2:18084:1:2"

task_id maps to the panel's ping tasks (1=VLESS red, 2=HY2 blue by default).
On measurement failure the round is skipped (no -1 written); the panel's
clean_neg1.py cron handles -1 rows written by the official agent.
"""
import os
import sqlite3
import subprocess
import time

DB = os.environ.get("PROBE_DB", "/opt/monitor/data/monitor.db")
INTERVAL = int(os.environ.get("PROBE_INTERVAL", "60"))
TEST_URL = os.environ.get("PROBE_TEST_URL", "https://www.google.com/generate_204")


def parse_targets():
    raw = os.environ.get("PROBE_TARGETS", "")
    targets = []
    if raw.strip():
        for entry in raw.split(","):
            tag, port, node_id, task_id = entry.strip().split(":")
            targets.append((tag, int(port), int(node_id), int(task_id)))
        return targets
    # Default: two nodes x two protocols, matching the example sing-box config.
    return [
        ("vless-old", 18083, 1, 1),
        ("hy2-old", 18084, 1, 2),
        ("vless-new", 18085, 2, 1),
        ("hy2-new", 18086, 2, 2),
    ]


PROXIES = parse_targets()


def test_proxy(port):
    """Return latency in ms, or -1 on failure."""
    try:
        r = subprocess.run(
            ["curl", "-x", "http://127.0.0.1:%d" % port,
             "-o", "/dev/null", "-s", "-w", "%{time_total}",
             "--max-time", "15", TEST_URL],
            capture_output=True, text=True, timeout=20)
        if r.returncode == 0 and r.stdout.strip():
            return int(float(r.stdout.strip()) * 1000)
    except Exception as e:
        print("probe fail port %d: %s" % (port, e), flush=True)
    return -1


def main():
    while True:
        ts = int(time.time())
        try:
            db = sqlite3.connect(DB, timeout=10)
            for tag, port, node_id, task_id in PROXIES:
                lat = test_proxy(port)
                if lat == -1:
                    print("%d %s=FAIL(skip)" % (ts, tag), flush=True)
                    continue
                db.execute(
                    "INSERT INTO ping_record(node_id,task_id,ts,latency)"
                    " VALUES(?,?,?,?)",
                    (node_id, task_id, ts, lat))
                print("%d %s=%dms" % (ts, tag, lat), flush=True)
            db.commit()
            db.close()
        except Exception as e:
            print("db fail: %s" % e, flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
