//! Continuous HTTP measurements through local sing-box inbounds. No VPN
//! configuration or credentials are read by the unprivileged agent.
use anyhow::{Context, Result};
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

#[derive(Clone, Default)]
pub struct Proxies {
    clients: HashMap<String, reqwest::Client>,
    url: String,
}

impl Proxies {
    pub fn from_env() -> Result<Self> {
        Self::parse(
            &std::env::var("MONITOR_PROXY_PORTS").unwrap_or_default(),
            &std::env::var("MONITOR_PROXY_TEST_URL")
                .unwrap_or_else(|_| "https://www.google.com/generate_204".into()),
        )
    }

    fn parse(ports: &str, url: &str) -> Result<Self> {
        let mut out = Self { clients: HashMap::new(), url: url.into() };
        if ports.trim().is_empty() {
            return Ok(out);
        }
        let parsed = url::Url::parse(url).context("invalid proxy test URL")?;
        anyhow::ensure!(matches!(parsed.scheme(), "http" | "https"), "proxy test URL needs HTTP(S)");
        for entry in ports.split(',') {
            let (tag, port) = entry.trim().split_once(':').context("proxy ports need tag:port")?;
            anyhow::ensure!(matches!(tag, "vless" | "hy2"), "unsupported proxy tag");
            let port: u16 = port.parse().context("invalid proxy port")?;
            anyhow::ensure!(port != 0 && !out.clients.contains_key(tag), "zero or duplicate proxy port");
            // Explicit proxy bypasses process HTTP_PROXY/NO_PROXY. No pooling:
            // each sample includes a fresh connection, matching curl time_total.
            let client = reqwest::Client::builder()
                .proxy(reqwest::Proxy::all(format!("http://127.0.0.1:{port}"))?)
                .redirect(reqwest::redirect::Policy::none())
                .pool_max_idle_per_host(0)
                .timeout(Duration::from_secs(15))
                .build()?;
            out.clients.insert(tag.into(), client);
        }
        Ok(out)
    }

    pub fn supports(&self, target: &str) -> bool {
        target.strip_prefix("proxy:").is_some_and(|tag| self.clients.contains_key(tag))
    }

    pub async fn measure(&self, target: &str) -> i64 {
        let Some(client) = target.strip_prefix("proxy:").and_then(|tag| self.clients.get(tag)) else {
            return -1;
        };
        let start = Instant::now();
        let request = async {
            let mut response = client.get(&self.url).send().await?;
            anyhow::ensure!(response.status().is_success(), "proxy test HTTP failure");
            // Drain incrementally, never buffer an arbitrary response body.
            while response.chunk().await?.is_some() {}
            Ok::<_, anyhow::Error>(())
        };
        match tokio::time::timeout(Duration::from_secs(15), request).await {
            Ok(Ok(())) => start.elapsed().as_millis() as i64,
            _ => -1,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn configured_only_and_http_failures_are_loss() {
        assert!(!Proxies::default().supports("proxy:vless"));
        for invalid in ["vless:0", "vless:abc", "vless:1,vless:2", "other:80"] {
            assert!(Proxies::parse(invalid, "https://example.com").is_err());
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            for status in ["204 No Content", "503 Unavailable"] {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut input = [0; 4096];
                let n = socket.read(&mut input).await.unwrap();
                assert!(String::from_utf8_lossy(&input[..n]).starts_with("GET http://example.invalid/check "));
                socket
                    .write_all(
                        format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            .as_bytes(),
                    )
                    .await
                    .unwrap();
            }
        });
        let p = Proxies::parse(&format!("vless:{port}"), "http://example.invalid/check").unwrap();
        assert!(p.supports("proxy:vless"));
        assert!(!p.supports("proxy:hy2"));
        assert!(p.measure("proxy:vless").await >= 0);
        assert_eq!(p.measure("proxy:vless").await, -1);
        server.await.unwrap();
        assert_eq!(p.measure("proxy:vless").await, -1);
    }
}
