#!/usr/bin/env python3
"""Exercise rollback of the actual installer proxy setup in a private filesystem."""
import json,pathlib,re,subprocess,tempfile
source=(pathlib.Path(__file__).resolve().parents[1]/'install.sh').read_text()
functions='\n'.join(re.search(r'^'+name+r'\(\) \{\n.*?^\}\n(?=\n)',source,re.M|re.S).group() for name in ['json_str','restore_probe_client','setup_latency_probe'])
report=json.dumps(dict(server='127.0.0.1',uuid='test',reality_public_key='test',short_id='test',hy2_password='test',obfs_password='test'))
with tempfile.TemporaryDirectory(prefix='monitor-proxy-install-') as tmp:
 root=pathlib.Path(tmp);(root/'probe').mkdir();(root/'agent').write_text('#!/bin/sh\nexit 0\n');(root/'agent').chmod(0o700)
 (root/'bin').mkdir(); fake=root/'bin/sing-box'; fake.write_text('#!/bin/sh\n[ ! -f '+str(root/'reject')+' ]\n');fake.chmod(0o700)
 functions=functions.replace('/etc/systemd/system/probe-singbox.service',str(root/'unit')).replace('/etc/systemd/system/monitor-probe.service',str(root/'sampler'))
 shell="""set -eu
root=$1; report=$2
PROBE_DIR=$root/probe; ROOT=$root; BIN=$root/agent; ENV_FILE=$root/env
NO_VPN=''; PROBE_VLESS_PORT=18083; PROBE_HY2_PORT=18084
printf 'original-env' >"$ENV_FILE"
printf 'original-config' >"$PROBE_DIR/sing-box.json"
printf 'original-unit' >"$root/unit"
printf 'original-sampler' >"$root/sampler"
check_fail=''; client_restart=0; agent_restart=0; retired=0
PATH=$root/bin:$PATH; export PATH
restart_agent() { agent_restart=$((agent_restart+1)); }
systemctl() {
 case "$1" in
 show) printf 0;;
 is-active|is-enabled|daemon-reload|enable) return 0;;
 restart) client_restart=$((client_restart+1)); [ "$client_restart" != 1 ];;
 disable) case "$*" in *monitor-probe*) retired=$((retired+1));; esac;;
 *) return 0;;
 esac
}
"""+functions+"""
setup_latency_probe "$report"
[ "$(cat "$PROBE_DIR/sing-box.json")" = original-config ]
[ "$(cat "$root/unit")" = original-unit ]
[ "$(cat "$ENV_FILE")" = original-env ]
[ "$(cat "$root/sampler")" = original-sampler ]
[ "$agent_restart" = 0 ] && [ "$retired" = 0 ] && [ "$client_restart" = 2 ]
touch "$root/reject"
setup_latency_probe "$report"
[ "$(cat "$PROBE_DIR/sing-box.json")" = original-config ]
[ "$(cat "$root/unit")" = original-unit ]
[ "$agent_restart" = 0 ] && [ "$retired" = 0 ]
echo 'proxy-install: startup failure restores config and unit; validation failure preserves live sampler and agent env'
"""
 subprocess.run(['sh','-c',shell,'test',tmp,report],check=True)
