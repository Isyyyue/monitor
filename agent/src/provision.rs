//! 节点 provision：按标准形态把 sing-box 与订阅铺到本机。
//!
//! **只由安装器以 root 调用一次**（`monitor-agent provision --server … --sni … --label …`）。
//! 常驻服务不引用本模块的任何写入函数 —— 运行期不存在 root 指令通道。
//!
//! 标准形态来自 2026-10-05 的实机定论：**节点以 64 机为准**。
//! 三个订阅文件的生成是**逐字节契约**，验收标准是能复现 64 机的现状。

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};
use base64::Engine as _;
use serde_json::{json, Value};

/// Replace a complete file on its own filesystem, retaining its permissions.
fn atomic_write(path: &Path, contents: impl AsRef<[u8]>) -> Result<()> {
    atomic_write_mode(path, contents, 0o600)
}

fn atomic_write_mode(path: &Path, contents: impl AsRef<[u8]>, mode: u32) -> Result<()> {
    use std::io::Write;
    let parent = path.parent().context("file has no parent")?;
    std::fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".monitor-{}-{}", std::process::id(), random_hex(8)?));
    let result = (|| -> Result<()> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(mode);
        }
        let mut file = options.open(&temporary)?;
        if let Ok(metadata) = std::fs::metadata(path) {
            file.set_permissions(metadata.permissions())?;
        }
        file.write_all(contents.as_ref())?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

