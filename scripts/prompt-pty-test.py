#!/usr/bin/env python3
"""Check the actual interactive yes/no prompt, without running the installer."""
import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import time

source = (Path(__file__).resolve().parent.parent / 'install-hub.sh').read_text()
start = source.index('confirm_answer() {')
function = source[start:source.index('\n}\n', start) + 3]


def check(answer, default, expected):
    master, slave = pty.openpty()
    script = function + f'\nY= N= D=\nresult=$(confirm_answer domain {default})\nprintf "RESULT=%s\\n" "$result"\n'
    proc = subprocess.Popen(['sh', '-eu', '-c', script], stdin=slave,
                            stdout=slave, stderr=slave)
    os.close(slave)
    output = b''
    sent = False
    deadline = time.monotonic() + 5
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    data = os.read(master, 4096)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                output += data
                if not sent and (b'[y/N]' in output or b'[Y/n]' in output):
                    os.write(master, answer.encode() + b'\n')
                    sent = True
            if proc.poll() is not None and not select.select([master], [], [], 0)[0]:
                break
        assert sent, output
        assert proc.wait(timeout=1) == 0, output
        assert (b'[Y/n]' if default == 'y' else b'[y/N]') in output, output
        assert f'RESULT={expected}'.encode() in output, output
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        os.close(master)


for answer, default, expected in [('y', 'n', 'y'), ('Y', 'n', 'y'),
                                  ('yes', 'n', 'y'), ('YES', 'n', 'y'),
                                  ('', 'n', 'n'), ('invalid', 'n', 'n'),
                                  ('', 'y', 'y'), ('n', 'y', 'n')]:
    check(answer, default, expected)
for default in ['n', 'y']:
    result = subprocess.run(['sh', '-eu', '-c', function +
                             f'\nconfirm_answer domain {default}\n'],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
    assert result.stdout == default and result.stderr == '', result
print('prompt-pty-test: 10 cases passed')
