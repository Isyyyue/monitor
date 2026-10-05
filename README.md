# monitor

轻量级服务器探针，Rust 构建，安全、极简、高效。

## 特性

- **实时监控**：秒级实时数据展示，节点状态、流量、延迟一目了然
- **轻量高效**：Rust 语言构建，单二进制部署，空转仅 7MB 内存
- **自托管**：数据完全掌握在自己手里，部署简单
- **Telegram 通知**：节点掉线、流量告警、到期提醒，推送到 Telegram
- **代理延迟探针**：通过真实代理连接实测 VLESS / Hysteria2 端到端延迟，
  延迟图展示的是真实数据（见 `probe/`）
- **安全设计**：agent 主动连接 hub，不监听端口；hub 控制不了节点；
  公开页不泄露敏感信息

## 快速开始

```bash
curl -fsSL https://github.com/Isyyyue/monitor/releases/latest/download/install-hub.sh -o install-hub.sh
chmod +x install-hub.sh
sudo ./install-hub.sh
```

## 组成

| 组件 | 说明 |
|---|---|
| hub | 后台管理、API、公开状态页（Rust + axum + SQLite） |
| agent | 跑在被监控机器上的采集端，WebSocket 上报数据（同一 release 发布） |
| probe/ | 代理延迟探针：用 sing-box + curl 实测代理延迟，写入面板数据库 |

```
agent (Linux)  ──WebSocket / JSON-RPC 2.0──▶  hub (axum + SQLite)  ──▶  后台 + 状态页
```

## 代理延迟探针

见 [probe/README.md](probe/README.md)。

## 可选主题

`themes/miku/`：初音未来动态壁纸样式，可选安装，默认不启用。
见 [themes/miku/README.md](themes/miku/README.md)。
