#!/bin/sh
# monitor hub installer.
#
#   curl -fsSL https://github.com/Isyyyue/monitor/releases/latest/download/install-hub.sh -o install-hub.sh
#   chmod +x install-hub.sh
#   sudo ./install-hub.sh
#
# Menu-driven when a terminal is available. A plain `curl ... | sh` has no
# terminal to read answers from, so it installs with the defaults rather than
# waiting on an invisible prompt.
set -eu
# useradd resides in sbin, which a root shell entered through `su` without `-`
# lacks on Debian: su keeps the caller's PATH unless ALWAYS_SET_PATH is set, and
# Debian does not set it.
PATH="$PATH:/usr/sbin:/sbin"

REPO="Isyyyue/monitor"
SERVICE="monitor-hub"
UNIT="/etc/systemd/system/monitor-hub.service"
# Everything but the unit lives under one directory: the two binaries at the top,
# and everything the hub writes -- database and themes/ -- under data/. One path
# to back up, one to move to another host, and the same split the container image
# uses, where data/ is mounted at /data.
ROOT="/opt/monitor"
BIN="$ROOT/monitor-hub"
DATA="$ROOT/data"
# A fixed data directory requires a fixed owner: DynamicUser= selects its uid at
# start, and a recycled one would leave the database unreadable.
USER_NAME="monitor"
PORT="28080"
PORT_SET=""
SITE=""
SITE_SET=""
# Self-signed HTTPS in front of the loopback hub, for a hub with no domain.
HTTPS=""
# 8444, not 443. The hub frequently shares a machine with a node, where sing-box
# holds 443 -- and REALITY hides itself by forwarding a handshake it does not
# recognise to its camouflage site, so a panel on that port would never be
# reached at all: the visitor would get cloudflare.com instead of a login page.
# 8444 is the port the standard form puts the panel on.
HTTPS_PORT="8444"
HTTPS_PORT_SET=""
# No TLS at all: the hub listens on the public interface and the panel is
# reached over plain HTTP. The other answer to having no domain, and the one
# that costs nothing to run.
PLAIN=""
# The node this machine reports as, created during the install.
LOCAL_NODE=""
YES=""
PURGE=""
ACTION=""
# Where the panel ends up being reached, and what nginx is found at. Both are
# set during the install and read by the summary.
PANEL=""
NGINX_BIN=""
NGINX_CONF_DIR=""

# ---- ui ----
# Colour only to a terminal, and never when NO_COLOR is set: the output of a
# piped run belongs in a log rather than in escape sequences.
if [ -t 1 ] && [ -z "${NO_COLOR-}" ]; then
	B="$(printf '\033[1m')" D="$(printf '\033[2m')" N="$(printf '\033[0m')"
	G="$(printf '\033[32m')" R="$(printf '\033[31m')" Y="$(printf '\033[33m')"
else
	B="" D="" N="" G="" R="" Y=""
fi

rule() { printf '  %s────────────────────────────────────────────%s\n' "$D" "$N"; }

banner() {
	if [ -t 1 ]; then printf '\033[H\033[2J'; fi
	printf '\n  %smonitor hub%s  %s·%s  安装器\n' "$B" "$N" "$D" "$N"
	rule
	printf '\n'
}

# Every label below is deliberately two CJK characters wide: printf pads by byte
# count, so any other width would break the column.
ok() { printf '  %s✓%s  %s    %s%s%s\n' "$G" "$N" "$1" "$D" "${2-}" "$N"; }
field() { printf '  %s%s%s    %s\n' "$D" "$1" "$N" "$2"; }
warn() { printf '  %s!%s  %s\n' "$Y" "$N" "$1"; }
die() { printf '  %s✗%s  %s\n' "$R" "$N" "$1" >&2; exit 1; }

# A default answer on Enter, and the same default when there is no terminal.
ask() {
	if [ ! -t 0 ]; then printf '%s' "$2"; return; fi
	printf '  %s?%s  %s %s[%s]%s ' "$Y" "$N" "$1" "$D" "$2" "$N" >&2
	read -r reply || reply=""
	printf '%s' "${reply:-$2}"
}

confirm() {
	if [ -n "$YES" ]; then return 0; fi
	if [ ! -t 0 ]; then die "$1（非交互运行时加 --yes 确认）"; fi
	printf '  %s?%s  %s  %s[y/N]%s ' "$Y" "$N" "$1" "$D" "$N"
	read -r reply || reply=""
	case "$reply" in y | Y | yes) return 0 ;; *) printf '  已取消\n'; return 1 ;; esac
}

press() {
	if [ ! -t 0 ]; then return 0; fi
	printf '\n  %s回车返回菜单%s ' "$D" "$N"
	read -r _ || true
}

