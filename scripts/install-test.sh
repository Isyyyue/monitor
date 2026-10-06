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

# Copies the functions the port decision is made of out of the installer, so
# this test cannot drift from the code it checks. Braces are counted rather
# than the closing one matched: several of these bodies hold a function-local
# block, whose `}` sits in column one exactly like the function's own.
extract() {
	start=$(grep -n "^$1() {" "$INSTALL" | cut -d: -f1)
	[ -n "$start" ] || fail "$1 is not defined in $INSTALL"
	awk -v s="$start" '
		NR >= s { d += gsub(/{/, "{"); d -= gsub(/}/, "}"); print }
		NR > s && d == 0 { exit }
	' "$INSTALL"
}

FUNCS="pick_sub_port pick_public_port read_prev_sub write_sub_nginx sub_file_names check_subscription"
{
	for fn in $FUNCS; do extract "$fn"; done
} >"$DIR/funcs.sh"
for fn in $FUNCS; do
	grep -q "^$fn() {" "$DIR/funcs.sh" || fail "$fn was not extracted"
done

cat >"$DIR/harness.sh" <<HARNESS
set -u
SUB_HOME=$DIR/sub-home
ENV_FILE=$DIR/agent.env
SUB_NGINX_CONF=$DIR/conf.d/monitor-sub.conf
SUB_BACKEND=18081
SUB_STATE=$DIR/subscription.json
TMP=$DIR/tmp
SUB_VIA_NGINX=
SUB_FOREIGN=
SUB_PREV_PUBLIC=
SUB_PREV_PORT=
SUB_PREV_BIND=

# What the surrounding installer would answer. nginx is the only one whose
# answer varies within a scenario, so it reads a file the scenario writes.
nginx() { [ -f $DIR/nginx-ok ]; }
foreign_sub_server() { [ "\${FOREIGN:-0}" = 1 ]; }
nginx_usable() { [ "\${NGINX_USABLE:-1}" = 1 ]; }
nginx_holds() { [ "\${NGINX_HOLDS:-1}" = 1 ]; }
# Whether a port is taken. LISTENING is the answer for 80, which is what almost
# every scenario asks; TAKEN names another port to answer yes for, so a scenario
# can hold 80 free while something else is busy -- or the reverse.
listening() { [ "\${LISTENING:-0}" = 1 ] && [ "\$1" = 80 ] || [ "\$1" = "\${TAKEN:-}" ]; }
sub_service_running() { [ "\${SUBRUN:-0}" = 1 ]; }

. $DIR/funcs.sh