/// Recover the previously serving files if activation or publication fails.
struct FileSnapshot(Vec<(PathBuf, Option<Vec<u8>>)>);
impl FileSnapshot {
    fn capture(paths: &[&Path]) -> Result<Self> {
        let mut files = Vec::new();
        for path in paths {
            let contents = match std::fs::read(path) {
                Ok(contents) => Some(contents),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                Err(e) => return Err(e.into()),
            };
            files.push((path.to_path_buf(), contents));
        }
        Ok(Self(files))
    }
    fn restore(&self) -> Result<()> {
        for (path, contents) in &self.0 {
            match contents {
                Some(contents) => atomic_write(path, contents)?,
                None => match std::fs::remove_file(path) {
                    Ok(()) => (),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                    Err(e) => return Err(e.into()),
                },
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------- 标准形态的固定部分

/// REALITY 的伪装目标站。全节点统一。
pub const REALITY_SERVER_NAME: &str = "www.cloudflare.com";
pub const REALITY_HANDSHAKE_PORT: u16 = 443;
/// VLESS 与 Hysteria2 都监听 443（TCP / UDP 不冲突）。
pub const LISTEN_PORT: u16 = 443;
pub const VLESS_FLOW: &str = "xtls-rprx-vision";
pub const CLIENT_FINGERPRINT: &str = "chrome";
pub const HY2_OBFS: &str = "salamander";
pub const HY2_ALPN: &str = "h3";

pub const CONFIG_DIR: &str = "/etc/sing-box";
pub const CERT_DIR: &str = "/etc/sing-box/certs";
pub const CERT_PATH: &str = "/etc/sing-box/certs/fullchain.pem";
pub const KEY_PATH: &str = "/etc/sing-box/certs/privkey.pem";
pub const SUB_DIR: &str = "/var/www/sub";
/// Where the subscription paths chosen on the first run are remembered, so a
/// rerun keeps serving the same URLs.
///
/// **Deliberately not in `CONFIG_DIR`.** The packaged unit starts sing-box with
/// `-C /etc/sing-box`, which decodes *every* `*.json` in that directory: a state
/// file there is read as configuration and the service refuses to start with
/// `unknown field "clash"`. This directory is sing-box's own state directory and
/// is not scanned for config.
pub const SUB_STATE: &str = "/var/lib/sing-box/subscription.json";
/// 包自带的单元，不是我们自己写的。provision 不写 unit。
pub const PACKAGE_UNIT: &str = "/lib/systemd/system/sing-box.service";

/// short_id 用满 16 位 hex（REALITY 的上限，64 机就是这个长度）。
const SHORT_ID_BYTES: usize = 8;
/// Hysteria2 密码与 obfs 密码各 16 字节 → 32 hex（与 64 机一致）。
const SECRET_BYTES: usize = 16;

// ---------------------------------------------------------------- 节点参数

/// 一个节点的全部可变量；其余一律来自上面的常量。
#[derive(Debug, Clone, Default)]
pub struct Node {
    /// 节点公网地址（IP 或域名）—— 订阅里客户端连的地址
    pub server: String,
    /// Hysteria2 的 sni，同时用作自签证书的 CN
    pub sni_hy2: String,
    /// 订阅里节点名的前缀，如 "LAX" → "LAX-VLESS" / "LAX-HY2"
    pub label: String,
    pub uuid: String,
    pub reality_private_key: String,
    pub reality_public_key: String,
    pub short_id: String,
    pub hy2_password: String,
    pub obfs_password: String,
    /// 订阅文件头两行注释（64 机的形态；可留空）
    pub title: String,
    pub subtitle: String,
}

impl Node {
    pub fn vless_name(&self) -> String {
        format!("{}-VLESS", self.label)
    }

    pub fn hy2_name(&self) -> String {
        format!("{}-HY2", self.label)
    }
}

// ---------------------------------------------------------------- 内容生成（逐字节契约）

/// sing-box config.json。
///
/// 与旧 `handle_vpn_deploy` 的差别：tag 是 `vless-reality-in`/`hysteria2-in`；
/// HY2 带 obfs salamander；证书在 `/etc/sing-box/certs/`；没有 socks inbound；listen 是 0.0.0.0。
pub fn render_config(n: &Node) -> Result<String> {
    let cfg = json!({
        "log": { "level": "info" },
        "inbounds": [
            {
                "type": "vless",
                "tag": "vless-reality-in",
                "listen": "0.0.0.0",
                "listen_port": LISTEN_PORT,
                "users": [{ "name": "v2rayN", "uuid": n.uuid, "flow": VLESS_FLOW }],
                "tls": {
                    "enabled": true,
                    "server_name": REALITY_SERVER_NAME,
                    "reality": {
                        "enabled": true,
                        "handshake": {
                            "server": REALITY_SERVER_NAME,
                            "server_port": REALITY_HANDSHAKE_PORT
                        },
                        "private_key": n.reality_private_key,
                        "short_id": [n.short_id]
                    }
                }
            },
            {
                "type": "hysteria2",
                "tag": "hysteria2-in",
                "listen": "0.0.0.0",
                "listen_port": LISTEN_PORT,
                "users": [{ "password": n.hy2_password }],
                "obfs": { "type": HY2_OBFS, "password": n.obfs_password },
                "tls": {
                    "enabled": true,
                    "server_name": n.sni_hy2,
                    "certificate_path": CERT_PATH,
                    "key_path": KEY_PATH
                },
                "brutal_debug": false
            }
        ],
        "outbounds": [{ "type": "direct", "tag": "direct" }]
    });
    let mut out = serde_json::to_string_pretty(&cfg).context("serialize sing-box config")?;
    out.push('\n');
    Ok(out)
}

/// v2rayN 订阅：两行，**无结尾换行**。逐字节契约。
pub fn render_v2ray_txt(n: &Node) -> String {
    let vless = format!(
        "vless://{}@{}:{}?encryption=none&flow={}&security=reality&sni={}&fp={}&pbk={}&sid={}#{}",
        n.uuid,
        n.server,
        LISTEN_PORT,
        VLESS_FLOW,
        REALITY_SERVER_NAME,
        CLIENT_FINGERPRINT,
        n.reality_public_key,
        n.short_id,
        n.vless_name()
    );
    let hy2 = format!(
        "hysteria2://{}@{}:{}?obfs={}&obfs-password={}&sni={}&insecure=1#{}",
        n.hy2_password,
        n.server,
        LISTEN_PORT,
        HY2_OBFS,
        n.obfs_password,
        n.sni_hy2,
        n.hy2_name()
    );
    format!("{vless}\n{hy2}")
}

/// v2rayN base64 订阅 = `base64(txt)`（标准 base64、带 padding），**无结尾换行**。逐字节契约。
pub fn render_v2ray_b64(n: &Node) -> String {
    base64::engine::general_purpose::STANDARD.encode(render_v2ray_txt(n))
}

/// Clash 订阅，**有结尾换行**。逐字节契约。
///
/// 必须带 `proxy-groups` 与 `rules`：没有它们的裸配置会把国内流量也送进代理，
/// 这是「能用」与「不能用」的差别，不是风格差异。
pub fn render_clash_yaml(n: &Node) -> String {
    let mut out = String::new();
    if !n.title.is_empty() {
        out.push_str(&format!("# {}\n", n.title));
    }
    if !n.subtitle.is_empty() {
        out.push_str(&format!("# {}\n", n.subtitle));
    }
    // 以下字面量从第 0 列开始写：任何缩进都会进入输出。
    out.push_str(&format!(
        r#"proxies:
  - name: "{vname}"
    type: vless
    server: {server}
    port: {port}
    uuid: {uuid}
    network: tcp
    udp: true
    tls: true
    flow: {flow}
    servername: {reality_sni}
    client-fingerprint: {fp}
    reality-opts:
      public-key: {pbk}
      short-id: {sid}

  - name: "{hname}"
    type: hysteria2
    server: {server}
    port: {port}
    password: {hy2}
    sni: {hy2_sni}
    skip-cert-verify: true
    obfs: {obfs}
    obfs-password: {obfsp}
    alpn:
      - {alpn}

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "AUTO"
      - "{vname}"
      - "{hname}"
      - DIRECT

  - name: "AUTO"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
      - "{vname}"
      - "{hname}"

rules:
  - GEOIP,lan,DIRECT,no-resolve
  - GEOIP,private,DIRECT,no-resolve
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
"#,
        vname = n.vless_name(),
        hname = n.hy2_name(),
        server = n.server,
        port = LISTEN_PORT,
        uuid = n.uuid,
        flow = VLESS_FLOW,
        reality_sni = REALITY_SERVER_NAME,
        fp = CLIENT_FINGERPRINT,
        pbk = n.reality_public_key,
        sid = n.short_id,
        hy2 = n.hy2_password,
        hy2_sni = n.sni_hy2,
        obfs = HY2_OBFS,
        obfsp = n.obfs_password,
        alpn = HY2_ALPN,
    ));
    out
}

// ---------------------------------------------------------------- 幂等

/// 从已有 config 里读回凭据，供重跑时复用。
#[derive(Debug, Clone, Default)]
pub struct Credentials {
    pub uuid: String,
    pub reality_private_key: String,
    pub short_id: String,
    pub hy2_password: String,
    pub obfs_password: String,
    pub sni_hy2: String,
}

impl Credentials {
    /// 六个字段齐全才算可用；缺任何一个都退回重新生成。
    pub fn complete(&self) -> bool {
        [&self.uuid, &self.reality_private_key, &self.short_id, &self.hy2_password, &self.obfs_password]
            .iter()
            .all(|v| !v.is_empty())
    }
}

pub fn credentials_from_config(cfg: &Value) -> Credentials {
    let mut c = Credentials::default();
    let Some(inbounds) = cfg.get("inbounds").and_then(Value::as_array) else {
        return c;
    };
    for ib in inbounds {
        let text = |p: &str| ib.pointer(p).and_then(Value::as_str).unwrap_or("").to_string();
        match ib.get("type").and_then(Value::as_str) {
            Some("vless") => {
                c.uuid = text("/users/0/uuid");
                c.reality_private_key = text("/tls/reality/private_key");
                c.short_id = text("/tls/reality/short_id/0");
            }
            Some("hysteria2") => {
                c.hy2_password = text("/users/0/password");
                c.obfs_password = text("/obfs/password");
                c.sni_hy2 = text("/tls/server_name");
            }
            _ => {}
        }
    }
    c
}

/// REALITY 的 public key 由 private key 推导（X25519）。
///
/// ⇒ **config 是唯一真相源，链接由它派生** ⇒ 公钥与私钥不可能失配。
pub fn public_key_from_private(private_b64: &str) -> Result<String> {
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(private_b64.trim_end_matches('='))
        .context("reality private key is not base64url")?;
    let bytes: [u8; 32] =
        raw.as_slice().try_into().map_err(|_| anyhow::anyhow!("reality private key is not 32 bytes"))?;
    let secret = x25519_dalek::StaticSecret::from(bytes);
    let public = x25519_dalek::PublicKey::from(&secret);
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(public.as_bytes()))
}

// ---------------------------------------------------------------- 随机凭据

pub fn random_hex(bytes: usize) -> Result<String> {
    let mut value = vec![0u8; bytes];
    getrandom::getrandom(&mut value).map_err(|_| anyhow::anyhow!("OS randomness unavailable"))?;
    Ok(value.iter().map(|b| format!("{b:02x}")).collect())
}

/// RFC 4122 v4。
pub fn generate_uuid() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::getrandom(&mut bytes).map_err(|_| anyhow::anyhow!("OS randomness unavailable"))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..]))
}

