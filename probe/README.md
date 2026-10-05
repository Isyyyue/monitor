# Proxy Latency Probe

Measures real end-to-end proxy latency and feeds it into the monitor panel's
latency graph. The official monitor-agent's built-in ping is unreliable for
proxy targets, so this prober tests through the actual proxy connections.

## How it works

```
probe.py --curl--> sing-box HTTP inbounds (127.0.0.1:18083-18086)
                        |
                        v (routes to real proxy outbounds)
                 VLESS / Hysteria2 servers
                        |
                        v
              https://www.google.com/generate_204
                        |
                        v
              ping_record(node_id, task_id, ts, latency)
```

Every 60 seconds, `probe.py` curls a test URL through each local HTTP
inbound. sing-box routes each inbound to its real proxy outbound. The total
time is written to the hub's `ping_record` table, where the panel draws one
line per (node, task).

## Files

| File | Purpose |
|---|---|
| `probe.py` | The prober. Configurable via env vars, no hardcoded secrets. |
| `clean_neg1.py` | Deletes `latency = -1` rows. Run from cron every minute. |
| `sing-box.example.json` | Template sing-box client config. Copy to `sing-box.json` and fill in your proxy credentials. |
| `probe-latency.service` | systemd unit for probe.py |
| `probe-singbox.service` | systemd unit for the sing-box client |

## Setup

1. Copy the example config and fill in your proxy details:

```bash
cp sing-box.example.json /opt/probe/sing-box.json
# edit /opt/probe/sing-box.json: server IPs, UUIDs, passwords, REALITY keys
```

2. Copy the scripts:

```bash
mkdir -p /opt/probe
cp probe.py clean_neg1.py /opt/probe/
chmod +x /opt/probe/*.py
```

3. Install and start the services:

```bash
cp probe-singbox.service probe-latency.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now probe-singbox.service probe-latency.service
```

4. Add the -1 cleaner to cron (the official agent writes -1 rows that
   corrupt the graph average; this keeps the table clean):

```bash
echo '* * * * * /usr/bin/python3 /opt/probe/clean_neg1.py' | crontab -
```

## Configuration

`probe.py` reads from environment variables:

| Variable | Default | Description |
|---|---|---|
| `PROBE_DB` | `/opt/monitor/data/monitor.db` | Path to the hub's SQLite database |
| `PROBE_INTERVAL` | `60` | Seconds between measurement rounds |
| `PROBE_TEST_URL` | `https://www.google.com/generate_204` | URL fetched through each proxy |
| `PROBE_TARGETS` | (see below) | Comma-separated `tag:port:node_id:task_id` |

Default targets (match the example sing-box config):

```
vless-old:18083:1:1,hy2-old:18084:1:2,vless-new:18085:2:1,hy2-new:18086:2:2
```

`task_id` must match a ping task in the panel (1=VLESS red, 2=HY2 blue
by default). `node_id` must match the node in the panel.

To customize, set env vars in the systemd unit:

```ini
[Service]
Environment="PROBE_TARGETS=vless:18083:1:1,hy2:18084:1:2"
Environment="PROBE_INTERVAL=30"
```

## Why not use the agent's ping

The official agent measures `proxy:vless` / `proxy:hy2` targets with its own
method, which intermittently fails and writes `-1`. The panel averages `-1`
as 0, producing phantom packet-loss and latency spikes. This prober measures
through the real proxy path with curl and skips failed measurements
entirely, so the graph only shows real data.
