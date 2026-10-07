#!/bin/sh
# Installs monitor-agent as a systemd or OpenRC service.
#   curl -fsSL https://hub.example.com/install.sh | sh -s -- --server URL --token TOKEN [options]
#   curl -fsSL https://hub.example.com/install.sh | sh -s -- --server URL --register KEY [options]
#   curl -fsSL https://hub.example.com/install.sh | sh -s -- --upgrade
#   curl -fsSL https://hub.example.com/install.sh | sh -s -- --uninstall
set -eu
# useradd and rc-update reside in sbin, which a root shell entered through `su`
# without `-` lacks on Debian: su keeps the caller's PATH unless ALWAYS_SET_PATH
# is set, and Debian does not set it.
PATH="$PATH:/usr/sbin:/sbin"

# Binary and token in one directory, the same one the hub uses, giving a node a
# single path to inspect and a single path to remove.
ROOT="/opt/monitor"
BIN="$ROOT/monitor-agent"
ENV_FILE="$ROOT/agent.env"
UNIT_FILE="/etc/systemd/system/monitor-agent.service"
RC_FILE="/etc/init.d/monitor-agent"
LOG_FILE="/var/log/monitor-agent.log"
SERVER=""
TOKEN=""
REGISTER=""
NAME=""
IFACE=""
IFACE_SET=""
INTERVAL=""
INSECURE=""
INSECURE_SET=""
UNINSTALL=""
UPGRADE=""
VPN_IP=""
NO_VPN=""
# The subscription server, installed alongside the agent. Its paths are here
# rather than beside its functions because --uninstall runs long before those are
# defined.
SUB_HOME="/opt/sub-dynamic"
SUB_UNIT="/etc/systemd/system/sub-dynamic.service"
SUB_RC="/etc/init.d/sub-dynamic"
# 对外端口：客户端订阅 URL 里的那个。默认 80，与已经在跑的两台一致。
SUB_PORT="80"
SUB_PORT_SET=""
# 走 nginx 时订阅服务自己绑的回环端口。nginx 在前面把订阅路径转过来，
# 对外仍然是 SUB_PORT —— 两种情况下客户端拿到的 URL 都不带端口。
SUB_BACKEND="18081"
SUB_NGINX_CONF="/etc/nginx/conf.d/monitor-sub.conf"
# 对外端口是 nginx 在听时置上：服务退到回环，由 nginx 转过来。
SUB_VIA_NGINX=""
# 端口上已经有人在伺服同一批文件（手工装的那份）时置上：什么都不动，我们也不装。
SUB_FOREIGN=""
# 上一轮记下的订阅落位，按它决定这一轮的对外端口，而不是又猜一次 80。
# 早读：重写 $ENV_FILE 的那一行是**截断写**，它晚于这份快照、早于用它的地方。
SUB_PREV_PUBLIC=""
SUB_PREV_PORT=""
SUB_PREV_BIND=""
SUB_PREV_STATE=""
SUB_BACKUP_DIR=""
SUB_LEGACY_RUNNING=""
read_prev_sub() {
	[ -f "$ENV_FILE" ] || return 0
	SUB_PREV_PUBLIC=$(sed -n 's/^MONITOR_SUB_PUBLIC_PORT=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	SUB_PREV_PORT=$(sed -n 's/^MONITOR_SUB_PORT=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	SUB_PREV_BIND=$(sed -n 's/^MONITOR_SUB_BIND=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	SUB_PREV_STATE=$(sed -n 's/^MONITOR_SUB_STATE=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	if [ -z "$SUB_PREV_PUBLIC" ] && [ "$SUB_PREV_BIND" = 127.0.0.1 ] && [ -f "$SUB_NGINX_CONF" ]; then
		SUB_PREV_PUBLIC=$(sed -n 's/^[[:space:]]*listen \([0-9][0-9]*\).*/\1/p' "$SUB_NGINX_CONF" | head -n 1)
	fi
}
read_prev_sub

save_sub_file() {
    [ ! -f "$1" ] || cp -p "$1" "$SUB_BACKUP_DIR/$2"
}

restore_sub_file() {
    if [ -f "$SUB_BACKUP_DIR/$2" ]; then cp -p "$SUB_BACKUP_DIR/$2" "$1"; else rm -f "$1"; fi
}

cleanup_install() {
    [ -z "${TMP:-}" ] || rm -f "$TMP"
    case "$SUB_BACKUP_DIR" in "$ROOT"/.subscription-backup.*) rm -rf "$SUB_BACKUP_DIR" ;; esac
}

while [ $# -gt 0 ]; do
	# A flag with no argument: under set -u, `$2` aborts with the shell's own
	# message rather than the usage below, and `shift 2` cannot proceed.
	case "$1" in
	--server | --token | --register | --name | --iface | --interval | --vpn-ip | --sub-port)
		[ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; } ;;
	esac
	case "$1" in
	--server) SERVER="$2"; shift 2 ;;
	--token) TOKEN="$2"; shift 2 ;;
	--register) REGISTER="$2"; shift 2 ;;
	--name) NAME="$2"; shift 2 ;;
	--iface) IFACE="$2"; IFACE_SET=1; shift 2 ;;
	--interval) INTERVAL="$2"; shift 2 ;;
	--vpn-ip) VPN_IP="$2"; shift 2 ;;
	--sub-port) SUB_PORT="$2"; SUB_PORT_SET=1; shift 2 ;;
	--no-vpn) NO_VPN=1; shift ;;
	--insecure) INSECURE=1; INSECURE_SET=1; shift ;;
	--verify-tls) INSECURE=""; INSECURE_SET=1; shift ;;
	--uninstall) UNINSTALL=1; shift ;;
	--upgrade) UPGRADE=1; shift ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# Removes exactly what an install writes and nothing else, for both init
# systems: the one present now need not be the one the install found, and
# systemctl fails outright where systemd is not PID 1 (WSL, containers) although
# the install left its files there. Each step therefore tolerates failure. The
# hub may be installed in $ROOT as well, so the directory is removed only once
# empty.
if [ -n "$UNINSTALL" ]; then
	rc-service monitor-agent stop 2>/dev/null || true
	rc-update del monitor-agent default >/dev/null 2>&1 || true
	systemctl disable --now monitor-agent 2>/dev/null || true
	rm -f "$UNIT_FILE" "$RC_FILE" "$LOG_FILE" "$BIN" "$BIN.old" "$ENV_FILE" "$ROOT/subscription.json"
	# 订阅现在由 agent 自己伺服，随它一起走 —— 上面那行已经删了它的环境文件，
	# 订阅的三条配置就在里面。这里再收掉上一代那份独立服务，以及 nginx 前面
	# 那一段：留着一条指向已删服务的 location，要等下一次 reload 才会发现。
	rc-service sub-dynamic stop 2>/dev/null || true
	rc-update del sub-dynamic default >/dev/null 2>&1 || true
	systemctl disable --now sub-dynamic 2>/dev/null || true
	rm -f "$SUB_UNIT" "$SUB_RC"
	rm -rf "$SUB_HOME"
	# nginx 前面那一段也撤掉，并重载 —— 留着一条指向已删服务的 location，
	# 要等下一次 reload 才会发现。
	rm -f "$SUB_NGINX_CONF" "$SUB_NGINX_CONF.monitor-prev"
	if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
		systemctl reload nginx 2>/dev/null || rc-service nginx reload >/dev/null 2>&1 || true
	fi
	systemctl daemon-reload 2>/dev/null || true
	userdel monitor-agent 2>/dev/null || deluser monitor-agent 2>/dev/null || true
	rmdir "$ROOT" 2>/dev/null || true
	echo "monitor-agent uninstalled"
	exit 0
