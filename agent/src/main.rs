//! monitor-agent: reports system metrics to the hub.
//!
//! Usage:
//!   monitor-agent --server wss://hub.example.com/api/agent/ws --token TOKEN
//!   MONITOR_SERVER=https://hub.example.com MONITOR_TOKEN=TOKEN monitor-agent --interval 1
//!   monitor-agent provision --server 203.0.113.10 [--sni …] [--label …]
//!
//! VPN 的写入动作（装 sing-box、写 config、写订阅）已移出常驻服务，改由 `provision`
//! 子命令承担，由安装器以 root 调用一次。**服务本身不再接受任何部署指令** ——
//! 运行期不存在 root 指令通道，hub 被攻破也无法在本机执行任何东西。

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, Message},
};
use tracing::{error, info, warn};

mod provision;

/// Arguments also accept the environment written by install.sh.
#[derive(Debug)]
struct Args {
    server: String,
    token: String,
    interval: Duration,
    ifaces: Vec<String>,
}

fn parse_values(
    values: impl IntoIterator<Item = String>,
    server: String,
    token: String,
    iface: String,
) -> Result<Args> {
    let mut out = Args {
        server,
        token,
        interval: Duration::from_secs(1),
        ifaces: iface.split(',').filter(|v| !v.is_empty()).map(str::to_owned).collect(),
    };
    let mut args = values.into_iter();
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--server" => out.server = args.next().context("--server needs a value")?,
            "--token" => out.token = args.next().context("--token needs a value")?,
            "--iface" => {
                out.ifaces = args
                    .next()
                    .context("--iface needs a value")?
                    .split(',')
                    .filter(|v| !v.is_empty())
                    .map(str::to_owned)
                    .collect()
            }
            "--interval" => {
                let seconds: f64 =
                    args.next().context("--interval needs a value")?.parse().context("invalid interval")?;
                if !seconds.is_finite() || !(0.5..=3600.0).contains(&seconds) {
                    anyhow::bail!("interval must be between 0.5 and 3600 seconds");
                }
                out.interval = Duration::from_secs_f64(seconds);
            }
            "--insecure" => anyhow::bail!("--insecure is unsupported: use a trusted HTTPS certificate"),
            _ => anyhow::bail!("unknown argument: {flag}"),
        }
    }
    if out.server.is_empty() || out.token.is_empty() {
        anyhow::bail!("set MONITOR_SERVER/MONITOR_TOKEN or --server/--token");
    }
    out.server = websocket_url(&out.server)?;
    Ok(out)
}

fn websocket_url(server: &str) -> Result<String> {
    let mut url = url::Url::parse(server).context("invalid server URL")?;
    let scheme = match url.scheme() {
        "http" | "ws" => "ws",
        "https" | "wss" => "wss",
        _ => anyhow::bail!("server must use http, https, ws or wss"),
    };
    url.set_scheme(scheme).map_err(|_| anyhow::anyhow!("invalid server scheme"))?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        anyhow::bail!("server URL must contain a host and no credentials, query or fragment");
    }
    if url.path().is_empty() || url.path() == "/" {
        url.set_path("/api/agent/ws");
    }
    Ok(url.into())
}

fn websocket_request(server: &str, token: &str) -> Result<http::Request<()>> {
    let mut request = server.into_client_request().context("invalid WebSocket request")?;
    request
        .headers_mut()
        .insert("Authorization", format!("Bearer {token}").parse().context("invalid token header")?);
    Ok(request)
}

fn parse_args() -> Result<Args> {
    parse_values(
        std::env::args().skip(1),
        std::env::var("MONITOR_SERVER").unwrap_or_default(),
        std::env::var("MONITOR_TOKEN").unwrap_or_default(),
        std::env::var("MONITOR_IFACE").unwrap_or_default(),
    )
}

/// System metrics collected from the host.
///
/// The field names are the hub's contract: `agent_ws::report_fields()` derives the
/// list it checks from `api::PUBLIC_METRICS`, and anything missing there is stored
/// as zero and shown as zero. `net_rx`/`net_tx` are rates over the report interval,
/// which the hub keeps as the minute's peak.
#[derive(Debug, Serialize)]
struct Metrics {
    boot_id: String,
    hostname: String,
    uptime: u64,
    cpu: f32,
    load: [f32; 3],
    mem_total: u64,
    mem_used: u64,
    swap_total: u64,
    swap_used: u64,
    disk_total: u64,
    disk_used: u64,
    net_rx: u64,
    net_tx: u64,
    net_rx_total: u64,
    net_tx_total: u64,
    tcp: u64,
    udp: u64,
    procs: u64,
}