# A copy of this script saved on the machine may be several releases old, and
# re-running it is the documented way to upgrade: it would rewrite the unit by
# that version's rules. The release publishes this script and hashes it
# alongside the binary, so a saved copy measures itself before the menu or the
# install and, when stale, replaces itself and hands the same request to the
# new copy. The replacement is unconditional: the stale rules are never the
# wanted ones, and an unattended run cannot answer a prompt. The new copy is
# held to the checksum file the binary is, so it is trusted exactly as far as
# the binary the install fetches.
#
# A piped run has no file to measure and needs none: it was fetched a moment
# ago. The marker keeps `curl | sh`, whose $0 is "sh", from measuring a file of
# that name in the working directory.
check_self() {
	[ -f "$0" ] && grep -qxF '# monitor hub installer.' "$0" 2>/dev/null || return 0
	base="https://github.com/$REPO/releases/latest/download"
	self="$(mktemp -d)"
	trap 'rm -rf "$self"' EXIT
	# GitHub out of reach is reported by the install, which needs it as well;
	# the menu's other entries do not. A release published before the script
	# was an asset carries no line for it.
	want=""
	if curl -fsSL --max-time 30 "$base/sha256sums.txt" -o "$self/sums" 2>/dev/null; then
		want="$(sed -n 's/^\([0-9a-f]\{64\}\)  *install-hub.sh$/\1/p' "$self/sums")"
	fi
	if [ -z "$want" ] || [ "$(sha256sum "$0" | cut -d' ' -f1)" = "$want" ]; then
		rm -rf "$self"
		trap - EXIT
		return 0
	fi

	warn "这份脚本不是最新发布的那一版，先换成新的"
	curl -fsSL --max-time 30 "$base/install-hub.sh" -o "$self/new" || die "新脚本下载失败：$base/install-hub.sh"
	[ "$(sha256sum "$self/new" | cut -d' ' -f1)" = "$want" ] || die "新脚本校验不通过，已丢弃，$0 未改动"
	# Written through the existing file, which keeps its mode and owner. The shell
	# reads nothing further from it: exec follows.
	cat "$self/new" >"$0" || die "写不进 $0。手动更新：curl -fsSL $base/install-hub.sh -o $0"
	rm -rf "$self"
	ok "脚本" "已更新"
	# The parser consumed "$@", so the request is rebuilt from what it recorded;
	# only the menu or an install reaches here.
	set --
	[ -z "$PORT_SET" ] || set -- "$@" --port "$PORT"
	[ -z "$SITE_SET" ] || set -- "$@" --site "$SITE"
	[ -z "$HTTPS" ] || set -- "$@" --https
	[ -z "$HTTPS_PORT_SET" ] || set -- "$@" --https-port "$HTTPS_PORT"
	[ -z "$PLAIN" ] || set -- "$@" --plain
	[ -z "$LOCAL_NODE" ] || set -- "$@" --local-node "$LOCAL_NODE"
	[ -z "$YES" ] || set -- "$@" --yes
	exec sh "$0" "$@"
}

check_port() {
	case "$1" in "" | *[!0-9]*) die "端口必须是 1-65535 的整数：$1" ;; esac
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "端口必须是 1-65535 的整数：$1"
}

# The `--listen ...` tail of the installed unit's ExecStart, empty when nothing
# is installed. An upgrade rewrites the unit, so anything not supplied on the
# command line must be recovered from the old one, or re-running to upgrade
# would silently reset the port and drop --site.
old_exec() { sed -n 's/^ExecStart=.*--listen //p' "$UNIT" 2>/dev/null || true; }

# Whether an earlier `--https` run left a self-signed listener behind, and which
# port it is on. Empty when there is none.
#
# Read from the machine rather than remembered on the command line, because that
# is where it lives: the vhost outlives the unit, so a re-run that omits --https
# would otherwise print "still needs a reverse proxy" over a deployment that has
# been reachable over TLS all along -- sending the operator off to configure a
# proxy they do not need, or to add --plain and put the credentials on the wire.
#
# Deliberately not routed through find_nginx: the summary asks this question
# after the install, when nginx must not be a precondition for answering it.
old_https_port() {
	for dir in /etc/nginx/sites-enabled /etc/nginx/conf.d; do
		file="$dir/monitor-hub-https.conf"
		[ -f "$file" ] || continue
		port="$(sed -n 's/^ *listen \([0-9]*\) ssl.*/\1/p' "$file" 2>/dev/null | head -1)"
		printf '%s: %s' "$dir" "${port:-8444}"
		return 0
	done
}

# The port that unit listens on, empty when there is none. Read twice: once for
# the carry-over and once for the default the menu offers, since pressing Enter
# there must leave a running deployment unchanged.
old_port() {
	listen="$(old_exec)"
	case "$listen" in
	*:[0-9]*) listen="${listen%% *}"; printf '%s' "${listen##*:}" ;;
	esac
}