fi

# Reinstalls the binary with what this machine already holds. It is the one
# command a whole fleet can be upgraded with, because it carries no credential
# and names no node: the token and the hub address come from the env file, which
# only an install writes. Registering is not reached, so it can neither add a
# node nor spend a key, and a machine with nothing installed is told to use the
# panel's command rather than quietly becoming a new node.
if [ -n "$UPGRADE" ]; then
	[ -z "$TOKEN$REGISTER" ] ||
		{ echo "--upgrade takes no --token or --register; it reuses what this machine holds" >&2; exit 2; }
	TOKEN=$(sed -n 's/^MONITOR_TOKEN=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	[ -n "$SERVER" ] || SERVER=$(sed -n 's/^MONITOR_SERVER=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	[ -n "$TOKEN" ] && [ -n "$SERVER" ] || {
		echo "no agent is installed here: $ENV_FILE holds no token and hub address." >&2
		echo "install it with the command from the panel instead" >&2
		exit 2
	}
fi

if [ -z "$SERVER" ] || { [ -z "$TOKEN" ] && [ -z "$REGISTER" ]; }; then
	echo "usage: install.sh --server URL (--token TOKEN | --register KEY) [--interval SECONDS] [--iface LIST] [--insecure]" >&2
	echo "       install.sh --upgrade [--iface LIST] [--interval SECONDS] [--vpn-ip ADDRESS]" >&2
	echo "       install.sh --uninstall" >&2
	echo "--name NAME names the node --register creates; the hostname otherwise" >&2
	echo "--vpn-ip ADDRESS is this machine's public address, for the VPN links;" >&2
	echo "  without it the address is looked up, and --no-vpn skips the VPN entirely" >&2
	echo "--sub-port PORT is where this node serves its own subscription, default 80;" >&2
	echo "  the subscription URL carries it, and clients read the traffic header from" >&2
	echo "  that response -- without the header their card loses the traffic row" >&2
	echo "--insecure accepts a hub whose certificate cannot be verified, which is a" >&2
	echo "  self-signed address or a plain HTTP one. It skips the check for this" >&2
	echo "  download and for the agent's connection, and is remembered across upgrades" >&2
	exit 2
fi
# Names the node a registration creates. A token belongs to a node that already
# has a name, which the panel changes; silently dropping the flag there would
# read as a rename that never happened.
[ -z "$NAME" ] || [ -z "$TOKEN" ] ||
	{ echo "--name applies only with --register; rename an existing node in the panel" >&2; exit 2; }
# A setting of this machine, kept by a rerun without the flag for the reason
# given for --iface below: the batch command carries none at the default. It is
# read back from the service definition the last install wrote; a first install
# takes 1.
if [ -z "$INTERVAL" ]; then
	INTERVAL=$(cat "$UNIT_FILE" "$RC_FILE" 2>/dev/null | sed -n \
		-e 's/^ExecStart=.* --interval \([0-9][0-9]*\).*/\1/p' \
		-e 's/^command_args="--interval \([0-9][0-9]*\).*/\1/p' | tail -n 1)
	if [ -n "$INTERVAL" ]; then echo "keeping --interval $INTERVAL from the previous install"; else INTERVAL=1; fi
fi
case "$INTERVAL" in "" | *[!0-9]*) echo "interval must be an integer from 1 to 3600" >&2; exit 2 ;; esac
[ "$INTERVAL" -ge 1 ] && [ "$INTERVAL" -le 3600 ] || { echo "interval must be from 1 to 3600" >&2; exit 2; }
# Which interfaces carry this machine's traffic is known only on the machine,
# and the batch command a fleet shares cannot carry one value per machine. A
# rerun without --iface, the documented upgrade, therefore keeps the value in
# the env file; --iface '' clears it.
#
# A kept value is written back as found, the last assignment being the one
# systemd and OpenRC apply: root wrote it, both already read it, and a hand edit
# with quotes must not block every later upgrade. A value given here is held to
# what the agent accepts -- full names separated by commas, each optionally led
# by one `-` -- since the agent refuses anything else at startup and would
# restart forever while this script reported success. The character set also
# keeps it inert where OpenRC sources the file as shell.
if [ -z "$IFACE_SET" ]; then
	IFACE=$(sed -n 's/^MONITOR_IFACE=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	[ -z "$IFACE" ] || echo "keeping --iface $IFACE from the previous install"
else
	case ",$IFACE," in
	*[!A-Za-z0-9._,-]* | *,-,* | *,--*)
		echo "--iface takes full interface names separated by commas, each optionally led by -, not: $IFACE" >&2
		exit 2
		;;
	esac
fi
# A bare host implies TLS, matching the upgrade the agent's ws_url() performs,
# and the same reversal under --insecure where the hub has no TLS to upgrade to.
# Without this the two diverge: the agent would dial wss:// while curl below
# defaults a scheme-less URL to http://, fetching over plaintext the binary about
# to run as root.
#
# Read back from the env file first, like --iface: an upgrade re-runs this script
# without the flags the first install used, and a node that suddenly refuses its
# hub's certificate is one that stops reporting -- which is the failure this
# whole flag exists to avoid.
if [ -z "$INSECURE_SET" ]; then
	INSECURE=$(sed -n 's/^MONITOR_INSECURE=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	case "$INSECURE" in 1 | true | yes) INSECURE=1 ;; *) INSECURE="" ;; esac
	[ -z "$INSECURE" ] || echo "keeping --insecure from the previous install"
fi
if [ -n "$INSECURE" ]; then SCHEME=http; else SCHEME=https; fi
# `--insecure` reaches the agent, as MONITOR_INSECURE below. It used to stop at
# this script, back when the flag only meant "the hub has no TLS, so download
# over plain HTTP" and the agent had nothing to verify either way.
#
# A hub with no domain now serves its panel under a certificate it signed
# itself, which is an encrypted channel the agent still refuses: it trusts
# public roots unless told otherwise. So the flag has to travel -- the fetch
# below skips the check with -k, and the unit gets MONITOR_INSECURE=1.
#
# Not passed as a command-line flag to the agent: it would land in `systemctl
# cat`, and the env file is 0600 for a reason.
CURL_INSECURE=""
[ -z "$INSECURE" ] || CURL_INSECURE="-k"
case "$SERVER" in *://*) ;; *) SERVER="$SCHEME://$SERVER" ;; esac
# The agent already refuses plaintext ws:// to a remote hub, since the token
# would travel in the clear. The same address fetches the binary about to run as
# root here, so the same rule applies: over plain HTTP anyone on the path can
# substitute a binary of their own.
#
# --insecure overrides both halves for a hub reached at ip:port with no TLS in
# front, and says so explicitly: this is the one step of the install that cannot
# be corrected afterwards, because a substituted binary is already running as
# root by then.
#
# The test applies to the host alone, with scheme, port and path removed, and
# matches an address rather than a prefix: `127.evil.com` is a registered name
# resolving wherever its owner points it, and reading it as loopback would hand
# this plaintext channel to that owner.
HOST="${SERVER#*://}"
HOST="${HOST%%/*}"
# RFC 3986 places userinfo before the host, so `127.0.0.1:28080@evil.example.com`
# leaves a loopback address where the test below looks while curl, which parses
# the URL correctly, fetches from the owner of that name -- over plain HTTP, with
# the bytes installed 0755 and started as root a few lines below. A hub address
# never requires userinfo; the agent's own ws_url rejects it as well.
case "$HOST" in
*@*) echo "server URL must not contain '@': the host is whatever follows it" >&2; exit 2 ;;
esac
case "$HOST" in
"["*) HOST="${HOST#\[}"; HOST="${HOST%%]*}" ;;
*) HOST="${HOST%%:*}" ;;
esac
# A full dotted quad in 127/8 and nothing shorter, matching what the agent's
# is_loopback() accepts, since Rust's IpAddr parser accepts nothing shorter
# either -- `127.1` is a name to it, not an address. The two must agree, or this
# installs over plaintext against a hub the agent then refuses to dial: the unit
# is written, the service started, and it crash-loops on RestartSec while this
# script has reported success.
#
# The first arm excludes anything containing a letter, which is a registered name
# however it begins, and anything with more than four components, which is not an
# address.
case "$HOST" in
localhost | ::1) LOCAL=1 ;;
*[!0-9.]* | *.*.*.*.*) LOCAL="" ;;
127.[0-9]*.[0-9]*.[0-9]*) LOCAL=1 ;;
*) LOCAL="" ;;
esac
case "$SERVER" in
http://*)
	if [ -z "$LOCAL" ]; then
		[ -n "$INSECURE" ] || {
			echo "refusing plaintext http:// to a remote hub; use https://, or --insecure if it has no TLS" >&2
			exit 2
		}
		echo "warning: --insecure over plain HTTP to $SERVER" >&2
		echo "         the token and every report travel in the clear, and the binary" >&2
		echo "         installed below is fetched over the same unverified channel" >&2
	fi
	;;
