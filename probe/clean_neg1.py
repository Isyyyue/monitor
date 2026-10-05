#!/usr/bin/env python3
"""Delete -1 latency rows written by the official monitor-agent.

The official agent writes latency=-1 into ping_record when its own
measurement fails (about once a minute). The panel averages these as 0,
which corrupts the latency graph. probe.py no longer writes -1 itself,
but the agent has no switch to disable it, so this script runs from cron
every minute to clean up.

    * * * * * /usr/bin/python3 /opt/probe/clean_neg1.py
"""
import os
import sqlite3

DB = os.environ.get("PROBE_DB", "/opt/monitor/data/monitor.db")

db = sqlite3.connect(DB, timeout=10)
cur = db.cursor()
cur.execute("DELETE FROM ping_record WHERE latency = -1")
db.commit()
db.close()