# ---- install ----
install_hub() {
	case "$(uname -m)" in
	x86_64 | amd64) arch=x86_64 ;;
	aarch64 | arm64) arch=aarch64 ;;
	*) die "不支持的架构：$(uname -m)（发布的是 x86_64 与 aarch64）" ;;
	esac
	asset="monitor-hub-$arch-unknown-linux-musl"
	base="https://github.com/$REPO/releases/latest/download"
	ok "架构" "$arch"

	# Whatever the command line did not specify is recovered from the old unit;
	# see old_exec.
	if [ -z "$PORT_SET" ]; then
		carried="$(old_port)"
		[ -z "$carried" ] || PORT="$carried"
	fi
	if [ -z "$SITE_SET" ]; then
		carried="$(old_exec)"
		case "$carried" in
		*--site\ *) SITE="${carried##*--site }"; SITE="${SITE%% *}" ;;
		esac
	fi
	check_port "$PORT"

	# A self-signed listener an earlier run left behind counts as configured, so
	# omitting --https on a re-run keeps it rather than quietly dropping the
	# deployment back to loopback-only; see old_https_port. A domain takes
	# precedence: --site serves the panel over a real certificate, and the
	# self-signed vhost would hold its port as the default server and shadow it.
	left="$(old_https_port)"
	if [ -n "$left" ] && [ -z "$PLAIN" ]; then
		port="${left##*: }"
		if [ -n "$SITE" ]; then
			HTTPS=""
		else
			# No line printed here: setup_https reports what it found, and one
			# fact printed twice reads as two things having happened.
			HTTPS=1
			[ -n "$HTTPS_PORT_SET" ] || HTTPS_PORT="$port"
		fi
	fi
	check_port "$HTTPS_PORT"

	# A domain is configured, so an earlier --https run's self-signed listener
	# has to go: it holds its port as the default server and would shadow
	# whichever certificate the domain is served with.
	#
	# --plain deliberately leaves it alone. The two answer different questions --
	# --https is how the panel is reached, --plain is whether that reach is
	# encrypted -- and a hub exposed on the public interface with an encrypted
	# entry point left standing is strictly better than one without. Removing it
	# is the operator's call, not a side effect of passing --plain.
	[ -z "$SITE" ] || remove_https_site

	# Before anything is stopped, replaced or downloaded: a port conflict must
	# leave the running hub untouched. The hub's own socket is never a conflict,
	# determined by pid rather than by the port written in the unit -- one this
	# script did not write, whether hand-edited or with ExecStart split across
	# lines, parses out empty, and the hub already on the port would be reported
	# as an unrelated process occupying it.
	if command -v ss >/dev/null 2>&1; then
		holder="$(ss -ltnpH "sport = :$PORT" 2>/dev/null |
			sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)"
		if [ -n "$holder" ] &&
			[ "$holder" != "$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null)" ]; then
			die "端口 $PORT 已被其它程序占用，换一个：--port <n>"
		fi
	fi

	id -u "$USER_NAME" >/dev/null 2>&1 ||
		useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME" ||
		die "无法创建系统用户 $USER_NAME"
	install -d -m 0755 "$ROOT"
	# 0700 owned by the service user, so its group is irrelevant and nothing here
	# depends on useradd having created one.
	install -d -m 0700 -o "$USER_NAME" "$DATA"

	# Only a missing database makes this a first install, which sets the
	# password. Checked before anything is installed.
	first=""
	[ -f "$DATA/monitor.db" ] || first=1

	# The tag comes from GitHub's own redirect for "latest", so there is no API
	# call to be rate-limited and no JSON to parse. Only the first hop carries it
	# -- the chain ends on release-assets.githubusercontent.com, whose URL
	# contains no tag -- so this must not follow redirects. A missing asset still
	# redirects, so the download below is what catches an architecture that was
	# never published.
	tag="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$base/$asset" 2>/dev/null |
		sed -n 's#.*/download/\([^/]*\)/.*#\1#p')" || true
	[ -n "$tag" ] || die "查不到最新发布版；GitHub 不可达，或还没有任何发布"
	ok "版本" "$tag"

	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	curl -fsSL --max-time 300 "$base/$asset" -o "$tmp/$asset" || die "二进制下载失败：$base/$asset"
	ok "下载" "$(du -h "$tmp/$asset" | cut -f1)"

	# Verified against the release's own checksum file, so a truncated transfer or
	# a substituted asset is caught before anything lands in /opt/monitor.
	curl -fsSL --max-time 30 "$base/sha256sums.txt" -o "$tmp/sums" ||
		die "校验文件下载失败"
	want="$(sed -n "s/^\([0-9a-f]\{64\}\)  *$asset\$/\1/p" "$tmp/sums")"
	[ -n "$want" ] || die "sha256sums.txt 里没有 $asset 这一项"
	got="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
	[ "$got" = "$want" ] || die "校验不通过，已丢弃下载的文件。期望 $want，实得 $got"
	ok "校验" "sha256 一致"

	# Keep the old binary until the new one has proved it starts: a failed upgrade
	# must leave a running hub rather than a dead service.
	backup=""
	if [ -f "$BIN" ]; then
		backup="$BIN.old"
		# Never over an existing backup. A run that died between the install below
		# and the health check left $BIN holding a binary that never proved it
		# starts; copying that over the good backup would make the rollback restore
		# the same broken binary while reporting success.
		[ -f "$backup" ] || cp -f "$BIN" "$backup"
	fi
	# Stopped first so the copy does not land beneath a live process.
	systemctl stop "$SERVICE" 2>/dev/null || true
	install -m 0755 "$tmp/$asset" "$BIN"
	# The download is complete. Cleared here as well as on EXIT because the menu
	# calls this more than once per run and each call replaces the trap, leaving
	# the previous directory and its binary uncollected.
	rm -rf "$tmp"
	trap - EXIT

	# A plaintext hub has no certificate to be reached through and no proxy in
	# front, so it answers on the public interface directly, and the address the
	# panel is reached at is this machine's own -- which is also what the install
	# command has to carry, since a node has to be able to reach it.
	#
	# Otherwise loopback only: the panel and the agent tokens then never traverse a
	# network in the clear, and there is no port to firewall. Reaching it is the
	# reverse proxy's responsibility, and 127.0.0.1 rather than [::1] because that
	# is every proxy's default upstream; the hub binds one address, not both.
	if [ -n "$PLAIN" ]; then
		listen="0.0.0.0:$PORT"
		if [ -z "$SITE" ]; then
			ip="$(public_ip)"
			[ -n "$ip" ] ||
				die "取不到本机公网地址，拼不出 --site。手动给一个：--site http://你的IP:$PORT"
			SITE="http://$ip"
			[ "$PORT" = 80 ] || SITE="$SITE:$PORT"
		fi
	else
		listen="127.0.0.1:$PORT"
	fi
	args="--listen $listen --db $DATA/monitor.db"
	[ -z "$SITE" ] || args="$args --site $SITE"
	cat >"$UNIT" <<UNIT
