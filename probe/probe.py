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
    PROBE_TARGETS   comma-separated tag:port:node_id entries, e.g.
                    "vless:18083:1,hy2:18084:1"

`tag` is the protocol, and it names the panel task to file under: `vless` is
the task whose target is `proxy:vless`. The task id is looked up, not written
down -- see `task_id()`. The older four-field form
`tag:port:node_id:task_id` is still accepted, for a deployment that has a
number pinned somewhere.

On measurement failure the round is skipped (no -1 written). The current
Rust Agent skips proxy:* targets; no periodic -1 cleanup is required.
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
            parts = entry.strip().split(":")
            if len(parts) == 3:
                tag, port, node_id = parts
                targets.append((tag, int(port), int(node_id), None))
            elif len(parts) == 4:
                tag, port, node_id, pinned = parts
                targets.append((tag, int(port), int(node_id), int(pinned)))
            else:
                raise SystemExit(
                    "PROBE_TARGETS 每项要写成 tag:port:node_id（旧的四段形式也认）：%r" % entry
                )
        return targets
    # Default: two nodes x two protocols, matching the example sing-box config.
    return [
        ("vless", 18083, 1, None),
        ("hy2", 18084, 1, None),
        ("vless", 18085, 2, None),
        ("hy2", 18086, 2, None),
    ]


def task_id(db, tag, pinned):
    """The panel's task id for this protocol, looked up by target.

    It used to be a number written into this file (1=VLESS, 2=HY2), which held
    only where those two happened to be the first tasks ever made. Add one of
    your own first, or delete and re-add one, and every measurement went to the
    wrong curve -- silently, because a latency chart with the wrong line drawn
    on it looks exactly like a right one.

    Returns None when the panel has no such task, which is a configuration
    problem worth saying out loud rather than writing to some other task's id.
    """
    if pinned is not None:
        return pinned
    row = db.execute("SELECT id FROM ping_task WHERE target = ?", ("proxy:" + tag,)).fetchone()
    return row[0] if row else None


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
            for tag, port, node_id, pinned in PROXIES:
                tid = task_id(db, tag, pinned)
                if tid is None:
                    # Said every round rather than once: the panel may not have
                    # had the task when this started, and a silent skip is how
                    # a curve stays empty for a week with nobody noticing.
                    print("%d %s: 面板上没有 target=proxy:%s 的任务，这一轮跳过" % (ts, tag, tag),
                          flush=True)
                    continue
                lat = test_proxy(port)
                if lat == -1:
                    print("%d %s=FAIL(skip)" % (ts, tag), flush=True)
                    continue
                db.execute(
                    "INSERT INTO ping_record(node_id,task_id,ts,latency)"
                    " VALUES(?,?,?,?)",
                    (node_id, tid, ts, lat))
                print("%d %s=%dms" % (ts, tag, lat), flush=True)
            db.commit()
            db.close()
        except Exception as e:
            print("db fail: %s" % e, flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
