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
use std::sync::Arc;
use std::time::Duration;
use tokio_tungstenite::{
    connect_async, connect_async_tls_with_config,
    tungstenite::{client::IntoClientRequest, Message},
    Connector,
};
use tracing::{error, info, warn};

mod provision;
mod proxy_probe;
mod subscription;

/// Arguments also accept the environment written by install.sh.
#[derive(Debug)]
struct Args {
    server: String,
    token: String,
    interval: Duration,
    ifaces: Vec<String>,
    /// Accept whatever certificate the hub presents. Needed for a hub with no
    /// domain, whose panel is served under a self-signed certificate no public
    /// CA will vouch for; off by default, because the same switch accepts a
    /// forged certificate just as happily.
    insecure: bool,
}

fn parse_values(
    values: impl IntoIterator<Item = String>,
    server: String,
    token: String,
    iface: String,
    insecure: bool,
) -> Result<Args> {
    let mut out = Args {
        server,
        token,
        interval: Duration::from_secs(1),
        ifaces: iface.split(',').filter(|v| !v.is_empty()).map(str::to_owned).collect(),
        insecure,
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
            // Accepted here rather than refused: a hub with no domain serves its
            // panel under a self-signed certificate, and this is what lets a
            // node reach it. It is still an explicit choice -- the installer
            // only writes MONITOR_INSECURE when the operator asked for it, and
            // the note printed at the end says what it gives up.
            "--insecure" => out.insecure = true,
            "--verify-tls" => out.insecure = false,
            _ => anyhow::bail!("unknown argument: {flag}"),
        }
    }
    if out.server.is_empty() || out.token.is_empty() {
        anyhow::bail!("set MONITOR_SERVER/MONITOR_TOKEN or --server/--token");
    }
    out.server = websocket_url(&out.server)?;
    out.ifaces =
        out.ifaces.iter().map(|name| name.trim().to_owned()).filter(|name| !name.is_empty()).collect();
    for name in &out.ifaces {
        let name = name.strip_prefix('-').unwrap_or(name);
        anyhow::ensure!(
            !name.is_empty()
                && !name.starts_with('-')
                && name.bytes().all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c)),
            "invalid interface name"
        );
    }
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

/// A connector that accepts any certificate the hub presents.
///
/// Reached only through `--insecure` / `MONITOR_INSECURE`. A hub with no domain
/// serves its panel under a self-signed certificate that no public CA vouches
/// for, and the alternative is not a stronger check -- it is plaintext HTTP,
/// where the node token crosses the network in the clear. This keeps the
/// traffic encrypted and gives up the identity check instead; the installer
/// says which one it took when it writes the setting.
///
/// `dangerous()` has carried no feature gate of its own since rustls 0.22 -- the
/// name is the warning. What keeps this out of a normal deployment is that
/// nothing calls it unless `--insecure` / `MONITOR_INSECURE` was set.
fn any_certificate() -> Connector {
    let config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCertificate))
        .with_no_client_auth();
    Connector::Rustls(Arc::new(config))
}

/// Says yes to every certificate, which is the whole point of `--insecure`.
///
/// The three verification methods are the ones rustls asks; returning the
/// "assertion" value from each is what turns a check into a formality. The
/// scheme list stays the real one -- offering to verify nothing is not the same
/// as offering to speak no TLS at all, and a short list here would break the
/// handshake against a perfectly good certificate.
#[derive(Debug)]
struct AcceptAnyCertificate;

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCertificate {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider().signature_verification_algorithms.supported_schemes()
    }
}

/// A switch that comes from the environment rather than the command line.
///
/// Anything but empty, `0`, `no` and `false` turns it on: install.sh writes
/// `1`, and someone setting it by hand should not have to guess which spelling
/// this build wants. The same reading as `MONITOR_IFACE` being non-empty.
fn env_flag(name: &str) -> bool {
    match std::env::var(name) {
        Ok(v) => !matches!(v.trim().to_ascii_lowercase().as_str(), "" | "0" | "no" | "false"),
        Err(_) => false,
    }
}