fn boot_id() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

/// Seconds since boot. `/proc/uptime` is two floats; only the first is wanted.
fn uptime() -> u64 {
    std::fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split_whitespace().next().map(str::to_owned))
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|v| v.is_finite() && *v >= 0.0)
        .map_or(0, |v| v as u64)
}

/// Established and listening sockets of one family, as `/proc/net` reports them.
///
/// The files carry a header line. A count rather than a state breakdown: the panel
/// draws one figure per family, and reading the state column would mean parsing
/// addresses this does not need.
fn socket_count(paths: &[&str]) -> u64 {
    paths
        .iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .map(|body| body.lines().count().saturating_sub(1) as u64)
        .sum()
}

/// Processes, counted from `/proc` rather than through `sysinfo`: the count is all
/// the panel shows, and a full process refresh costs far more than a readdir.
fn process_count() -> u64 {
    std::fs::read_dir("/proc")
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .filter(|e| e.file_name().to_string_lossy().bytes().all(|b| b.is_ascii_digit()))
                .count() as u64
        })
        .unwrap_or(0)
}

/// Turns two monotonic counters into a rate, remembering the previous reading.
///
/// The interval is measured with `Instant` rather than a wall clock: a rate divides
/// by elapsed time, and an NTP step would make that negative. A counter that went
/// backwards means the interface was reset, so the rate is reported as zero rather
/// than as a huge number.
#[derive(Default)]
struct Rate {
    last: Option<(u64, u64, std::time::Instant)>,
}

impl Rate {
    fn measure(&mut self, rx: u64, tx: u64) -> (u64, u64) {
        let now = std::time::Instant::now();
        let out = match self.last {
            Some((prx, ptx, at)) => {
                let secs = now.duration_since(at).as_secs_f64();
                if secs <= 0.0 || rx < prx || tx < ptx {
                    (0, 0)
                } else {
                    (((rx - prx) as f64 / secs) as u64, ((tx - ptx) as f64 / secs) as u64)
                }
            }
            None => (0, 0),
        };
        self.last = Some((rx, tx, now));
        out
    }
}

fn collect_metrics(sys: &mut sysinfo::System, ifaces: &[String], rate: &mut Rate) -> Metrics {
    sys.refresh_all();

    let cpu = sys.global_cpu_info().cpu_usage();
    let load = sysinfo::System::load_average();

    let mem_total = sys.total_memory();
    let mem_used = sys.used_memory();
    let swap_total = sys.total_swap();
    let swap_used = sys.used_swap();

    // Disks
    let disks = sysinfo::Disks::new_with_refreshed_list();
    let (disk_total, disk_used) = disks
        .iter()
        .fold((0, 0), |(t, u), d| (t + d.total_space(), u + d.total_space() - d.available_space()));

    // Networks
    let networks = sysinfo::Networks::new_with_refreshed_list();
    let (rx, tx) = networks
        .iter()
        .filter(|(name, _)| ifaces.is_empty() || ifaces.iter().any(|wanted| wanted == *name))
        .fold((0, 0), |(r, t), (_, n)| (r + n.total_received(), t + n.total_transmitted()));
    let (net_rx, net_tx) = rate.measure(rx, tx);

    Metrics {
        boot_id: boot_id(),
        hostname: hostname(),
        uptime: uptime(),
        cpu,
        load: [load.one as f32, load.five as f32, load.fifteen as f32],
        mem_total,
        mem_used,
        swap_total,
        swap_used,
        disk_total,
        disk_used,
        net_rx,
        net_tx,
        net_rx_total: rx,
        net_tx_total: tx,
        tcp: socket_count(&["/proc/net/tcp", "/proc/net/tcp6"]),
        udp: socket_count(&["/proc/net/udp", "/proc/net/udp6"]),
        procs: process_count(),
    }
}

/// The slow-changing facts a node sends once, on connect.
///
/// The hub stores these in `node` and six of them go straight into the anonymous
/// public frame. Its `save_facts` reads exactly these keys, and anything absent
/// leaves the panel's row blank -- which is what an agent sending only its hostname
/// produced.
#[derive(Debug, Serialize)]
struct Facts {
    hostname: String,
    os: String,
    kernel: String,
    arch: String,
    virt: String,
    cpu_name: String,
    cpu_cores: u64,
    mem_total: u64,
    swap_total: u64,
    disk_total: u64,
    agent_version: String,
    /// The machine's own addresses. See [`own_addresses`].
    ipv4: String,
    ipv6: String,
}

