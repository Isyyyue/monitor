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
	from=${2:-$INSTALL}
	start=$(grep -n "^$1() {" "$from" | cut -d: -f1)
	[ -n "$start" ] || fail "$1 is not defined in $from"
	awk -v s="$start" '
		NR >= s { d += gsub(/{/, "{"); d -= gsub(/}/, "}"); print }
		NR > s && d == 0 { exit }
	' "$from"
}

# Source a function out of the installer instead of evaluating its text.
#
# `eval "$(extract fn)"` re-runs the shell over the function body, and that extra
# pass strips one level of backslashes: a `sed 's@...@\1...@'` inside the
# function arrives as `1`, so the test exercises something the installer never
# runs -- and passes. Writing the body to a file and sourcing it keeps the text
# exactly as it was read.
#
# $1 = function name, $2 = file to read (default $INSTALL). When a caller needs
# to rewrite paths in the body first, it should extract into its own file with
# `extract ... > f` && sed that file, then call `load_file f`.
load() {
	body="$DIR/fn-$1.sh"
	extract "$1" "${2:-$INSTALL}" >"$body"
	load_file "$body"
}

load_file() {
	# shellcheck disable=SC1090  # the path is this test's own temporary file
	. "$1"
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
# write_sub_nginx calls this before writing its config. Its own behaviour is
# covered in section 9; here it only has to exist, or the port scenarios die on
# "command not found" instead of reaching their assertion.
sub_default_server_patch() { return 0; }

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

# `old_https_port` answers "dir: port" because the caller needs the directory to
# write into; these cases only care about the port, and the directory is a
# temporary one whose name would otherwise have to be predicted.
norm() {
	[ -n "$1" ] || {
		printf 'NONE'
		return 0
	}
	[ "$1" = "${1%%: *}" ] && printf 'FOUND' || printf 'found:%s' "${1##*: }"
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

# --- 7. 重跑不会把已配好的 HTTPS 丢掉 ----------------------------------------
#
# Two separate failures, both found only on a real machine and both invisible to
# a single run:
#
#   a) The map block was written only when `nginx -T` did not already define it.
#      `-T` reads the config on disk, which on a second run includes the map the
#      first run wrote -- so the check passed, the new vhost went out without a
#      map, and nginx refused to reload: `unknown "connection_upgrade" variable`.
#      Whether `-T` answered at all was a race, which is why it failed about one
#      run in three rather than every time.
#
#   b) `HTTPS` came from the command line only, so a bare re-run reported the
#      panel as loopback-only and told the operator to go configure a reverse
#      proxy over a deployment that was already reachable over TLS.
#
# (a) is a property of the text: the map must not be sourced from a listing that
# includes our own file. (b) is a property of the run: the port has to be read
# back from what is on disk.

# (a) The listing is cut at our own file before the question is asked. Matched
# as a fixed string: the sed expression is mostly punctuation, and a pattern for
# it would have to escape every one of them twice over.
grep -qF 'configuration file $site:#' "$HUB_INSTALL" ||
	fail "setup_https asks nginx -T for the map without excluding its own vhost"

# The same defect in an earlier shape: a plain whole-output grep for the map.
if grep -q '"$NGINX_BIN" -T 2>/dev/null | grep -q' "$HUB_INSTALL"; then
	fail "setup_https greps nginx -T whole, so its own map counts as already defined"
fi

# (b) The carry-over exists, reads the vhost, and feeds HTTPS.
grep -q '^old_https_port() {' "$HUB_INSTALL" ||
	fail "install-hub.sh has no old_https_port"
grep -q 'left="$(old_https_port)"' "$HUB_INSTALL" ||
	fail "old_https_port is never called, so a re-run still drops the HTTPS setup"

# Exercised for real against a directory tree, because the whole bug was that
# the answer depends on what is on disk rather than on the arguments. `where` is
# the directory the vhost is planted in, which is also what old_https_port
# reports back -- Debian uses sites-enabled, RHEL and Alpine use conf.d, and the
# function has to find the file in either.
probe() {
	where=$1
	body=$2
	root="$DIR/nginx"
	rm -rf "$root"
	mkdir -p "$root/sites-enabled" "$root/conf.d"
	[ -z "$body" ] || printf '%s\n' "$body" >"$root/$where/monitor-hub-https.conf"
	# shellcheck disable=SC2016  # the body is the installer's own sed, run as written
	( cd "$root" && eval "$(sed -n '/^old_https_port() {/,/^}/p' "$HUB_INSTALL" |
		sed 's#/etc/nginx#'"$root"'#g')" && old_https_port )
}

got=$(probe sites-enabled 'listen 8444 ssl default_server;')
check "old_https_port finds a vhost on 8444" "found:8444" "$(norm "$got")"

got=$(probe sites-enabled 'listen 9443 ssl default_server;')
check "old_https_port reads the port it found" "found:9443" "$(norm "$got")"

# The other layout: no sites-enabled on the machine, the file under conf.d.
got=$(probe conf.d 'listen 9443 ssl default_server;')
check "old_https_port finds a vhost under conf.d too" "found:9443" "$(norm "$got")"

got=$(probe sites-enabled '')
check "old_https_port reports nothing when there is no vhost" "NONE" "$(norm "$got")"

# And the summary: with HTTPS carried over, the note about needing a reverse
# proxy must not be reachable on that path.
grep -q 'if \[ -z "\$SITE" \] && \[ -z "\$HTTPS" \]; then' "$HUB_INSTALL" ||
	fail "the reverse-proxy note no longer keys off HTTPS, so a re-run would print it"

# --- 8. 卸载要把 nginx 那份配置一起收走 --------------------------------------
#
# The vhost is nginx's file, not systemd's, so disabling the unit does not take
# it along. Left behind it holds its port and proxies to a hub that is gone:
# a visitor gets 502, and the operator's next install finds the port taken.
#
# Measured on a real machine -- after `--uninstall`, nginx was still listening
# on 0.0.0.0:8444 and answered 502 Bad Gateway. Nothing in the run said so.
#
# The cleanup is drop_https_site, shared with the domain path that already
# needed it, so the two cannot drift apart.

grep -q '^drop_https_site() {' "$HUB_INSTALL" ||
	fail "install-hub.sh has no drop_https_site"

# Both uninstall paths call it: the ordinary one, and the --purge branch on a
# machine whose unit is already gone -- which is the state an older version of
# this installer leaves behind, vhost and all.
uninstall_body=$(awk '/^uninstall_hub\(\) \{/,/^\}$/' "$HUB_INSTALL")
[ -n "$uninstall_body" ] || fail "uninstall_hub was not found in $HUB_INSTALL"
# Counted with awk rather than `grep -c`: grep exits 1 when nothing matches, and
# that code travels out of the command substitution, so `set -e` would end the
# run right here -- with no message, on exactly the broken case this is meant to
# report. awk prints 0 and exits 0.
calls=$(printf '%s\n' "$uninstall_body" | awk '/drop_https_site/ { n++ } END { print n + 0 }')
[ "$calls" -ge 2 ] ||
	fail "uninstall_hub calls drop_https_site $calls time(s); both paths need it"

# Run for real against a directory tree, with nginx and systemctl stubbed, so
# the file handling and the return code are the installer's own.
drop_probe() {
	where=$1
	root="$DIR/drop"
	rm -rf "$root"
	mkdir -p "$root/sites-enabled" "$root/conf.d"
	[ -z "$where" ] || printf 'listen 8444 ssl default_server;\n' \
		>"$root/$where/monitor-hub-https.conf"
	(
		cd "$root" || exit 1
		# `command -v nginx` finds a shell function, which is what makes the
		# guard inside drop_https_site take the reload branch.
		nginx() { return 0; }
		systemctl() { return 0; }
		eval "$(extract drop_https_site "$HUB_INSTALL" | sed 's#/etc/nginx#'"$root"'#g')"
		rc=0
		drop_https_site || rc=$?
		left=$(find "$root" -name 'monitor-hub-https.conf' | wc -l | tr -d ' ')
		printf 'rc=%s left=%s' "$rc" "$left"
	)
}

got=$(drop_probe sites-enabled)
check "uninstall drops the vhost it wrote" "rc=0 left=0" "$got"

# Debian puts it in sites-enabled, RHEL and Alpine in conf.d; both are cleaned.
got=$(drop_probe conf.d)
check "uninstall drops it under conf.d too" "rc=0 left=0" "$got"

# A machine without one is not an error, or the caller would report a cleanup
# it did not do.
got=$(drop_probe '')
check "nothing to drop reports non-zero" "rc=1 left=0" "$got"

# Transaction rollback operates only on this test's temporary files.
(
    ROOT="$DIR/rollback"
    mkdir -p "$ROOT/backup"
    SUB_BACKUP_DIR="$ROOT/backup"
    # These settings are consumed by the installer functions extracted with eval.
    # shellcheck disable=SC2034
    export ENV_FILE="$ROOT/env" UNIT_FILE="$ROOT/unit" RC_FILE="$ROOT/rc"
    # shellcheck disable=SC2034
    export SUB_NGINX_CONF="$ROOT/nginx" SUB_UNIT="$ROOT/legacy-unit" SUB_RC="$ROOT/legacy-rc"
    # shellcheck disable=SC2034
    export SUB_PREV_PUBLIC=18082 SUB_PREV_PORT=18081 SUB_LEGACY_RUNNING=1 INIT=systemd
    printf 'MONITOR_SUB_PORT=18081\nMONITOR_SUB_BIND=127.0.0.1\n' >"$SUB_BACKUP_DIR/env"
    printf 'previous unit\n' >"$SUB_BACKUP_DIR/unit"
    printf 'previous nginx\n' >"$SUB_BACKUP_DIR/nginx"
    printf 'previous state\n' >"$SUB_BACKUP_DIR/agent-state"
    printf 'broken replacement\n' >"$ENV_FILE"
    printf 'broken nginx\n' >"$SUB_NGINX_CONF"
    eval "$(extract restore_sub_file)"
    eval "$(extract restore_prev_sub)"
    sub_caps() { grep -q '^MONITOR_SUB_PORT=18081$' "$ENV_FILE" || fail 'capability chose new port'; }
    systemctl() { return 0; }
    restart_agent() { return 0; }
    check_subscription() { [ "$1" = http://127.0.0.1:18082 ]; }
    restore_prev_sub || fail 'rollback rejected restored public endpoint'
    grep -q 'previous nginx' "$SUB_NGINX_CONF" || fail 'old nginx was lost'
    grep -q 'previous unit' "$UNIT_FILE" || fail 'old unit was lost'
    grep -q 'previous state' "$ROOT/subscription.json" || fail 'route map was lost'
    check_subscription() { return 1; }
    if restore_prev_sub; then fail 'rollback claimed success despite failed HTTP validation'; fi
    # shellcheck disable=SC2034
    NO_VPN=1
    eval "$(extract configure_optional_vpn)"
    provision_vpn() { fail '--no-vpn entered provision'; }
    configure_optional_vpn
    echo '  ok  rollback restores files, public port and checks real success; --no-vpn skips changes'
)

# --- 9. 80 端口上别人的 default_server 要让位 ---------------------------------
#
# A stock `apt install nginx` on Debian and Ubuntu enables sites-enabled/default,
# which already declares `listen 80 default_server`. A second one on the same
# port is not "last writer wins" -- `nginx -t` rejects the whole tree with
# `a duplicate default server for 0.0.0.0:80`. So on a fresh machine the
# subscription vhost could not be installed at all, the installer fell back to
# 8080, and the client's address grew a `:8080` -- with the only explanation
# being `nginx refused the subscription config`, which reads as our config being
# wrong. Reproduced on a real machine.
#
# sub_default_server_patch comments out just that keyword on the other file,
# leaving the site itself (root, location, try_files) untouched, and records the
# file so uninstall can put it back.

grep -q '^sub_default_server_patch() {' "$INSTALL" ||
	fail "install.sh has no sub_default_server_patch"
grep -q '^sub_default_server_unpatch() {' "$INSTALL" ||
	fail "install.sh has no sub_default_server_unpatch"
# Counted as a live call, not merely present: a commented-out or `:`-prefixed
# line (the no-op form) still matches a plain grep, so the line is taken whole
# and its first non-blank character checked instead.
patched=$(awk '
	index($0, "sub_default_server_patch") && index($0, "$SUB_PORT") {
		line = $0
		sub(/^[ \t]+/, "", line)
		if (substr(line, 1, 1) != "#" && substr(line, 1, 1) != ":") n++
	}
	END { print n + 0 }
' "$INSTALL")
[ "$patched" -ge 1 ] ||
	fail "write_sub_nginx never calls sub_default_server_patch on the port, so a stock nginx still breaks it"

# The uninstall branch at the top of the script runs before any function is
# defined, so it cannot call sub_default_server_unpatch; it restores in place.
# Both use the same `nginx -T` file walk, or one would miss what the other moved.
awk '/^if \[ -n "\$UNINSTALL" \]; then$/,/^fi$/' "$INSTALL" |
	grep -q 'monitor-orig' ||
	fail "uninstall does not restore the default_server markers it removed"

# Exercised against a directory tree with nginx stubbed, so the file handling and
# the restore are the installer's own.
#
# `nginx -T` is the only thing that tells the function which files are live, and
# its output format is `# configuration file <path>:` -- the stub reproduces it,
# and its `nginx -t` answer is scripted per case so both the accepted and the
# rejected patch can be reached.
patch_probe() {
	case_name=$1
	root="$DIR/default-server"
	rm -rf "$root"
	mkdir -p "$root/sites-enabled" "$root/conf.d"
	printf 'server {\n\tlisten 80 default_server;\n\troot /var/www/html;\n}\n' \
		>"$root/sites-enabled/default"
	printf 'server {\n\tlisten 8444 ssl default_server;\n}\n' \
		>"$root/sites-enabled/monitor-hub-https.conf"
	(
		cd "$root" || exit 1
		SUB_NGINX_CONF="$root/conf.d/monitor-sub.conf"
		export SUB_NGINX_CONF
		extract sub_default_server_patch >"$DIR/fn-patch.sh"
		sed -i 's#/etc/nginx#'"$root"'#g' "$DIR/fn-patch.sh"
		load_file "$DIR/fn-patch.sh"
		load sub_default_server_unpatch
		# `nginx -T` lists every live file, the way the real one does.
		nginx() {
			case "$1" in
			-T)
				printf '# configuration file %s:\n' \
					"$root/sites-enabled/default" "$root/sites-enabled/monitor-hub-https.conf"
				;;
			-t)
				# The rejected case: this tree never validates.
				[ "$case_name" = reject ] && return 1
				return 0
				;;
			esac
		}
		sub_default_server_patch 80
		marked=$(grep -c 'listen 80 default_server' "$root/sites-enabled/default" || true)
		commented=$(grep -c '# default_server (monitor' "$root/sites-enabled/default" || true)
		kept=$(grep -c 'root /var/www/html' "$root/sites-enabled/default" || true)
		orig=$(find "$root" -name '*.monitor-orig' | wc -l | tr -d ' ')
		# 8444 must be untouched: a different port is someone else's business.
		other=$(grep -c 'listen 8444 ssl default_server' "$root/sites-enabled/monitor-hub-https.conf" || true)
		printf 'marked=%s commented=%s kept=%s orig=%s other=%s' \
			"$marked" "$commented" "$kept" "$orig" "$other"
	)
}

got=$(patch_probe accept)
check "the other default_server on 80 is taken over, its site kept" \
	"marked=0 commented=1 kept=1 orig=1 other=1" "$got"

# A tree that still will not validate must be left exactly as it was found: a
# patch we could not justify would otherwise be a machine we broke.
got=$(patch_probe reject)
check "a refused patch is rolled back, marker and site intact" \
	"marked=1 commented=0 kept=1 orig=0 other=1" "$got"

# And the restore puts the file back the way it was. Run against a tree patched
# by the accept case above, whose .monitor-orig is the untouched original.
(
	root="$DIR/default-server"
	# The reject case above rebuilt the tree; lay down the patched state again.
	printf 'server {\n\tlisten 80 default_server;\n\troot /var/www/html;\n}\n' \
		>"$root/sites-enabled/default.monitor-orig"
	printf 'server {\n\tlisten 80 # default_server (monitor: moved to monitor-sub.conf);\n\troot /var/www/html;\n}\n' \
		>"$root/sites-enabled/default"
	(
		cd "$root" || exit 1
		SUB_NGINX_CONF="$root/conf.d/monitor-sub.conf"
		# shellcheck disable=SC2034
		SUB_DEFAULT_RESTORE="$root/sites-enabled/default"
		load sub_default_server_unpatch
		sub_default_server_unpatch
	)
	grep -q 'listen 80 default_server;' "$root/sites-enabled/default" ||
		fail "unpatch did not restore the original default_server"
	grep -q 'root /var/www/html' "$root/sites-enabled/default" ||
		fail "unpatch lost the site it restored"
	[ -z "$(find "$root" -name '*.monitor-orig')" ] ||
		fail "unpatch left a .monitor-orig file behind"
	echo "  ok  unpatch restores the original file byte for byte"
)

# --- 10. 订阅伺服失败不等于 VPN 没部署 ----------------------------------------
#
# report_vpn used to sit inside setup_subscription's success branch, so anything
# wrong with serving the subscription -- a port it could not take, an nginx that
# refused the config -- also suppressed the report. The hub then had no vpn row
# and the panel said "未部署 VPN" while sing-box was running and carrying traffic.
# The user is sent looking for a VPN that is already up, and nothing in the
# output explains the contradiction.
#
# The two outcomes are independent: provision_vpn succeeding means the node is
# deployed; setup_subscription is only about putting the links on a URL.

grep -q '^report_vpn() {' "$INSTALL" || fail "install.sh has no report_vpn"

# Measured live: a node with a running sing-box, a subscription it could not
# serve, and an empty vpn table on the hub.
(
	prov=0 sub=0
	NO_VPN=
	eval "$(extract configure_optional_vpn)"
	# report_vpn and setup_subscription are both stubbed: this checks only the
	# order and the independence of the two, not what either does. The probe is
	# stubbed too -- it needs a real machine and a sing-box client; section 11
	# covers what it writes.
	provision_vpn() { return 0; }
	report_vpn() { prov=$((prov + 1)); }
	setup_subscription() { sub=$((sub + 1)); return 1; }
	setup_latency_probe() { return 0; }
	configure_optional_vpn
	[ "$prov" -eq 1 ] ||
		fail "a failed subscription suppressed the deployment report (reported $prov time(s))"
	[ "$sub" -eq 1 ] || fail "setup_subscription ran $sub time(s)"
	echo "  ok  a failed subscription still reports the deployment to the hub"
)

# The reverse, so the check is not one-sided: a successful subscription must not
# turn one report into two.
(
	prov=0
	NO_VPN=
	eval "$(extract configure_optional_vpn)"
	provision_vpn() { return 0; }
	report_vpn() { prov=$((prov + 1)); }
	setup_subscription() { return 0; }
	setup_latency_probe() { return 0; }
	configure_optional_vpn
	[ "$prov" -eq 1 ] || fail "the deployment was reported $prov time(s), expected once"
	echo "  ok  a served subscription reports it exactly once"
)

# A failed provision must report nothing: there is no deployment to record, and
# a vpn row for a node that never got one is worse than an empty table.
(
	prov=0
	# Read by the function pulled in with extract; shellcheck cannot see that.
	# shellcheck disable=SC2034
	NO_VPN=
	eval "$(extract configure_optional_vpn)"
	provision_vpn() { return 1; }
	report_vpn() { prov=$((prov + 1)); }
	setup_subscription() { fail "subscription ran after a failed provision"; }
	setup_latency_probe() { fail "the probe ran without a deployment to measure"; }
	configure_optional_vpn
	[ "$prov" -eq 0 ] || fail "a failed provision still reported a deployment"
	echo "  ok  a failed provision reports nothing"
)

# --- 11. 延迟探针自动装起来 ----------------------------------------------------
#
# The panel has a 网络延迟 tab and the hub creates the two proxy tasks at
# startup, but the thing that measures them was never installed: probe/ ships a
# README that says "Optional" and a list of manual steps -- fill in
# YOUR_SERVER_IP, YOUR_VLESS_UUID, YOUR_REALITY_PUBLIC_KEY. Nobody did, so
# ping_record stayed empty and the tab said 这段时间没有延迟数据, which reads as
# "broken" rather than "never installed".
#
# Measured on a real node: ping_task rows=2, ping_node rows=2, ping_record rows=0,
# no /opt/probe, no probe process.
#
# The installer now writes the client config itself, from the credentials
# provision just generated -- it holds them in $VPN_JSON, so there is nothing for
# the user to fill in.

grep -q '^setup_latency_probe() {' "$INSTALL" ||
	fail "install.sh has no setup_latency_probe"
grep -q '^json_str() {' "$INSTALL" ||
	fail "install.sh has no json_str"
# Called from the VPN path, and only after the report, so the probe can rely on
# $VPN_JSON being the deployment it just reported.
probe_call=$(awk '
	index($0, "setup_latency_probe") && !index($0, "setup_latency_probe()") {
		line = $0
		sub(/^[ \t]+/, "", line)
		if (substr(line, 1, 1) != "#" && substr(line, 1, 1) != ":") n++
	}
	END { print n + 0 }
' "$INSTALL")
[ "$probe_call" -ge 1 ] ||
	fail "setup_latency_probe is never called, so the latency tab stays empty"

# json_str is the whole reason this can be done without jq: the machine is not
# guaranteed to have one, so the report is parsed with tr/sed. `grep -o` was
# measured to return only the first match per line on a single-line JSON, which
# is why the value is taken after splitting on commas.
load json_str
REPORT='{"success":true,"reused_credentials":false,"server":"1.2.3.4","sni":"vpn.example.com","uuid":"76b86267-f1b2-4f4b-87fb-e1a0e9e80bc8","reality_public_key":"BsN37-DA66bg7fqRkZWounOYs6ssqqKfPe-eP2--cWo","short_id":"f08819fd94b685fe","hy2_password":"ca4d1ee4e4a1e5e8abbb65b13e933947","obfs_password":"3fb4f7b17040adbc00eb14f27fb0510c","vless_link":"vless://76b8@1.2.3.4:443","clash_sub_url":"http://1.2.3.4/sub-a.yaml"}'

check "json_str reads a key from the report" "1.2.3.4" "$(json_str "$REPORT" server)"
check "json_str reads the sni, not the server" "vpn.example.com" "$(json_str "$REPORT" sni)"
check "json_str reads a key near the end" "3fb4f7b17040adbc00eb14f27fb0510c" "$(json_str "$REPORT" obfs_password)"
check "json_str reads every credential it is asked for" \
	"76b86267-f1b2-4f4b-87fb-e1a0e9e80bc8 BsN37-DA66bg7fqRkZWounOYs6ssqqKfPe-eP2--cWo f08819fd94b685fe ca4d1ee4e4a1e5e8abbb65b13e933947" \
	"$(json_str "$REPORT" uuid) $(json_str "$REPORT" reality_public_key) $(json_str "$REPORT" short_id) $(json_str "$REPORT" hy2_password)"
# An absent key must come back empty rather than as some other key's value: this
# is what the caller's completeness check reads.
check "an absent key reads as empty" "" "$(json_str "$REPORT" no_such_key)"
# The last value on the line has no trailing comma; a parser that only looks
# after one would drop it and the probe would be skipped as incomplete.
check "the last key on the line is still read" "http://1.2.3.4/sub-a.yaml" "$(json_str "$REPORT" clash_sub_url)"

# The installer must refuse rather than write a half-filled client config: a
# config missing a credential starts and then fails every round, which looks
# exactly like a dead proxy.
grep -q 'missing a credential' "$INSTALL" ||
	fail "setup_latency_probe writes a config even when a credential is missing"

# And it must not claim to have installed the probe when the runtime it needs is
# absent -- python3 for the prober, sing-box for the client.
grep -q 'python3 is not installed' "$INSTALL" ||
	fail "the probe does not check for python3"
grep -q 'sing-box is not on PATH' "$INSTALL" ||
	fail "the probe does not check for sing-box"

# The node id is not written into PROBE_TARGETS: the agent holds a token, never
# an id, so a constant there would file this machine's latency under whichever
# node happens to be number 1. The prober looks it up from ping_node instead.
grep -q 'PROBE_TARGETS=vless:\$PROBE_VLESS_PORT,hy2:\$PROBE_HY2_PORT' "$INSTALL" ||
	fail "PROBE_TARGETS carries a node id, which the installer has no way to know"
grep -q '^def node_for(' "$ROOT/probe/probe.py" ||
	fail "probe.py has no node_for, so a two-field target cannot be resolved"
grep -q 'SELECT node_id FROM ping_node WHERE task_id' "$ROOT/probe/probe.py" ||
	fail "probe.py does not look the node up from ping_node"

# Uninstall must take the probe with it: it runs its own sing-box client, which
# would otherwise keep holding 127.0.0.1:18083/18084 with nothing left to test.
awk '/^if \[ -n "\$UNINSTALL" \]; then$/,/^fi$/' "$INSTALL" |
	grep -q 'probe-singbox' ||
	fail "uninstall leaves the latency probe's sing-box client running"

# The hub serves the prober to the installer, the same way it serves itself: a
# fresh machine must not need a second network to reach GitHub.
grep -q 'route("/probe.py"' "$ROOT/src/main.rs" ||
	fail "the hub does not serve /probe.py, so the installer cannot fetch the prober"

# --- 12. 自签证书这件事要一路告诉面板 ---------------------------------------
#
# The panel presets its "accept an unverified certificate" switch from what the
# installer was told, so one answer at install time is not asked again at every
# node -- and, more importantly, the command it hands out is correct without the
# operator having to know it needed a switch. That is a three-link chain:
# install-hub.sh writes the flag into the unit, the hub records it, the panel
# reads it off /api/me. Any one link missing leaves the switch off, and the
# command it produces still runs and still looks right -- it just fails to
# connect, which is exactly the silent failure this test exists for.

HUB="$ROOT/install-hub.sh"

# Whether a line of code is live, as opposed to text in a comment. A plain
# `grep -q` cannot tell them apart, and every assertion below would then pass on
# a file where the line had been commented out -- which is how the check for the
# flag reaching ExecStart was first written, and it stayed green when the line
# was disabled. `#` and `:` (the POSIX "do nothing" command) both stop the line
# from running, so both are excluded.
live() {
	awk -v pat="$1" '
		index($0, pat) {
			line = $0
			sub(/^[ \t]+/, "", line)
			if (substr(line, 1, 1) != "#" && substr(line, 1, 1) != ":") n++
		}
		END { exit (n > 0 ? 0 : 1) }
	' "$2"
}

# Link 1: --https sets it, and a domain clears it. Both directions are asserted
# because only one of them breaks loudly: a stale "on" hands out `--insecure`
# where it is not needed, and that command works.
live 'SELF_SIGNED=1' "$HUB" ||
	fail "install-hub.sh never sets SELF_SIGNED, so the hub cannot know"
awk '/^	if \[ -n "\$SITE" \] \|\| \[ -n "\$PLAIN" \]; then$/,/^	fi$/' "$HUB" |
	grep -q 'SELF_SIGNED=""' ||
	fail "a hub with a domain keeps claiming a self-signed certificate"

# Link 1b: the unit carries it, and a re-run that omits --https recovers it from
# the unit it is about to replace. Without the recovery the second run would
# silently turn the switch off on a hub that is still self-signed.
live 'args="$args --self-signed"' "$HUB" ||
	fail "the flag never reaches the hub's ExecStart"
live ') SELF_SIGNED=1' "$HUB" ||
	fail "a re-run drops --self-signed instead of recovering it from the old unit"

# Link 2: the hub accepts the flag and records it. Read unconditionally on every
# start, so a re-run that drops --https clears it again.
live '"--self-signed" => self_signed = true' "$ROOT/src/main.rs" ||
	fail "the hub does not accept --self-signed"
live 'db.set("self_signed"' "$ROOT/src/main.rs" ||
	fail "the hub accepts --self-signed but never records it"
live '"self_signed": app.db.get("self_signed")' "$ROOT/src/api.rs" ||
	fail "the hub records it but never tells the panel"

# Link 2b: it is deliberately NOT a /api/settings key. That endpoint echoes every
# field back to save_settings, which rejects unknown keys -- listing it there
# would make the settings form fail on every hub, self-signed or not.
awk '/^const READABLE_SETTINGS/,/^\];$/' "$ROOT/src/api.rs" | grep -q 'self_signed' &&
	fail "self_signed is a readable setting, so saving settings would reject it"

# Link 3: the panel reads it and seeds all four install/register dialogs from it.
live 'self_signed: boolean' "$ROOT/web-admin/src/App.tsx" ||
	fail "the panel does not read self_signed from /api/me"
live 'selfSigned={me.self_signed}' "$ROOT/web-admin/src/App.tsx" ||
	fail "the panel reads self_signed but never passes it down"
seeded=$(awk '
	index($0, "useState(selfSigned)") {
		line = $0
		sub(/^[ \t]+/, "", line)
		if (substr(line, 1, 1) != "#" && substr(line, 1, 1) != ":") n++
	}
	END { print n + 0 }
' "$ROOT/web-admin/src/components/Admin.tsx")
[ "$seeded" = 4 ] ||
	fail "expected all four certificate switches seeded from selfSigned, found $seeded"
# The switch must still be operator-overridable: seeding the state is not the
# same as latching it, and a hub behind a proxy the installer did not configure
# may legitimately differ from what --https recorded.
live 'onCheckedChange={onChange}' "$ROOT/web-admin/src/components/Admin.tsx" ||
	fail "the certificate switch can no longer be changed by the operator"

echo "install-test: ok"