[Unit]
Description=monitor hub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN $args
Restart=always
RestartSec=5
# The database and the themes/ directory beside it live in data/, which is the
# only path this service may write to, excluding even the binary above it.
User=$USER_NAME
WorkingDirectory=$ROOT
ReadWritePaths=$DATA
NoNewPrivileges=yes
RestrictSUIDSGID=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_INET AF_INET6
MemoryMax=256M

[Install]
WantedBy=multi-user.target
UNIT

	# Taken from the binary's stdout rather than the journal, which some hosts
	# keep nowhere. Set before the service starts, so the hub finds a password in
	# place and does not generate a second one. A reset refuses a missing
	# database, so the file is created first under the service user; SQLite reads
	# an empty file as an empty database.
	pw=""
	if [ -n "$first" ]; then
		install -m 0600 -o "$USER_NAME" /dev/null "$DATA/monitor.db"
		pw="$(new_password)"
	fi

	systemctl daemon-reload
	systemctl enable "$SERVICE" >/dev/null 2>&1 || true
	# Not left to set -e: a binary that cannot exec fails the job itself, which is
	# precisely the case the rollback below exists for. Unguarded, the script
	# would exit here with a raw systemd error and leave the hub down on the
	# binary that just failed.
	systemctl restart "$SERVICE" || true
	# is-active answers before a unit that exits immediately has done so. Wait,
	# then query.
	sleep 3
	if ! systemctl is-active --quiet "$SERVICE"; then
		# A first install has nothing to keep serving, so there is no rollback.
		# The new database holds nothing but a password never shown; it is removed
		# so that a rerun is again a first install and shows one, and the unit is
		# disabled, since any binary it started later -- on a reboot as well --
		# would set a password on an empty database and print it only to the
		# journal. A backup, if any, stays for the next run.
		if [ -n "$first" ]; then
			systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
			rm -f "$DATA/monitor.db" "$DATA/monitor.db-wal" "$DATA/monitor.db-shm"
			die "服务启动失败。日志：journalctl -u $SERVICE -n 50"
		fi
		if [ -n "$backup" ]; then
			install -m 0755 "$backup" "$BIN"
			rm -f "$backup"
			systemctl restart "$SERVICE" 2>/dev/null || true
			die "新版本没能启动，已回滚到上一版。日志：journalctl -u $SERVICE -n 50"
		fi
		die "服务启动失败。日志：journalctl -u $SERVICE -n 50"
	fi
	rm -f "$BIN.old"
	ok "服务" "已启动并开机自启"

	# What the panel answers at. --site wins when it is given: that is the
	# address nodes use, which is the one worth printing. setup_https replaces
	# it with the https:// address it just made reachable.
	PANEL="${SITE:-http://127.0.0.1:$PORT}"
	# Both below run only after the service is up: nginx proxies to a hub that
	# already answers, and the node goes into a database that already exists.
	if [ -n "$HTTPS" ]; then setup_https; fi
	add_local_node "$LOCAL_NODE"

	if [ -n "$first" ]; then done_title="安装完成"; else done_title="升级完成"; fi
	printf '\n  %s%s%s\n' "$B" "$done_title" "$N"
	rule
	printf '\n'
	field "面板" "$PANEL/admin"
	if [ -n "$first" ]; then
		if [ -n "$pw" ]; then
			field "密码" "$pw"
			field "    " "${D}记下来，登录后到「安全」里改掉${N}"
		else
			field "密码" "没取到，重跑安装器选「重置密码」"
		fi
	fi
	field "数据" "$DATA/monitor.db"
	field "服务" "systemctl status $SERVICE"
	field "日志" "journalctl -u $SERVICE -f"
	printf '\n'

	# The hub is on loopback, so this is the remaining half of the install rather
	# than optional advice. It deliberately omits --site: the panel builds install
	# commands from the browser's own address, so once the domain works everything
	# downstream follows.
	if [ -z "$SITE" ] && [ -z "$HTTPS" ]; then
		printf '  %s还差一步：配个反向代理%s\n' "$B" "$N"
		printf '     面板只监听本机，公网访问不到——这是故意的，凭证不会在链路上裸奔。\n'
		printf '     用 nginx / caddy / cf tunnel 任选一种，把 hub.example.com 换成你的域名，\n'
		printf '     配好之后用域名访问面板，我相信这难不倒你。\n'
		printf '     没有域名的话，重跑一次加 --https，安装器会签一张自签证书并配好 nginx。\n'
		# The documented configurations use the default port.
		[ "$PORT" = 28080 ] || printf '     文档里的 28080 换成 %s。\n' "$PORT"
		printf '     反向代理文档：https://monitor-document.pages.dev/install/reverse-proxy\n'
	fi
	# A self-signed certificate is enough for the panel and for an agent on this
	# same machine, which reaches the hub over loopback. It is not enough for a
	# node elsewhere: the agent trusts public roots only, so a remote node needs a
	# real certificate, and that needs a domain.
	if [ -z "$SITE" ] && [ -n "$HTTPS" ]; then
		printf '  %s只有面板和本机节点能用%s\n' "$B" "$N"
		printf '     自签证书浏览器点一次「继续」就过了，但远程节点的 agent 只认公共 CA 签的证书，\n'
		printf '     它会直接连不上。要有远程节点，两条路：\n'
		printf '       · 等域名解析过来后重跑：--site https://你的域名（推荐，全程加密）\n'
		printf '       · 或者重跑加 --plain：面板明文跑在公网，token 会裸奔\n'
	fi
	# The one deployment where the credentials the panel hands out really do
	# cross the network in the clear. Said here where the operator reads it, and
	# again by the hub at startup, where it is seen on the next restart.
	if [ -n "$PLAIN" ]; then
		printf '  %s面板在公网上是明文的%s\n' "$B" "$N"
		printf '     登录密码、会话 cookie、节点 token 都不加密，抓包就能拿走；\n'
		printf '     拿到 token 就能接管对应节点。只在你信得过的网络里这么用。\n'
		printf '     哪天有域名了，重跑一次加 --https 或 --site https://你的域名 就能收紧。\n'
	fi
}

