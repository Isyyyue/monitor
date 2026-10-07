//! 订阅伺服：跟着 agent 一起跑，不再单独常驻一个 Python 进程。
//!
//! 它只读三样东西：状态文件（订阅文件的当前名字）、那三个文件本身、以及本节点从
//! hub 读来的额度与用量。**不碰 sing-box 的配置和密钥** —— 那两样本来就只有 root
//! 读得到，也不需要给这个进程。
//!
//! 绑在哪由 `MONITOR_SUB_BIND` / `MONITOR_SUB_PORT` 决定。前面有 nginx 时绑回环、
//! 由 nginx 伺服，这个进程就不开公网端口 —— 它持有节点 token，能少开一个是一个。

use std::{collections::HashMap, net::IpAddr, path::PathBuf, sync::Arc, time::Duration};

use anyhow::{Context, Result};
use axum::{
    extract::State,
    http::{header, StatusCode, Uri},
    response::{IntoResponse, Response},
    Router,
};
use serde::Deserialize;
use tokio::net::TcpListener;

/// 头的缓存时间。一个客户端可能连开几个连接，没必要每个都去问 hub 一次。
const CACHE: Duration = Duration::from_secs(5);

struct Server {
    state: PathBuf,
    traffic_url: String,
    token: String,
    client: reqwest::Client,
    /// 串行化取数，并留一个短缓存；取不到就是 `None`，那时**不发这个头**。
    traffic: tokio::sync::Mutex<TrafficCache>,
    refreshed: tokio::sync::Notify,
}

#[derive(Default)]
struct TrafficCache {
    at: Option<std::time::Instant>,
    value: Option<String>,
    fetching: bool,
}

#[derive(Deserialize)]
struct Traffic {
    #[serde(default)]
    month_tx: i64,
    #[serde(default)]
    month_rx: i64,
    #[serde(default)]
    traffic_limit: i64,
    expires_at: Option<String>,
}

/// `subscription-userinfo` 的值。`upload` 是节点发出的、`download` 是节点收到的，
/// 与已经在跑的两台一致；客户端只认这个顺序。
fn userinfo(t: &Traffic) -> String {
    let expire = t
        .expires_at
        .as_deref()
        .and_then(|v| chrono::NaiveDate::parse_from_str(v, "%Y-%m-%d").ok())
        .and_then(|d| d.and_hms_opt(0, 0, 0))
        .map_or(0, |d| d.and_utc().timestamp());
    format!("upload={}; download={}; total={}; expire={}", t.month_tx, t.month_rx, t.traffic_limit, expire)
}

impl Server {
    async fn header(self: &Arc<Self>) -> Option<String> {
        let ready = self.refreshed.notified();
        tokio::pin!(ready);
        ready.as_mut().enable();
        let mut cache = self.traffic.lock().await;
        if cache.at.is_some_and(|at| at.elapsed() < CACHE) {
            return cache.value.clone();
        }
        if !cache.fetching {
            cache.fetching = true;
            let server = Arc::clone(self);
            // The task outlives a cancelled HTTP request and always clears the
            // in-flight flag. Other clients wait for the same bounded refresh.
            tokio::spawn(async move {
                let value = server.fetch_header().await;
                let mut cache = server.traffic.lock().await;
                cache.value = value;
                cache.at = Some(std::time::Instant::now());
                cache.fetching = false;
                drop(cache);
                server.refreshed.notify_waiters();
            });
        }
        drop(cache);
        let _ = tokio::time::timeout(Duration::from_millis(1200), ready).await;
        let cache = self.traffic.lock().await;
        cache.at.filter(|at| at.elapsed() < CACHE).and_then(|_| cache.value.clone())
    }

    async fn fetch_header(&self) -> Option<String> {
        self.client
            .get(&self.traffic_url)
            .bearer_auth(&self.token)
            .send()
            .await
            .ok()?
            .error_for_status()
            .ok()?
            .json::<Traffic>()
            .await
            .ok()
            .map(|t| userinfo(&t))
    }
}

