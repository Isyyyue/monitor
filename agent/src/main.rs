//! monitor-agent: reports system metrics to the hub and handles VPN deployment.
//!
//! Usage:
//!   monitor-agent --server wss://hub.example.com/agent --token TOKEN
//!   monitor-agent --server wss://hub.example.com/agent --token TOKEN --vpn-deploy

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{error, info, warn};

/// Command-line arguments
#[derive(Debug)]
struct Args {
    server: String,
    token: String,
}

fn parse_args() -> Result<Args> {
    let args: Vec<String> = std::env::args().collect();
    let mut server = String::new();
    let mut token = String::new();
    
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--server" => {
                i += 1;
                server = args.get(i).context("--server needs a value")?.clone();
            }
            "--token" => {
                i += 1;
                token = args.get(i).context("--token needs a value")?.clone();
            }
            _ => {}
        }
        i += 1;
    }
    
    if server.is_empty() || token.is_empty() {
        anyhow::bail!("Usage: monitor-agent --server WS_URL --token TOKEN");
    }
    
    Ok(Args { server, token })
}

/// System metrics collected from the host
#[derive(Debug, Serialize)]
struct Metrics {
    boot_id: String,
    hostname: String,
    cpu: f32,
    load: [f32; 3],
    mem_total: u64,
    mem_used: u64,
    disk_total: u64,
    disk_used: u64,
    net_rx_total: u64,
    net_tx_total: u64,
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

fn collect_metrics(sys: &mut sysinfo::System) -> Metrics {
    sys.refresh_all();
    
    let cpu = sys.global_cpu_info().cpu_usage();
    let load = sysinfo::System::load_average();
    
    let mem_total = sys.total_memory();
    let mem_used = sys.used_memory();
    
    // Disks
    let disks = sysinfo::Disks::new_with_refreshed_list();
    let (disk_total, disk_used) = disks.iter().fold((0, 0), |(t, u), d| {
        (t + d.total_space(), u + d.total_space() - d.available_space())
    });
    
    // Networks
    let networks = sysinfo::Networks::new_with_refreshed_list();
    let (rx, tx) = networks.iter().fold((0, 0), |(r, t), (_, n)| {
        (r + n.total_received(), t + n.total_transmitted())
    });
    
    Metrics {
        boot_id: boot_id(),
        hostname: hostname(),
        cpu,
        load: [load.one as f32, load.five as f32, load.fifteen as f32],
        mem_total,
        mem_used,
        disk_total,
        disk_used,
        net_rx_total: rx,
        net_tx_total: tx,
    }
}

/// JSON-RPC message from hub
#[derive(Debug, Deserialize)]
struct RpcMessage {
    method: String,
    params: serde_json::Value,
}

/// Handle vpn.deploy command from hub
async fn handle_vpn_deploy(_params: serde_json::Value) -> Result<serde_json::Value> {
    info!("Received vpn.deploy command");
    
    // 1. Check if running as root
    let uid = unsafe { libc::getuid() };
    if uid != 0 {
        return Ok(json!({
            "success": false,
            "error": "vpn.deploy requires root privileges"
        }));
    }
    
    // 2. Install sing-box if not present
    if !std::path::Path::new("/usr/local/bin/sing-box").exists() {
        info!("Installing sing-box...");
        install_sing_box().await?;
    }
    
    // 3. Generate credentials
    let uuid = generate_uuid();
    let (reality_private, reality_public) = generate_reality_keypair()?;
    let short_id = generate_short_id();
    let hy2_password = generate_password();
    
    // 4. Get server IP for links
    let server_ip = get_server_ip().unwrap_or_else(|| "SERVER_IP".to_string());
    
    // 5. Write sing-box config
    let config = generate_singbox_config(&uuid, &reality_private, &short_id, &hy2_password);
    std::fs::create_dir_all("/etc/sing-box")?;
    std::fs::write("/etc/sing-box/config.json", config)?;
    
    // 6. Generate self-signed cert for HY2
    generate_self_signed_cert()?;
    
    // 7. Create systemd service
    let service = r#"[Unit]
Description=sing-box VPN service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
"#;
    std::fs::write("/etc/systemd/system/sing-box.service", service)?;
    
    // 8. Start service
    let _ = tokio::process::Command::new("systemctl")
        .args(["daemon-reload"])
        .output().await;
    let _ = tokio::process::Command::new("systemctl")
        .args(["enable", "--now", "sing-box"])
        .output().await;
    
    // 9. Generate links
    let vless_link = format!(
        "vless://{}@{}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk={}&sid={}#VLESS",
        uuid, server_ip, reality_public, short_id
    );
    let hy2_link = format!(
        "hysteria2://{}@{}:443?insecure=1&sni=www.cloudflare.com#HY2",
        hy2_password, server_ip
    );
    
    info!("VPN deployment completed");
    
    Ok(json!({
        "success": true,
        "vless_link": vless_link,
        "hy2_link": hy2_link,
        "uuid": uuid,
        "reality_public_key": reality_public,
        "hy2_password": hy2_password,
    }))
}

fn generate_uuid() -> String {
    // Simple UUID v4 generation
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    use std::time::{SystemTime, UNIX_EPOCH};
    
    let mut hasher = DefaultHasher::new();
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos().hash(&mut hasher);
    std::process::id().hash(&mut hasher);
    let h1 = hasher.finish();
    
    let mut hasher = DefaultHasher::new();
    h1.hash(&mut hasher);
    "seed".hash(&mut hasher);
    let h2 = hasher.finish();
    
    format!("{:08x}-{:04x}-4{:03x}-{:04x}-{:012x}",
        (h1 >> 32) as u32,
        ((h1 >> 16) & 0xffff) as u16,
        (h1 & 0xfff) as u16,
        ((h2 >> 48) & 0xffff) as u16,
        h2 & 0xffffffffffff as u64
    )
}

fn generate_reality_keypair() -> Result<(String, String)> {
    // Use sing-box to generate reality keypair
    let output = std::process::Command::new("/usr/local/bin/sing-box")
        .args(["generate", "reality-keypair"])
        .output()
        .context("Failed to generate reality keypair")?;
    
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut private = String::new();
    let mut public = String::new();
    
    for line in stdout.lines() {
        if line.starts_with("PrivateKey:") {
            private = line.replace("PrivateKey:", "").trim().to_string();
        } else if line.starts_with("PublicKey:") {
            public = line.replace("PublicKey:", "").trim().to_string();
        }
    }
    
    if private.is_empty() || public.is_empty() {
        anyhow::bail!("Failed to parse reality keypair");
    }
    
    Ok((private, public))
}

fn generate_short_id() -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    use std::time::{SystemTime, UNIX_EPOCH};
    