/// Whether an address is one the internet routes to.
///
/// A loopback or private address names no country, and reporting one would make the
/// hub fall back to the connection address anyway -- which is the case this exists
/// to cover.
fn routable(ip: std::net::IpAddr) -> bool {
    use std::net::IpAddr;
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            // 100.64/10 is carrier-grade NAT: routable-looking, but not an address
            // a geo database will know.
            !(v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.is_unspecified()
                || v4.is_multicast()
                || (o[0] == 100 && (64..128).contains(&o[1])))
        }
        IpAddr::V6(v6) => {
            let head = v6.segments()[0];
            !(v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || head & 0xfe00 == 0xfc00 // unique-local
                || head & 0xffc0 == 0xfe80) // link-local
        }
    }
}

/// The machine's own global addresses, at most one per family.
///
/// The hub attributes a country from these before it falls back to where the
/// connection came from, and that fallback names nothing when the node reaches the
/// hub through a reverse proxy -- which is the standard deployment, since the hub
/// listens on loopback and nginx fronts it. Without this, every node behind a proxy
/// is left without a country.
fn own_addresses() -> (String, String) {
    let (mut v4, mut v6) = (String::new(), String::new());
    let Ok(ifaces) = if_addrs::get_if_addrs() else {
        return (v4, v6);
    };
    for iface in ifaces {
        match iface.addr {
            if_addrs::IfAddr::V4(a) if v4.is_empty() && routable(a.ip.into()) => {
                v4 = a.ip.to_string();
            }
            if_addrs::IfAddr::V6(a) if v6.is_empty() && routable(a.ip.into()) => {
                v6 = a.ip.to_string();
            }
            _ => {}
        }
    }
    (v4, v6)
}

/// One `KEY="value"` line out of a shell-style environment file.
fn env_field(path: &str, key: &str) -> String {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|body| {
            body.lines()
                .find_map(|l| l.strip_prefix(key))
                .map(|v| v.trim_start_matches('=').trim().trim_matches('"').to_string())
        })
        .unwrap_or_default()
}

/// The container this runs in, from what the kernel and systemd expose.
///
/// Empty when none is detected on purpose: a virtual machine and bare metal look
/// identical from inside, and labelling one as the other would put a wrong value
/// on the panel where a blank one is merely unhelpful.
fn container() -> String {
    if let Ok(env) = std::fs::read("/proc/1/environ") {
        let text = String::from_utf8_lossy(&env);
        if let Some(v) = text.split('\0').find_map(|p| p.strip_prefix("container=")) {
            if !v.is_empty() {
                return v.to_string();
            }
        }
    }
    std::fs::read_to_string("/run/systemd/container").map(|s| s.trim().to_string()).unwrap_or_default()
}

/// The CPU model, from `/proc/cpuinfo` on either architecture's spelling.
fn cpu_name() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|body| {
            body.lines().find_map(|l| {
                let (k, v) = l.split_once(':')?;
                let k = k.trim();
                matches!(k, "model name" | "Model" | "Hardware" | "cpu model").then(|| v.trim().to_string())
            })
        })
        .unwrap_or_default()
}

fn collect_facts(sys: &sysinfo::System) -> Facts {
    let disks = sysinfo::Disks::new_with_refreshed_list();
    let disk_total = disks.iter().fold(0, |t, d| t + d.total_space());
    // Physical cores where the platform reports them, logical otherwise: the panel
    // labels this "cores", and one figure has to serve both.
    let cpu_cores = sys.physical_core_count().filter(|n| *n > 0).unwrap_or_else(|| sys.cpus().len()) as u64;

    let (ipv4, ipv6) = own_addresses();

    Facts {
        hostname: hostname(),
        os: env_field("/etc/os-release", "PRETTY_NAME"),
        kernel: std::fs::read_to_string("/proc/sys/kernel/osrelease")
            .map(|s| s.trim().to_string())
            .unwrap_or_default(),
        arch: std::env::consts::ARCH.to_string(),
        virt: container(),
        cpu_name: cpu_name(),
        cpu_cores,
        mem_total: sys.total_memory(),
        swap_total: sys.total_swap(),
        disk_total,
        agent_version: env!("CARGO_PKG_VERSION").to_string(),
        ipv4,
        ipv6,
    }
}