https://*)
	# A name can hold a certificate a public CA vouches for; an address cannot,
	# which is why a hub with no domain is reached at one. Both halves of the
	# flag are in play here, so both are said: this fetch, and the agent's own
	# connection -- an agent that refuses the hub's certificate is a node that
	# silently stops reporting.
	if [ -n "$INSECURE" ] && [ -z "$LOCAL" ]; then
		echo "warning: --insecure over $SERVER" >&2
		echo "         the certificate is not verified, here or by the agent. Traffic is" >&2
		echo "         still encrypted; what is given up is who vouches for the far end" >&2
	fi
	;;
esac
if command -v systemctl >/dev/null; then
	INIT=systemd
elif command -v rc-update >/dev/null; then
	INIT=openrc
else
	echo "this installer needs systemd or OpenRC" >&2
	exit 1
fi

# Alpine ships BusyBox adduser rather than useradd: -S system, -D no password,
# -H no home.
add_user() {
	if command -v useradd >/dev/null; then
		useradd --system --no-create-home --shell /usr/sbin/nologin monitor-agent
	else
		adduser -S -D -H -s /sbin/nologin monitor-agent
	fi
}

# The service user the agent runs as under either init system, created before
# the download and the registration, so a host where this fails keeps the agent
# it already runs and spends no registration key. One case passes this check
# without a user and is settled after the old agent stops; see there.
id -u monitor-agent >/dev/null 2>&1 || add_user ||
	{ echo "cannot create the system user monitor-agent" >&2; exit 1; }

case "$(uname -m)" in
x86_64 | amd64) ARCH=x86_64 ;;
aarch64 | arm64) ARCH=aarch64 ;;
*) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# The hub relays the binary, so a node need only reach the hub it already talks
# to: an IPv6-only or blocked machine cannot resolve github.com. A hub unable to
# fetch releases itself is configured with a GitHub proxy in its own settings,
# which is why none is requested here.
URL="${SERVER%/}/agent/$ARCH"
TMP="$(mktemp)"
trap cleanup_install EXIT

echo "downloading monitor-agent ($ARCH)"
# The hub relays four downloads at once and queues the rest for 30 seconds. A
# batch run on more machines than drain in that time is turned away with 503,
# which is retried here rather than failing the machine. Any other refusal is
# final and shown with the hub's own reason, which --fail would discard.
TRIES=0
while :; do
	CODE=$(curl -sSL $CURL_INSECURE --max-time 300 -w '%{http_code}' "$URL" -o "$TMP") || exit 1
	[ "$CODE" = 503 ] && [ "$TRIES" -lt 5 ] || break
	TRIES=$((TRIES + 1))
	echo "the hub is busy relaying to other machines; retrying in 5 seconds"
	sleep 5
done
[ "$CODE" = 200 ] ||
	{ printf 'download failed (HTTP %s): %s\n' "$CODE" "$(head -n 1 "$TMP" | cut -c1-500)" >&2; exit 1; }
# A relay can answer 200 with something other than the program, such as a
# mirror's error page. Checked before the running agent is stopped, so a batch
# run through such a relay leaves each machine on the agent it had, rather than
# on bytes that cannot start while this script reports success.
[ "$(head -c 4 "$TMP")" = "$(printf '\177ELF')" ] ||
	{ echo "the download is not a Linux executable: $(head -n 1 "$TMP" | tr -cd '[:print:]' | cut -c1-200)" >&2; exit 1; }

# Downloaded before the registration below, because that step spends a node: the
# key returns a token and the panel gains a row, while the env file recording it
# is only written once the binary is in place. A download that fails after
# registering therefore leaves an unusable node behind, and the rerun -- the
# documented way to recover -- registers a second one.
#
# --register exchanges a key for this node's own token, which is what allows one
# command to provision a batch of machines. The key is valid only within the
# window the panel opened and never becomes the credential the agent runs with.
if [ -z "$TOKEN" ]; then
	# Re-running the same command must not add a second node, so the token this
	# machine already holds travels with the key. The hub returns it unchanged
	# while it still opens a node, also after the window has closed; otherwise
	# the request is a new registration, which needs an open window. The env file
	# alone cannot tell a node deleted from the panel, and trusting it would keep
	# a revoked token while this installer reported success.
	#
	# Only for the same hub: a token issued by hub A means nothing to hub B.
	HELD=""
	CACHED=$(sed -n 's/^MONITOR_SERVER=//p' "$ENV_FILE" 2>/dev/null || true)
	if [ "${CACHED%/}" = "${SERVER%/}" ]; then
		HELD=$(sed -n 's/^MONITOR_TOKEN=//p' "$ENV_FILE" 2>/dev/null || true)
	fi
	# --name as given on this machine, or else the hostname, restricted to
	# characters a hostname may contain. The hub trims and bounds either.
	[ -n "$NAME" ] || NAME=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
	echo "registering $NAME with the hub"
	# curl sends no header at all for an empty $HELD. The status follows the body
	# on a line of its own, so a refusal shows the hub's own reason: a closed
	# window, a lockout, an entry that is not an https domain and a database
	# error share one exit status under --fail. A request that got no response
	# stops here, with curl's own message. The name travels on stdin: as an
	# argument, one beginning with @ would be read as a file to send.
	REPLY=$(printf '%s' "$NAME" | curl -sS $CURL_INSECURE --max-time 30 -w '\n%{http_code}' -H "Authorization: Bearer $REGISTER" \
		-H "X-Node-Token: $HELD" --data-binary @- "${SERVER%/}/api/agent/register") || exit 1
	CODE=$(printf '%s\n' "$REPLY" | tail -n 1)
	TOKEN=$(printf '%s\n' "$REPLY" | sed '$d')
	if [ "$CODE" != 200 ]; then
		# The hub answers in one line of text. A proxy or CDN in front may answer
		# with a page of HTML instead, of which the first line is enough.
		printf 'registration failed (HTTP %s): %s\n' "$CODE" "$(printf '%s\n' "$TOKEN" | head -n 1 | cut -c1-500)" >&2
		[ -z "$HELD" ] || echo "if this machine's node was deleted or its token reissued, the token it holds no longer counts." >&2
		exit 1
	fi
	[ -n "$TOKEN" ] || { echo "the hub answered without a token" >&2; exit 1; }
	if [ "$TOKEN" = "$HELD" ]; then
		echo "this machine is already registered; keeping its token and the name the panel shows"
	elif [ -n "$HELD" ]; then
		echo "the token this machine held no longer opens a node; registered as a new node."
		echo "if that token was reissued rather than its node deleted, delete the old node in the panel."
	fi