# ---- https without a domain ----
# Terminates TLS in front of the loopback hub, so a hub with no domain is still
# reached over an encrypted hop rather than a plaintext one. The hub keeps
# listening on 127.0.0.1 throughout; only nginx is exposed.
#
# The certificate is self-signed, which is what makes this work without a
# domain and also what limits it: see the note the caller prints afterwards.
#
# Debian and Ubuntu include sites-enabled/; RHEL and Alpine include conf.d/.
# Both sit inside the http block, which is where a server block belongs, so the
# file goes wherever this nginx already looks.
# Drops the listener an earlier --https run installed, and says so. Called when
# a domain is configured instead: the self-signed site holds its port as the
# default server, so leaving it would shadow the real certificate.
remove_https_site() {
	for dir in /etc/nginx/sites-enabled /etc/nginx/conf.d; do
		[ -f "$dir/monitor-hub-https.conf" ] || continue
		rm -f "$dir/monitor-hub-https.conf"
		if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
			systemctl reload nginx 2>/dev/null || true
		fi
		warn "已删掉之前 --https 装的自签配置（$dir/monitor-hub-https.conf），交回给你的域名证书"
	done
}

# This machine's public address, as the address bar and the install command will
# have it. Three services because any one of them can be unreachable from here,
# and the address the default route leaves from as a last resort -- which on a
# VPS with a public address is the one asked for, and behind NAT is not.
public_ip() {
	addr=""
	for src in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
		addr="$(curl -fsS --max-time 8 "$src" 2>/dev/null | tr -d '[:space:]')"
		case "$addr" in "" | *[!0-9.]*) addr="" ;; *) break ;; esac
	done
	if [ -z "$addr" ]; then
		addr="$(ip -4 route get 1.1.1.1 2>/dev/null |
			sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
	fi
	printf '%s' "$addr"
}

find_nginx() {
	NGINX_BIN="$(command -v nginx || true)"
	NGINX_CONF_DIR=""
	if [ -d /etc/nginx/sites-enabled ]; then
		NGINX_CONF_DIR=/etc/nginx/sites-enabled
	elif [ -d /etc/nginx/conf.d ]; then
		NGINX_CONF_DIR=/etc/nginx/conf.d
	fi
	if [ -n "$NGINX_BIN" ] && [ -n "$NGINX_CONF_DIR" ]; then return 0; fi
	return 1
}

install_nginx() {
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
			DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q nginx
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q nginx
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-cache nginx
	else
		return 1
	fi
}

setup_https() {
	command -v openssl >/dev/null 2>&1 ||
		die "自签证书要 openssl，先装上（apt install openssl / dnf install openssl）"
	# -addext is the only way to put an address in the subjectAltName from the
	# command line, and a certificate without one is refused by every current
	# browser -- CN alone has been ignored since Chrome 58.
	openssl req -help 2>&1 | grep -q -- '-addext' ||
		die "openssl 太旧，不支持 -addext（要 1.1.1 以上）。升级后重跑"

	if ! find_nginx; then
		printf '  装 nginx……\n'
		install_nginx || die "装不上 nginx。手动装好再重跑，或用 --site 自己配反代"
		find_nginx || die "装完还是找不到 nginx 和它 include 的目录"
	fi

	# Something else on the port means this listener never comes up, and the
	# reload below would fail after the config was already written. Checked
	# first, so a refusal leaves nginx exactly as it was.
	if command -v ss >/dev/null 2>&1; then
		holder="$(ss -ltnpH "sport = :$HTTPS_PORT" 2>/dev/null |
			sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)"
		if [ -n "$holder" ] &&
			[ "$(readlink -f "/proc/$holder/exe" 2>/dev/null)" != "$(readlink -f "$NGINX_BIN")" ]; then
			die "端口 $HTTPS_PORT 被别的程序占着（pid $holder）。换一个：--https-port <n>"
		fi
	fi

	# The address the user will type into the address bar, and the one that has
	# to be in the certificate. A domain may not resolve here yet, so the
	# machine's own public address is what there is to name. Worth getting
	# right: a certificate naming a different address gives the browser a name
	# mismatch, which is a much harder warning to click through than the
	# self-signed one this is meant to produce.
	ip="$(public_ip)"
	[ -n "$ip" ] || die "取不到本机公网地址，签不了证书。改用 --site 配反代"

	certdir=/etc/nginx/ssl
	cert="$certdir/monitor-hub.crt"
	key="$certdir/monitor-hub.key"
	if [ -f "$cert" ] && [ -f "$key" ]; then
		ok "证书" "沿用 $certdir 里已有的"
	else
		install -d -m 0755 "$certdir"
		# A leaf certificate, not a CA one. `req -x509` defaults to
		# `basicConstraints=critical,CA:TRUE` and emits no key usage at all,
		# which is a CA certificate pressed into service as a server
		# certificate: rustls rejects it outright with CaUsedAsEndEntity, and
		# browsers outside Chrome are stricter about it than they need to be.
		openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
			-keyout "$key" -out "$cert" -subj "/CN=$ip" \
			-addext "basicConstraints=critical,CA:FALSE" \
			-addext "keyUsage=critical,digitalSignature,keyEncipherment" \
			-addext "extendedKeyUsage=serverAuth" \
			-addext "subjectAltName=IP:$ip,IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1 ||
			die "证书生成失败"
		chmod 0600 "$key"
		ok "证书" "自签十年，$ip（浏览器会警告一次）"
	fi

	site="$NGINX_CONF_DIR/monitor-hub-https.conf"

	# Debian defines this map in its own nginx.conf. Where it is not defined --
	# RHEL, Alpine -- it has to come from somewhere, and defining it twice is a
	# duplicate-map error that fails the reload.
	#
	# Asked of every config except ours, and that exclusion is the whole point:
	# this file is about to be overwritten, so its own map cannot count as
	# "already defined". `nginx -T` would, and it does -- on the second run the
	# map written by the first is still there, so the check passes, the new file
	# goes out without one, and the reload dies on `unknown "connection_upgrade"
	# variable`. Whether that happens is a race against nginx being ready to
	# answer `-T` at all, which is why it only showed up some of the time.
	head=""
	"$NGINX_BIN" -T 2>/dev/null |
		sed -e "\#configuration file $site:#,\$d" |
		grep -q 'map \$http_upgrade \$connection_upgrade' ||
		head='map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      close;
}
'
	cat >"$site" <<CONF