    let mut hasher = DefaultHasher::new();
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos().hash(&mut hasher);
    format!("{:016x}", hasher.finish() & 0xffffffffffffffff)[..8].to_string()
}

fn generate_password() -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    use std::time::{SystemTime, UNIX_EPOCH};
    
    let mut hasher = DefaultHasher::new();
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos().hash(&mut hasher);
    format!("{:x}", hasher.finish())
}

async fn install_sing_box() -> Result<()> {
    info!("Downloading sing-box...");
    
    // Detect architecture
    let arch = std::env::consts::ARCH;
    let sb_arch = match arch {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        _ => anyhow::bail!("Unsupported architecture: {}", arch),
    };
    
    // Get latest version (hardcode for now, or fetch from API)
    let version = "1.14.2";
    let url = format!(
        "https://github.com/SagerNet/sing-box/releases/download/v{}/sing-box-{}-linux-{}.tar.gz",
        version, version, sb_arch
    );
    
    // Download using curl
    let output = tokio::process::Command::new("curl")
        .args(["-fsSL", "-o", "/tmp/sing-box.tar.gz", &url])
        .output()
        .await
        .context("Failed to download sing-box")?;
    
    if !output.status.success() {
        anyhow::bail!("curl failed to download sing-box");
    }
    
    // Extract
    let output = tokio::process::Command::new("tar")
        .args(["-xzf", "/tmp/sing-box.tar.gz", "-C", "/tmp"])
        .output()
        .await?;
    
    if !output.status.success() {
        anyhow::bail!("Failed to extract sing-box");
    }
    
    // Install binary
    let output = tokio::process::Command::new("sh")
        .args(["-c", &format!("cp /tmp/sing-box-{0}-linux-{1}/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box", version, sb_arch)])
        .output()
        .await?;
    
    if !output.status.success() {
        anyhow::bail!("Failed to install sing-box binary");
    }
    
    info!("sing-box installed successfully");
    Ok(())
}