fi

# Stop an agent already running here before replacing its binary. The service
# name is fixed, so a reinstall could never start a second copy, but without this
# the new binary lands beneath a live process and only the restart at the end
# picks it up. Stopping first also means the copy does not depend on `install`
# unlinking rather than failing with ETXTBSY. Placed after the download, so a
# node that cannot fetch the binary keeps running.
if [ "$INIT" = openrc ]; then
	rc-service monitor-agent stop 2>/dev/null || true
else
	systemctl stop monitor-agent 2>/dev/null || true
	# An agent installed before the fixed user ran under DynamicUser=, and while
	# it runs nss-systemd resolves its transient user of the same name: the check
	# above passes, and useradd refuses the name as taken. Stopping the unit
	# releases that user, so the fixed one is created here. Should that fail, the
	# old binary and unit are still in place and are started again.
	id -u monitor-agent >/dev/null 2>&1 || add_user || {
		systemctl start monitor-agent 2>/dev/null || true
		echo "cannot create the system user monitor-agent" >&2
		exit 1
	}
fi
install -d -m 0755 "$ROOT"
SUB_BACKUP_DIR=$(mktemp -d "$ROOT/.subscription-backup.XXXXXX")
save_sub_file "$ENV_FILE" env
save_sub_file "$ROOT/subscription.json" agent-state
save_sub_file "$UNIT_FILE" unit
save_sub_file "$RC_FILE" rc
save_sub_file "$SUB_NGINX_CONF" nginx
save_sub_file "$SUB_UNIT" legacy-unit
save_sub_file "$SUB_RC" legacy-rc
if [ -f "$SUB_HOME/env" ]; then
    if [ "$INIT" = openrc ]; then
        rc-service sub-dynamic status >/dev/null 2>&1 && SUB_LEGACY_RUNNING=1 || true
    else
        systemctl is-active --quiet sub-dynamic 2>/dev/null && SUB_LEGACY_RUNNING=1 || true
    fi
fi
# Kept until the new binary has proved it starts; see not_started. Never over
# an existing copy: a run that died before that check left an unproven binary
# in $BIN, and the copy is the one that ran before it.
[ ! -f "$BIN" ] || [ -f "$BIN.old" ] || cp "$BIN" "$BIN.old"
install -m 0755 "$TMP" "$BIN"

# The token lives in a root-only environment file rather than the unit, keeping
# it out of `systemctl cat` and the world-readable journal. 0600 root is what
# keeps it private, since $ROOT itself is readable and holds the binaries. Set in
# a subshell, because the unit file written below is read by anyone debugging
# with `systemctl cat` and need not be 0600.
(
	umask 077
	cat >"$ENV_FILE" <<ENV
MONITOR_SERVER=$SERVER
MONITOR_TOKEN=$TOKEN
ENV
	[ -z "$IFACE" ] || printf 'MONITOR_IFACE=%s\n' "$IFACE" >>"$ENV_FILE"
	# Read by the agent at startup; see CURL_INSECURE above for why the flag has
	# to reach it at all. Written here rather than in the unit so it stays out of
	# `systemctl cat`.
	[ -z "$INSECURE" ] || printf 'MONITOR_INSECURE=1\n' >>"$ENV_FILE"
	# Keep the old listener until a new subscription plan has passed validation.
	[ -z "$SUB_PREV_BIND" ] || printf 'MONITOR_SUB_BIND=%s\n' "$SUB_PREV_BIND" >>"$ENV_FILE"
	[ -z "$SUB_PREV_PORT" ] || printf 'MONITOR_SUB_PORT=%s\n' "$SUB_PREV_PORT" >>"$ENV_FILE"
	[ -z "$SUB_PREV_PUBLIC" ] || printf 'MONITOR_SUB_PUBLIC_PORT=%s\n' "$SUB_PREV_PUBLIC" >>"$ENV_FILE"
	[ -z "$SUB_PREV_STATE" ] || printf 'MONITOR_SUB_STATE=%s\n' "$SUB_PREV_STATE" >>"$ENV_FILE"
)

# The new agent is not running. The binary it replaced is put back and started
# again, so a failed upgrade leaves the machine reporting as before; the unit
# and env file just written suit that binary as well, since an upgrade keeps the
# token and the settings. A first install has nothing to put back.
not_started() {
	echo "monitor-agent did not start; see: $1" >&2
	[ -f "$BIN.old" ] || exit 1
	mv -f "$BIN.old" "$BIN"
	restore_sub_file "$ENV_FILE" env
	restore_sub_file "$UNIT_FILE" unit
	restore_sub_file "$RC_FILE" rc
	if [ "$INIT" = openrc ]; then
		rc-service monitor-agent restart >/dev/null 2>&1 || true
	else
		systemctl daemon-reload
		systemctl restart monitor-agent || true
	fi
	echo "the previous monitor-agent binary is back in place and was restarted" >&2
	exit 1
}

# sing-box and the subscription are written here, once, as root. Nothing the hub
# sends can do this afterwards: the service runs unprivileged and, since the
# `vpn.deploy` channel was removed, has no deploy path at all.
#
# Failure is not fatal. The machine is already reporting by this point, and
# `provision` is idempotent -- it reuses the credentials in an existing config --
# so a rerun is the fix rather than a reinstall.
VPN_JSON=""
provision_vpn() {
	[ -z "$NO_VPN" ] || { echo "skipping VPN setup (--no-vpn)"; return 0; }
	# 订阅 URL 要指向订阅伺服真正在听的那个端口，所以端口先定下来。
	pick_sub_port
	if [ -z "$VPN_IP" ]; then
		VPN_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || true)
	fi
	case "$VPN_IP" in
	"" | *[!0-9.]*)
		echo "warning: could not determine this machine's public address" >&2
		echo "         VPN setup skipped; re-run with --upgrade --vpn-ip ADDRESS" >&2
		return 1
		;;
	esac
	# The certificate's CN follows the name clients actually send, so a hub reached
	# by domain gives one. Reached by a bare address, provision's own default stands.
	VPN_SNI=""
	case "$HOST" in
	*[!0-9.]*) VPN_SNI="$HOST" ;;
	esac
	echo "setting up sing-box and the subscription for $VPN_IP"
	# Built with `set --` rather than `${VAR:+--sni "$VAR"}`: inside `:+` the quotes
	# are not quote removal, so the address would reach provision wrapped in them.
	set -- provision --server "$VPN_IP"
	[ -z "$VPN_SNI" ] || set -- "$@" --sni "$VPN_SNI"
	# 订阅地址要落在订阅伺服真正监听的那个端口上；80 不用写端口。
	if [ "$SUB_PORT" = 80 ]; then
		set -- "$@" --sub-base "http://$VPN_IP"
	else
		set -- "$@" --sub-base "http://$VPN_IP:$SUB_PORT"
	fi
	if ! VPN_JSON=$("$BIN" "$@"); then
		echo "warning: VPN setup failed; this machine still reports as a node" >&2
		echo "         re-run with: --upgrade --vpn-ip $VPN_IP" >&2
		return 1
	fi
    return 0
}