${head}server {
    listen $HTTPS_PORT ssl default_server;
    listen [::]:$HTTPS_PORT ssl default_server;
    server_name _;

    ssl_certificate     $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # No HSTS. It outlives the warning the user clicks through and would pin the
    # browser to a certificate nobody can verify, leaving no way back.
    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        # Without --site the hub decides the session cookie's Secure flag from
        # this header alone; a proxy that omits it costs the flag.
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        # The panel's live view is one long-lived WebSocket.
        proxy_read_timeout 3600s;
    }
}
CONF

	# Written then tested, and removed again on failure, so a config this nginx
	# will not accept never reaches a reload.
	if ! "$NGINX_BIN" -t >/dev/null 2>&1; then
		msg="$("$NGINX_BIN" -t 2>&1)"
		rm -f "$site"
		die "nginx 配置检查没过，刚写的文件已删除。$msg"
	fi
	if systemctl is-active --quiet nginx 2>/dev/null; then
		systemctl reload nginx || die "nginx 重载失败"
	else
		systemctl enable --now nginx >/dev/null 2>&1 || die "nginx 起不来"
	fi
	PANEL="https://$ip"
	# 443 is https's implicit port, not ours: it is the only value that can be
	# left out of the URL. Whatever HTTPS_PORT is set to otherwise -- 8444 by
	# default -- has to be written down, or the printed address points at nothing.
	[ "$HTTPS_PORT" = 443 ] || PANEL="$PANEL:$HTTPS_PORT"
	ok "HTTPS" "$PANEL"
}

# Creates the node this machine reports as, straight in the database rather than
# through the panel's API. The API refuses a node added from a plain-http entry,
# which is how a hub without a domain is reached; and a token made here never
# crosses the network. Running it twice reuses the node of that name, so an
# upgrade does not leave a second one behind.
add_local_node() {
	[ -n "$1" ] || return 0
	token="$("$BIN" --db "$DATA/monitor.db" --add-local-node "$1" |
		sed -n 's/^Node token: //p')"
	[ -n "$token" ] ||
		die "建本机节点失败。手动看报错：$BIN --db $DATA/monitor.db --add-local-node $1"
	printf '\n'
	printf '  %s本机节点%s  %s\n' "$B" "$N" "$1"
	printf '  %s服务器和面板是同一台机器时，再跑这一条把 agent 装上：%s\n' "$D" "$N"
	printf '    curl -fsSL http://127.0.0.1:%s/install.sh | sudo sh -s -- --server http://127.0.0.1:%s --token %s\n' \
		"$PORT" "$PORT" "$token"
}

# ---- password ----
# Prints nothing on failure; the hub's own error reaches stderr. Running as root
# is safe: SQLite gives the -wal and -shm files it creates the database file's
# owner.
new_password() {
	"$BIN" --db "$DATA/monitor.db" --reset-password | sed -n 's/^Emergency password: //p'
}

reset_password() {
	# The data outlives --uninstall, so the database alone does not mean a hub.
	if [ ! -f "$BIN" ] || [ ! -f "$DATA/monitor.db" ]; then
		die "这台机器上没有装 monitor hub"
	fi
	confirm "重置面板密码？所有已登录的会话都会被登出" || return 0
	pw="$(new_password)"
	# Versions without the flag report "unknown argument" on stderr.
	[ -n "$pw" ] || die "重置失败。上面提示 unknown argument 的话是 hub 版本太旧，先升级"
	field "密码" "$pw"
}

