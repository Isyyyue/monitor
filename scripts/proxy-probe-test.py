#!/usr/bin/env python3
"""Regression checks for the retained legacy sampler's identity and loss contract."""
from contextlib import closing
import importlib.util
import pathlib
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("probe", pathlib.Path(__file__).resolve().parents[1] / "probe/probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class ProbeTests(unittest.TestCase):
    def database(self, path=":memory:"):
        db = sqlite3.connect(path)
        db.executescript("CREATE TABLE ping_task(id INTEGER,target TEXT); CREATE TABLE ping_node(task_id INTEGER,node_id INTEGER); CREATE TABLE ping_record(node_id INTEGER,task_id INTEGER,ts INTEGER,latency INTEGER); INSERT INTO ping_task VALUES(8,'proxy:vless'),(9,'proxy:hy2'); INSERT INTO ping_node VALUES(8,10),(8,20),(9,20);")
        db.commit()
        return db

    def test_ambiguous_identity_is_never_guessed(self):
        with closing(self.database()) as db:
            self.assertIsNone(probe.node_for(db, 8, None))
            self.assertEqual(probe.node_for(db, 8, 20), 20)
            self.assertIsNone(probe.node_for(db, 8, 30))
            self.assertEqual(probe.node_for(db, 9, None), 20)
            self.assertIsNone(probe.node_for(db, 99, None))
            self.assertEqual(probe.task_id(db, 'vless', None), 8)

    def test_http_error_and_timeout_are_loss(self):
        for code, output, expected in [(0,'204 0.125',125),(0,'503 0.001',-1),(28,'000 15.000',-1),(0,'invalid',-1)]:
            with self.subTest(output=output), patch.object(probe.subprocess,'run',return_value=subprocess.CompletedProcess([],code,output,'')) as run:
                self.assertEqual(probe.test_proxy(18083),expected)
                args=run.call_args.args[0]
                self.assertEqual(args[args.index('--noproxy')+1],'')
                self.assertEqual(args[args.index('-x')+1],'http://127.0.0.1:18083')

    def test_failures_persist_without_holding_write_lock_during_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=str(pathlib.Path(tmp)/'probe.db')
            db=self.database(path); db.close()
            def measure(_port):
                # A second writer must succeed throughout every network measurement.
                with closing(sqlite3.connect(path,timeout=0)) as other:
                    other.execute("INSERT INTO ping_record VALUES(99,99,0,0)")
                    other.commit()
                return -1
            with patch.object(probe,'DB',path), patch.object(probe,'PROXIES', [('vless',18083,20,None),('hy2',18084,None,None),('vless',18085,None,None)]), patch.object(probe,'test_proxy',side_effect=measure), patch.object(probe.time,'sleep',side_effect=KeyboardInterrupt):
                with self.assertRaises(KeyboardInterrupt): probe.main()
            with closing(sqlite3.connect(path)) as check:
                self.assertEqual(check.execute('SELECT node_id,task_id,latency FROM ping_record WHERE task_id != 99 ORDER BY task_id').fetchall(),[(20,8,-1),(20,9,-1)])

if __name__ == '__main__': unittest.main()