report_vpn() {
    [ -n "$VPN_JSON" ] || return 0
	# The links live in the panel, which is where they are shown and kept. A refusal
	# here would leave the node serving traffic it cannot display, so it is said out
	# loud rather than swallowed.
	CODE=$(printf '%s' "$VPN_JSON" | curl -sS $CURL_INSECURE --max-time 30 -w '%{http_code}' -o /dev/null \
		-X POST -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
		--data-binary @- "${SERVER%/}/api/agent/vpn" 2>/dev/null) || CODE=000
	[ "$CODE" = 200 ] ||
		echo "warning: the hub did not record the deployment (HTTP $CODE); the node is running" >&2
	return 0
}

# ---- 订阅伺服 ----
# 节点自己伺服订阅三件套，并带上 `subscription-userinfo` 头 —— 客户端读它显示
# 已用流量和到期日。**没有这个头，客户端那一行是直接不见的**：不报错，只是卡片上
# 少了它。所以这个头不是锦上添花，是订阅「显示得对」的全部。
#
# 数字从 hub 读，用的是**节点自己的 token**（`/api/agent/traffic`）。不把面板管理员
# 密码放到每台节点上 —— 那等于一台节点被攻破就是面板被攻破。
SUB_STATE="/var/lib/sing-box/subscription.json"

# 某个端口上有没有人在听。
listening() {
	ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

# 监听 $1 的是不是 nginx。
nginx_holds() {
	pid="$(ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
	[ -n "$pid" ] || return 1
	tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'nginx'
}

# 订阅服务在跑吗。重跑时要靠它认出「上一轮那个是我自己」。
#
# 只覆盖上一代那份独立服务。agent 自己伺服的那种机器没有这个服务名，它那侧的证据
# 是 $ENV_FILE 里我们写过的订阅配置 —— 那份文件在本脚本较早的地方就被读成了
# SUB_PREV_*（见 read_prev_sub），因为重写它的那次截断写晚于读取、又早于这里。
sub_service_running() {
	if [ "$INIT" = openrc ]; then
		rc-service sub-dynamic status >/dev/null 2>&1
	else
		systemctl is-active --quiet sub-dynamic 2>/dev/null
	fi
}

# nginx 装着、在跑 —— 才敢往里加一个 vhost。
nginx_usable() {
	command -v nginx >/dev/null 2>&1 || return 1
	if [ "$INIT" = openrc ]; then
		rc-service nginx status >/dev/null 2>&1
	else
		systemctl is-active --quiet nginx 2>/dev/null
	fi
}

# 这个端口上已经有人在伺服我们的订阅了，而且**不是我们自己** —— 比如手工装的那份。
# README 里那句「已有的独立订阅服务不由此模块自动接管」就是这条：接管它会连它的
# 绑定地址一起改掉，而它可能只绑回环。
#
# 认 env 而不是认服务名：手工那份也叫 sub-dynamic.service（从别处搬来时就是这个
# 名字），只看服务在不在跑会把它当成自己。
foreign_sub_server() {
	[ -f "$SUB_HOME/env" ] && return 1
	[ -f "$SUB_STATE" ] || return 1
	clash="$(sed -n 's/.*"clash"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SUB_STATE" | head -n 1)"
	[ -n "$clash" ] || return 1
	curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$SUB_PORT/$(basename "$clash")" 2>/dev/null
}

# OpenRC 没有 ambient capabilities，只能把能力打在二进制上。那意味着**任何本地用户**
# 跑这个二进制都能绑低端口，所以顺带把可执行权限收到 root 与 agent 所在的组 ——
# 这样那个能力就只有它们够得着。
grant_bind_capability() {
	if [ -z "$SUB_CAPS" ]; then
		command -v setcap >/dev/null 2>&1 && setcap -r "$BIN" 2>/dev/null || true
		chmod 0755 "$BIN"
		return 0
	fi
	command -v setcap >/dev/null 2>&1 || {
		echo "warning: no setcap, so a non-root agent cannot bind port $SUB_PORT" >&2
		echo "         install libcap (or re-run with --sub-port 8080) and try again" >&2
		return 0
	}
	group="$(id -gn monitor-agent 2>/dev/null || echo monitor-agent)"
	chown "root:$group" "$BIN" 2>/dev/null || true
	chmod 0750 "$BIN"
	if ! setcap cap_net_bind_service=+ep "$BIN" 2>/dev/null; then
		echo "warning: setcap failed; the agent may not be able to bind port $SUB_PORT" >&2
	fi
}