# ---- uninstall ----
uninstall_hub() {
	if [ ! -f "$BIN" ] && [ ! -f "$UNIT" ]; then
		# The data outlives the unit, so --purge still has work to do.
		if [ -n "$PURGE" ] && [ -e "$DATA" ]; then
			confirm "服务已经卸载了。删除 $DATA 下的数据库？不可撤销" || return 0
			rm -rf "$DATA"
			rmdir "$ROOT" 2>/dev/null || true
			ok "数据" "已删除"
			return 0
		fi
		[ ! -e "$DATA" ] || die "服务已经卸载了，数据还留在 $DATA；要一并删掉就加 --purge"
		die "这台机器上没有装 monitor hub"
	fi
	if [ -n "$PURGE" ]; then
		confirm "卸载 monitor hub，并删除 $DATA 下的数据库？不可撤销" || return 0
	else
		confirm "卸载 monitor hub？数据保留在 $DATA" || return 0
	fi
	systemctl disable --now "$SERVICE" 2>/dev/null || true
	rm -f "$UNIT" "$BIN" "$BIN.old"
	systemctl daemon-reload
	ok "服务" "已移除"
	if [ -n "$PURGE" ]; then
		rm -rf "$DATA"
		# Only when the agent is not installed alongside it.
		rmdir "$ROOT" 2>/dev/null || true
		ok "数据" "已删除"
	else
		field "数据" "保留在 $DATA，重新安装会直接接着用"
	fi
}

menu() {
	while :; do
		banner
		printf '    1  安装 / 升级\n'
		printf '    2  卸载\n'
		printf '    3  状态\n'
		printf '    4  日志\n'
		printf '    5  重置密码\n'
		printf '    q  退出\n\n'
		printf '  %s›%s ' "$B" "$N"
		read -r choice || exit 0
		printf '\n'
		case "$choice" in
		1)
			# The default offered is what the unit already listens on, so Enter
			# leaves a running deployment unchanged. PORT_SET marks the answer as
			# supplied: without it the carry-over in install_hub would read the port
			# back out of that same unit and discard the answer given here.
			carried="$(old_port)"
			PORT="$(ask "监听端口" "${carried:-$PORT}")"
			check_port "$PORT"
			PORT_SET=1
			# Offered as the default where an earlier run installed it, so
			# pressing Enter on an upgrade keeps the panel reachable at the
			# address it is already at.
			https_default=n
			if [ -f /etc/nginx/sites-enabled/monitor-hub-https.conf ] ||
				[ -f /etc/nginx/conf.d/monitor-hub-https.conf ]; then
				https_default=y
			fi
			reply="$(ask "没有域名？签自签证书 + 配好 nginx（浏览器会警告一次）" "$https_default")"
			case "$reply" in y | Y | yes) HTTPS=1 ;; *) HTTPS="" ;; esac
			# Asked only when the answer above was no: the two are alternatives
			# to each other, not settings that combine. Offered as the default
			# where the running unit already answers on the public interface, so
			# pressing Enter on an upgrade leaves it there.
			plain_default=n
			case "$(old_exec)" in
			0.0.0.0:* | "[::]:"*) plain_default=y ;;
			esac
			if [ -z "$HTTPS" ]; then
				reply="$(ask "也不用证书？面板明文跑在公网（token 会裸奔）" "$plain_default")"
				case "$reply" in y | Y | yes) PLAIN=1 ;; *) PLAIN="" ;; esac
			fi
			# Blank skips it. Asked because the hub and the agent are on one
			# machine often enough that the panel's own install command, which
			# needs a domain, is not the way to add this node.
			LOCAL_NODE="$(ask "顺手把本机也建成节点？填名字，回车跳过" "")"
			printf '\n'
			install_hub
			press
			;;
		2) uninstall_hub; press ;;
		3) systemctl status "$SERVICE" --no-pager || true; press ;;
		4) journalctl -u "$SERVICE" -f --no-pager ;;
		5) reset_password; press ;;
		q | Q | exit | "") exit 0 ;;
		*) ;;
		esac
	done
}

usage() {
	cat <<TXT
monitor hub 安装器

  sudo ./install-hub.sh                有终端时给菜单，否则按默认安装
  sudo ./install-hub.sh --port 28081    指定端口安装
  sudo ./install-hub.sh --plain        没有域名时用：面板明文跑在公网，不加密
  sudo ./install-hub.sh --https        没有域名时用：签自签证书 + 配好 nginx
  sudo ./install-hub.sh --uninstall    卸载，保留数据
  sudo ./install-hub.sh --purge        卸载并删除数据库
  sudo ./install-hub.sh --reset-password
                                       重置面板密码，登出所有会话

  --port <n>     本机监听端口，默认 $PORT
  --plain        没有域名、也不想配证书时用。hub 直接监听公网，面板走 http://
                 公网IP:端口。**登录密码、会话 cookie、节点 token 都不加密**，
                 抓包就能拿走，拿到 token 就能接管节点。好处是零依赖、零维护，
                 远程节点也能加。只在信得过的网络里这么用
  --https        面板没有域名、但想要加密时用。安装器装好 nginx，签一张
                 自签证书，把 8444 反代到本机的 hub。浏览器第一次会警告「不安全」，
                 点「继续」即可；流量是加密的。只有面板和本机 agent 能用——
                 远程节点的 agent 只认公共 CA 签的证书，等域名解析过来后加
                 --site https://你的域名 重跑一次即可
  --https-port <n>
                 自签 HTTPS 的监听端口，默认 8444。443 让给 sing-box ——
                 同一台机器既当面板又当节点时，REALITY 会把不认识的握手转发
                 给伪装站，面板放 443 根本进不去
  --local-node <名字>
                 顺手把本机这个节点建好，并打印装 agent 的命令。服务器和面板是
                 同一台机器时用；token 只在本地生成，不过网。重名会复用不重复建
  --site <url>   一般不用填。面板拼安装命令用的是浏览器地址栏，配好反代
                 用域名访问就自动对了。三种情况要填：节点该连的域名和你
                 进面板的域名不是同一个；走 SSH 隧道进面板（地址栏是
                 127.0.0.1，节点连不上它）；反代不发 X-Forwarded-Proto
                 （那时会话 cookie 拿不到 Secure 标志）
                 写 https:// 时后面必须是域名；没有域名就写 http:// 加公网
                 IP 和端口，配合 --plain 用
  --yes, -y      跳过确认
  --help, -h     显示这段

hub 默认只监听 127.0.0.1，公网访问不到，需要自己配 nginx / caddy / CF 隧道把
域名指过来，配法见 https://monitor-document.pages.dev/install/reverse-proxy
没有域名就用 --https（加密，但只有本机能连）或 --plain（明文，但哪台都能连）。

重跑一次就是升级：校验通过后才替换二进制，起不来会自动回滚到上一版；
没写的参数沿用上次的，所以升级不会把端口和 --site 冲掉。
这份脚本不是最新发布的那一版时，会先把自己换成新版再接着装。
二进制和数据都在 $ROOT 下（数据库和主题在 $DATA），卸载默认保留数据。
TXT
}