fn parse_args() -> Result<Args> {
    parse_values(
        std::env::args().skip(1),
        std::env::var("MONITOR_SERVER").unwrap_or_default(),
        std::env::var("MONITOR_TOKEN").unwrap_or_default(),
        std::env::var("MONITOR_IFACE").unwrap_or_default(),
        env_flag("MONITOR_INSECURE"),
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
    iface: String,
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
    paths.iter().filter_map(|p| std::fs::File::open(p).ok().and_then(|f| count_socket_rows(f).ok())).sum()
}

fn count_socket_rows(mut reader: impl std::io::Read) -> std::io::Result<u64> {
    let mut buffer = [0; 8192];
    let mut lines = 0u64;
    let mut last = None;
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        lines += buffer[..n].iter().filter(|&&b| b == b'\n').count() as u64;
        last = Some(buffer[n - 1]);
    }
    Ok((lines + u64::from(last.is_some_and(|b| b != b'\n'))).saturating_sub(1))
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

#[derive(Default)]
struct Sampling {
    rate: Rate,
    disks: Option<sysinfo::Disks>,
    listed_at: Option<std::time::Instant>,
    boot: Option<String>,
    host: Option<String>,
}

fn includes_interface(name: &str, rules: &[String]) -> bool {
    let included = !rules.iter().any(|rule| !rule.starts_with('-')) || rules.iter().any(|rule| rule == name);
    included && !rules.iter().any(|rule| rule.strip_prefix('-') == Some(name))
}

fn network_totals(body: &str, rules: &[String]) -> (u64, u64) {
    body.lines()
        .filter_map(|line| {
            let (name, counters) = line.split_once(':')?;
            if !includes_interface(name.trim(), rules) {
                return None;
            }
            let mut counters = counters.split_whitespace();
            let rx = counters.next()?.parse::<u64>().ok()?;
            let tx = counters.nth(7)?.parse::<u64>().ok()?;
            Some((rx, tx))
        })
        .fold((0u64, 0u64), |(rx, tx), (r, t)| (rx.saturating_add(r), tx.saturating_add(t)))
}

fn collect_metrics(sys: &mut sysinfo::System, ifaces: &[String], sample: &mut Sampling) -> Metrics {
    // 只刷 CPU 与内存。`refresh_all()` 还会走一遍**每个进程**去建一张没人读的列表
    // —— 在忙一点的机器上那是这个 agent 最大的一笔开销，而它采完就扔。
    // 进程数是从 /proc 数的，磁盘和网卡在下面各自刷新自己的列表。
    sys.refresh_cpu();
    sys.refresh_memory();

    let cpu = sys.global_cpu_info().cpu_usage();
    let load = sysinfo::System::load_average();

    let mem_total = sys.total_memory();
    let mem_used = sys.used_memory();
    let swap_total = sys.total_swap();
    let swap_used = sys.used_swap();

    // Disks
    let relist = sample.listed_at.is_none_or(|at| at.elapsed() >= Duration::from_secs(30));
    let disks = sample.disks.get_or_insert_with(sysinfo::Disks::new);
    if relist {
        disks.refresh_list();
        sample.listed_at = Some(std::time::Instant::now());
        sample.host = Some(hostname());
    } else {
        disks.refresh();
    }
    let (disk_total, disk_used) = disks
        .iter()
        .fold((0, 0), |(t, u), d| (t + d.total_space(), u + d.total_space() - d.available_space()));

    // Networks
    let (rx, tx) = network_totals(&std::fs::read_to_string("/proc/net/dev").unwrap_or_default(), ifaces);
    let (net_rx, net_tx) = sample.rate.measure(rx, tx);

    Metrics {
        iface: ifaces.join(","),
        boot_id: sample.boot.get_or_insert_with(boot_id).clone(),
        hostname: sample.host.clone().unwrap_or_default(),
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
/// `params` 只有 `ping.tasks` 用。`vpn.deploy` 分支删除后这里不再是指令通道，
/// 运行期依旧不存在任何 root 动作 —— 探针只做一次 TCP 连接。
#[derive(Debug, Deserialize)]
struct RpcMessage {
    method: String,
    #[serde(default)]
    params: serde_json::Value,
}

/// hub 派给本节点的探针：每 `interval` 秒对 `target` 做一次 TCP 连接，回报耗时。
///
/// 只有 `host:port` 一种形态，面板的输入提示就是这么写的，hub 也照原样下发。
#[derive(Debug, Deserialize)]
struct PingTask {
    id: i64,
    target: String,
    interval: i64,
}

/// hub 保存任务时夹到同一个下限（`Db::MIN_PROBE_INTERVAL`）。这里再夹一次是兜底：
/// 跑得比 hub 收得下的还快，多出来的结果只会被丢掉，不会变成更细的曲线。
const MIN_PROBE_INTERVAL: i64 = 5;
/// 同上，对应 `Db::MAX_PROBES_PER_NODE`。
const MAX_PROBES: usize = 64;
/// 够一次跨洋握手，又不至于让黑洞目标把下一次探测挤到间隔之外。
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);
// VPN deployment restarts sing-box and the agent together. Give the local
// inbounds a moment to bind before the first proxy sample, otherwise a healthy
// tunnel is drawn with one artificial loss at the deployment boundary.
const PROXY_WARMUP: Duration = Duration::from_secs(5);

/// 一次 TCP 连接的耗时，毫秒；连不上回报 -1。
///
/// 失败必须**回报**而不是跳过：hub 把负值记为丢包，而缺 `latency_ms` 的帧会被
/// 当成畸形帧丢掉 —— 沉默会在图上画出一段空白，而不是一次丢包。
async fn probe_once(target: &str) -> i64 {
    let started = std::time::Instant::now();
    match tokio::time::timeout(PROBE_TIMEOUT, tokio::net::TcpStream::connect(target)).await {
        Ok(Ok(_)) => started.elapsed().as_millis() as i64,
        _ => -1,
    }
}

/// 这个目标是不是一个拨得动的 `host:port`。
///
/// 普通 TCP 任务必须有可解析的端口。`proxy:vless` / `proxy:hy2` 由已配置的
/// 本地 HTTP 代理测量；未配置的代理标签不执行，避免产生虚假的失败记录。
fn dialable(target: &str) -> bool {
    let Some((host, port)) = target.rsplit_once(':') else {
        return false;
    };
    !host.is_empty() && !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit())
}

/// 值得跑的探针，夹到 hub 收得下的范围内。
///
/// hub 在保存任务时已经拦过一遍，这里是兜底：一个越界的列表会让多出来的探针跑了
/// 却发不出去，节点白忙，面板上却什么都没有。
fn runnable(tasks: Vec<PingTask>, proxies: &proxy_probe::Proxies) -> Vec<PingTask> {
    tasks
        .into_iter()
        .filter(|t| t.id > 0 && (dialable(t.target.trim()) || proxies.supports(t.target.trim())))
        .take(MAX_PROBES)
        .map(|t| PingTask {
            target: t.target.trim().to_owned(),
            interval: t.interval.max(MIN_PROBE_INTERVAL),
            ..t
        })
        .collect()
}

/// 一条正在跑的探针。
struct Running {
    target: String,
    interval: i64,
    handle: tokio::task::JoinHandle<()>,
}

/// 本会话在跑的探针，按任务 id。
#[derive(Default)]
struct Probes {
    running: std::collections::HashMap<i64, Running>,
    proxies: proxy_probe::Proxies,
}

impl Probes {
    /// 把在跑的对齐到 hub 刚下发的列表。
    ///
    /// 目标和间隔都没变的探针**原样留着**：hub 只要有一个任务改动就会推整个列表，
    /// 把其余的重启会重置它们的计时，还会丢掉正要发出的那一次读数。
    fn reconcile(&mut self, tasks: Vec<PingTask>, results: &tokio::sync::mpsc::Sender<Message>) {
        let mut keep = std::collections::HashSet::new();
        for task in runnable(tasks, &self.proxies) {
            keep.insert(task.id);
            let unchanged = self
                .running
                .get(&task.id)
                .is_some_and(|r| r.target == task.target && r.interval == task.interval);
            if unchanged {
                continue;
            }
            if let Some(old) = self.running.remove(&task.id) {
                old.handle.abort();
            }
            let handle = tokio::spawn(run_probe(
                task.id,
                task.target.clone(),
                task.interval,
                results.clone(),
                self.proxies.clone(),
            ));
            self.running.insert(task.id, Running { target: task.target, interval: task.interval, handle });
        }
        // 这一轮没提到的任务：面板删了它，或者本节点被取消了分配。
        self.running.retain(|id, r| {
            let gone = !keep.contains(id);
            if gone {
                r.handle.abort();
            }
            !gone
        });
    }
}

/// 会话结束时把它的探针收掉。
///
/// 进程现在活得比一个会话长（断了会在原地重连），所以丢掉 JoinHandle 不等于任务
/// 停了 —— 它们会一直跑，每到一个间隔就往一个已经没有人读的通道里写一帧。
impl Drop for Probes {
    fn drop(&mut self) {
        for probe in self.running.values() {
            probe.handle.abort();
        }
    }
}

/// 一条探针的循环：连、回报、等。
///
/// 第一次立刻做，面板上刚加的监控不用等满一个间隔才有数字。
async fn run_probe(
    id: i64,
    target: String,
    interval: i64,
    results: tokio::sync::mpsc::Sender<Message>,
    proxies: proxy_probe::Proxies,
) {
    let period = Duration::from_secs(interval.max(MIN_PROBE_INTERVAL) as u64);
    let mut ticker = tokio::time::interval(period);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    if proxies.supports(&target) {
        tokio::time::sleep(PROXY_WARMUP).await;
    }
    loop {
        ticker.tick().await;
        let latency = if proxies.supports(&target) {
            proxies.measure(&target).await
        } else {
            probe_once(&target).await
        };
        let frame = json!({
            "jsonrpc": "2.0",
            "method": "ping.result",
            "params": { "task_id": id, "latency_ms": latency },
        });
        // 写端已经走了就收工；留在这里只会攒下一堆没人要的帧。
        if results.send(Message::Text(frame.to_string())).await.is_err() {
            return;
        }
    }
}

fn main() -> Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--supports-proxy-probes") {
        return Ok(());
    }
    // `provision` 是安装器以 root 调用的一次性动作，与常驻服务无关。
    // 在起 tracing、连 hub 之前就分派掉 —— 也就不用先起一个 runtime。
    if std::env::args().nth(1).as_deref() == Some("provision") {
        return provision::run(provision::parse_args(std::env::args().skip(2))?);
    }

    // 单线程 runtime。`#[tokio::main]` 默认开的是多线程的，按核数铺 worker 线程，
    // 每个都带自己的栈 —— 而这个 agent 的活是「每秒发一帧、几条探针各自睡等」，
    // 用不上它们。阻塞线程数也压到 4。
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(4)
        .build()?
        .block_on(run())
}