# 订阅的文件名每次 provision 都会换一个随机串，只有状态文件里记着 —— 所以要验订阅
# 得先问状态文件它叫什么。echo 出那三个名字，目录外的路径（状态文件被改过）一律忽略。
sub_file_names() {
	[ -f "$SUB_STATE" ] || return 0
	# 状态文件是一行 JSON，三个键并列在同一行上，所以一个个抓而不是一次替换：
	# 按行替换只会拿到每行的第一个匹配，另外两个会静默漏掉。
	# 按逗号拆行再一个个看：`grep -o` 在这类单行 JSON 上一次只给一个匹配
	# （GNU 与 BusyBox 都如此），三个键里会静默漏掉两个。
	tr ',' '
' <"$SUB_STATE" | while IFS= read -r pair; do
		kind=${pair%%:*}
		path=${pair#*:}
		kind=${kind#*\"}
		kind=${kind%%\"*}
		path=${path#*\"}
		path=${path%%\"*}
		case "$kind" in
		clash | v2ray_txt | v2ray_b64) ;;
		*) continue ;;
		esac
		# 认文件名，不认路径：agent 也只认状态文件里那个文件的名字，比它更宽的
		# 请求它自己就会拒掉。路径的目录部分（状态文件被改过时）直接忽略。
		name=${path##*/}
		[ -n "$name" ] && [ "$path" = "/var/lib/sing-box/$name" ] && echo "$name"
	done
}

# 订阅到底能不能取到。端口在听只说明进程起来了，不代表请求有回答：状态文件在不在、
# agent 找不找得到文件、nginx 有没有转对地方，任何一条断了都是 404 —— 而客户端把
# 404 显示成「卡片上少了那一行」，不报错。所以这里真的取一次。
#
# 判据是 HTTP 200 且正文非空。subscription-userinfo 头缺失不算失败：它的值要 agent
# 回头问 hub，hub 不可达时头就是空的，那不是订阅坏了（agent 自己就是这么设的）。
# $1 = 对外的 URL 前缀（http://IP 或 http://IP:PORT）
check_subscription() {
	base=$1
	names=$(sub_file_names)
	[ -n "$names" ] || {
		echo "warning: the subscription state file lists no routes: $SUB_STATE" >&2
		return 1
	}
	hdr="$TMP.hdr"
	failed=""
	while read -r name; do
		[ -n "$name" ] || continue
		# 一次请求拿齐三样：状态码、正文字节数、响应头。正文不落盘 —— 这里要
		# 知道的只是它有没有内容，不是内容本身。
		read -r code size <<EOF
		$(curl -sS -o /dev/null -D "$hdr" -w '%{http_code} %{size_download}' --max-time 10 \
			"$base/$name" 2>/dev/null)
EOF
		case "$code" in
		200) ;;
		*)
			echo "warning: $base/$name answered HTTP ${code:-nothing}" >&2
			failed=1
			continue
			;;
		esac
		case "$size" in
		"" | 0)
			echo "warning: $base/$name answered 200 with an empty body" >&2
			failed=1
			continue
			;;
		esac
	done <<NAMES
$names
NAMES
	# 流量头只提示、不判失败：它的值要 agent 回头问 hub，hub 不可达时头就是空的，
	# 那不是订阅坏了 —— agent 自己就是这么设的。最后一次请求的头留在 $hdr 里。
	if [ -z "$failed" ]; then
		grep -qi '^subscription-userinfo:' "$hdr" ||
			echo "note: no subscription-userinfo header came back; clients show no traffic row" >&2
	fi
	rm -f "$hdr"
	[ -z "$failed" ]
}

# 订阅伺服。**它现在就是 agent 自己** —— 不再有第二个进程、不再需要 python。
#
# 三条路，给客户端的 URL 都是 `http://IP/xxx.yaml`（不带端口）：
#   80 空着          → agent 自己绑 80
#   80 上是 nginx    → agent 绑回环 $SUB_BACKEND，nginx 转过来；agent 不开公网端口
#   80 被别人占着    → 退到 8080
setup_subscription() {
	[ -z "$NO_VPN" ] || return 0
	# --no-vpn 没有订阅可伺服；没写过订阅也一样。
	[ -f "$SUB_STATE" ] || return 0
	# 别人已经在这个端口上伺服同一批文件（手工装的那份）—— 不接管。
	# 判断在 pick_sub_port 里就做过了，那里才拿得到「改端口之前」的端口号。
	if [ -n "$SUB_FOREIGN" ]; then
		echo "note: the subscription on port $SUB_PORT is already served by something else" >&2
		echo "      leaving it alone; the agent will not serve it" >&2
		return 0
	fi
	# Keep sing-box's directory private. The agent reads its own route map.
	cp "$SUB_STATE" "$ROOT/subscription.json.new"
	chown root:monitor-agent "$ROOT/subscription.json.new"
	chmod 0640 "$ROOT/subscription.json.new"
	mv -f "$ROOT/subscription.json.new" "$ROOT/subscription.json"

	bind="0.0.0.0"
	served="$SUB_PORT"
	if [ -n "$SUB_VIA_NGINX" ]; then
		bind="127.0.0.1"
		served="$SUB_BACKEND"
	fi

	# 单元里的能力是按端口算的，而端口比写单元晚定 —— 所以按最终结论再写一次。
	write_sub_env "$bind" "$served"
	sub_caps
	if [ "$INIT" = openrc ]; then
		grant_bind_capability
	else
		write_agent_unit
		systemctl daemon-reload
	fi

	if [ -n "$SUB_LEGACY_RUNNING" ]; then
		if [ "$INIT" = openrc ]; then rc-service sub-dynamic stop >/dev/null 2>&1 || true;
		else systemctl stop sub-dynamic >/dev/null 2>&1 || true; fi
	fi
	restart_agent
	if [ -n "$SUB_VIA_NGINX" ]; then
		if [ "$INIT" = openrc ]; then
			rc-service nginx reload >/dev/null 2>&1 || true
		else
			systemctl reload nginx 2>/dev/null || true
		fi
	fi

	# 端口真的在听，才算过了第一关：服务 active 只说明进程起来了，agent 绑不上时
	# 会记一条警告继续跑监控，而面板和客户端上什么也看不出来。
	i=0
	while [ "$i" -lt 12 ] && ! listening "$served"; do
		i=$((i + 1))
		sleep 0.5
	done
	if ! listening "$served"; then
		echo "warning: nothing is listening on port $served, so the subscription is not being served" >&2
		echo "         see: journalctl -u monitor-agent -n 20" >&2
		VPN_JSON=""
		restore_prev_sub || true
		return 1
	fi

	# 第二关：真的取一次。上面两关都过了、订阅仍然是 404 是可以发生的 —— 状态文件
	# 被删、agent 找不到文件、nginx 转错了地方，都是这个结果，而客户端把它显示成
	# 「卡片上少了那一行」，不报错。这里验不过就回到上一轮那份配置，别把一个取不到
	# 的订阅留在原地址后面 —— 那比安装失败更难发现。
	#
	# 验的是**对外**那个地址，不是 agent 绑的那个：走 nginx 时后者只覆盖一半链路。
	if check_subscription "http://127.0.0.1:$SUB_PORT"; then
		retire_legacy_sub_service
		if [ -n "$SUB_VIA_NGINX" ]; then
			echo "subscription served by monitor-agent on port $SUB_PORT through nginx"
		else
			echo "subscription served by monitor-agent on port $SUB_PORT"
		fi
		return 0
	fi

	echo "warning: the subscription could not be fetched on port $SUB_PORT" >&2
	VPN_JSON=""
	restore_prev_sub || {
		echo "         there is no previous configuration to go back to" >&2
		echo "         see: journalctl -u monitor-agent -n 20" >&2
		return 1
	}
	echo "         the subscription this node served before has been put back" >&2
	return 0
}

# 把上一轮的订阅落位放回去。装完验不过时才走这里：新配置取不到订阅，而旧的那份
# 曾经能取到，留旧的比留新的强 —— 地址没变，客户端那边不会察觉。
#
# 没有上一轮（首次安装）就什么都不做并报失败，让调用方把话说清楚。
restore_prev_sub() {
    [ -n "$SUB_BACKUP_DIR" ] && [ -f "$SUB_BACKUP_DIR/env" ] || return 1
    restore_sub_file "$ENV_FILE" env
    restore_sub_file "$ROOT/subscription.json" agent-state
    restore_sub_file "$UNIT_FILE" unit
    restore_sub_file "$RC_FILE" rc
    restore_sub_file "$SUB_NGINX_CONF" nginx
    restore_sub_file "$SUB_UNIT" legacy-unit
    restore_sub_file "$SUB_RC" legacy-rc
    SUB_PORT="${SUB_PREV_PUBLIC:-$SUB_PREV_PORT}"
    sub_caps
    if [ "$INIT" = openrc ]; then
        grant_bind_capability
        rc-service nginx reload >/dev/null 2>&1 || true
        [ -z "$SUB_LEGACY_RUNNING" ] || rc-service sub-dynamic start >/dev/null 2>&1 || return 1
    else
        systemctl daemon-reload
        systemctl reload nginx 2>/dev/null || true
        [ -z "$SUB_LEGACY_RUNNING" ] || systemctl start sub-dynamic >/dev/null 2>&1 || return 1
    fi
    restart_agent
    case "$SUB_PORT" in "" | *[!0-9]*) return 1 ;; esac
    check_subscription "http://127.0.0.1:$SUB_PORT"
}