fn generate_singbox_config(uuid: &str, reality_private: &str, short_id: &str, hy2_password: &str) -> String {
    json!({
        "log": {"level": "info"},
        "inbounds": [
            {
                "type": "vless",
                "tag": "vless-in",
                "listen": "::",
                "listen_port": 443,
                "users": [{"uuid": uuid, "flow": "xtls-rprx-vision"}],
                "tls": {
                    "enabled": true,
                    "server_name": "www.cloudflare.com",
                    "reality": {
                        "enabled": true,
                        "handshake": {"server": "www.cloudflare.com", "server_port": 443},
                        "private_key": reality_private,
                        "short_id": [short_id]
                    }
                }
            },
            {
                "type": "hysteria2",
                "tag": "hy2-in",
                "listen": "::",
                "listen_port": 443,
                "users": [{"password": hy2_password}],
                "tls": {
                    "enabled": true,
                    "alpn": ["h3"],
                    "certificate_path": "/etc/sing-box/cert.pem",
                    "key_path": "/etc/sing-box/key.pem"
                }
            }
        ],
        "outbounds": [{"type": "direct", "tag": "direct"}]
    }).to_string()
}

fn generate_self_signed_cert() -> Result<()> {
    let output = std::process::Command::new("openssl")
        .args([
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", "/etc/sing-box/key.pem",
            "-out", "/etc/sing-box/cert.pem",
            "-days", "3650", "-nodes",
            "-subj", "/CN=www.cloudflare.com"
        ])
        .output()
        .context("Failed to generate self-signed cert")?;
    
    if !output.status.success() {
        anyhow::bail!("openssl failed");
    }
    
    Ok(())
}

fn get_server_ip() -> Option<String> {
    // Try to get public IP
    std::process::Command::new("curl")
        .args(["-s", "--max-time", "5", "https://api.ipify.org"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout).ok().map(|s| s.trim().to_string())
            } else {
                None
            }
        })
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    
    let args = parse_args()?;
    info!("Connecting to {}", args.server);
    
    // Build WebSocket request with Bearer token in Authorization header
    // (Hub expects Authorization: Bearer <token>, not ?token= in URL)
    let request = http::Request::builder()
        .uri(args.server.as_str())
        .header("Authorization", format!("Bearer {}", args.token))
        .header("Host", args.server.split("://").nth(1).unwrap_or("localhost").split('/').next().unwrap_or("localhost"))
        .body(())
        .context("Failed to build WebSocket request")?;
    
    let (ws_stream, _) = connect_async(request)
        .await
        .context("Failed to connect to hub")?;
    
    info!("Connected to hub");
    
    let (mut write, mut read) = ws_stream.split();
    
    // Send hello
    let hello = json!({
        "jsonrpc": "2.0",
        "method": "hello",
        "params": {
            "hostname": hostname(),
            "version": env!("CARGO_PKG_VERSION"),
        }
    });
    write.send(Message::Text(hello.to_string())).await?;
    info!("Sent hello");
    
    let mut sys = sysinfo::System::new_all();
    let mut interval = tokio::time::interval(Duration::from_secs(10));
    
    loop {
        tokio::select! {
            _ = interval.tick() => {
                // Send metrics report
                let metrics = collect_metrics(&mut sys);
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
                                "vpn.deploy" => {
                                    match handle_vpn_deploy(rpc.params).await {
                                        Ok(result) => {
                                            let response = json!({
                                                "jsonrpc": "2.0",
                                                "method": "vpn.result",
                                                "params": result,
                                            });
                                            let _ = write.send(Message::Text(response.to_string())).await;
                                        }
                                        Err(e) => {
                                            error!("vpn.deploy failed: {}", e);
                                        }
                                    }
                                }
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
    
    Ok(())
}