/// JSON-RPC message from hub。
///
/// 只有 `method`：`vpn.deploy` 分支删除后，唯一还会到达的是 `ping.tasks`，
/// 而它尚未实现、参数也不用。等 ping.tasks 落地时再把 `params` 加回来。
#[derive(Debug, Deserialize)]
struct RpcMessage {
    method: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    // `provision` 是安装器以 root 调用的一次性动作，与常驻服务无关。
    // 在起 tracing、连 hub 之前就分派掉。
    if std::env::args().nth(1).as_deref() == Some("provision") {
        return provision::run(provision::parse_args(std::env::args().skip(2))?);
    }

    tracing_subscriber::fmt::init();

    let args = parse_args()?;
    info!("Connecting to {}", args.server);

    let request = websocket_request(&args.server, &args.token)?;

    let (ws_stream, _) = connect_async(request).await.context("Failed to connect to hub")?;

    info!("Connected to hub");

    let (mut write, mut read) = ws_stream.split();

    let mut sys = sysinfo::System::new_all();

    // Send hello: the facts the panel shows and never changes. Sent as a struct
    // rather than a hand-written object so a renamed field is a compile error here
    // rather than a blank column on the panel.
    let hello = json!({
        "jsonrpc": "2.0",
        "method": "hello",
        "params": collect_facts(&sys),
    });
    write.send(Message::Text(hello.to_string())).await?;
    info!("Sent hello");

    let mut rate = Rate::default();
    let mut interval = tokio::time::interval(args.interval);