# 让 nginx 把订阅路径转到我们的回环端口。写成一个独立文件，不动别人的站点。
#
# 必须是 default_server：同端口上已经有别的 server 时，`server_name _` 那份会被
# 盖住 —— 请求落到别人的 default 上，订阅就 404，而配置文件本身看着没问题。
#
# 返回 0 = 新配置已生效；2 = 新配置不行、但上一轮那份还原回来仍可用（继续走
# nginx）；1 = 两边都不行，调用方退到自己绑端口。绝不把一份 nginx 起不来的配置
# 留在 conf.d 里。
write_sub_nginx() {
	# 写之前先把上一轮那份留下来。`cat >` 是截断写，而 nginx -t 失败可能不是
	# 因为这份新配置 —— 比如别人同时改坏了别的站点。那种情况下若不还原，我们
	# 就把这台机器上唯一能用的那份订阅 vhost 删掉了。
	backup=""
	if [ -f "$SUB_NGINX_CONF" ]; then
		backup="$SUB_NGINX_CONF.monitor-prev"
		cp "$SUB_NGINX_CONF" "$backup" 2>/dev/null || backup=""
	fi
	cat >"$SUB_NGINX_CONF" <<CONF
# Written by monitor's install.sh; removed by install.sh --uninstall.
server {
    listen $SUB_PORT default_server;
    listen [::]:$SUB_PORT default_server;
    server_name _;

    # 订阅三件套交给订阅服务：它按当前状态文件找文件，并带上
    # subscription-userinfo 头 —— 客户端靠它显示已用流量与到期日。
    location ~ ^/(sub-[0-9a-f]+\.yaml|v2-[0-9a-f]+\.(txt|b64))\$ {
        proxy_pass http://127.0.0.1:$SUB_BACKEND;
        proxy_set_header Host \$host;
    }

    location / {
        return 404;
    }
}
CONF
	if nginx -t >/dev/null 2>&1; then
		[ -z "$backup" ] || rm -f "$backup"
		return 0
	fi
	# 这份配置 nginx 不收。把上一轮那份放回去，别让这次失败连带删掉它 ——
	# 放回去之后再验一次，通得过说明是这次的新配置有问题，而旧的那份照旧能用，
	# 那就让它继续用（返回 2：仍然走 nginx，只是没用上新配置）。
	if [ -n "$backup" ] && cp "$backup" "$SUB_NGINX_CONF" 2>/dev/null; then
		rm -f "$backup"
		if nginx -t >/dev/null 2>&1; then
			return 2
		fi
		# 连旧的那份都不通，说明问题不在我们这儿；撤掉，避免把一份 nginx
		# 起不来的配置留在 conf.d 里 —— 那会让 reload 把整个 nginx 打死。
		rm -f "$SUB_NGINX_CONF"
		return 1
	fi
	rm -f "$SUB_NGINX_CONF"
	return 1
}

# 订阅的几条配置写进 agent 自己的环境文件 —— 它自己就是订阅服务，不再有第二个进程。
# $1 = 绑的地址，$2 = 绑的端口（走 nginx 时是回环那个）。
#
# PUBLIC_PORT 是**对外**那个（客户端 URL 上出现的），走 nginx 时与绑的端口不同：
# nginx 在对外端口上听、把请求转到回环。重跑要靠它把上一轮的对外端口认回来，否则
# 服务挪到别处、地址跟着变，客户端手里那个当场失效而没有任何地方会报错。
#
# 走 nginx 时 $2 是 $SUB_BACKEND，而写 nginx 配置的那段用的是同一个变量，所以
# 两边不会各记一个回环端口。
write_sub_env() {
	sed -i '/^MONITOR_SUB_/d' "$ENV_FILE"
	{
		printf 'MONITOR_SUB_BIND=%s
' "$1"
		printf 'MONITOR_SUB_PORT=%s
' "$2"
		printf 'MONITOR_SUB_PUBLIC_PORT=%s
' "$SUB_PORT"
		printf 'MONITOR_SUB_STATE=%s
' "$ROOT/subscription.json"
	} >>"$ENV_FILE"
}

# 旧的那份独立订阅服务（Python 那个 sub-dynamic）该退了：它和 agent 抢同一个端口，
# 而且现在 agent 自己就能伺服。文件留着，回退时还能用。
retire_legacy_sub_service() {
	if [ "$INIT" = openrc ]; then
		rc-service sub-dynamic stop >/dev/null 2>&1 || true
		rc-update del sub-dynamic default >/dev/null 2>&1 || true
	else
		systemctl disable --now sub-dynamic >/dev/null 2>&1 || true
	fi
	rm -f "$SUB_UNIT" "$SUB_RC"
	# 它自己那份 env 和脚本留着不动：里面有上一轮记的端口，回退时还要用。
}

restart_agent() {
	if [ "$INIT" = openrc ]; then
		rc-service monitor-agent restart >/dev/null 2>&1 || true
	else
		systemctl restart monitor-agent 2>/dev/null || true
	fi
}

# 订阅的对外端口：客户端 URL 里带的那个。确定的顺序是**先读上一轮记下的值**、
# 再考虑默认 80 —— 反过来就是这台机器上试出过的那个缺陷：nginx 的 vhost 还在 80
# 上，重跑先试 80、一试就成，于是换了个端口落下，客户端手里那个地址当场作废而
# 没有任何地方会报错。
#
# 三级读，全部先于重写 $ENV_FILE 的那次截断写（见顶部的 read_prev_sub）：
#   1. agent 自己记的 MONITOR_SUB_PUBLIC_PORT（v1.9.2 起）
#   2. 上一代 Python 服务记的 SUB_PUBLIC_PORT
#   3. v1.9.0/1.9.1 的 agent：没有 PUBLIC_PORT 这一条，但它自己绑着对外端口，
#      所以 MONITOR_SUB_PORT 就是对外那个 —— 判据是 BIND=0.0.0.0。绑在回环说明
#      nginx 在前面，那个端口是回环的，当对外端口用会把地址改错，所以只提示。
#
# 只有「上一轮确实是我们装的」才认这些值：机器上换手过（服务名/配置都不是我们的）
# 就退回默认，否则会把上一个装法的端口当成自己的。
pick_public_port() {
	[ -z "$SUB_PORT_SET" ] || return 0
	# 「上一轮是我们装的」= agent 的订阅配置还在，或旧的独立服务在跑。判据都在
	# 早读的那份快照里：$ENV_FILE 这时还没被重写。
	if [ -z "$SUB_PREV_PORT" ] && ! sub_service_running; then
		return 0
	fi
	prev="$SUB_PREV_PUBLIC"
	if [ -z "$prev" ]; then
		if [ "$SUB_PREV_BIND" = "0.0.0.0" ]; then
			prev="$SUB_PREV_PORT"
		elif [ -n "$SUB_PREV_PORT" ]; then
			# 只记着回环端口 —— 那是 nginx 后面的监听口，不是对外口。不拿它
			# 顶替，但要说出来：否则这个节点会静悄悄地换到 80。
			echo "note: this node records no public subscription port; the one it had" >&2
			echo "      cannot be told from the loopback port behind nginx, so it is" >&2
			echo "      being chosen again rather than reused" >&2
		fi
	fi
	if [ -z "$prev" ]; then
		prev="$(sed -n 's/^SUB_PUBLIC_PORT=//p' "$SUB_HOME/env" 2>/dev/null | tail -n 1)"
	fi
	case "$prev" in
	"" | *[!0-9]* | 0) return 0 ;;
	esac
	[ "$prev" -le 65535 ] 2>/dev/null || return 0
	SUB_PORT="$prev"
	echo "note: reusing port $SUB_PORT, where this node's subscription is already served" >&2
}