# Prints "port via foreign conf" for the caller to assert against.
#
# ORDER=read walks the rerun path as install.sh actually runs it: the previous
# values are read off the env file first, the file is then overwritten the way
# the install overwrites it -- truncating, keeping only the lines that install
# writes -- and only then is the port chosen. Calling pick_sub_port alone skips
# that overwrite, and would pass even while the real thing loses the port: it
# is the overwrite, not the port choice, that used to drop the record.
scenario() {
	SUB_PORT=\${START_PORT:-80}
	SUB_PORT_SET=\${PORT_SET:-}
	SUB_VIA_NGINX=
	SUB_FOREIGN=
	SUB_PREV_PUBLIC=
	SUB_PREV_PORT=
	SUB_PREV_BIND=
	mkdir -p "\$(dirname "\$SUB_NGINX_CONF")"
	eval "\${PREP:-:}" >/dev/null 2>&1 || true
	if [ "\${ORDER:-}" = read ]; then
		read_prev_sub
		# install.sh writes MONITOR_SERVER/MONITOR_TOKEN and nothing else.
		umask 077
		printf 'MONITOR_SERVER=https://hub.example\nMONITOR_TOKEN=t\n' >"\$ENV_FILE"
	fi
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
#
# The scenario text is one `eval`, so a variable assignment on the text's first
# line only prefixes the first command on it: `ORDER=read touch f` sets ORDER
# for `touch` and nothing else, and scenario() then reads it as unset. Keep the
# settings on lines of their own.
run() {
	( . "$DIR/harness.sh"; eval "$1"; scenario )
}

echo "subscription port:"

# --- A first install: nothing recorded, so each rule decides on its own ------

# nginx takes the new config: it serves the subscription, on the public port.
got=$(run 'touch '"$DIR"'/nginx-ok
	NGINX_USABLE=1 NGINX_HOLDS=1 LISTENING=0')
check "nginx accepts the new config" "80 1 . present" "$got"

# nginx rejects the new config but the one already there still loads. The node
# keeps the address it has; falling back to 8080 here would break it.
got=$(run 'printf "# previous\n" >'"$DIR"'/conf.d/monitor-sub.conf
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

# --- A re-run: the port recorded last time is what decides --------------------
#
# Every scenario below walks the rerun path in the order install.sh runs it
# (ORDER=read): read the previous values off the env file, overwrite that file
# the way the install does, then choose. The overwrite is the part that used to
# drop the record, so a scenario that only calls pick_sub_port proves nothing.

# An install from before the subscription moved into the agent: the Python
# service's env holds the port.
mkdir -p "$DIR/sub-home"
printf 'SUB_PUBLIC_PORT=18082\n' >"$DIR/sub-home/env"
rm -f "$DIR/agent.env"
got=$(run 'ORDER=read NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0 SUBRUN=1')
check "re-run keeps the port the old service recorded" "18082 . . absent" "$got"
rm -f "$DIR/sub-home/env"

# v1.9.0/1.9.1's agent binds the public port itself and records no separate
# public port. Its MONITOR_SUB_PORT is therefore the public one.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=0.0.0.0
MONITOR_SUB_PORT=18082
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'ORDER=read NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "the port survives the env being rewritten" "18082 . . absent" "$got"

# The same machine, with nginx holding 80 in front of the subscription. This is
# the case that shipped broken: nginx was tried on the default 80 first, that
# succeeded, and the port recorded above was never looked at -- so the node
# moved to 80 and every client's address went dead without a word.
rm -f "$DIR/agent.env"
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=0.0.0.0
MONITOR_SUB_PORT=18082
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'ORDER=read
	touch '"$DIR"'/nginx-ok
	NGINX_USABLE=1 NGINX_HOLDS=1 LISTENING=0')
check "nginx in front does not overrule the recorded port" "18082 1 . present" "$got"

# ...but only when it binds the public port. Behind nginx the bound port is the
# loopback one, and reusing it as the public port would move the address.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=127.0.0.1
MONITOR_SUB_PORT=18081
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'ORDER=read NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "the loopback port is not mistaken for the public one" "80 . . absent" "$got"

# From v1.9.2 on, the public port is recorded outright, so it survives a re-run
# even behind nginx -- the case the loopback reading above cannot settle.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=127.0.0.1
MONITOR_SUB_PORT=18081
MONITOR_SUB_PUBLIC_PORT=18082
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'ORDER=read NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "the recorded public port wins over the loopback one" "18082 . . absent" "$got"

# The same record with nginx in front: the public port is what nginx serves on,
# so the agent still goes to the loopback backend behind it.
#
# The env file is written again first: ORDER=read ends by overwriting it the way
# the install does, so the record above is gone by the time this scenario runs.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=127.0.0.1
MONITOR_SUB_PORT=18081
MONITOR_SUB_PUBLIC_PORT=18082
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'ORDER=read
	touch '"$DIR"'/nginx-ok
	NGINX_USABLE=1 NGINX_HOLDS=1 LISTENING=0')
check "the recorded public port survives nginx being in front" "18082 1 . present" "$got"
rm -f "$DIR/agent.env"

# A stopped service still has its configuration, and losing the port because
# the process is not up would move a node that is merely restarting.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=0.0.0.0
MONITOR_SUB_PORT=18082
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'ORDER=read NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "a stopped subscription keeps its port" "18082 . . absent" "$got"
rm -f "$DIR/agent.env"

# A port given on the command line is never overridden by a fallback, recorded
# value or not.
cat >"$DIR/agent.env" <<ENV
MONITOR_SUB_BIND=0.0.0.0
MONITOR_SUB_PORT=18082
MONITOR_SUB_STATE=/var/lib/sing-box/subscription.json
ENV
got=$(run 'ORDER=read START_PORT=18090 PORT_SET=1 NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=0')
check "--sub-port is kept" "18090 . . absent" "$got"
rm -f "$DIR/agent.env"

# A fresh machine has nothing recorded, so the fallback applies.
got=$(run 'ORDER=read NGINX_USABLE=0 NGINX_HOLDS=0 LISTENING=1')
check "a fresh machine falls back when 80 is taken" "8080 . . absent" "$got"

# --- 3. 订阅取到的是哪几个文件 ------------------------------------------------
#
# The installer now fetches the subscription to prove it works, which means it
# has to know the file names -- and those are random per provision, recorded
# only in the state file. Getting them wrong is a 404 that clients render as a
# missing row rather than an error, so the reading is checked here.

names() {
	SUB_STATE=$DIR/subscription.json
	export SUB_STATE
	( . "$DIR/funcs.sh"; sub_file_names )
}

# All three, from one line of JSON. A per-line substitution would return only
# the first of them: they share a line.
cat >"$DIR/subscription.json" <<JSON
{"clash":"/var/lib/sing-box/sub-abc123.yaml","v2ray_txt":"/var/lib/sing-box/v2-def456.txt","v2ray_b64":"/var/lib/sing-box/v2-def456.b64"}
JSON
check "every route in the state file is found" \
	"sub-abc123.yaml v2-def456.txt v2-def456.b64" "$(names | tr '\n' ' ' | sed 's/ $//')"

# A path outside the directory the agent serves from is not a name it would
# answer for, so it is dropped rather than fetched.
cat >"$DIR/subscription.json" <<JSON
{"clash":"/etc/passwd","v2ray_txt":"/var/lib/sing-box/v2-ok.txt"}
JSON
check "a path outside the subscription directory is ignored" "v2-ok.txt" "$(names)"

# An unknown key is not one of the three routes.
cat >"$DIR/subscription.json" <<JSON
{"token":"/var/lib/sing-box/secret.txt","clash":"/var/lib/sing-box/sub-f00d.yaml"}
JSON
check "only the three known routes are read" "sub-f00d.yaml" "$(names)"

# No state file at all: --no-vpn, or provision not yet run.
rm -f "$DIR/subscription.json"
check "no state file yields no names" "" "$(names)"

# --- 4. 订阅取不取得回来 ------------------------------------------------------
#
# The port being listened on says the process is up. It does not say the
# request is answered: a deleted state file, a file the agent cannot find and
# an nginx that forwards to the wrong place all produce a 404, and clients draw
# that as a missing row. check_subscription is what tells those apart, so each
# answer is exercised here. curl is stubbed: what is under test is how the
# answer is read, not whether curl can send one -- and the stub reaches the
# failures a live server cannot (a timeout, a refusal).

fetch() {
	# $1 = the response to emulate, $2 = the state file
	SUB_STATE=$DIR/subscription.json
	TMP=$DIR/tmp
	export SUB_STATE TMP
	mkdir -p "$DIR"
	printf '%s\n' "$2" >"$DIR/subscription.json"
	(
		. "$DIR/funcs.sh"
		eval "$1"
		check_subscription "http://127.0.0.1:80" && echo YES || echo NO
	)
}

# A 200 with a body and the traffic header: served.
got=$(fetch 'curl() {
		prev=
		for a in "$@"; do
			case "$a" in
			-D) prev=1 ;;
			*) [ -n "$prev" ] && { printf "subscription-userinfo: upload=1; download=2\n" >"$a"; prev=; } ;;
			esac
		done
		printf "200 512"
	}' '{"clash":"/var/lib/sing-box/sub-abc123.yaml"}')
check "a served subscription passes" "YES" "$got"

# 200 but nothing in it: the client gets an empty card.
got=$(fetch 'curl() { printf "200 0"; }' '{"clash":"/var/lib/sing-box/sub-abc123.yaml"}')
check "a 200 with an empty body fails" "NO" "$got"

# A 404, which is what all three silent failures look like.
got=$(fetch 'curl() { printf "404 0"; }' '{"clash":"/var/lib/sing-box/sub-abc123.yaml"}')
check "a 404 fails" "NO" "$got"

# No answer at all: curl exits nonzero and prints nothing.
got=$(fetch 'curl() { return 7; }' '{"clash":"/var/lib/sing-box/sub-abc123.yaml"}')
check "no answer at all fails" "NO" "$got"

# The state file names no route -- --no-vpn, or provision never ran.
got=$(fetch 'curl() { printf "200 512"; }' '{"total":123}')
check "a state file without routes fails" "NO" "$got"

# The traffic header missing is not a failure: its value comes from the hub,
# and an unreachable hub leaves it off rather than breaking the subscription.
got=$(fetch 'curl() { printf "200 512"; }' '{"clash":"/var/lib/sing-box/sub-abc123.yaml"}')
check "a missing traffic header still passes" "YES" "$got"

# --- 5. 面板端口 -------------------------------------------------------------
#
# `--https` defaults to 8444, and `PANEL` must stay without a suffix for it:
# 443 is https's implicit port, so a panel URL built with it would be wrong.
grep -q '^HTTPS_PORT="8444"' "$HUB_INSTALL" ||
	fail "install-hub.sh --https no longer defaults to 8444"
grep -q '\[ "\$HTTPS_PORT" = 443 \] || PANEL="\$PANEL:\$HTTPS_PORT"' "$HUB_INSTALL" ||
	fail "the 443 comparison in install-hub.sh changed; 443 is https's implicit port"

# --- 6. 备份文件不会被 nginx 当成配置 ----------------------------------------
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
