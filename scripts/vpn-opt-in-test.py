#!/usr/bin/env python3
"""Exercise fresh install/upgrade opt-in decisions without touching any service."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parent.parent / 'install.sh').read_text()
start = source.index('configure_optional_vpn() {')
function = source[start:source.index('\n}\n', start) + 3]
parser = source[:source.index('\n[ "$(id -u)" = 0 ]')]
for arguments, expected in [([], '|'), (['--upgrade'], '|'),
                            (['--vpn'], '1|'), (['--vpn-ip', '127.0.0.1'], '1|'),
                            (['--vpn', '--no-vpn'], '1|1'),
                            (['--no-vpn', '--vpn'], '1|1')]:
    result = subprocess.run(['sh', '-eu', '-c', parser +
                             '\nprintf "%s|%s" "$VPN_ENABLED" "$NO_VPN"',
                             'installer-parser', *arguments],
                            capture_output=True, text=True, check=True)
    assert result.stdout == expected, (arguments, result.stdout)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    for existing, enabled, disabled, expected in [
        (False, '', '', 0), (False, '1', '', 1),
        (True, '', '', 1), (True, '1', '', 1),
        (False, '1', '1', 0), (True, '', '1', 0),
    ]:
        state = root / 'subscription.json'
        if existing:
            state.write_text('{"yaml_path":"/var/www/sub/existing.yaml"}')
        else:
            state.unlink(missing_ok=True)
        script = f'''ROOT='{root}'
VPN_ENABLED='{enabled}' NO_VPN='{disabled}'
SUB_STATE=saved SUB_FOREIGN= SUB_PORT=18082 VPN_JSON=credentials
count=0
provision_vpn() {{ count=$((count + 1)); }}
setup_subscription() {{ :; }}
wait_subscription() {{ :; }}
report_vpn() {{ :; }}
setup_latency_probe() {{ :; }}
{function}
configure_optional_vpn
[ "$count" -eq {expected} ]
'''
        result = subprocess.run(['sh', '-eu'], input=script, text=True, capture_output=True)
        assert result.returncode == 0, (existing, enabled, disabled, result.stdout, result.stderr)
        assert state.exists() == existing
print('vpn-opt-in-test: 6 argument and 6 deployment cases passed')