pub fn generate_short_id() -> Result<String> {
    random_hex(SHORT_ID_BYTES)
}

pub fn generate_secret() -> Result<String> {
    random_hex(SECRET_BYTES)
}

// ---------------------------------------------------------------- 系统步骤（root）

fn run_cmd(program: &str, args: &[&str]) -> Result<()> {
    let out =
        Command::new(program).args(args).output().with_context(|| format!("failed to run {program}"))?;
    if !out.status.success() {
        anyhow::bail!("{program} {} failed: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

/// The repository, not the binary, is what gives sing-box an upgrade path.
const SAGERNET_SOURCES: &str = "/etc/apt/sources.list.d/sagernet.sources";
const SAGERNET_KEY: &str = "/etc/apt/keyrings/sagernet.asc";
const SAGERNET_BODY: &str = "Types: deb\nURIs: https://deb.sagernet.org/\nSuites: *\nComponents: *\nEnabled: yes\nSigned-By: /etc/apt/keyrings/sagernet.asc\n";
/// The packaged binary. A file dropped here by hand is not the same thing.
const SINGBOX_BIN: &str = "/usr/bin/sing-box";

/// Ensure sing-box comes from the official package, so it can be upgraded.
///
/// The package brings `/lib/systemd/system/sing-box.service` with it; provision
/// **does not write a unit of its own**.
///
/// What is checked is the *repository*, not the binary. A `/usr/bin/sing-box`
/// installed by hand has no upgrade path — which is the whole point of the
/// standard — so adding the repository is also what replaces such a binary with
/// the packaged one.
pub fn ensure_singbox() -> Result<()> {
    let had_repo = Path::new(SAGERNET_SOURCES).exists();
    if !had_repo {
        // Official instructions: https://sing-box.sagernet.org/installation/package-manager/
        std::fs::create_dir_all("/etc/apt/keyrings").context("mkdir /etc/apt/keyrings")?;
        run_cmd("curl", &["-fsSL", "https://sing-box.app/gpg.key", "-o", SAGERNET_KEY])?;
        run_cmd("chmod", &["a+r", SAGERNET_KEY])?;
        std::fs::write(SAGERNET_SOURCES, SAGERNET_BODY).context("write sagernet.sources")?;
    }
    if !had_repo || !Path::new(SINGBOX_BIN).exists() {
        run_cmd("apt-get", &["update"])?;
        run_cmd("apt-get", &["install", "-y", "sing-box"])?;
    }
    Ok(())
}

/// 自签证书，CN 对齐客户端实际使用的 sni。
///
/// 客户端是 `skip-cert-verify`，所以证书的作用是「握手看起来正常」而不是通过校验；
/// CN 对齐 sni 让这一层更自洽。
pub fn ensure_cert(sni: &str) -> Result<()> {
    if Path::new(CERT_PATH).exists() && Path::new(KEY_PATH).exists() {
        return Ok(());
    }
    std::fs::create_dir_all(CERT_DIR).context("mkdir certs")?;
    run_cmd(
        "openssl",
        &[
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            KEY_PATH,
            "-out",
            CERT_PATH,
            "-days",
            "3650",
            "-nodes",
            "-subj",
            &format!("/CN={sni}"),
        ],
    )
}

/// 订阅三件套的落盘路径。
pub struct SubscriptionPaths {
    pub clash: PathBuf,
    pub v2ray_txt: PathBuf,
    pub v2ray_b64: PathBuf,
}

impl SubscriptionPaths {
    /// 64 机的命名：Clash 是 `sub-<32hex>.yaml`，v2rayN 是 `v2-<16hex>.{txt,b64}`。
    fn random_in(dir: &Path) -> Result<Self> {
        let stem = format!("v2-{}", random_hex(8)?);
        Ok(Self {
            clash: dir.join(format!("sub-{}.yaml", random_hex(16)?)),
            v2ray_txt: dir.join(format!("{stem}.txt")),
            v2ray_b64: dir.join(format!("{stem}.b64")),
        })
    }

    /// Reuse the paths a previous run chose, or pick new ones.
    ///
    /// The names carry randomness on purpose — an unguessable subscription URL is
    /// the only thing protecting it — so they cannot be derived. Without this the
    /// second run would mint a different name, leave the first files behind, and
    /// silently change the URL the panel holds: a rerun is supposed to be a no-op.
    pub fn resolve(dir: &Path, state: &Path) -> Result<Self> {
        if let Some(prev) = Self::from_state(state) {
            return Ok(prev);
        }
        Self::random_in(dir)
    }

    fn from_state(state: &Path) -> Option<Self> {
        let text = std::fs::read_to_string(state).ok()?;
        let value: Value = serde_json::from_str(&text).ok()?;
        let path = |key: &str| value.get(key).and_then(Value::as_str).map(PathBuf::from);
        let (clash, txt, b64) = (path("clash")?, path("v2ray_txt")?, path("v2ray_b64")?);
        // A recorded path whose file is gone is not a path that can be reused.
        if !(clash.exists() && txt.exists() && b64.exists()) {
            return None;
        }
        Some(Self { clash, v2ray_txt: txt, v2ray_b64: b64 })
    }

    /// Remember the paths, so the next run reuses them.
    pub fn save_state(&self, state: &Path) -> Result<()> {
        let body = json!({
            "clash": self.clash.to_string_lossy(),
            "v2ray_txt": self.v2ray_txt.to_string_lossy(),
            "v2ray_b64": self.v2ray_b64.to_string_lossy(),
        });
        atomic_write(state, serde_json::to_string_pretty(&body)?).context("write subscription state")
    }
}

pub fn write_subscriptions(n: &Node, paths: &SubscriptionPaths, state: &Path) -> Result<()> {
    if let Some(parent) = paths.clash.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }
    atomic_write_mode(&paths.clash, render_clash_yaml(n), 0o644).context("write clash yaml")?;
    atomic_write_mode(&paths.v2ray_txt, render_v2ray_txt(n), 0o644).context("write v2ray txt")?;
    atomic_write_mode(&paths.v2ray_b64, render_v2ray_b64(n), 0o644).context("write v2ray b64")?;
    paths.save_state(state)
}

// ---------------------------------------------------------------- 入口

pub struct ProvisionArgs {
    pub server: String,
    pub sni: String,
    pub label: String,
    pub config_dir: PathBuf,
    pub sub_dir: PathBuf,
    /// 订阅里给客户端用的基地址，如 `http://1.2.3.4`
    pub sub_base: String,
}

/// 解析 `provision` 子命令的参数。
pub fn parse_args(values: impl IntoIterator<Item = String>) -> Result<ProvisionArgs> {
    let mut args = ProvisionArgs {
        server: String::new(),
        sni: String::new(),
        label: "NODE".to_string(),
        config_dir: PathBuf::from(CONFIG_DIR),
        sub_dir: PathBuf::from(SUB_DIR),
        sub_base: String::new(),
    };
    let mut it = values.into_iter();
    while let Some(flag) = it.next() {
        // 不抽闭包：`|what| it.next()` 会把 `it` 的可变借用持有到闭包生命周期结束，
        // 与循环条件里的 `it.next()` 冲突（借用检查会拒）。
        match flag.as_str() {
            "--server" => args.server = it.next().context("--server needs a value")?,
            "--sni" => args.sni = it.next().context("--sni needs a value")?,
            "--label" => args.label = it.next().context("--label needs a value")?,
            "--config-dir" => {
                args.config_dir = PathBuf::from(it.next().context("--config-dir needs a value")?)
            }
            "--sub-dir" => args.sub_dir = PathBuf::from(it.next().context("--sub-dir needs a value")?),
            "--sub-base" => args.sub_base = it.next().context("--sub-base needs a value")?,
            other => anyhow::bail!("unknown provision argument: {other}"),
        }
    }
    if args.server.is_empty() {
        anyhow::bail!("provision needs --server");
    }
    if args.sni.is_empty() {
        args.sni = REALITY_SERVER_NAME.to_string();
    }
    if args.sub_base.is_empty() {
        args.sub_base = format!("http://{}", args.server);
    }
    Ok(args)
}

/// 执行 provision。**必须在 root 下运行。**
pub fn run(args: ProvisionArgs) -> Result<()> {
    if unsafe { libc::getuid() } != 0 {
        anyhow::bail!("provision writes /etc and installs packages; run it as root");
    }
    ensure_singbox()?;

    let config_path = args.config_dir.join("config.json");

    // 幂等：已有 config 就复用其中的凭据，只补缺失项。
    let existing =
        std::fs::read_to_string(&config_path).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok());
    let creds = existing.as_ref().map(credentials_from_config).unwrap_or_default();

    let mut n = Node {
        server: args.server.clone(),
        sni_hy2: if creds.sni_hy2.is_empty() { args.sni.clone() } else { creds.sni_hy2.clone() },
        label: args.label.clone(),
        uuid: creds.uuid.clone(),
        reality_private_key: creds.reality_private_key.clone(),
        reality_public_key: String::new(),
        short_id: creds.short_id.clone(),
        hy2_password: creds.hy2_password.clone(),
        obfs_password: creds.obfs_password.clone(),
        title: format!("新 VPS 节点订阅 — {}", args.server),
        subtitle: format!("{} 节点", args.label),
    };

    let reused = creds.complete();
    if !reused {
        if n.uuid.is_empty() {
            n.uuid = generate_uuid()?;
        }
        if n.reality_private_key.is_empty() {
            // 由 sing-box 自己生成密钥对，保证与它运行时用的是同一套语义。
            let out = Command::new("/usr/bin/sing-box")
                .args(["generate", "reality-keypair"])
                .output()
                .context("failed to generate reality keypair")?;
            let text = String::from_utf8_lossy(&out.stdout);
            for line in text.lines() {
                if let Some(v) = line.strip_prefix("PrivateKey:") {
                    n.reality_private_key = v.trim().to_string();
                } else if let Some(v) = line.strip_prefix("PublicKey:") {
                    n.reality_public_key = v.trim().to_string();
                }
            }
            if n.reality_private_key.is_empty() || n.reality_public_key.is_empty() {
                anyhow::bail!("sing-box generate reality-keypair produced no parseable keypair");
            }
        }
        if n.short_id.is_empty() {
            n.short_id = generate_short_id()?;
        }
        if n.hy2_password.is_empty() {
            n.hy2_password = generate_secret()?;
        }
        if n.obfs_password.is_empty() {
            n.obfs_password = generate_secret()?;
        }
    }
    // 无论复用还是新生成，公钥一律由私钥推导 —— 这是不失配的保证。
    n.reality_public_key = public_key_from_private(&n.reality_private_key)?;

    std::fs::create_dir_all(&args.config_dir).context("mkdir config dir")?;
    // The certificate before the config is rendered and checked, not after:
    // `sing-box check` opens every file the config names, and a certificate it
    // cannot read fails the check outright. On a machine that has never run this
    // there is no certificate yet, so the other order failed the first
    // deployment on every new node -- and passed on the ones that worked,
    // because an earlier run had already left the files behind.
    ensure_cert(&n.sni_hy2)?;
    // Rendered, written aside, and accepted by sing-box *before* the live file is
    // touched. A config it refuses would otherwise take the service down on the
    // restart below, and the file already there is the one still serving.
    let rendered = render_config(&n)?;
    let scratch = args.config_dir.join("config.json.new");
    let scratch_str = scratch.to_string_lossy().to_string();
    atomic_write(&scratch, &rendered).context("write scratch config")?;
    if let Err(e) = run_cmd(SINGBOX_BIN, &["check", "-c", &scratch_str]) {
        let _ = std::fs::remove_file(&scratch);
        return Err(e.context("sing-box refused the rendered config; nothing was changed"));
    }
    let state = PathBuf::from(SUB_STATE);
    if let Some(parent) = state.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }
    let paths = SubscriptionPaths::resolve(&args.sub_dir, &state)?;
    // 用包自带的单元；不写自己的 unit。
    if !Path::new(PACKAGE_UNIT).exists() {
        anyhow::bail!("{PACKAGE_UNIT} not found; is sing-box installed from the package?");
    }
    run_cmd("systemctl", &["daemon-reload"])?;
    let was_active = run_cmd("systemctl", &["is-active", "--quiet", "sing-box"]).is_ok();
    let was_enabled = run_cmd("systemctl", &["is-enabled", "--quiet", "sing-box"]).is_ok();
    let snapshot =
        FileSnapshot::capture(&[&config_path, &paths.clash, &paths.v2ray_txt, &paths.v2ray_b64, &state])?;
    std::fs::rename(&scratch, &config_path).context("replace sing-box config")?;
    let activate = (|| -> Result<()> {
        run_cmd("systemctl", &["enable", "sing-box"])?;
        run_cmd("systemctl", &["restart", "sing-box"])?;
        run_cmd("systemctl", &["is-active", "--quiet", "sing-box"])?;
        write_subscriptions(&n, &paths, &state)
    })();
    if let Err(error) = activate {
        snapshot.restore().context("deployment failed and restoring previous files also failed")?;
        if was_active {
            run_cmd("systemctl", &["restart", "sing-box"])
                .context("previous files restored but previous service could not restart")?;
            run_cmd("systemctl", &["is-active", "--quiet", "sing-box"])?;
        } else {
            run_cmd("systemctl", &["stop", "sing-box"])?;
        }
        if !was_enabled {
            run_cmd("systemctl", &["disable", "sing-box"])?;
        }
        return Err(error.context("deployment failed; previous files and service restored"));
    }

    // 交给安装器回填面板。安装器已是 root 且在本地。
    println!("{}", render_report(&n, &paths, &args.sub_base, reused));
    Ok(())
}

