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
    PROBE_TARGETS   comma-separated tag:port entries, e.g. "vless:18083,hy2:18084"

`tag` is the protocol, and it names the panel task to file under: `vless` is
the task whose target is `proxy:vless`. Both the task id and the node id are
looked up from the database, not written down -- see `task_id()` and
`node_for()`. This is what lets an automated install write this list without
knowing either: the agent holds a token, never a node id. The older three- and
four-field forms (`tag:port:node_id`, `tag:port:node_id:task_id`) are still
accepted, for a deployment that has a number pinned somewhere.

Measurement failures are stored as -1 (loss); unassigned tasks are not sampled.
Ambiguous node assignments must be made explicit rather than guessed.
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
            # Two fields is what an automated install writes: the node is looked
            # up from `ping_node` (see `node_for`), so the installer does not
            # have to know the panel's node id -- it does not, at the point the
            # agent has only ever been given a token.
            if len(parts) == 2:
                tag, port = parts
                targets.append((tag, int(port), None, None))
            elif len(parts) == 3:
                tag, port, node_id = parts
                targets.append((tag, int(port), int(node_id), None))
            elif len(parts) == 4:
                tag, port, node_id, pinned = parts
                targets.append((tag, int(port), int(node_id), int(pinned)))
            else:
                raise SystemExit(
                    "PROBE_TARGETS 每项要写成 tag:port（旧的三段/四段形式也认）：%r" % entry
                )
        return targets
    # Never invent node IDs. A task with several nodes needs an explicit ID.
    return [
        ("vless", 18083, None, None),
        ("hy2", 18084, None, None),
    ]


def node_for(db, task_id, declared):
    """The node this task's samples belong to, or None when it cannot be told.

    An automated install leaves this blank rather than guessing: the installer
    knows the panel's node id nowhere -- the agent is given a token, not an id --
    so writing a constant would file this machine's measurements under whichever
    node happens to be number 1.

    `ping_node` already holds the answer: the hub binds each auto-created proxy
    task to every node it knows, which is the same row the panel reads. Taking
    the declared value when there is one keeps the older hand-written form
    working.
    """
    if declared is not None:
        row = db.execute(
            "SELECT node_id FROM ping_node WHERE task_id = ? AND node_id = ?",
            (task_id, declared),
        ).fetchone()
        return row[0] if row else None
    rows = db.execute(
        "SELECT node_id FROM ping_node WHERE task_id = ? LIMIT 2",
        (task_id,),
    ).fetchall()
    return rows[0][0] if len(rows) == 1 else None


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
             "--noproxy", "", "-o", "/dev/null", "-s", "-w", "%{http_code} %{time_total}",
             "--max-time", "15", TEST_URL],
            capture_output=True, text=True, timeout=20)
        if r.returncode == 0 and r.stdout.strip():
            status, elapsed = r.stdout.strip().split()
            if 200 <= int(status) < 300:
                return int(float(elapsed) * 1000)
    except Exception as e:
        print("probe fail port %d: %s" % (port, e), flush=True)
    return -1


def main():
    while True:
        ts = int(time.time())
        db = None
        try:
            db = sqlite3.connect(DB, timeout=10)
            rows = []
            for tag, port, declared_node, pinned in PROXIES:
                tid = task_id(db, tag, pinned)
                if tid is None:
                    # Said every round rather than once: the panel may not have
                    # had the task when this started, and a silent skip is how
                    # a curve stays empty for a week with nobody noticing.
                    print("%d %s: 面板上没有 target=proxy:%s 的任务，这一轮跳过" % (ts, tag, tag),
                          flush=True)
                    continue
                node_id = node_for(db, tid, declared_node)
                if node_id is None:
                    # The task exists but is bound to no node, so there is
                    # nowhere to file this. Named rather than written to a made-up
                    # id, which would show another node's line as this one's.
                    print("%d %s: 任务 %d 的节点归属无法确定，这一轮跳过" % (ts, tag, tid),
                          flush=True)
                    continue
                lat = test_proxy(port)
                if lat == -1:
                    print("%d %s=FAIL" % (ts, tag), flush=True)
                rows.append((node_id, tid, ts, lat))
                print("%d %s=%dms" % (ts, tag, lat), flush=True)
            # Acquire the write lock only after network measurements finish.
            db.executemany("INSERT INTO ping_record(node_id,task_id,ts,latency) VALUES(?,?,?,?)", rows)
            db.commit()
        except Exception as e:
            print("db fail: %s" % e, flush=True)
        finally:
            if db is not None:
                db.close()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
