# Monitor

自托管的服务器监控面板：一个后台管理多台 Linux 服务器的状态、流量、延迟与到期信息，并通过 Telegram 告警。

Hub 用 Rust + axum + SQLite，后台用 React + TypeScript。后台与默认主题嵌入 Hub 二进制，运行时不依赖 Node.js，也不需要独立数据库服务。

本项目基于 [monitor-probe/monitor](https://github.com/monitor-probe/monitor) 开发，增加了定制后台、自研 Agent 与 VPN 部署模块。

## 能做什么

- **监控**：在线状态、系统信息、CPU、负载、内存、磁盘、网络；WebSocket 推送，公开状态页实时更新并保留历史趋势。节点可命名、排序、设为公开或私有、加备注，每个节点独立 token。
- **流量与账单**：上传 / 下载流量、当前周期用量与额度、计费方式（双向合计 / 仅上传 / 仅下载 / 取最大）、计费起始日、到期日、价格与币种。流量来自节点网络计数器，最终计费以服务商记录为准。
- **延迟探测**：两条路。Hub 的探测任务量节点到目标的 **TCP 连通性与延迟**，由 Agent 执行；`probe/` 代理探针量**真实代理链路的 HTTP 耗时**（Python + curl + sing-box），可以为 VLESS、Hysteria2 分别建曲线。详见 [代理探针说明](probe/README.md)。
- **Telegram 告警**：节点离线 / 恢复、流量阈值与额度用尽、到期与续费、后台登录。模板、宽限期、阈值、提前天数都可配。需自备 Bot Token 与 Chat ID。
- **公开状态页与主题**：公开页与后台分开，访客只看公开节点。可开关公开页、安装 / 切换 / 预览主题、上传主题包，或从 GitHub 主题仓库安装更新。`themes/miku/` 只是背景样式与接入说明，要自备素材，默认不启用。
- **后台页面**：节点、延迟、通知、数据（备份 / 恢复 / 历史保留）、主题、安全、网站（反代配置示例）、部署（各节点状态与订阅地址）。

## VPN 部署模块

目标：在节点上装好 sing-box、配 VLESS + REALITY 与 Hysteria2，并生成 Clash 与 v2rayN 订阅。

**部署由安装器完成，不由 Hub 下发。** `install.sh` 在节点上以 root 跑一次，调 `monitor-agent provision` 写配置与订阅，再把结果 `POST` 到 Hub 的 `/api/agent/vpn`，用节点自己的 token 鉴权。Hub 只能收不能发 —— Agent 的常驻服务里没有部署分支，因此它也不必以 root 常驻。

`provision` 的要点：

- sing-box 从官方源装（`deb.sagernet.org`），用包自带的 systemd 单元，可 `apt upgrade`。
- **凭据由已有的 config 派生**：重跑复用 uuid、REALITY 私钥与 short_id，链接里的公钥由私钥推导 —— 重跑不会改变已发出的链接。要轮换就先删掉节点上的 `/etc/sing-box/config.json`。
- 订阅三件套（Clash yaml 带分流规则、v2rayN txt、b64）由同一份凭据生成，路径记在 `/var/lib/sing-box/subscription.json`。
- **订阅由节点自己伺服，并带 `subscription-userinfo` 头**：额度与用量由节点用**自己的 token** 调 `/api/agent/traffic` 读，面板管理员密码不会落到节点上。客户端靠这个头显示「已用 / 总量」和到期日，**没有它那一行是直接不见的**，不报错。

重新部署在节点上执行面板给出的命令：

```bash
curl -fsSL https://<面板地址>/install.sh | sudo sh -s -- --upgrade --vpn-ip <节点公网地址>
```

仓库内的测试覆盖内容生成与 Hub 侧收发，不覆盖目标机器上的 sing-box 启动与实际代理连接。

## 项目组成

| 目录 | 作用 |
|---|---|
| `src/` | Rust Hub：HTTP API、WebSocket、鉴权、数据库、通知、主题 |
| `web-admin/` | React / TypeScript 管理后台 |
| `agent/` | 自研 Rust Agent：指标采集、探测执行、订阅伺服、VPN 配置生成 |
| `probe/` | Python + curl + sing-box 代理延迟探针 |
| `themes/miku/` | 初音主题样式与接入说明 |
| `install-hub.sh`、`install.sh` | Hub 与 Agent 安装脚本 |
| `.github/workflows/`、`Dockerfile` | 检查与发布工作流、容器镜像 |

Hub 与 Agent 是两个独立进程，跑在不同角色的机器上。本地编译 Hub 不会自动编译 `agent/`，发布工作流分别构建两者。

## 部署与运行

目标环境是 Linux（Windows 开发可用 WSL）。Hub 安装器用 systemd，Agent 安装脚本另含 OpenRC；`provision` 需要包管理器与 systemd。

### 安装 Hub

先看 [Releases](https://github.com/Isyyyue/monitor/releases) 里有没有所需架构的资产：

```bash
curl -fsSL https://github.com/Isyyyue/monitor/releases/latest/download/install-hub.sh -o install-hub.sh
chmod +x install-hub.sh
sudo ./install-hub.sh
```

默认装在 `/opt/monitor/`，由 `monitor-hub.service` 管理。没有可用 Release 时走源码构建：

```bash
git clone https://github.com/Isyyyue/monitor.git && cd monitor
(cd web-admin && npm ci && npm run build)   # 需要 Node.js 24
sh scripts/theme.sh                         # 下载并校验默认主题
cargo build --release --locked

mkdir -p data && ./target/release/monitor-hub \
  --listen 127.0.0.1:28080 --db ./data/monitor.db --themes ./data/themes
```

本地访问 `http://127.0.0.1:28080/`（公开页）和 `/admin/`（后台）。首次建库时终端会显示一次随机管理员密码（标签 `Emergency password`），登录后在安全页改掉。

正式部署到域名时走 HTTPS 反向代理，并给 Hub 设 `--site https://your-domain.example`；代理要转发 WebSocket。

**没有域名时**二选一：`--https` 签自签证书 + nginx，面板走 `https://公网IP:8444`，但**只有面板和本机节点能用**（远程节点的 Agent 只认公共 CA 签的证书）；`--plain` 不要证书，Hub 直接监听公网，面板走 `http://公网IP:28080`，但**密码、会话 cookie、节点 token 都不加密**，只在信得过的网络里用。两条路都可加 `--local-node 名字` 顺手建好本机节点。域名解析过来后重跑一次带上 `--site` 即可收紧。

完整参数见 `install-hub.sh --help`。

### 端口占用

**动端口前先看这张表**：订阅地址和面板地址里都带着端口，挪一个就会打断已发出的链接，而且**客户端不一定报错** —— 它只是少显示一些东西，或者连不上。

标准形态一句话：**`443` 归 sing-box，面板放 `8444`。**

| 端口 | 谁 | 绑在哪 | 用途 |
|---|---|---|---|
| `80/tcp` | nginx，或 agent 自己 | 公网 | 订阅。有 nginx 就由它转给 `18081`，没有就 agent 自己绑 `80` |
| `443/tcp` `443/udp` | sing-box | 公网 | VLESS + REALITY（tcp）与 Hysteria2（udp） |
| `8444/tcp` | nginx stream | 公网 | 按 SNI 分流：伪装 SNI 给 REALITY，其余给面板 |
| `28080/tcp` | monitor-hub | 回环 | Hub 自己。`--port` 可改；`--plain` 时绑公网 |
| `9443/tcp` | nginx | 回环 | 面板 vhost，证书在这里，从 `8444` 分流进来 |
| `9444/tcp` | nginx | 回环 | 面板的第二个入口，给 SSH 隧道用 |
| `18081/tcp` | monitor-agent | 回环 | 走 nginx 时 agent 绑这里 |

**面板不能放 `443`**：REALITY 靠「不认识的 SNI 就转发给伪装站」隐藏自己，同一个 SNI 没法既当代理又当面板。`8444` 上按 SNI 再分一次，是因为代理客户端带的是伪装站的 SNI（`www.cloudflare.com`），面板带的是你的域名。

```nginx
stream {
    map $ssl_preread_server_name $tls_backend {
        www.cloudflare.com reality;   # REALITY 的伪装 SNI
        default            panel;
    }
    upstream reality { server 127.0.0.1:8443; }
    upstream panel   { server 127.0.0.1:9443; }
    server { listen 8444; ssl_preread on; proxy_pass $tls_backend; }
}
```

纯节点（只跑 `install.sh`）少掉 Hub 和面板那几条，只剩 `80`、`443` tcp+udp、`22`。订阅**对外永远在 `80`**，所以客户端地址是 `http://IP/xxx.yaml`，不带端口。

**安装器装出来的：** `install-hub.sh` 让 Hub 监听 `28080`（回环），`--https` 另外装 nginx 把面板放到 `8444`。`install.sh` 装 sing-box（`443`）与订阅：`80` 空着就自己绑；`80` 上是 nginx 就退到 `127.0.0.1:18081` 并由 nginx 转过来；`80` 被别人占着、nginx 又收不下配置，才退到 `8080`。**已经有别人在伺服同一批文件时不接管**，**重跑复用上一轮的落位**。

写 nginx 那份配置时**必须用 `default_server`**：同端口上已有别的 server 时，`server_name _` 会被盖住，请求落到别人的 default 上，订阅 404 **而配置文件看着完全正常**。所以 `80` 上已有别人的 `default_server` 时它加不进去，会退回 `8080` 并说明；想让订阅留在 `80`，把这段加进那个 server 块：

```nginx
location ~ ^/(sub-[0-9a-f]+\.yaml|v2-[0-9a-f]+\.(txt|b64))$ {
    proxy_pass http://127.0.0.1:18081;
    proxy_set_header Host $host;
}
```

绑低端口时只给 agent `CAP_NET_BIND_SERVICE` 一个能力（systemd 用 `AmbientCapabilities`，OpenRC 用 `setcap` 并把二进制权限收到 root 与 agent 那个组）。

**出站：** Hub → `github.com`（取发布包转给节点）；节点 → Hub 的 `28080` 或反代端口；节点 → `deb.sagernet.org`（装 sing-box）；客户端 → 节点的 `80` 与 `443`。

### 安装 Agent

面板的节点页会给出安装命令。Agent 的配置通过 `MONITOR_SERVER`、`MONITOR_TOKEN`、可选的 `MONITOR_IFACE` 传入，也可用 `--server`、`--token`、`--interval`、`--iface`。`install.sh` 另有 `--vpn-ip ADDRESS`（缺省自行查询）与 `--no-vpn`。

自行编译：

```bash
cd agent && cargo build --release --locked
```

产物 `agent/target/release/monitor-agent` 有两个入口：不带子命令是常驻的指标上报服务，`provision` 子命令由安装器以 root 调一次。

Agent 本身不接受 `--insecure`（它按地址协议决定 `ws://` 还是 `wss://`）。`install.sh` 的 `--insecure` 是另一回事 —— 它放行「向非本机的 Hub 用明文 HTTP」，那条链路上既取要执行的二进制、又送节点 token，所以默认拒绝。

## 鉴权与权限边界

- 后台用密码 + 服务端会话，密码以 Argon2 保存，登录失败有限制。公开 API 与管理员 API 分开，公开视图过滤 token、备注等字段。
- Agent 主动连 Hub，不需要开放接收 Hub 请求的端口；节点以独立 token 鉴权。
- VPN 的写入由安装器在节点上以 root 完成，Hub 侧没有下发指令的能力；节点只能通过 `/api/agent/vpn` 上报自己。**部署命令里含节点 token**，面板与 Hub 要按管理入口保护。
- 第三方主题在站点里运行，只装可信来源。VPN 链接、订阅地址、Bot Token、节点 token 都按凭据保管。

## 开发

CI 跑的就是这些（见 `.github/workflows/`）：

```bash
(cd web-admin && npm run lint && npm test)
cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo test --locked --manifest-path agent/Cargo.toml
```

这些检查不替代真实 Agent 联调、VPN 连通测试与生产部署验收。默认主题是独立项目，改公开页通常还要动主题。

## 许可证

[MIT License](LICENSE)。上游及依赖项目的版权与许可证按各自文件保留。