while [ $# -gt 0 ]; do
	case "$1" in
	# An explicit guard rather than `${2-}`: `shift 2` with nothing to shift is
	# fatal in dash, and the output would be the shell's diagnostic rather than
	# this message.
	--port) [ $# -ge 2 ] || die "--port 后面要跟端口号"; PORT="$2"; PORT_SET=1; shift 2 ;;
	--site) [ $# -ge 2 ] || die "--site 后面要跟地址"; SITE="$2"; SITE_SET=1; shift 2 ;;
	--https) HTTPS=1; shift ;;
	--https-port) [ $# -ge 2 ] || die "--https-port 后面要跟端口号"; HTTPS_PORT="$2"; HTTPS_PORT_SET=1; shift 2 ;;
	--plain) PLAIN=1; shift ;;
	--local-node) [ $# -ge 2 ] || die "--local-node 后面要跟节点名"; LOCAL_NODE="$2"; shift 2 ;;
	--uninstall) ACTION=uninstall; shift ;;
	--purge) ACTION=uninstall; PURGE=1; shift ;;
	--reset-password) ACTION=reset; shift ;;
	--yes | -y) YES=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "未知参数：$1（--help 看用法）" ;;
	esac
done

check_port "$PORT"
check_port "$HTTPS_PORT"
# The two answer different situations, and together they contradict: --https
# installs a self-signed listener as the port's default server, while --site
# states that a real certificate is already in front of the hub.
if [ -n "$HTTPS" ] && [ -n "$SITE" ]; then
	die "--https 和 --site 别一起给。有域名就自己配反代、用 --site 告诉 hub 节点该连哪个地址；--https 是给没有域名的人签自签证书的"
fi
# The same form `api::https_domain` measures --site against on the hub, checked
# here because this is where the value is entered. A hub started with a value it
# refuses starts normally and then declines to add or install any node, which
# surfaces only in the journal and the panel, long after the value was typed.
SITE="${SITE%/}"
if [ -n "$SITE" ]; then
	case "$SITE" in
	https://*) scheme=https ;;
	http://*) scheme=http ;;
	*) die "--site 要以 https:// 或 http:// 开头：$SITE" ;;
	esac
	rest="${SITE#*://}"
	case "$rest" in
	*/*) die "--site 后面不能带路径，只要 协议://主机[:端口]：$SITE" ;;
	*@*) die "--site 里不能带用户名：$SITE" ;;
	esac
	# IPv6 literals are bracketed, so the port is not split off at the first
	# colon. The same shape `loopback_origin` parses on the hub.
	case "$rest" in
	"["*) site_host="${rest#\[}"; site_host="${site_host%%]*}" ;;
	*) site_host="${rest%%:*}" ;;
	esac
	[ -n "$site_host" ] || die "--site 里要有主机名或地址：$SITE"
	# An address on this machine names nothing a node could reach. The hub
	# refuses the same values, in `plain_entry` and `https_domain`.
	case "$site_host" in
	localhost | *.localhost | 0.0.0.0 | "::" | "::1" | 127.*) die "--site 不能用本机地址：$SITE" ;;
	esac
	# https needs a name: a certificate is issued to one, and a browser refuses
	# an address before the page loads. http is the no-domain path, where there
	# is no name to use, so anything a node can reach is allowed.
	if [ "$scheme" = https ]; then
		case "$site_host" in
		*[!0-9.]*) ;;
		*) die "--site 用 https:// 时必须是域名，不能是 IP 地址：$SITE" ;;
		esac
	fi
fi
# The two answers to having no domain, and they contradict: one encrypts with a
# certificate this machine signs for itself, the other does not encrypt at all.
if [ -n "$HTTPS" ] && [ -n "$PLAIN" ]; then
	die "--https 和 --plain 是相反的两条路，只能给一个：--https 签自签证书加密，--plain 完全不加密"
fi
case "$SITE" in
https://*)
	[ -z "$PLAIN" ] ||
		die "--plain 是明文部署，--site 不能写 https://：去掉 --plain，或把 --site 改成 http://"
	;;
esac
[ "$(id -u)" = 0 ] || die "需要 root：sudo sh $0"
command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v sha256sum >/dev/null 2>&1 || die "需要 sha256sum（装 coreutils）"
command -v systemctl >/dev/null 2>&1 ||
	die "这个安装器只装 systemd 服务。手动运行：$BIN --listen 127.0.0.1:$PORT --db $DATA/monitor.db"

case "$ACTION" in
uninstall) banner; uninstall_hub ;;
reset) banner; reset_password ;;
*)
	check_self
	if [ -t 0 ]; then
		menu
	else
		banner
		install_hub
	fi
	;;
esac