async fn run() -> Result<()> {
    tracing_subscriber::fmt::init();

    let args = parse_args()?;

    // 订阅和监控是两件事：一个坏了不该把另一个带走。这里起不来只记一条警告，
    // 安装器会独立确认监听到底有没有起来。
    if let Err(e) = subscription::start(&args.server, &args.token, args.insecure).await {
        warn!("subscription listener unavailable: {e:#}");
    }

    loop {
        if let Err(e) = session(&args).await {
            error!("Hub session ended: {e:#}");
        }
        // 订阅要一直在，所以这里重连而不是退出：退出会让服务管理器重启进程，
        // 端口跟着断一下 —— 而客户端可能正好在这时候来取订阅。
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

async fn session(args: &Args) -> Result<()> {
    info!("Connecting to {}", args.server);

    let request = websocket_request(&args.server, &args.token)?;

    // `connect_async` keeps webpki's roots and is what every normal deployment
    // takes. The TLS-aware entry point is the only one that accepts a
    // connector, so it is reached only when the operator asked for it -- a
    // deployment that did not ask cannot end up with the loosened connector by
    // accident.
    let (ws_stream, _) = if args.insecure {
        connect_async_tls_with_config(request, None, false, Some(any_certificate()))
            .await
            .context("Failed to connect to hub")?
    } else {
        connect_async(request).await.context("Failed to connect to hub")?
    };

    info!("Connected to hub");

    let (mut write, mut read) = ws_stream.split();

    // 不用 `new_all()`：那会走一遍每个进程，建一张没人读的列表。
    let mut sys = sysinfo::System::new();
    sys.refresh_cpu();
    sys.refresh_memory();

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

    let mut sampling = Sampling::default();
    let mut interval = tokio::time::interval(args.interval);
    // 探针各自跑在 spawn 出来的任务里，读数从这里回到唯一的写端：一个 WebSocket
    // 只能有一个写者，几条探针各写各的会交错成坏帧。
    //
    // 有界：hub 那头慢下来时，无限队列会一直攒帧。有界则让探针在写端堵住时等一等，
    // 而 64 条正好是一个节点能跑的最大探针数。
    let (results_tx, mut results_rx) = tokio::sync::mpsc::channel::<Message>(MAX_PROBES);
    let proxies = proxy_probe::Proxies::from_env().unwrap_or_else(|e| {
        warn!("proxy measurements disabled: {e:#}");
        Default::default()
    });
    let mut probes = Probes { proxies, running: Default::default() };

    loop {
        tokio::select! {
            _ = interval.tick() => {
                // Send metrics report
                let metrics = collect_metrics(&mut sys, &args.ifaces, &mut sampling);
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
            Some(frame) = results_rx.recv() => {
                if let Err(e) = write.send(frame).await {
                    error!("Failed to send probe result: {}", e);
                    break;
                }
            }
            msg = read.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(rpc) = serde_json::from_str::<RpcMessage>(&text) {
                            match rpc.method.as_str() {
                                "ping.tasks" => {
                                    // 整个列表，不是增量：hub 只在任务变化时推，收到的
                                    // 就是本节点当前该跑的全部。
                                    match serde_json::from_value::<Vec<PingTask>>(rpc.params) {
                                        Ok(tasks) => {
                                            info!("Received {} ping task(s)", tasks.len());
                                            probes.reconcile(tasks, &results_tx);
                                        }
                                        Err(e) => warn!("Unusable ping.tasks payload: {}", e),
                                    }
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

    anyhow::bail!("hub connection closed")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_row_count_matches_text_count_across_chunks() {
        for input in [
            String::new(),
            "header".into(),
            "header\n".into(),
            "header\r\nrow\r\nrow".into(),
            format!("header\n{}", "row\n".repeat(100_000)),
        ] {
            assert_eq!(
                count_socket_rows(input.as_bytes()).unwrap(),
                input.lines().count().saturating_sub(1) as u64
            );
        }
    }

    #[test]
    fn reports_the_interface_configuration_to_the_panel() {
        let mut sys = sysinfo::System::new();
        let value =
            serde_json::to_value(collect_metrics(&mut sys, &["-lo".into()], &mut Sampling::default()))
                .unwrap();
        assert_eq!(value["iface"], "-lo");
    }

    #[test]
    fn interface_rules_select_real_counter_columns() {
        let body = "lo: 10 0 0 0 0 0 0 0 100\neth0: 20 0 0 0 0 0 0 0 200\neth1: 30 0 0 0 0 0 0 0 300\n";
        assert_eq!(network_totals(body, &[]), (60, 600));
        assert_eq!(network_totals(body, &["-lo".into()]), (50, 500));
        assert_eq!(network_totals(body, &["eth0".into(), "eth1".into(), "-eth1".into()]), (20, 200));
    }

    #[test]
    fn excluding_an_absent_interface_preserves_other_counters() {
        let mut sys = sysinfo::System::new();
        let all = collect_metrics(&mut sys, &[], &mut Sampling::default());
        let excluded = collect_metrics(&mut sys, &["-monitor-not-present".into()], &mut Sampling::default());
        assert!(all.net_rx_total + all.net_tx_total > 0);
        assert!(excluded.net_rx_total + excluded.net_tx_total >= all.net_rx_total + all.net_tx_total);
    }
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
            false,
        )
        .unwrap();
        assert_eq!(args.server, "wss://example.com/api/agent/ws");
        assert_eq!(args.interval, Duration::from_secs(2));
        assert_eq!(args.ifaces, ["eth0", "eth1"]);
        assert!(!args.insecure, "证书校验默认开着");
        for interval in ["0", "NaN", "-1", "3601"] {
            assert!(parse_values(
                ["--interval".into(), interval.into()],
                "http://localhost".into(),
                "t".into(),
                String::new(),
                false
            )
            .is_err());
        }
    }

    /// `--insecure` is how a node reaches a hub with no domain, whose panel is
    /// served under a self-signed certificate. It has to survive the trip in
    /// from the environment, because that is where install.sh puts it.
    #[test]
    fn insecure_is_off_by_default_and_on_when_asked() {
        let from_flag = parse_values(
            ["--insecure".into()],
            "https://198.51.100.1:8444".into(),
            "t".into(),
            String::new(),
            false,
        )
        .unwrap();
        assert!(from_flag.insecure, "--insecure 要能打开");

        let from_env =
            parse_values([], "https://198.51.100.1:8444".into(), "t".into(), String::new(), true).unwrap();
        assert!(from_env.insecure, "环境变量那条路也要能打开");
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
        let mut rate = Sampling::default();
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

    /// 探针要么量到一个耗时，要么回报丢包。沉默不是选项：hub 把负值记为丢包，
    /// 而缺 `latency_ms` 的帧会被当畸形帧丢掉 —— 图上就成了空白而不是一次丢包。
    #[tokio::test]
    async fn a_probe_measures_a_handshake_and_reports_a_refusal() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { while listener.accept().await.is_ok() {} });
        assert!(probe_once(&addr.to_string()).await >= 0, "连得上的目标应该量到耗时");

        // 绑过再放掉：端口已经关掉，没人应答。
        let closed = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let dead = closed.local_addr().unwrap();
        drop(closed);
        assert_eq!(probe_once(&dead.to_string()).await, -1, "连不上要回报丢包");
    }

    /// hub 保存任务时拦过一遍，agent 这边是兜底：越界的探针跑了却发不出去，
    /// 节点白忙而面板上什么都没有。
    #[test]
    fn probes_are_clamped_to_what_the_hub_will_accept() {
        let task = |id, target: &str, interval| PingTask { id, target: target.into(), interval };
        let kept = runnable(
            vec![
                task(1, "1.1.1.1:443", 60),
                task(0, "1.1.1.1:443", 60),
                task(-3, "1.1.1.1:443", 60),
                task(2, "   ", 60),
                task(3, "1.1.1.1:443", 1),
            ],
            &Default::default(),
        );
        assert_eq!(kept.len(), 2, "只有 id 和目标都成立的留下");
        assert_eq!(kept[0].id, 1);
        assert_eq!(kept[1].interval, MIN_PROBE_INTERVAL, "低于下限的间隔夹到下限");

        let many: Vec<_> = (1..=MAX_PROBES as i64 + 10).map(|i| task(i, "1.1.1.1:443", 60)).collect();
        assert_eq!(runnable(many, &Default::default()).len(), MAX_PROBES, "超出上限的截掉");
    }

    /// 面板上的任务不全是给 agent 的：`proxy:vless` 这类是给代理探针的标签。
    /// 拨它只会得到 -1，而 hub 把负值记成丢包 —— 探针的曲线会被假丢包污染。
    #[test]
    fn only_dialable_targets_are_probed() {
        assert!(dialable("1.1.1.1:443"));
        assert!(dialable("example.com:80"));
        assert!(dialable("[2606:4700::1111]:443"), "带方括号的 IPv6 也算");
        assert!(!dialable("proxy:vless"), "端口位不是数字，拨不动");
        assert!(!dialable("proxy:hy2"));
        assert!(!dialable("example.com"), "没有端口");
        assert!(!dialable(":443"), "没有主机");
        assert!(!dialable("example.com:"));
        assert!(!dialable(""));

        // 这一条是真正要防的：探针占着 task 1/2，agent 不能去写同一批行。
        let tasks = vec![
            PingTask { id: 1, target: "proxy:vless".into(), interval: 60 },
            PingTask { id: 2, target: "proxy:hy2".into(), interval: 60 },
            PingTask { id: 3, target: "1.1.1.1:443".into(), interval: 60 },
        ];
        let kept = runnable(tasks, &Default::default());
        assert_eq!(kept.len(), 1, "只留拨得动的那条");
        assert_eq!(kept[0].id, 3);
    }
}