async fn serve(State(server): State<Arc<Server>>, uri: Uri) -> Response {
    // 每次请求重读状态文件，使重新部署后的路径立即生效。
    let routes = match tokio::fs::read(&server.state)
        .await
        .ok()
        .and_then(|b| serde_json::from_slice::<HashMap<String, PathBuf>>(&b).ok())
    {
        Some(routes) => routes,
        None => return StatusCode::NOT_FOUND.into_response(),
    };
    // 只认状态文件里记着的那三个文件名。路径、目录、别的任何东西一律不认。
    let route = routes.into_iter().find_map(|(kind, path)| {
        let name = path.file_name()?.to_str()?;
        if uri.path() != format!("/{name}") {
            return None;
        }
        let mime = match kind.as_str() {
            "clash" => "text/yaml",
            "v2ray_txt" | "v2ray_b64" => "text/plain",
            _ => return None,
        };
        Some((path, mime))
    });
    let Some((path, mime)) = route else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let body = match tokio::fs::read(path).await {
        Ok(body) => body,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let mut response =
        ([(header::CONTENT_TYPE, mime), (header::CACHE_CONTROL, "no-store")], body).into_response();
    if let Some(value) = server.header().await {
        if let Ok(value) = value.parse() {
            response.headers_mut().insert("subscription-userinfo", value);
        }
    }
    response
}

/// 起订阅伺服。没配 `MONITOR_SUB_PORT` 就什么都不做 —— 一台只做监控、不跑 VPN 的
/// 机器不该多开一个端口。
///
/// 起不来**不致命**：调用方只记一条警告，监控照常。订阅和监控是两件事，一个坏了
/// 不该把另一个带走。
pub async fn start(server: &str, token: &str, insecure: bool) -> Result<()> {
    let Some(port) = std::env::var("MONITOR_SUB_PORT").ok().filter(|p| !p.is_empty()) else {
        return Ok(());
    };
    let port: u16 = port.parse().context("invalid MONITOR_SUB_PORT")?;
    anyhow::ensure!(port > 0, "MONITOR_SUB_PORT must be nonzero");
    let bind: IpAddr = std::env::var("MONITOR_SUB_BIND")
        .ok()
        .filter(|b| !b.is_empty())
        .unwrap_or_else(|| "127.0.0.1".into())
        .parse()
        .context("invalid MONITOR_SUB_BIND")?;

    // hub 的地址是给 WebSocket 用的（ws:// 或 wss://），换成 http(s) 再指到取数的路由。
    let mut url = url::Url::parse(server).context("invalid hub URL")?;
    let scheme = match url.scheme() {
        "ws" => "http",
        "wss" => "https",
        other => other,
    }
    .to_owned();
    url.set_scheme(&scheme).map_err(|_| anyhow::anyhow!("invalid hub URL scheme"))?;
    url.set_path("/api/agent/traffic");
    url.set_query(None);
    url.set_fragment(None);

    let listener = TcpListener::bind((bind, port)).await.context("cannot bind subscription port")?;
    let state = std::env::var_os("MONITOR_SUB_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(super::provision::SUB_STATE));
    // 读不到状态文件就别把自己挂起来：服务看着在跑，而每个请求都 404。
    tokio::fs::read(&state).await.context("cannot read subscription state")?;

    let server = Arc::new(Server {
        state,
        traffic_url: url.into(),
        token: token.to_owned(),
        client: reqwest::Client::builder()
            .timeout(Duration::from_secs(1))
            .danger_accept_invalid_certs(insecure)
            // 取数不该跟着跳转走：地址是我们自己拼的，跳转只可能是被中间人改过。
            .redirect(reqwest::redirect::Policy::none())
            .build()?,
        traffic: tokio::sync::Mutex::new(TrafficCache::default()),
        refreshed: tokio::sync::Notify::new(),
    });
    tokio::spawn(async move {
        let app = Router::new().fallback(axum::routing::get(serve)).with_state(server);
        if let Err(e) = axum::serve(listener, app).await {
            tracing::error!("subscription server stopped: {e}");
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn concurrent_clients_share_one_bounded_refresh() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let calls = Arc::new(AtomicUsize::new(0));
        let count = calls.clone();
        let app = Router::new().route(
            "/",
            axum::routing::get(move || {
                let count = count.clone();
                async move {
                    count.fetch_add(1, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(40)).await;
                    (
                        [(header::CONTENT_TYPE, "application/json")],
                        "{\"month_tx\":12,\"month_rx\":34,\"traffic_limit\":100,\"expires_at\":null}",
                    )
                }
            }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let server = Arc::new(Server {
            state: PathBuf::new(),
            traffic_url: format!("http://{address}/"),
            token: "test".into(),
            client: reqwest::Client::builder().timeout(Duration::from_secs(1)).build().unwrap(),
            traffic: tokio::sync::Mutex::new(TrafficCache::default()),
            refreshed: tokio::sync::Notify::new(),
        });
        let (first, second) = tokio::join!(server.header(), server.header());
        assert_eq!(first, Some("upload=12; download=34; total=100; expire=0".into()));
        assert_eq!(first, second);
        assert_eq!(server.header().await, first);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        task.abort();
    }

    #[tokio::test]
    async fn an_unresponsive_hub_cannot_hold_subscription_requests() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = Arc::new(Server {
            state: PathBuf::new(),
            traffic_url: format!("http://{address}/"),
            token: "test".into(),
            client: reqwest::Client::builder().timeout(Duration::from_secs(1)).build().unwrap(),
            traffic: tokio::sync::Mutex::new(TrafficCache::default()),
            refreshed: tokio::sync::Notify::new(),
        });
        assert_eq!(tokio::time::timeout(Duration::from_secs(2), server.header()).await.unwrap(), None);
        assert!(!server.traffic.lock().await.fetching);
    }

    /// 头的字节要和线上那两台一模一样：客户端按这个顺序解析，错一位就整行不显示。
    #[test]
    fn the_header_matches_what_the_two_machines_already_send() {
        let t = Traffic {
            month_tx: 15676630630,
            month_rx: 15032385536,
            traffic_limit: 536870912000,
            expires_at: Some("2026-11-01".into()),
        };
        assert_eq!(
            userinfo(&t),
            "upload=15676630630; download=15032385536; total=536870912000; expire=1793491200"
        );
    }

    /// 没有到期日就写 0 —— 客户端把 0 当「不过期」，而不是当缺失。
    #[test]
    fn a_missing_expiry_is_zero() {
        let t = Traffic { month_tx: 1, month_rx: 2, traffic_limit: 3, expires_at: None };
        assert_eq!(userinfo(&t), "upload=1; download=2; total=3; expire=0");
        let t = Traffic { expires_at: Some("不是日期".into()), ..t };
        assert_eq!(userinfo(&t), "upload=1; download=2; total=3; expire=0");
    }
}
