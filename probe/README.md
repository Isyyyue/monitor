# Proxy Latency Probe

The Agent can continuously measure HTTP requests through local sing-box client
inbounds and report results over its authenticated WebSocket connection. VPN
installation configures `MONITOR_PROXY_PORTS=vless:18083,hy2:18084`; tasks
`proxy:vless` and `proxy:hy2` use these routes. `MONITOR_PROXY_TEST_URL` defaults
to `https://www.google.com/generate_204`. Only HTTP 2xx responses succeed;
connection, timeout and HTTP failures report -1 using the Hub's loss convention.
The client remains bound to loopback. Ordinary `host:port` tasks retain TCP
measurement. Unconfigured proxy tasks are skipped.

`probe.py` remains available for manual, legacy deployments on the Hub. Do not
run it for the same node/task while the Agent's integrated measurement is enabled:
duplicate samplers would produce duplicate history. New installer deployments do
not require Python or curl for continuous measurements.

## Legacy measurement

Every 60 seconds, `probe.py` fetches `PROBE_TEST_URL` through local sing-box HTTP
inbounds and writes elapsed milliseconds to the Hub's SQLite `ping_record`
table. HTTP 2xx responses succeed; failures are stored as -1. Tasks with no
assignment, or several assignments without an explicit node ID, are skipped.
This legacy mode requires Python 3, curl and a sing-box client on the Hub machine.

## Setup

Run from this directory on the Hub machine:

```bash
mkdir -p /opt/probe
cp sing-box.example.json /opt/probe/sing-box.json
# Fill in server addresses, UUIDs, passwords and REALITY keys.
cp probe.py /opt/probe/
cp probe-singbox.service probe-latency.service /etc/systemd/system/
# Adjust service paths and PROBE_DB if your installation uses other directories.
systemctl daemon-reload
systemctl enable --now probe-singbox.service probe-latency.service
```

Create panel tasks with targets `proxy:vless` and `proxy:hy2`, and use the actual
panel node IDs in `PROBE_TARGETS`. Leave `MONITOR_PROXY_PORTS` unset for these tasks when using the legacy sampler.
Keep the sing-box HTTP inbounds bound to `127.0.0.1`.

## Configuration

Set environment variables in `probe-latency.service` or a systemd override:

| Variable | Default | Description |
|---|---|---|
| `PROBE_DB` | `/opt/monitor/data/monitor.db` | Hub SQLite database path |
| `PROBE_INTERVAL` | `60` | Seconds between rounds |
| `PROBE_TEST_URL` | `https://www.google.com/generate_204` | URL fetched through each proxy |
| `PROBE_TARGETS` | See below | Comma-separated `tag:port:node_id` entries |

Default targets match `sing-box.example.json`:

```text
vless:18083,hy2:18084
```

`tag` identifies the panel task by its target (`vless` → `proxy:vless`,
`hy2` → `proxy:hy2`). Task IDs are looked up from the database, not assumed to be
1 or 2. The older `tag:port:node_id:task_id` format remains supported when an
explicit task ID is required.

```ini
[Service]
Environment="PROBE_TARGETS=vless:18083:1,hy2:18084:1"
Environment="PROBE_INTERVAL=30"
```

After editing a unit, run `systemctl daemon-reload` and restart
`probe-latency.service`.

## Historical cleanup

`clean_neg1.py` is a legacy cleanup tool that deletes **all** `latency = -1` rows
from the configured database, including legitimate failed TCP probes. It is not
required by the current Agent and should not be scheduled as routine cleanup.
Back up the database and inspect affected records before any manual use.
