#!/usr/bin/env python3
"""Exact resource boundaries and delayed worker-event acceptance fixtures."""
import importlib.util
import json
from pathlib import Path
import queue
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools/lsp"))
from framing import Framer, FrameError, MAX_HEADER, MAX_BODY
from snapshot import discover, valid_text, InputError, SOURCE_BYTES
from projection import diagnostics_steps
from server import Server

def drain(iterator):
    while True:
        try:
            next(iterator)
        except StopIteration as result:
            return result.value

class BoundaryTests(unittest.TestCase):
    def test_exact_header_and_body_limits(self):
        first = b"Content-Length: 2\r\nX-Pad: "
        header = first + b"x" * (MAX_HEADER-len(first)-4) + b"\r\n\r\n"
        self.assertEqual(Framer().feed(header+b"{}"), [{}])
        with self.assertRaises(FrameError):
            Framer().feed(header[:-4]+b"x\r\n\r\n{}")
        body = b'{"x":"' + b"x"*(MAX_BODY-8) + b'"}'
        self.assertEqual(len(body), MAX_BODY)
        self.assertEqual(len(Framer().feed(b"Content-Length: "+str(len(body)).encode()+b"\r\n\r\n"+body)[0]["x"]), MAX_BODY-8)
        with self.assertRaises(FrameError):
            Framer().feed(b"Content-Length: "+str(MAX_BODY+1).encode()+b"\r\n\r\n")

    def test_exact_stall_deadlines_and_progress_reset(self):
        for partial, limit in [(b"C",5),(b"Content-Length: 3\r\n\r\n",10)]:
            f=Framer()
            with patch("framing.time.monotonic", return_value=100):
                f.feed(partial)
            with patch("framing.time.monotonic", return_value=100+limit-0.001):
                f.check_deadline()
            with patch("framing.time.monotonic", return_value=100+limit):
                with self.assertRaises(FrameError):f.check_deadline()
            with patch("framing.time.monotonic", return_value=100+limit):
                f.feed(b"x")
                f.check_deadline()

    def test_source_bytes_and_overlay_project_replacement(self):
        text="x"*SOURCE_BYTES
        self.assertEqual(valid_text(text),text)
        with self.assertRaises(InputError):valid_text(text+"x")
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/"src").mkdir();(root/"mognitio.toml").write_text("[project]")
            for i in range(16):(root/"src"/f"{i:02}.mgn").write_text(text)
            self.assertEqual(len(discover(str(root),{})["sources"]),16)
            target=root/"src/00.mgn"
            result=discover(str(root),{target.as_uri():{"text":"short","version":2}})
            self.assertEqual(result["sources"]["src/00.mgn"],"short")
            (root/"src/extra.mgn").write_text("x")
            with self.assertRaises(InputError):discover(str(root),{})
            self.assertEqual(len(discover(str(root),{target.as_uri():{"text":"short","version":2}})["sources"]),17)

    def test_source_count_and_depth_boundaries(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);src=root/"src";src.mkdir();(root/"mognitio.toml").write_text("[project]")
            for i in range(4096):(src/f"{i}.mgn").touch()
            self.assertEqual(len(discover(str(root),{})["sources"]),4096)
            extra=src/"extra.mgn";extra.touch()
            with self.assertRaises(InputError):discover(str(root),{})
            extra.unlink()
            deep=src
            for i in range(64):deep=deep/"d";deep.mkdir()
            discover(str(root),{})
            (deep/"d").mkdir()
            with self.assertRaises(InputError):discover(str(root),{})

    def test_exploration_entry_and_time_boundaries(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);src=root/"src";src.mkdir();(root/"mognitio.toml").write_text("[project]")
            # Actual directory entries, including ignored non-source files.
            for i in range(65535):(src/str(i)).touch()
            discover(str(root),{})
            (src/"extra").touch()
            with self.assertRaises(InputError):discover(str(root),{})
            with patch("snapshot.time.monotonic", side_effect=[100,105]):
                with self.assertRaises(InputError):discover(str(root),{})

    def test_diagnostic_caps_and_deterministic_notice(self):
        for files,per_file,expected in [(1,200,200),(1,201,200),(10,200,2000),(11,200,2000)]:
            sources={f"file:///{i}.mgn":"x" for i in range(files)}
            diagnostics=[{"path":name,"start":0,"end":1,"phase":"type","message":str(i)}
                         for name in sources for i in range(per_file)]
            snapshot={"root":None,"sources":sources}
            result={"diagnostics":diagnostics}
            first=drain(diagnostics_steps(snapshot,result))
            self.assertEqual(first,drain(diagnostics_steps(snapshot,result)))
            groups,messages=first
            self.assertEqual(sum(map(len,groups.values())),expected)
            self.assertEqual(bool(messages),files*per_file>expected)

    def test_old_worker_completion_after_dependency_edit_is_discarded(self):
        server=Server.__new__(Server)
        server.root=None;server.state="running";server.generation=5;server.worker=None;server.retiring=[]
        server.projection=None;server.token_job=None;server.token_cache={};server.result=None
        server.pending={};server.events=queue.Queue();server.memory=SimpleNamespace(check=lambda:None)
        a,b="file:///a.mgn","file:///b.mgn"
        server.documents={a:{"version":5,"text":"a"},b:{"version":2,"text":"b"}}
        server.sent=[];server.send=server.sent.append
        old=SimpleNamespace(returncode=0)
        server.worker=(old,5,time.monotonic())
        old.terminate=lambda:None;old.poll=lambda:0
        server.document("textDocument/didChange",{"textDocument":{"uri":b,"version":3},"contentChanges":[{"text":"new b"}]})
        self.assertEqual(server.documents[a]["version"],5)
        current=SimpleNamespace(returncode=0)
        server.worker=(current,6,time.monotonic())
        server.snapshot={"root":None,"sources":{a:"a",b:"new b"}}
        server.mapping={};server.modifier_mapping={};server.published=set();server.refresh=False
        accepted={"diagnostics":[],"tokens":{}}
        # Old failure would terminate the coordinator if erroneously accepted.
        old.returncode=1
        server.events.put((old,5,"invalid old result","old failure"))
        server.events.put((current,6,json.dumps(accepted),""))
        for _ in range(5):server.supervise()
        self.assertEqual(server.result,accepted)
        self.assertTrue(all(not m["params"]["diagnostics"] for m in server.sent))
        self.assertEqual(server.documents[b]["version"],3)


    def test_syntax_depth_exactly_256_and_257(self):
        import os
        import subprocess
        payload=Path(os.environ["MOGNITIO_TEST_PAYLOAD"])
        for unary_count,complete in [(253,True),(254,False)]:
            # The syntax walk includes program/declaration wrappers as well as unary nodes.
            text="let value: Int = "+"-"*unary_count+"1;"
            snapshot={"root":None,"sources":{"sample.mgn":text}}
            p=subprocess.run([str(payload/"runtime/sbcl"),"--core",str(payload/"runtime/mognitio.core"),
                "--noinform","--no-sysinit","--no-userinit","--mognitio-worker"],
                input=json.dumps(snapshot),capture_output=True,text=True,timeout=12)
            self.assertEqual(p.returncode,0,p.stderr)
            result=json.loads(p.stdout);self.assertEqual(result["complete"],complete)
            if not complete:self.assertTrue(any("Syntax nesting budget exceeded" in d["message"] for d in result["diagnostics"]))


    def test_oversized_full_change_clears_old_results_and_recovers(self):
        import os
        spec=importlib.util.spec_from_file_location("toolchain_fixture",Path(__file__).with_name("v015-toolchain.py"))
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        module.PAYLOAD=Path(os.environ["MOGNITIO_TEST_PAYLOAD"])
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"sample.mgn";path.write_text("let value: Int = 1;")
            peer=module.Peer()
            try:
                peer.open(path.as_uri(),path.read_text(),1)
                self.assertTrue(peer.tokens(path.as_uri())["result"]["data"])
                peer.change(path.as_uri(),"x"*(SOURCE_BYTES+1),2)
                self.assertEqual(peer.tokens(path.as_uri(),21)["result"]["data"],[])
                peer.change(path.as_uri(),"let value: Int = 2;",3)
                self.assertTrue(peer.tokens(path.as_uri(),22)["result"]["data"])
            finally:
                peer.close()
                for stream in (peer.process.stdin,peer.process.stdout,peer.process.stderr):stream.close()

if __name__=="__main__":unittest.main()
