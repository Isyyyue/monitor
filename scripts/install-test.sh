#!/bin/sh
# Checks the two installer scripts where reading them is not enough: the order
# their top-level code runs in, and what the subscription port ends up being.
#
# Both cover failures that stay silent on a machine that already works. An
# OpenRC install hit `sub_caps: not found` only after the agent had been
# installed, so it read as "installed" with a subscription that never came up;
# a rejected nginx config deleted the working one beside it, and the node moved
# to 8080 with the panel still showing the old address.
#   scripts/install-test.sh
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname -- "$HERE")
INSTALL=$ROOT/install.sh
HUB_INSTALL=$ROOT/install-hub.sh
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

fail() {
	echo "install-test: $*" >&2
	exit 1
}

# --- 1. 顶层执行顺序 ---------------------------------------------------------
#
# A shell reads a script top to bottom, so a function used by the top-level
# install code must be defined above the point where that code runs. Defining it
# later is invisible to `sh -n` and to shellcheck: only the run that reaches
# that branch fails, and it fails after the agent has already been installed.
#
# The line the OpenRC branch executes on is the one that writes its service
# script -- every call below it is on that path.
order=$(
	awk '
		/^if \[ "\$INIT" = openrc \]; then$/ { top = NR }
		/^sub_caps\(\) \{/        { def_sub = NR }
		/^write_agent_unit\(\) \{/ { def_unit = NR }
		END { printf "%s %s %s\n", top, def_sub, def_unit }
	' "$INSTALL"
)
set -- $order
branch=$1
def_sub=$2
def_unit=$3
[ -n "$branch" ] || fail "no top-level OpenRC branch in $INSTALL"
[ -n "$def_sub" ] || fail "sub_caps is not defined in $INSTALL"
[ -n "$def_unit" ] || fail "write_agent_unit is not defined in $INSTALL"
[ "$def_sub" -lt "$branch" ] ||
	fail "sub_caps is defined on line $def_sub but the OpenRC branch runs on line $branch"
[ "$def_unit" -lt "$branch" ] ||
	fail "write_agent_unit is defined on line $def_unit but the OpenRC branch runs on line $branch"

# --- 2. 订阅端口 -------------------------------------------------------------
#
# pick_sub_port decides the port the client's address is built from, so every
# branch here is a change to an address already in someone's client. The
# functions are exercised in a subshell with the commands it calls stubbed out,
# which is what lets each path be reached without a machine around it.

# Copies pick_sub_port and write_sub_nginx out of the installer, so this test
# cannot drift from the code it checks. Braces are counted rather than the
# closing one matched: both bodies hold a function-local block, whose `}` sits
# in column one exactly like the function's own.
extract() {
	start=$(grep -n "^$1() {" "$INSTALL" | cut -d: -f1)
	[ -n "$start" ] || fail "$1 is not defined in $INSTALL"
	awk -v s="$start" '
		NR >= s { d += gsub(/{/, "{"); d -= gsub(/}/, "}"); print }
		NR > s && d == 0 { exit }
	' "$INSTALL"
}

extract pick_sub_port >"$DIR/funcs.sh"
extract write_sub_nginx >>"$DIR/funcs.sh"
grep -q '^pick_sub_port() {' "$DIR/funcs.sh" || fail "pick_sub_port was not extracted"
grep -q '^write_sub_nginx() {' "$DIR/funcs.sh" || fail "write_sub_nginx was not extracted"

cat >"$DIR/harness.sh" <<HARNESS
set -u
SUB_HOME=$DIR/sub-home
ENV_FILE=$DIR/agent.env
SUB_NGINX_CONF=$DIR/conf.d/monitor-sub.conf
SUB_BACKEND=18081
SUB_VIA_NGINX=
SUB_FOREIGN=

# What the surrounding installer would answer. nginx is the only one whose
# answer varies within a scenario, so it reads a file the scenario writes.
nginx() { [ -f $DIR/nginx-ok ]; }
foreign_sub_server() { [ "\${FOREIGN:-0}" = 1 ]; }
nginx_usable() { [ "\${NGINX_USABLE:-1}" = 1 ]; }
nginx_holds() { [ "\${NGINX_HOLDS:-1}" = 1 ]; }
listening() { [ "\${LISTENING:-0}" = 1 ]; }
sub_service_running() { [ "\${SUBRUN:-0}" = 1 ]; }
sub_agent_serving() { grep -q '^MONITOR_SUB_PORT=' $DIR/agent.env 2>/dev/null; }

. $DIR/funcs.sh

# Prints "port via foreign conf" for the caller to assert against.
scenario() {
	SUB_PORT=\${START_PORT:-80}
	SUB_PORT_SET=\${PORT_SET:-}
	SUB_VIA_NGINX=
	SUB_FOREIGN=
	mkdir -p "\$(dirname "\$SUB_NGINX_CONF")"
	eval "\${PREP:-:}" >/dev/null 2>&1 || true
	pick_sub_port || true
	printf '%s %s %s %s\n' "\$SUB_PORT" "\${SUB_VIA_NGINX:-.}" "\${SUB_FOREIGN:-.}" \
		"\$([ -f "\$SUB_NGINX_CONF" ] && echo present || echo absent)"
	rm -f "\$SUB_NGINX_CONF" $DIR/nginx-ok
}
HARNESS

check() {
	desc=$1
	expect=$2
	got=$3
	[ "$got" = "$expect" ] || fail "$desc: expected '$expect', got '$got'"
	echo "  ok  $desc -> $got"
}

# Each scenario runs in its own shell so a stub set here cannot reach the next.
run() {
	( . "$DIR/harness.sh"; eval "$1"; scenario )
}

echo "subscription port:"

# nginx takes the new config: it serves the subscription, on the public port.
got=$(run 'touch '"$DIR"'/nginx-ok
	NGINX_USABLE=1 NGINX_HOLDS=1 LISTENING=0')
check "nginx accepts the new config" "80 1 . present" "$got"

# nginx rejects the new config but the one already there still loads. The node
# keeps the address it has; falling back to 8080 here would break it.
got=$(run 'printf "# previous\n" >'"$DIR"'/conf.d/monitor-sub.conf
	NGINX_OK_PREV=1
	nginx() { grep -q "# previous" '"$DIR"'/conf.d/monitor-sub.conf; }
	NGINX_USABLE=1 NGINX_HOLDS=1 LISTENING=0')
check "nginx rejects the new one, the previous one loads" "80 1 . present" "$got"

# Neither loads: drop ours rather than leave a config nginx cannot start with,
# and serve directly on the port that needs no nginx.
got=$(run 'NGINX_USABLE=1 NGINX_HOLDS=1 LISTENING=0')
check "nginx rejects everything" "8080 . . absent" "$got"

# No nginx at all and 80 is free: the agent binds it itself.
got=$(run 'NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "no nginx, port 80 free" "80 . . absent" "$got"

# 80 belongs to something that is not a usable nginx.
got=$(run 'NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=1')
check "no nginx, port 80 taken" "8080 . . absent" "$got"

# A re-run with a port chosen earlier. The agent does not listen on it when
# nginx fronts the subscription, so nothing can be asked on the port itself --
# the recorded value is what the address was built from and must be reused.
#
# Two places can hold it: the agent's own env (where v1.9.0 moved the
# subscription to) and the env the Python service left behind. A machine
# installed from the agent has no SUB_HOME at all, so reading only the old file
# loses the port and moves the node to 80 -- breaking an address the client
# already holds, with nothing reporting it.
mkdir -p "$DIR/sub-home"

# An install from before the subscription moved into the agent.
printf 'SUB_PUBLIC_PORT=18082\n' >"$DIR/sub-home/env"
rm -f "$DIR/agent.env"
got=$(run 'NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0 SUBRUN=1')
check "re-run keeps the port the old service recorded" "18082 . . absent" "$got"
rm -f "$DIR/sub-home/env"

# An install from v1.9.0/1.9.1: the agent binds the public port itself, and its
# env has no separate record of which port that is.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=0.0.0.0
MONITOR_SUB_PORT=18082
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "re-run keeps the port in the agent's env" "18082 . . absent" "$got"

# ...but only when it binds the public port. Behind nginx the bound port is the
# loopback one, and reusing it as the public port would move the address.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=127.0.0.1
MONITOR_SUB_PORT=18081
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "the loopback port is not mistaken for the public one" "80 . . absent" "$got"

# From v1.9.2 on, the public port is recorded outright, so it survives a re-run
# even behind nginx.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=127.0.0.1
MONITOR_SUB_PORT=18081
MONITOR_SUB_PUBLIC_PORT=18082
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "the recorded public port wins over the loopback one" "18082 . . absent" "$got"
rm -f "$DIR/agent.env"

# A port given on the command line is never overridden by a fallback.
got=$(run 'START_PORT=18090 PORT_SET=1 NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=1')
check "--sub-port is kept" "18090 . . absent" "$got"

# A fresh machine has nothing recorded, so the fallback applies.
got=$(run 'NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=1')
check "a fresh machine falls back when 80 is taken" "8080 . . absent" "$got"

# --- 3. 面板端口 -------------------------------------------------------------
#
# `--https` defaults to 8444, and `PANEL` must stay without a suffix for it:
# 443 is https's implicit port, so a panel URL built with it would be wrong.
grep -q '^HTTPS_PORT="8444"' "$HUB_INSTALL" ||
	fail "install-hub.sh --https no longer defaults to 8444"
grep -q '\[ "\$HTTPS_PORT" = 443 \] || PANEL="\$PANEL:\$HTTPS_PORT"' "$HUB_INSTALL" ||
	fail "the 443 comparison in install-hub.sh changed; 443 is https's implicit port"

# --- 4. 备份文件不会被 nginx 当成配置 ----------------------------------------
#
# write_sub_nginx saves the previous file next to its own, and nginx loads
# everything matching *.conf in that directory. A suffix ending in .conf would
# make nginx read the backup as a second vhost on the same port -- two servers
# claiming default_server, which nginx refuses to start with.
grep -q 'backup="\$SUB_NGINX_CONF\.monitor-prev"' "$INSTALL" ||
	fail "the nginx backup is no longer named alongside the vhost"
backupname=$(grep -o 'backup="\$SUB_NGINX_CONF[^"]*"' "$INSTALL" | head -1)
case $backupname in
*.conf\") fail "the nginx backup name ends in .conf, so nginx would load it" ;;
esac

# The uninstaller has to take the backup with it, or a removed install leaves a
# file behind in a directory nginx reads.
grep -q 'rm -f "\$SUB_NGINX_CONF" "\$SUB_NGINX_CONF.monitor-prev"' "$INSTALL" ||
	fail "uninstall does not remove the nginx backup"

echo "install-test: ok"
