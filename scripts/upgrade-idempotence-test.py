#!/usr/bin/env python3
"""Exercise the actual installer restart decision against real process inodes."""
import pathlib
import re
import subprocess
import tempfile

source=(pathlib.Path(__file__).resolve().parents[1]/'install.sh').read_text()
function='\n'.join(re.search(r'^'+name+r'\(\) \{\n.*?^\}',source,re.M|re.S).group() for name in ['same_agent_env','same_executable','restart_agent'])
with tempfile.TemporaryDirectory(prefix='monitor-restart-test-') as tmp:
    script="""set -eu
root=$1
ENV_FILE=$root/env; UNIT_FILE=$root/unit; RC_FILE=$root/rc
SUB_BACKUP_DIR=$root/snapshot; INIT=systemd; AGENT_BINARY_CHANGED=''
BIN=/bin/sleep
mkdir "$SUB_BACKUP_DIR"
printf 'A=1\nB=2\n' >"$ENV_FILE"; printf unit >"$UNIT_FILE"
cp "$ENV_FILE" "$SUB_BACKUP_DIR/running-env"
cp "$UNIT_FILE" "$SUB_BACKUP_DIR/running-unit"
/bin/sleep 120 & pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
calls=0
systemctl() {
    case "$1" in
    is-active) return 0;;
    show) printf '%s' "$pid";;
    restart) kill "$pid"; /bin/sleep 120 & pid=$!; calls=$((calls+1));;
    *) return 1;;
    esac
}
"""+function+"""
! same_executable "$root/missing" "$root/also-missing"
! same_executable "$BIN" /proc/0/exe
same_executable "$BIN" "/proc/$pid/exe"
restart_agent
[ "$calls" = 0 ] || { echo 'unchanged install restarted'; exit 1; }
printf 'B=2\nA=1\n' >"$ENV_FILE"
restart_agent
[ "$calls" = 0 ] || { echo 'assignment reordering restarted'; exit 1; }
printf 'A=1\nB=2\nA=3\n' >"$ENV_FILE"
restart_agent
[ "$calls" = 1 ]
restart_agent
[ "$calls" = 1 ] || { echo 'env snapshot not advanced'; exit 1; }
printf updated-unit >"$UNIT_FILE"
restart_agent
[ "$calls" = 2 ]
AGENT_BINARY_CHANGED=1
restart_agent
[ "$calls" = 3 ]
# On-disk equality is insufficient if the active process runs another inode.
cp /bin/sleep "$root/replacement"; BIN=$root/replacement
restart_agent
[ "$calls" = 4 ] || { echo 'stale process executable not detected'; exit 1; }
echo 'upgrade-idempotence: unchanged PID retained; env/unit/binary changes and stale executable restart passed'
"""
    subprocess.run(['sh','-c',script,'test',tmp],check=True)