    loop {
        tokio::select! {
            _ = interval.tick() => {
                // Send metrics report
                let metrics = collect_metrics(&mut sys, &args.ifaces, &mut rate);
                let report = json!({
                    "jsonrpc": "2.0",
                    "method": "report",
                    "params": metrics,
                });
                if let Err(e) = write.send(Message::Text(report.to_string())).await {
                    error!("Failed to send report: {}", e);
                    break;
                }
            }
            msg = read.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(rpc) = serde_json::from_str::<RpcMessage>(&text) {
                            match rpc.method.as_str() {
                                "ping.tasks" => {
                                    // TODO: Handle ping tasks
                                    info!("Received ping.tasks (not implemented)");
                                }
                                // `vpn.deploy` 曾在这里处理，需要 root 才能写 /etc 与调 systemctl。
                                // 那条通道已删除：部署改由 `provision` 在安装期以 root 完成。
                                // 这里刻意不保留任何等价分支 —— 运行期不得存在 root 指令通道。
                                other => {
                                    warn!("Unknown method from hub: {}", other);
                                }
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        info!("Connection closed by hub");
                        break;
                    }
                    Some(Err(e)) => {
                        error!("WebSocket error: {}", e);
                        break;
                    }
                    _ => {}
                }
            }
        }
    }

    anyhow::bail!("hub connection closed; service manager should reconnect")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_contains_complete_handshake_and_bearer_auth() {
        let r = websocket_request("ws://localhost:28080/api/agent/ws", "audit-token").unwrap();
        for header in ["Host", "Upgrade", "Connection", "Sec-WebSocket-Version", "Sec-WebSocket-Key"] {
            assert!(r.headers().contains_key(header), "{header}");
        }
        assert_eq!(r.headers()["Authorization"], "Bearer audit-token");
        assert!(r.uri().query().is_none());
        assert!(websocket_request("ws://localhost/api/agent/ws", "bad\r\nheader").is_err());
    }
    #[test]
    fn installer_environment_and_interval_are_supported() {
        let args = parse_values(
            ["--interval".into(), "2".into()],
            "https://example.com".into(),
            "audit-token".into(),
            "eth0,eth1".into(),
        )
        .unwrap();
        assert_eq!(args.server, "wss://example.com/api/agent/ws");
        assert_eq!(args.interval, Duration::from_secs(2));
        assert_eq!(args.ifaces, ["eth0", "eth1"]);
        for interval in ["0", "NaN", "-1", "3601"] {
            assert!(parse_values(
                ["--interval".into(), interval.into()],
                "http://localhost".into(),
                "t".into(),
                String::new()
            )
            .is_err());
        }
    }
    #[test]
    fn endpoint_conversion_preserves_ipv6_and_rejects_url_credentials() {
        assert_eq!(websocket_url("http://[::1]:28080").unwrap(), "ws://[::1]:28080/api/agent/ws");
        assert_eq!(
            websocket_url("wss://example.com/api/agent/ws").unwrap(),
            "wss://example.com/api/agent/ws"
        );
        assert!(websocket_url("https://user:secret@example.com").is_err());
        assert!(websocket_url("https://example.com?token=t").is_err());
    }

    /// The rate divides by elapsed time, so the first reading has none to divide by,
    /// and a counter that went backwards -- an interface reset -- must not become a
    /// negative or an enormous figure.
    #[test]
    fn the_rate_needs_two_readings_and_survives_a_reset() {
        let mut rate = Rate::default();
        assert_eq!(rate.measure(1_000, 2_000), (0, 0), "第一次没有间隔可除");
        std::thread::sleep(std::time::Duration::from_millis(20));
        let (rx, tx) = rate.measure(3_000, 4_000);
        assert!(rx > 0 && tx > 0, "第二次应该算出速率，实得 {rx}/{tx}");
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert_eq!(rate.measure(10, 20), (0, 0), "计数器回退说明接口重置，不能算成负数或巨大值");
    }

    /// The report has to carry every field the hub reads, or the panel shows a zero
    /// with nothing in any log to say why. This is the list `agent_ws::report_fields`
    /// checks on the other side; it is asserted here because that is the side that
    /// can be changed without noticing.
    #[test]
    fn the_report_carries_every_field_the_hub_reads() {
        let mut sys = sysinfo::System::new_all();
        let mut rate = Rate::default();
        let m = serde_json::to_value(collect_metrics(&mut sys, &[], &mut rate)).unwrap();
        let obj = m.as_object().unwrap();
        for key in [
            "boot_id",
            "net_rx_total",
            "net_tx_total",
            "uptime",
            "cpu",
            "load",
            "mem_total",
            "mem_used",
            "swap_total",
            "swap_used",
            "disk_total",
            "disk_used",
            "net_rx",
            "net_tx",
            "tcp",
            "udp",
            "procs",
        ] {
            assert!(obj.contains_key(key), "缺 {key}：hub 要它，缺了面板显示 0");
        }
    }

    /// The same argument for the facts `db::save_facts` stores on connect. Sending
    /// only a hostname left the panel's system row blank and the country attributed
    /// from the connection address instead of the machine's own.
    #[test]
    fn the_hello_carries_the_facts_the_hub_stores() {
        let sys = sysinfo::System::new_all();
        let f = serde_json::to_value(collect_facts(&sys)).unwrap();
        let obj = f.as_object().unwrap();
        for key in [
            "hostname",
            "os",
            "kernel",
            "arch",
            "virt",
            "cpu_name",
            "cpu_cores",
            "mem_total",
            "swap_total",
            "disk_total",
            "agent_version",
            "ipv4",
            "ipv6",
        ] {
            assert!(obj.contains_key(key), "缺 {key}：hub 的 save_facts 读它");
        }
        assert!(obj["mem_total"].as_u64().unwrap() > 0, "内存总量要读得到");
        assert!(!obj["os"].as_str().unwrap().is_empty(), "os 要读得到（/etc/os-release）");
        assert!(obj["cpu_cores"].as_u64().unwrap() > 0, "核数要读得到");
    }

    /// The address filter: a loopback or private address names no country, and the
    /// hub would fall back to the connection address -- which is `127.0.0.1` for
    /// every node behind a reverse proxy, so nothing at all.
    #[test]
    fn only_routable_addresses_are_reported() {
        use std::net::IpAddr;
        for private in [
            "127.0.0.1",
            "10.0.0.1",
            "192.168.1.1",
            "172.16.0.1",
            "169.254.1.1",
            "100.64.0.1",
            "::1",
            "fd00::1",
            "fe80::1",
        ] {
            assert!(!routable(private.parse::<IpAddr>().unwrap()), "{private} 不是全球可路由");
        }
        for public in ["50.114.172.226", "64.81.26.233", "2606:4700::1111"] {
            assert!(routable(public.parse::<IpAddr>().unwrap()), "{public} 应该被上报");
        }
    }

    /// The `/proc` readers, on the platform they are written for.
    #[test]
    fn the_proc_readers_answer_plausibly() {
        assert!(uptime() > 0, "开机时长应大于 0");
        assert!(process_count() >= 1, "至少有本进程");
        assert!(!hostname().is_empty());
        assert!(!boot_id().is_empty());

        // The header line is not a socket, and a file that is not there counts as
        // none rather than failing the report.
        let dir = std::env::temp_dir().join(format!("sock-count-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let f = dir.join("tcp");
        std::fs::write(&f, "  sl  local_address rem_address\n0: 1 2\n1: 3 4\n").unwrap();
        assert_eq!(socket_count(&[f.to_str().unwrap()]), 2, "表头不算");
        assert_eq!(socket_count(&["/proc/net/does-not-exist"]), 0, "缺失的文件算 0");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