/// The report the installer posts to the hub.
///
/// Its keys are the hub's contract, not ours: `db::save_vpn_result` reads exactly
/// these six. **`success` is the one that matters** -- without it the hub reads the
/// report as a *failure* and writes nothing, while still answering 200. That is
/// what happened the first time this ran against a real panel, and no unit test
/// caught it because the api.rs test hand-writes its request body.
pub fn render_report(n: &Node, paths: &SubscriptionPaths, sub_base: &str, reused: bool) -> Value {
    let links: Vec<String> = render_v2ray_txt(n).lines().map(str::to_owned).collect();
    let base = sub_base.trim_end_matches('/');
    let name = |p: &Path| p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    json!({
        "success": true,
        "reused_credentials": reused,
        "server": n.server,
        "uuid": n.uuid,
        "reality_public_key": n.reality_public_key,
        "short_id": n.short_id,
        "hy2_password": n.hy2_password,
        "obfs_password": n.obfs_password,
        "vless_link": links.first().cloned().unwrap_or_default(),
        "hy2_link": links.get(1).cloned().unwrap_or_default(),
        "clash_sub_url": format!("{base}/{}", name(&paths.clash)),
        "v2ray_sub_url": format!("{base}/{}", name(&paths.v2ray_txt)),
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn failed_publication_restores_previous_and_removes_new_files() {
        let dir = std::env::temp_dir().join(format!("monitor-rollback-{}", super::random_hex(8).unwrap()));
        std::fs::create_dir_all(&dir).unwrap();
        let old = dir.join("existing");
        let new = dir.join("new");
        std::fs::write(&old, "old contents").unwrap();
        let snapshot = super::FileSnapshot::capture(&[&old, &new]).unwrap();
        super::atomic_write(&old, "new contents").unwrap();
        super::atomic_write(&new, "new file").unwrap();
        snapshot.restore().unwrap();
        assert_eq!(std::fs::read_to_string(&old).unwrap(), "old contents");
        assert!(!new.exists());
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
    use super::*;

    fn sample() -> Node {
        Node {
            server: "64.81.26.233".into(),
            sni_hy2: "zbdx.us.ci".into(),
            label: "LAX".into(),
            uuid: "<UUID>".into(),
            reality_private_key: "<PRIV>".into(),
            reality_public_key: "<PBK>".into(),
            short_id: "<SID>".into(),
            hy2_password: "<HYPASS>".into(),
            obfs_password: "<OBFSPASS>".into(),
            title: "新 VPS 节点订阅 — 64.81.26.233".into(),
            subtitle: "LAX-CUII Lite，中国双程优化".into(),
        }
    }

    /// 黄金样本取自 64.81.26.233 的 /var/www/sub/（2026-10-05 只读抓取），
    /// 凭据已替换为占位符 —— 样本里不含任何真实密钥，可以进仓库。
    const GOLD_YAML: &str = "IyDmlrAgVlBTIOiKgueCueiuoumYhSDigJQgNjQuODEuMjYuMjMzCiMgTEFYLUNVSUkgTGl0Ze+8jOS4reWbveWPjOeoi+S8mOWMlgpwcm94aWVzOgogIC0gbmFtZTogIkxBWC1WTEVTUyIKICAgIHR5cGU6IHZsZXNzCiAgICBzZXJ2ZXI6IDY0LjgxLjI2LjIzMwogICAgcG9ydDogNDQzCiAgICB1dWlkOiA8VVVJRD4KICAgIG5ldHdvcms6IHRjcAogICAgdWRwOiB0cnVlCiAgICB0bHM6IHRydWUKICAgIGZsb3c6IHh0bHMtcnByeC12aXNpb24KICAgIHNlcnZlcm5hbWU6IHd3dy5jbG91ZGZsYXJlLmNvbQogICAgY2xpZW50LWZpbmdlcnByaW50OiBjaHJvbWUKICAgIHJlYWxpdHktb3B0czoKICAgICAgcHVibGljLWtleTogPFBCSz4KICAgICAgc2hvcnQtaWQ6IDxTSUQ+CgogIC0gbmFtZTogIkxBWC1IWTIiCiAgICB0eXBlOiBoeXN0ZXJpYTIKICAgIHNlcnZlcjogNjQuODEuMjYuMjMzCiAgICBwb3J0OiA0NDMKICAgIHBhc3N3b3JkOiA8SFlQQVNTPgogICAgc25pOiB6YmR4LnVzLmNpCiAgICBza2lwLWNlcnQtdmVyaWZ5OiB0cnVlCiAgICBvYmZzOiBzYWxhbWFuZGVyCiAgICBvYmZzLXBhc3N3b3JkOiA8T0JGU1BBU1M+CiAgICBhbHBuOgogICAgICAtIGgzCgpwcm94eS1ncm91cHM6CiAgLSBuYW1lOiAiUFJPWFkiCiAgICB0eXBlOiBzZWxlY3QKICAgIHByb3hpZXM6CiAgICAgIC0gIkFVVE8iCiAgICAgIC0gIkxBWC1WTEVTUyIKICAgICAgLSAiTEFYLUhZMiIKICAgICAgLSBESVJFQ1QKCiAgLSBuYW1lOiAiQVVUTyIKICAgIHR5cGU6IHVybC10ZXN0CiAgICB1cmw6IGh0dHA6Ly93d3cuZ3N0YXRpYy5jb20vZ2VuZXJhdGVfMjA0CiAgICBpbnRlcnZhbDogMzAwCiAgICB0b2xlcmFuY2U6IDUwCiAgICBwcm94aWVzOgogICAgICAtICJMQVgtVkxFU1MiCiAgICAgIC0gIkxBWC1IWTIiCgpydWxlczoKICAtIEdFT0lQLGxhbixESVJFQ1Qsbm8tcmVzb2x2ZQogIC0gR0VPSVAscHJpdmF0ZSxESVJFQ1Qsbm8tcmVzb2x2ZQogIC0gRE9NQUlOLVNVRkZJWCxjbixESVJFQ1QKICAtIEdFT0lQLENOLERJUkVDVAogIC0gTUFUQ0gsUFJPWFkK";

    const GOLD_TXT: &str = "dmxlc3M6Ly88VVVJRD5ANjQuODEuMjYuMjMzOjQ0Mz9lbmNyeXB0aW9uPW5vbmUmZmxvdz14dGxzLXJwcngtdmlzaW9uJnNlY3VyaXR5PXJlYWxpdHkmc25pPXd3dy5jbG91ZGZsYXJlLmNvbSZmcD1jaHJvbWUmcGJrPTxQQks+JnNpZD08U0lEPiNMQVgtVkxFU1MKaHlzdGVyaWEyOi8vPEhZUEFTUz5ANjQuODEuMjYuMjMzOjQ0Mz9vYmZzPXNhbGFtYW5kZXImb2Jmcy1wYXNzd29yZD08T0JGU1BBU1M+JnNuaT16YmR4LnVzLmNpJmluc2VjdXJlPTEjTEFYLUhZMg==";

    fn b64d(s: &str) -> String {
        String::from_utf8(base64::engine::general_purpose::STANDARD.decode(s).unwrap()).unwrap()
    }

    /// 逐字节契约：生成器必须能复现 64 机的三个订阅文件。
    /// 这就是「以 64 机为标准」的可执行定义 —— 通过即意味着 64 机不需要被改。
    #[test]
    fn the_subscriptions_reproduce_the_reference_node_byte_for_byte() {
        let n = sample();
        assert_eq!(render_clash_yaml(&n), b64d(GOLD_YAML), "clash yaml");
        assert_eq!(render_v2ray_txt(&n), b64d(GOLD_TXT), "v2rayN txt");
        // .b64 文件的内容就是 base64(txt)
        assert_eq!(render_v2ray_b64(&n), GOLD_TXT, "v2rayN b64");
    }

    /// 反例自检：改任一字段都必须让输出变化，否则上面的断言是恒真的。
    #[test]
    fn the_contract_test_is_not_vacuous() {
        let gold = b64d(GOLD_YAML);
        let mut n = sample();
        n.label = "TYO".into();
        assert_ne!(render_clash_yaml(&n), gold, "label");

        let mut n = sample();
        n.server = "198.51.100.7".into();
        assert_ne!(render_clash_yaml(&n), gold, "server");

        let mut n = sample();
        n.obfs_password = "<OBFSPASS2>".into();
        assert_ne!(render_clash_yaml(&n), gold, "obfs-password");

        let mut n = sample();
        n.short_id = "<SID2>".into();
        assert_ne!(render_clash_yaml(&n), gold, "short-id");
    }

    /// 幂等：凭据写进 config 之后必须能原样读回来。
    /// 读不回来就意味着重跑会换凭据，已发出去的链接会失效。
    #[test]
    fn credentials_survive_a_round_trip_through_the_config() {
        let mut n = sample();
        n.uuid = "11111111-2222-4333-8444-555555555555".into();
        n.reality_private_key = "AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK".into();
        n.short_id = "0123456789abcdef".into();
        n.hy2_password = "aa".repeat(16);
        n.obfs_password = "bb".repeat(16);

        let cfg: Value = serde_json::from_str(&render_config(&n).unwrap()).unwrap();
        let back = credentials_from_config(&cfg);

        assert_eq!(back.uuid, n.uuid);
        assert_eq!(back.reality_private_key, n.reality_private_key);
        assert_eq!(back.short_id, n.short_id);
        assert_eq!(back.hy2_password, n.hy2_password);
        assert_eq!(back.obfs_password, n.obfs_password);
        assert_eq!(back.sni_hy2, n.sni_hy2);
        assert!(back.complete(), "六个字段齐全才算可用");
    }

    /// config 里不该出现的东西：旧的 tag 名、socks inbound、自签证书的老路径。
    #[test]
    fn the_config_follows_the_reference_shape_not_the_old_one() {
        let cfg: Value = serde_json::from_str(&render_config(&sample()).unwrap()).unwrap();
        let tags: Vec<&str> =
            cfg["inbounds"].as_array().unwrap().iter().filter_map(|i| i["tag"].as_str()).collect();
        assert_eq!(tags, ["vless-reality-in", "hysteria2-in"]);
        assert_eq!(cfg["inbounds"][1]["obfs"]["type"], HY2_OBFS, "HY2 必须带混淆");
        assert_eq!(cfg["inbounds"][1]["tls"]["certificate_path"], CERT_PATH);
        assert!(cfg["inbounds"].as_array().unwrap().len() == 2, "不得有 socks inbound");
    }

    /// A rerun must serve the same URLs. The names carry randomness on purpose, so
    /// they can only come back from the state file -- without it a rerun would mint
    /// a new name and silently move the URL the panel holds.
    #[test]
    fn subscription_paths_are_reused_across_runs() {
        let dir = std::env::temp_dir().join(format!("prov-paths-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let sub = dir.join("sub");
        let cfg = dir.join("cfg");
        std::fs::create_dir_all(&cfg).unwrap();
        // A local path on purpose: the real SUB_STATE is absolute, and joining it
        // would write to the system directory from a test.
        let state = cfg.join("subscription.json");

        // First run: nothing recorded, so a fresh name is chosen and written out.
        let first = SubscriptionPaths::resolve(&sub, &state).unwrap();
        write_subscriptions(&sample(), &first, &state).unwrap();
        assert!(state.exists(), "第一次运行要把路径记下来");

        // Second run: the recorded paths come back, so the URL does not move.
        let second = SubscriptionPaths::resolve(&sub, &state).unwrap();
        assert_eq!(second.clash, first.clash, "clash 路径必须复用");
        assert_eq!(second.v2ray_txt, first.v2ray_txt, "v2rayN txt 路径必须复用");
        assert_eq!(second.v2ray_b64, first.v2ray_b64, "v2rayN b64 路径必须复用");

        // A recorded path whose file is gone is not reusable: a new one is picked
        // rather than serving a 404 forever.
        std::fs::remove_file(&first.clash).unwrap();
        let third = SubscriptionPaths::resolve(&sub, &state).unwrap();
        assert_ne!(third.clash, first.clash, "文件没了就该重新选");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The report's keys are the hub's contract. `save_vpn_result` reads exactly
    /// these six, and a missing `success` makes it treat a completed deployment as
    /// a failure report and write nothing -- while the route still answers 200.
    ///
    /// This is the check an `api.rs` test cannot make: that one hand-writes its
    /// request body, so it agrees with itself. This one uses what provision prints.
    #[test]
    fn the_report_carries_the_keys_the_hub_reads() {
        let paths = SubscriptionPaths {
            clash: PathBuf::from("/var/www/sub/sub-aaa.yaml"),
            v2ray_txt: PathBuf::from("/var/www/sub/v2-bbb.txt"),
            v2ray_b64: PathBuf::from("/var/www/sub/v2-bbb.b64"),
        };
        let r = render_report(&sample(), &paths, "http://203.0.113.10/", true);

        for key in ["success", "vless_link", "hy2_link", "uuid", "clash_sub_url", "v2ray_sub_url"] {
            assert!(r.get(key).is_some(), "缺 {key}：hub 的 save_vpn_result 读这个键");
        }
        assert_eq!(r["success"], true, "success 不是 true，hub 会当成失败上报，行不会被写");
        // 末尾斜杠要归一，否则拼出 `//sub-aaa.yaml`
        assert_eq!(r["clash_sub_url"], "http://203.0.113.10/sub-aaa.yaml");
        assert_eq!(r["v2ray_sub_url"], "http://203.0.113.10/v2-bbb.txt");
        assert!(r["vless_link"].as_str().unwrap().starts_with("vless://"));
        assert!(r["hy2_link"].as_str().unwrap().starts_with("hysteria2://"));
    }

    #[test]
    fn generated_credentials_have_uuid_v4_bits_and_independent_secrets() {
        let uuid = generate_uuid().unwrap();
        assert_eq!(uuid.len(), 36);
        assert_eq!(&uuid[14..15], "4");
        assert!(matches!(&uuid[19..20], "8" | "9" | "a" | "b"));
        assert_eq!(generate_short_id().unwrap().len(), 16);
        assert_eq!(generate_secret().unwrap().len(), 32);
        assert_ne!(generate_secret().unwrap(), generate_secret().unwrap());
    }

    /// provision 的参数解析，含默认值。
    #[test]
    fn provision_arguments_default_the_sni_and_subscription_base() {
        let a = parse_args(["--server".into(), "203.0.113.10".into()]).unwrap();
        assert_eq!(a.sni, REALITY_SERVER_NAME);
        assert_eq!(a.sub_base, "http://203.0.113.10");
        assert_eq!(a.label, "NODE");

        let a = parse_args([
            "--server".into(),
            "1.2.3.4".into(),
            "--sni".into(),
            "panel.example.com".into(),
            "--label".into(),
            "LAX".into(),
        ])
        .unwrap();
        assert_eq!(a.sni, "panel.example.com");
        assert_eq!(a.label, "LAX");

        assert!(parse_args(Vec::<String>::new()).is_err(), "缺 --server 必须报错");
        assert!(parse_args(["--nope".into()]).is_err());
    }

    /// X25519 推导的已知向量：私钥全 1 时，公钥是一个固定值。
    /// 这条与 sing-box 的语义无关，只锁住「实现的是标准 X25519」。
    #[test]
    fn public_key_derivation_is_standard_x25519() {
        // 32 字节 0x01 → base64url 无 padding
        let private = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([1u8; 32]);
        let public = public_key_from_private(&private).unwrap();
        assert_eq!(public.len(), 43, "32 字节的 base64url 无 padding 是 43 字符");
        assert!(!public.contains('='), "不带 padding");
        assert_ne!(public, private);
        // 幂等：同一个私钥永远推出同一个公钥
        assert_eq!(public, public_key_from_private(&private).unwrap());
    }
}
