# Monitor

自托管的 Linux 服务器监控与 VPN 部署面板，集中管理节点状态、流量、延迟、到期信息及 Telegram 告警。

Hub 使用 Rust、axum 和 SQLite，管理后台与公开状态页使用 React、TypeScript。前端和默认主题嵌入 Hub 二进制，运行时无需 Node.js 或独立数据库服务。Agent 使用单线程异步运行，指标采集、TCP 探测和订阅服务共用一个进程。

项目源自 [monitor-probe/monitor](https://github.com/monitor-probe/monitor)，Hub、自研 Agent、后台、默认主题及部署脚本的源码均在本仓库。

## 功能

- **节点监控**：在线状态、系统信息、CPU、负载、内存、磁盘与网络；实时推送、历史趋势、公开或私有节点及独立 token。
- **流量与账单**：周期用量、额度、计费方式、起始日、到期日、价格与币种。统计来自节点计数器，账单以服务商记录为准。
- **延迟探测**：Agent 执行 TCP 连通性与延迟任务；[代理探针](probe/README.md)独立测量经 VLESS、Hysteria2 等代理链路的 HTTP 耗时。
- **Telegram 告警**：离线与恢复、流量、到期和后台登录提醒，支持规则及通知模板配置。
- **数据与主题**：备份、恢复、历史保留、密码与会话管理；主题上传、安装、预览和切换。
- **VPN 与订阅**：节点安装 sing-box，配置 VLESS + REALITY、Hysteria2，生成 Clash YAML 与 v2rayN TXT/Base64 订阅，并提供流量和到期响应头。

## 快速部署

推荐使用 Debian/Ubuntu 与 systemd，部署前准备 HTTPS 入口及所需端口。Hub 安装器依赖 systemd；Agent 也支持 OpenRC，但自动 VPN 配置使用 apt 和 systemd，不能据此认为 VPN 部署支持所有发行版。

### 1. 安装 Hub

[Releases](https://github.com/Isyyyue/monitor/releases/latest) 提供 Linux x86_64、aarch64 的 Hub、Agent、安装脚本和 SHA-256 清单。

```bash
curl -fsSL https://github.com/Isyyyue/monitor/releases/latest/download/install-hub.sh -o install-hub.sh
sudo sh install-hub.sh
```

安装目录为 `/opt/monitor/`，服务名为 `monitor-hub`，数据保存在 `/opt/monitor/data/`。默认监听 `127.0.0.1:28080`；通过 HTTPS 反向代理访问，代理需支持 WebSocket。可用 `--site https://hub.example.com` 指定节点连接入口。

公开页位于 `/`，后台位于 `/admin/`。首次建库时生成管理员密码，按安装输出登录后修改密码。

无域名部署可选 `--https`（自签 HTTPS，默认 `8444`）或 `--plain`（公网 HTTP）。自签 HTTPS 需在后台生成安装命令时明确勾选接受未受信任证书，或手动传入 `--insecure`；可信 HTTPS 使用 `--verify-tls`。此选择同时应用于安装下载、Agent 连接和订阅流量查询，升级时保留。HTTP 会明文传输密码、会话和节点 token。正式部署建议使用可信 HTTPS 入口。

### 2. 安装节点 Agent

在后台添加节点或开启注册窗口，复制节点页生成的安装命令，在目标节点执行。安装器默认配置 VPN；仅需监控时添加 `--no-vpn`。

| 参数 | 用途 |
|---|---|
| `--server` | Hub 入口地址 |
| `--token` / `--register` | 已有节点 token / 注册窗口密钥 |
| `--interval` / `--iface` | 上报间隔 / 统计网卡 |
| `--vpn-ip` | VPN 链接中的节点公网地址 |
| `--sub-port` | 对外订阅端口 |
| `--no-vpn` | 跳过自动 VPN 配置 |
| `--upgrade` | 升级已有 Agent |

安装器需要 root 完成安装与配置，常驻 Agent 使用独立普通用户运行。VPN 操作由本机的 `monitor-agent provision` 执行，结果通过节点 token 上报 Hub；Hub 不向节点下发 VPN 安装指令。

### 3. 检查服务

```bash
systemctl status monitor-hub          # Hub 所在机器
systemctl status monitor-agent        # 节点
systemctl status sing-box             # 启用 VPN 的节点
```

同时确认后台节点在线、订阅可下载、客户端能读取流量与到期信息，并实际测试代理连通性。服务启动成功不能替代 VPN 验收。

## 端口与订阅

| 默认端口 | 用途 |
|---|---|
| `28080/tcp` | Hub 回环监听；`--plain` 模式对公网开放 |
| `8444/tcp` | Hub 安装器 `--https` 模式的 HTTPS 入口 |
| `443/tcp`、`443/udp` | 节点 VLESS + REALITY、Hysteria2 |
| `80/tcp` | 默认对外订阅入口，可通过 `--sub-port` 修改 |
| `18081/tcp` | nginx 前置时，Agent 的回环订阅端口 |

订阅与 Agent 共用进程：有可用 nginx 前置时绑定回环，由 nginx 转发；直接提供订阅时监听对外端口。端口冲突或 nginx 配置无法使用时，安装器可能回退到 `8080`，应以安装输出及后台记录的地址为准。独立的既有订阅服务不自动接管。

`--no-vpn` 升级保留已有订阅配置。订阅切换失败时恢复原配置并检查原入口；sing-box 激活失败时恢复原配置和订阅文件。Agent 使用自身目录下的订阅路由状态，不需要放宽 sing-box 状态目录权限。

Hub 与 VPN 节点部署在同一台机器时，分别安排 HTTPS 面板与 sing-box 的监听端口，避免占用同一地址的 `443/tcp`。自定义 SNI 分流属于额外 nginx 配置，不是默认安装步骤。

重跑 VPN 配置会复用已有凭据及仍可用的订阅文件路径。升级前备份数据库、配置及旧二进制；端口或域名变更后同步检查客户端订阅地址。参数详情见 `sh install-hub.sh --help` 和节点安装脚本的用法输出。

## 主题

默认公开页源码位于 [web-theme/](web-theme/README.md)，与后台一起构建并嵌入 Hub。初音视频主题为可选主题，可从 Release 下载 `theme-miku.tar.gz` 后在后台上传安装，默认不启用。

默认与初音主题由本仓库发布，包名分别为 `theme-default.tar.gz`、`theme-miku.tar.gz`，主题版本与 Release 版本一致。后台更新按主题选择对应包；旧版默认主题的上游地址会自动迁回本仓库。第三方主题仍按其声明的仓库更新，使用 `theme.tar.gz`。

主题代码和资源会在浏览器中执行或加载，仅安装可信来源。背景视频可能增加网络传输和客户端渲染开销。

## 源码构建

需要 Rust stable、C 编译工具链及 Node.js 24。Node.js 仅用于构建和开发。

```bash
git clone https://github.com/Isyyyue/monitor.git
cd monitor

(cd web-admin && npm ci && npm run build)
(cd web-theme && npm ci && npm run build)
cargo build --release --locked
cargo build --release --locked --manifest-path agent/Cargo.toml

mkdir -p data
./target/release/monitor-hub --listen 127.0.0.1:28080 --db ./data/monitor.db
```

Hub 与 Agent 分别位于 `target/release/monitor-hub`、`agent/target/release/monitor-agent`。Hub 构建脚本自动暂存已构建的默认主题；修改公开页应编辑 `web-theme/`。

主要目录：`src/` 为 Hub，`agent/` 为节点 Agent 与 VPN 配置模块，`web-admin/` 为后台，`web-theme/` 为公开页，`probe/` 为独立代理探针。

CI 检查两个前端的 lint、测试和构建，Hub/Agent 的格式、Clippy、测试，以及安装脚本和联调。具体命令见 [.github/workflows/ci.yml](.github/workflows/ci.yml)。这些检查不替代目标机器上的安装、升级与代理连通验证。

## 安全与许可

后台使用 Argon2 密码哈希与服务端会话；公开视图过滤管理字段。节点 token、VPN 凭据、订阅地址和 Telegram Bot Token 均应妥善保管。`--insecure` 涉及降低传输校验或放行明文连接，须区分安装器与 Agent 的具体行为，不能替代可信 HTTPS。

采用 [MIT License](LICENSE)，保留上游及依赖项目的版权与许可证。
