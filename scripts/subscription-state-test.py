#!/usr/bin/env python3
"""Exercise installer functions against a real subscription/Hub HTTP server."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOURCE = (Path(__file__).resolve().parent.parent / 'install.sh').read_text()


def function(name):
    start = SOURCE.index(name + '() {')
    return SOURCE[start:SOURCE.index('\n}\n', start) + 3]


class Handler(BaseHTTPRequestHandler):
    ready = True
    status = 200
    reports = []
    requests = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        type(self).requests.append(self.path)
        self.send_response(200 if self.ready else 404)
        self.send_header('subscription-userinfo', 'upload=1; download=2; total=3')
        self.end_headers()
        self.wfile.write(b'valid subscription\n')

    def do_POST(self):
        assert self.path == '/api/agent/vpn'
        type(self).reports.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(self.status)
        self.end_headers()


def run(script):
    result = subprocess.run(['sh', '-eu'], input=script, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_port
try:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        state = root / 'subscription.json'
        names = ['sub-test.yaml', 'v2-test.txt', 'v2-test.b64']
        functions = '\n'.join(function(n) for n in (
            'json_str', 'sub_file_names', 'check_subscription', 'wait_subscription', 'report_vpn', 'configure_optional_vpn'
        ))
        report = {'success': True, 'uuid': 'credential-kept', 'vless_link': 'vless://kept',
                  'hy2_link': 'hysteria2://kept', 'clash_sub_url': 'http://candidate:8080/new.yaml',
                  'v2ray_sub_url': 'http://candidate:8080/new.txt'}
        settings = f'''ROOT='{root}'
SUB_STATE='{state}'
SUB_PORT={port}
SUB_FOREIGN=
SUB_READY=
NO_VPN=
VPN_ENABLED=1
VPN_IP=127.0.0.1
TMP='{root}/curl'
SERVER=http://127.0.0.1:{port}
TOKEN=test
CURL_INSECURE=
VPN_JSON='{json.dumps(report)}'
'''
        for folder in ['/var/www/sub', '/custom/subscriptions']:
            state.write_text(json.dumps(dict(zip(['clash', 'v2ray_txt', 'v2ray_b64'],
                                                [folder + '/' + name for name in names]))))
            Handler.requests.clear()
            run(functions + settings + f'check_subscription http://127.0.0.1:{port}\n')
            assert Handler.requests == ['/' + name for name in names], Handler.requests
        print('ok: all three routes fetched with default and custom directories')

        complete_state = state.read_text()
        partial = json.loads(complete_state)
        del partial['v2ray_b64']
        state.write_text(json.dumps(partial))
        Handler.requests.clear()
        run(functions + settings + f'if check_subscription http://127.0.0.1:{port}; then exit 1; fi\n')
        assert not Handler.requests
        state.write_text(complete_state)
        print('ok: incomplete route maps cannot advertise a working subscription')

        Handler.ready = False
        threading.Timer(0.2, lambda: setattr(Handler, 'ready', True)).start()
        run(functions + settings + f'wait_subscription http://127.0.0.1:{port}\n')
        print('ok: bounded HTTP retries tolerate a listener/reload readiness delay')

        # Successful setup, restored old setup, and no usable subscription.
        for mode in ['success', 'rollback', 'unavailable']:
            Handler.ready = mode != 'unavailable'
            Handler.status = 200
            Handler.reports.clear()
            run(functions + settings + f'''
provision_vpn() {{ return 0; }}
setup_subscription() {{ [ '{mode}' = success ]; }}
setup_latency_probe() {{ [ "$1" = "$VPN_JSON" ]; printf '%s' "$1" >"$ROOT/probe-input"; }}
configure_optional_vpn
[ ! -f "$ROOT/vpn-report.pending.json" ]
''')
            saved = Handler.reports[-1]
            assert saved['success'] and saved['uuid'] == report['uuid']
            assert saved['vless_link'] == report['vless_link']
            assert json.loads((root / 'probe-input').read_text()) == report
            expected = '' if mode == 'unavailable' else f'http://127.0.0.1:{port}/{names[0]}'
            assert saved['clash_sub_url'] == expected, saved
            assert saved['v2ray_sub_url'] == ('' if mode == 'unavailable' else
                                             f'http://127.0.0.1:{port}/{names[1]}')
        print('ok: successful, restored and unavailable subscriptions publish final state; probe credentials retained')

        Handler.ready = True
        Handler.status = 503
        run(functions + settings + '''SUB_READY=1
if report_vpn; then exit 1; fi
''')
        pending = root / 'vpn-report.pending.json'
        assert pending.stat().st_mode & 0o777 == 0o600
        assert json.loads(pending.read_text())['clash_sub_url'].endswith('/sub-test.yaml')
        Handler.status = 200
        run(functions + settings + 'SUB_READY=1\nreport_vpn\n')
        assert not pending.exists()
        print('ok: Hub failure retains a private retry payload; successful resync removes it')

        # Verify ownership against a real process, not a saved port or process name.
        binary = os.readlink(f'/proc/{os.getpid()}/exe')
        script = function('agent_holds') + f'''
BIN='{binary}'
ss() {{ printf 'users:(("python",pid={os.getpid()},fd=3))\\n'; }}
agent_holds 18082
BIN=/unrelated/monitor-agent
if agent_holds 18082; then exit 1; fi
'''
        run(script)
        print('ok: listener ownership uses the executable, rejecting unrelated processes')

        # Both front and backend ownership are needed. An unrelated nginx route
        # that serves the same files must remain outside the installer's control.
        conf = root / 'nginx.conf'
        conf.write_text('proxy_pass http://127.0.0.1:18081;\n')
        script = function('foreign_sub_server') + f"""
ROOT='{root}'
SUB_PORT=18090; SUB_PREV_PUBLIC=18090; SUB_PREV_PORT=18081
SUB_PREV_BIND=127.0.0.1; SUB_PREV_STATE="$ROOT/subscription.json"
SUB_NGINX_CONF='{conf}'; SUB_HOME="$ROOT/no-legacy-service"; SUB_STATE='{state}'
nginx_holds() {{ return 0; }}
agent_holds() {{ [ "$1" = 18081 ]; }}
curl() {{ return 0; }}
if foreign_sub_server; then exit 1; fi
SUB_PREV_BIND=0.0.0.0
foreign_sub_server
SUB_PREV_BIND=127.0.0.1
printf 'proxy_pass http://127.0.0.1:18082;\n' >"$SUB_NGINX_CONF"
foreign_sub_server
"""
        run(script)
        print('ok: owned nginx plus Agent backend is retained; unrelated routes remain foreign')

finally:
    server.shutdown()
    server.server_close()
