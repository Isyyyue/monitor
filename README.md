# Monitor

自托管的轻量级服务器监控面板，用一个后台管理多台 Linux 服务器的运行状态、流量、延迟和到期信息，并通过 Telegram 接收告警。

Hub 使用 Rust、axum 和 SQLite，管理后台使用 React 和 TypeScript，公开状态页通过主题提供。后台与默认主题嵌入 Hub 二进制，运行 Hub 不需要额外的 Node.js 服务或独立数据库服务。

本项目基于 [monitor-probe/monitor](https://github.com/monitor-probe/monitor) 开发，增加了定制后台、自研 Agent 和 VPN 部署模块。VPN 的安装与配置由安装器在节点上以 root 完成一次，节点把结果回报给面板；Hub 不向节点下发任何指令。具体状态见下文。

## 能做什么

### 服务器监控

- 集中查看多台服务器的在线状态、系统信息、CPU、负载、内存、磁盘和网络数据。
- 通过 WebSocket 更新公开状态页，查看实时读数和历史趋势。
- 管理节点名称、排序、公开状态及备注；私有节点不出现在公开列表中。
- 为每个节点设置独立 token，并支持轮换 token、批量编辑及安装注册窗口。

Hub 依赖的字段就是仓库内自研 Agent 上报的字段。两侧由同一份清单约束：Hub 侧据此检查每一份报告，Agent 侧有测试断言每一个字段都在——改名会在测试期失败，而不是让面板静默显示 0。

### 流量与服务器账单

- 保存上传、下载流量，显示当前计费周期的用量与额度。
- 支持双向合计、仅上传、仅下载及双向取最大值等计费方式。
- 设置计费起始日、服务器到期日、价格、币种和付费周期，集中查看续费信息。
- 保存资源与延迟历史，通过分钟明细及小时聚合提供不同时间范围的查询。

流量统计来自节点的网络计数器，不是云厂商账单接口；最终计费仍应以服务商记录为准。

### 延迟探测

项目包含两种测量路径，适合不同用途：

| 路径 | 用途 | 工作方式 |
|---|---|---|
| Hub 的探测任务 | 查看节点到指定目标的 TCP 连通性与延迟 | 后台配置目标及间隔，由兼容 Agent 执行并上报 |
| `probe/` 代理探针 | 查看真实代理链路的 HTTP 请求耗时 | Python 调用 curl，经本地 sing-box 的代理出站请求测试地址，再写入 Hub 数据库 |

代理测量包含代理连接和 HTTP 请求过程，不等同于 ICMP ping 或单次 TCP 握手时间。可以为 VLESS、Hysteria2 等出站建立不同曲线。

自研 Agent 会执行 Hub 下发的 `ping.tasks`：每 `interval` 秒对 `target` 做一次 TCP 连接，把耗时作为 `ping.result` 回报；连不上回报 -1，Hub 记为丢包。间隔下限 5 秒、每个节点最多 64 条，与 Hub 保存任务时的校验一致。`probe/` 是另一条路——它经本地 sing-box 的代理出站，量的是代理链路的 HTTP 耗时，需要自行配置出站、数据库路径、节点 ID 与任务 ID，不能直接套用示例中的编号。跳过或删除失败样本会改变丢包统计的含义。

详见 [代理探针说明](probe/README.md)。

### Telegram 告警

- 节点离线与恢复在线提醒。
- 流量阈值和额度用尽提醒。
- 到期与续费提醒。
- 后台登录提醒。
- 自定义通知模板、离线宽限期、流量阈值和到期提前天数，并发送测试消息。

当前定制版本使用 Telegram 通知，需自行配置 Bot Token 和接收 Chat ID。

### 公开状态页与主题

- 公开页和管理后台分开；访客查看公开节点，管理员登录后管理节点与配置。
- 支持开关公开页、安装和切换主题、预览主题以及配置主题提供的选项。
- 可上传主题包，或从 GitHub 主题仓库安装及更新。
- 默认主题在构建时按固定版本和 SHA-256 下载；运行时可使用自定义主题。
- `themes/miku/` 提供初音背景样式及接入说明，需要自行准备图片或视频并整合到主题，默认不启用。

主题效果和配置项由具体主题决定。初音目录不是一个已经包含完整视频资源的主题发行包。参见 [初音主题说明](themes/miku/README.md)。

### 后台管理与数据维护

| 页面 | 主要用途 |
|---|---|
| 节点 | 节点信息、安装入口、token、流量及账单信息 |
| 延迟 | 探测任务、目标、间隔及节点分配 |
| 通知 | Telegram 配置、提醒规则及模板 |
| 数据 | 数据库统计、历史保留设置、备份、恢复和空间整理 |
| 主题 | 安装、预览、切换、更新和主题配置 |
| 安全 | 密码修改、登录会话管理 |
| 网站 | 域名访问状态与 nginx HTTPS 反向代理配置示例 |
| 部署 | 查看各节点的部署状态与订阅地址，复制重新部署的命令 |

密码修改页面要求验证旧密码。网站页面生成的是供管理员执行的配置说明，并不会自动修改服务器 DNS、安装 nginx 或申请证书。

## VPN 部署模块

模块的目标是：在节点上装好 sing-box、配置 VLESS + REALITY 与 Hysteria2，并生成 Clash 与 v2rayN 订阅。

**部署由安装器完成，不由 Hub 下发。** `install.sh` 在节点上以 root 运行一次，调用
`monitor-agent provision` 写入配置与订阅，再把结果 `POST` 到 Hub 的 `/api/agent/vpn`，
用节点自己的 token 鉴权。Hub 只能收，不能叫节点做事——自研 Agent 的常驻服务里没有任何
部署分支，因此它也不需要以 root 常驻。

`provision` 的要点：

- sing-box 从官方包源安装（`deb.sagernet.org`），使用包自带的 systemd 单元，可 `apt upgrade`。
- **凭据由已有的 config 派生**：重跑复用其中的 uuid、REALITY 私钥与 short_id，
  链接里的公钥由私钥推导，因此重跑不会改变已经发出去的链接。
- 订阅三件套（Clash yaml 带 proxy-group 与分流规则、v2rayN txt、v2rayN b64）由同一份凭据生成；
  路径记在 `/var/lib/sing-box/subscription.json`，供重跑复用。

重新部署在节点上执行面板给出的命令即可：

```bash
curl -fsSL https://<面板地址>/install.sh | sudo sh -s -- --upgrade --vpn-ip <节点公网地址>
```

目前的边界：

- **订阅由节点自己伺服**：`provision` 把三件套写到 `/var/www/sub/`，由节点上的 nginx 提供。
  已有的独立订阅服务不由此模块自动接管。
- **真实连通需要实测**：仓库内的测试覆盖内容生成与 Hub 侧的收发，不覆盖目标机器上的
  sing-box 启动与实际代理连接。
- **凭据默认不轮换**：重跑复用现有凭据是刻意的。需要轮换时，先删掉节点上的
  `/etc/sing-box/config.json` 再执行。

独立运行的既有 VPN 或订阅服务，与本仓库这一部署模块的完成程度应分别判断。

## 项目组成

| 目录或文件 | 作用 |
|---|---|
| `src/` | Rust Hub：HTTP API、WebSocket、鉴权、数据库、通知和主题管理 |
| `web-admin/` | React / TypeScript 管理后台 |
| `agent/` | 自研 Rust Agent：指标采集与 VPN 部署处理，指标与探测实现仍在完善 |
| `probe/` | Python + curl + sing-box 代理延迟探针 |
| `themes/miku/` | 初音主题样式与接入说明 |
| `scripts/theme.sh`、`web-theme.pin` | 默认主题下载与摘要校验 |
| `install-hub.sh`、`install.sh` | Hub 与监控 Agent 安装脚本 |
| `.github/workflows/` | 检查与 Hub 发布工作流 |
| `Dockerfile` | 打包已构建 Hub 二进制的容器镜像 |

Hub 与 Agent 是两个独立进程，运行在不同角色的机器上。本地编译 Hub 不会自动编译 `agent/`；发布工作流分别构建两者。

```mermaid
flowchart LR
    A[Linux 节点 / 兼容监控 Agent] -->|指标与探测结果| H[Monitor Hub]
    A -->|POST /api/agent/vpn · 节点 token| H
    H --> D[(SQLite)]
    H --> P[公开状态页]
    H --> M[管理后台]
    H --> T[Telegram]
    M -.->|复制部署命令| I[install.sh · 在节点上以 root 运行一次]
    I -->|monitor-agent provision| V[sing-box + 订阅三件套]
    V -->|nginx 伺服| S[订阅地址]
    Q[Python 代理探针] -->|延迟样本| D
```

## 部署与运行

### 环境要求

Hub 和 Agent 以 Linux 为目标环境；Windows 开发可使用 WSL。Hub 的安装器使用 systemd，监控 Agent 安装脚本另包含 OpenRC 支持。`provision` 需要包管理器与 systemd，在 systemd 的机器上运行。

源码构建需要 Rust stable、C 编译工具、Node.js 24 / npm，以及 curl、tar、sha256sum 等工具。Node.js 用于构建后台，Hub 运行时不依赖它。初次构建需要访问依赖仓库及默认主题下载地址。

### 方式一：使用发布版本

先查看 [Releases](https://github.com/Isyyyue/monitor/releases) 是否已经提供所需架构的 Hub 二进制、`install-hub.sh` 和 `sha256sums.txt`。只有发布资产存在时，以下安装入口才可使用：

```bash
curl -fsSL https://github.com/Isyyyue/monitor/releases/latest/download/install-hub.sh -o install-hub.sh
chmod +x install-hub.sh
sudo ./install-hub.sh
```

安装器默认使用 `/opt/monitor/monitor-hub` 和 `/opt/monitor/data/`，由 `monitor-hub.service` 管理进程。没有可用 Release 时，请使用源码构建；仓库中的临时构建文件不能替代有版本和摘要的正式发布。

监控 Agent 安装入口与仓库内自研 Agent 并不是自动等价的发行路径。使用前应确认下载源、二进制版本及其与 Hub 的协议兼容性；v1.3.3 的发布流程同时构建 Hub 与自研 Agent 的 x86_64/aarch64 Linux musl 产物，并附带 SHA-256 校验文件。

### 方式二：从源码构建 Hub

```bash
git clone https://github.com/Isyyyue/monitor.git
cd monitor

# 构建管理后台
cd web-admin
npm ci
npm run build
cd ..

# 下载并校验默认主题，再构建 Hub
sh scripts/theme.sh
cargo build --release --locked

# 用单独的数据目录进行本地运行
mkdir -p data
./target/release/monitor-hub \
  --listen 127.0.0.1:28080 \
  --db ./data/monitor.db \
  --themes ./data/themes
```

本地访问：

- 公开页：`http://127.0.0.1:28080/`
- 管理后台：`http://127.0.0.1:28080/admin/`

首次创建数据库时，终端会显示一次随机管理员密码。登录后在安全页修改密码。终端密码标签为“Emergency password”，当前后台使用密码登录。

正式部署到域名时，通过 HTTPS 反向代理访问，并给 Hub 设置 `--site https://your-domain.example`；代理需要转发 WebSocket。网站页面提供配置示例，已有 nginx 或端口分流配置应按现有拓扑整合。

### 没有域名怎么办

默认安装只监听回环，公网访问不到，而且没有 HTTPS 域名就不给添加节点。没有域名时安装器有两条路，二选一：

- `sudo ./install-hub.sh --https`：签一张自签证书并配好 nginx，面板走 `https://公网IP`。浏览器第一次会警告「不安全」，点「继续」即可，流量是加密的。**但只有面板和本机节点能用**——远程节点的 Agent 只认公共 CA 签的证书，连不上自签的 Hub。
- `sudo ./install-hub.sh --plain`：不要证书，Hub 直接监听公网，面板走 `http://公网IP:28080`。**登录密码、会话 cookie 和节点 token 都不加密**，链路上抓包就能拿走，拿到 token 就能接管对应节点。好处是零依赖、零维护，远程节点也能加。只在信得过的网络里这么用。

两条路都可以加 `--local-node 名字`，安装器会顺手把本机建成节点并打印装 Agent 的命令——服务器和面板是同一台机器时用这个，token 只在本地生成，不过网。

等域名解析过来之后，重跑一次带上 `--site https://你的域名`，就能收紧到全程加密。`--plain` 的明文状态会在三处被告知：安装完成时的汇总、Hub 每次启动的日志、以及面板上安装命令的下方。

### 自研 Agent 构建

```bash
cd agent
cargo build --release --locked
```

产物是 `agent/target/release/monitor-agent`。同一个二进制有两个入口：不带子命令时是常驻的指标上报服务，`provision` 子命令则由安装器以 root 调用一次，用于写入 sing-box 配置与订阅。

安装器通过 `MONITOR_SERVER`、`MONITOR_TOKEN` 和可选的 `MONITOR_IFACE` 传递配置；也可显式使用 `--server`、`--token`、`--interval` 与 `--iface`。`install.sh` 另有 `--vpn-ip ADDRESS`（本机公网地址，缺省时自行查询）与 `--no-vpn`（只装监控、不部署 VPN）。

Agent 本身不接受 `--insecure`：它按连接地址的协议决定用 `ws://` 还是 `wss://`，明文连接不做证书校验，也就没有需要关掉的东西。`install.sh` 的 `--insecure` 是另一回事——它放行「向非本机的 Hub 用明文 HTTP」，那条链路上既取要执行的二进制、又送节点 token，所以默认拒绝。Hub 没有域名时（`--plain`）面板拼出的安装命令会自动带上它。

### Hub 常用参数

| 参数 | 作用 |
|---|---|
| `--listen` | 监听地址；建议在反向代理后明确使用回环地址 |
| `--db` | SQLite 数据库路径，默认 `monitor.db` |
| `--themes` | 外部主题目录，默认在数据库旁的 `themes/` |
| `--site` | 节点安装入口使用的站点地址。有域名写 `https://` 加域名；没有域名写 `http://` 加公网 IP 和端口，配合 `--plain` |
| `--plain` | 无域名部署：Hub 监听公网、面板走明文 HTTP。密码与节点 token 不加密 |
| `--https` | 无域名部署：签自签证书并配好 nginx，面板走 `https://公网IP`。只有面板和本机节点能用 |
| `--https-port` | 自签 HTTPS 的监听端口，默认 443 |
| `--local-node` | 顺手建好本机节点并打印装 Agent 的命令；重名会复用而不是再建一个 |
| `--reset-password` | 重置管理员密码并使现有会话失效，打印新密码后退出 |

日志级别可通过 `MONITOR_LOG` 设置。数据库与主题目录需要持久保存；升级前保留一致的数据库备份、旧二进制和相关服务配置。

## 鉴权与权限边界

- 管理后台使用密码和服务端会话；密码以 Argon2 哈希保存，并有限制登录失败的机制。
- 监控 Agent 主动连接 Hub，不需要开放用于接收 Hub 请求的独立管理端口；节点以独立 token 鉴权。
- 公开 API 与管理员 API 分开，公开节点视图过滤 token、备注等管理字段。
- VPN 的写入由安装器在节点上以 root 完成，Hub 侧没有下发指令的能力；节点只通过 `/api/agent/vpn` 上报结果，且只能上报自己。面板与 Hub 仍应按管理入口保护——部署命令里含节点 token。
- 第三方主题在站点中运行，应仅安装可信来源的主题。VPN 链接、订阅地址、Bot Token 和节点 token 均应作为凭据保管。

## 开发检查

在构建后台和默认主题后，可运行：

```bash
cd web-admin
npm run lint
npm test
cd ..

cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo test --locked --manifest-path agent/Cargo.toml
```

这些检查不替代真实 Agent 联调、VPN 连通测试和生产部署验收。默认主题是独立项目，修改公开页通常还需要调整主题，而不仅是 `web-admin/`。

## 许可证

采用 [MIT License](LICENSE)。上游及依赖项目的版权和许可证按各自文件保留。