# 谁在前面。读的是**已经定下来的** $SUB_PORT，不是默认的 80：端口可能来自上面那
# 轮的复用，而那一轮之所以存在，正是因为上一回这里的结论是「nginx 在前面」。
#
# 在这里就把 nginx 配置写好并验证，而不是等 setup_subscription：对外端口要拿去
# 拼 `--sub-base`（写进面板里的订阅地址），而 nginx 有可能不收这份配置。
pick_sub_port() {
	# 先看端口上有没有**别人**在伺服同一批文件（手工装的那份）。这一步必须在
	# 改端口之前：一旦退到 8080，探的就成了 8080，而那个人在 80 上 —— 探不到，
	# 于是我们照样装一份，两份抢同一批文件。
	if foreign_sub_server; then
		SUB_FOREIGN=1
		return 0
	fi
	pick_public_port
	# nginx 占着这个端口 → 让它伺服，我们退到回环。重跑时也走这条：
	# 上一轮是我们写的 vhost，nginx 还在听，结论一样。
	if nginx_usable && nginx_holds "$SUB_PORT"; then
		# `set -e` 下不能裸调用再取 $? —— 非 0 会当场把脚本终止掉。
		rc=0
		write_sub_nginx || rc=$?
		case $rc in
		0)	SUB_VIA_NGINX=1
			return 0
			;;
		# 新配置不行，但上一轮那份还原回来了、nginx 收得下 —— 订阅照旧在
		# $SUB_PORT 上由 nginx 伺服，什么都不用变。退回 8080 反而会把一个
		# 本来好好的、不带端口的订阅地址弄失效。
		2)	SUB_VIA_NGINX=1
			echo "warning: nginx refused the new subscription config; the previous one is still in place" >&2
			return 0
			;;
		esac
		echo "warning: nginx refused the subscription config, so it was removed" >&2
		SUB_PORT="8080"
		echo "note: serving the subscription directly on 8080 instead" >&2
		return 0
	fi
	# 80 被别的东西占着才退。
	listening "$SUB_PORT" || return 0
	SUB_PORT="8080"
	echo "note: port 80 is taken, so the subscription will be served on 8080" >&2
}

# 订阅要绑 80（低端口）时给 agent 那**一个**能力，别的不给：`CapabilityBoundingSet`
# 把它限定成只有这一个，`AmbientCapabilities` 让它对非 root 的 agent 生效。
# 走 nginx 时不绑低端口，这里就是空的 —— 能力不白给。
sub_caps() {
	SUB_CAPS=""
	bound=$(sed -n 's/^MONITOR_SUB_PORT=//p' "$ENV_FILE" 2>/dev/null | tail -n 1)
	case "$bound" in
	"" | *[!0-9]*) return 0 ;;
	esac
	[ "$bound" -lt 1024 ] || return 0
	SUB_CAPS="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
}

configure_optional_vpn() {
    [ -z "$NO_VPN" ] || { echo "keeping existing subscription settings (--no-vpn)"; return 0; }
    if ! provision_vpn; then
        echo "warning: monitoring is installed; VPN setup did not complete" >&2
        return 0
    fi
    if setup_subscription; then report_vpn;
    else echo "warning: monitoring is installed; subscription setup failed" >&2; fi
}

# agent 的单元。抽成函数是因为订阅那边可能还要再写一次：绑 80 需要能力，而那是
# 等端口定下来才知道的，比这里晚。
write_agent_unit() {
	cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=monitor agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$BIN --interval $INTERVAL
Restart=always
RestartSec=5
# A fixed user rather than DynamicUser=: when the mount namespace cannot be
# created, as in an LXC container without nesting, systemd skips ProtectSystem=
# and the other mount sandboxing for a unit with a static User=, but refuses to
# start one with DynamicUser= and exits 226/NAMESPACE. DynamicUser= also implied
# RestrictSUIDSGID=, which is therefore stated below.
User=monitor-agent
NoNewPrivileges=yes
RestrictSUIDSGID=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
# AF_NETLINK is how getifaddrs(3) obtains this host's own addresses from the
# kernel; without it the agent reports none.
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
MemoryMax=64M
$SUB_CAPS

[Install]
WantedBy=multi-user.target
UNIT
}

if [ "$INIT" = openrc ]; then
	cat >"$RC_FILE" <<RC
#!/sbin/openrc-run
description="monitor agent"
command="$BIN"
command_args="--interval $INTERVAL"
supervisor="supervise-daemon"
command_user="monitor-agent"
respawn_delay=5
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
	need net
}

# The token stays in the root-only env file rather than the service script;
# this runs as root, and the agent inherits what it exports. supervise-daemon
# opens the log only after dropping to command_user, so the file must be the
# agent's, including one an earlier install left to root.
start_pre() {
	checkpath --file --owner monitor-agent --mode 0600 $LOG_FILE
	set -a
	. $ENV_FILE
	set +a
}
RC
	chmod 0755 "$RC_FILE"
	rc-update add monitor-agent default >/dev/null
	sub_caps
	grant_bind_capability
	rc-service monitor-agent restart
	# supervise-daemon reports the service started while it respawns an agent
	# that exits at once, so the process itself is what is looked for, inside
	# the respawn delay. pidof rather than pgrep -x, which BusyBox matches
	# against the full path.
	sleep 3
	pidof monitor-agent >/dev/null || not_started "$LOG_FILE"
	rm -f "$BIN.old"
	# 订阅装不上不算安装失败：agent 已经在报数了，而它自己会记一条警告继续跑。
	# `set -e` 下裸调用会把「已装好」变成一次失败退出，把真正的问题盖过去。
	configure_optional_vpn
	echo "monitor-agent installed; follow it with: tail -f $LOG_FILE"
	exit 0
fi


sub_caps
write_agent_unit

systemctl daemon-reload
systemctl enable monitor-agent >/dev/null
# restart rather than `enable --now`: --now leaves an already-running service
# untouched, so reinstalling over a live agent would keep the old binary
# running.
systemctl restart monitor-agent
# Type=simple counts the service started once it is forked, so `restart` above
# succeeds also for one that fails at once -- a user it cannot resolve
# (217/USER), a binary that exits -- and is then restarted every RestartSec.
# Checked inside that window, so a batch run shows the failure on the machine
# where it happened rather than a line reading "installed".
sleep 3
systemctl is-active --quiet monitor-agent || not_started "journalctl -u monitor-agent -n 20"
rm -f "$BIN.old"
configure_optional_vpn
echo "monitor-agent installed; follow it with: journalctl -u monitor-agent -f"
