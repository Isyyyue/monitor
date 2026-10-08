#!/usr/bin/env python3
"""Isolated Hub/Agent integration: authenticated proxy samples, loss, task removal and reconnect."""
import contextlib
import http.server
import json
import os
import re
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

class Proxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.path == 'http://example.invalid/check', self.path
        self.send_response(self.server.status)
        self.send_header('Content-Length','0')
        self.end_headers()
    def log_message(self,*_args): pass

def main(hub,agent):
    with tempfile.TemporaryDirectory(prefix='monitor-proxy-e2e-') as tmp, contextlib.ExitStack() as stack:
        root=pathlib.Path(tmp)
        servers=[]
        for status in (204,503):
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy);server.status=status
            threading.Thread(target=server.serve_forever,daemon=True).start()
            stack.callback(server.server_close);stack.callback(server.shutdown);servers.append(server)
        # Reserve a port before starting the child, avoiding a fixed developer port.
        import socket
        with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        url=f'http://127.0.0.1:{port}'
        def spawn(command,name,env=None):
            log=stack.enter_context(open(root/name,'w'))
            proc=subprocess.Popen(command,stdout=log,stderr=log,env=env)
            def stop():
                if proc.poll() is None:
                    proc.terminate()
                    try: proc.wait(10)
                    except subprocess.TimeoutExpired: proc.kill();proc.wait()
            stack.callback(stop)
            return proc
        spawn([hub,'--listen',f'127.0.0.1:{port}','--db',str(root/'hub.db'),'--themes',str(root/'themes')],'hub.log')
        cookie=''
        def api(path,data=None):
            headers={'Cookie':cookie,'Origin':'https://hub.example.com','Sec-Fetch-Site':'same-origin'}
            if data is not None:headers['Content-Type']='application/json'
            req=urllib.request.Request(url+'/api/'+path, data=None if data is None else json.dumps(data).encode(),headers=headers)
            with urllib.request.urlopen(req,timeout=10) as response:return json.load(response),response.headers
        def wait(check,what):
            until=time.monotonic()+75
            while time.monotonic()<until:
                try:
                    value=check()
                    if value:return value
                except (OSError,ValueError,sqlite3.Error):pass
                time.sleep(.25)
            print('diagnostics',what,flush=True)
            for log in root.glob('*.log'):
                text=log.read_text()
                if 'Emergency password: ' in text:text='\n'.join(l for l in text.splitlines() if 'Emergency password: ' not in l)
                print(log.name,text[-4000:],flush=True)
            raise AssertionError('timed out: '+what)
        wait(lambda:api('me'),'Hub listener')
        def asset(path):
            with urllib.request.urlopen(url+path,timeout=10) as r:return r.read()
        repository=pathlib.Path(__file__).resolve().parents[1]
        assert asset('/install.sh')==(repository/'install.sh').read_bytes(), 'embedded installer differs from source'
        assert asset('/probe.py')==(repository/'probe/probe.py').read_bytes(), 'embedded legacy sampler differs from source'
        html=asset('/admin/nodes').decode()
        entry=re.search(r'src="([^"]+\.js)"',html).group(1)
        bundle=asset(entry).decode()
        for page in ['Ping','Themes','Notify','Website','Deploy','Security','Data']:
            chunk=re.search(page+r'-[\w-]+\.js',bundle).group()
            body=asset(entry.rsplit('/',1)[0]+'/'+chunk)
            assert len(body)>100 and not body.startswith(b'<!doctype'), ('lazy asset',page)

        password=wait(lambda:next((line.split('Emergency password: ',1)[1].strip() for line in (root/'hub.log').read_text().splitlines() if 'Emergency password: ' in line),None),'initial password')
        _,headers=api('auth/login',{'password':password});cookie=headers['Set-Cookie'].split(';')[0]
        api('nodes',{'name':'proxy-one'});api('nodes',{'name':'proxy-two'})
        time.sleep(2)
        nodes=api('nodes')[0]['nodes'];ids=[n['id'] for n in nodes]
        assert len(ids)==2, ('node count',len(ids))
        vless=api('ping-tasks',{'name':'vless','target':'proxy:vless','interval':5,'nodes':ids})[0]['id']
        hy2=api('ping-tasks',{'name':'hy2','target':'proxy:hy2','interval':5,'nodes':ids})[0]['id']
        env=os.environ|{'MONITOR_PROXY_PORTS':f'vless:{servers[0].server_port},hy2:{servers[1].server_port}','MONITOR_PROXY_TEST_URL':'http://example.invalid/check','NO_PROXY':'*'}
        processes=[spawn([agent,'--server',url,'--token',n['token'],'--interval','1'],f'agent-{n["id"]}.log',env) for n in nodes]
        def rows(task):
            with contextlib.closing(sqlite3.connect(root/'hub.db')) as db:return db.execute('SELECT node_id,latency FROM ping_record WHERE task_id=?',(task,)).fetchall()
        wait(lambda:set(n for n,_ in rows(vless))==set(ids) and set(n for n,_ in rows(hy2))==set(ids),'both authenticated nodes')
        assert all(lat>=0 for _,lat in rows(vless)),rows(vless)
        assert all(lat==-1 for _,lat in rows(hy2)),rows(hy2)
        api('ping-tasks',{'id':hy2,'name':'hy2','target':'proxy:hy2','interval':5,'nodes':[]})
        time.sleep(1);before=len(rows(hy2));time.sleep(6)
        assert len(rows(hy2))==before,'removed tasks still sampled'
        first=processes[0];first.terminate();first.wait(10)
        count=sum(n==ids[0] for n,_ in rows(vless));spawn([agent,'--server',url,'--token',nodes[0]['token'],'--interval','1'],'reconnect.log',env)
        wait(lambda:sum(n==ids[0] for n,_ in rows(vless))>count,'reconnected agent (minute batch flush)')
        req=urllib.request.Request(url+'/api/nodes')
        with urllib.request.urlopen(req) as response: assert all('token' not in n for n in json.load(response)['nodes'])
        print('proxy-e2e: two node identities, HTTP 503 loss, explicit proxy despite NO_PROXY, task removal, reconnect and public privacy passed')
if __name__=='__main__':main(*sys.argv[1:])
