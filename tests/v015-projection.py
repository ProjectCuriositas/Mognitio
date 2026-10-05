#!/usr/bin/env python3
"""Large diagnostic projection and live coordinator responsiveness regressions."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import unittest
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools/lsp"))
from framing import encode
from projection import diagnostics_steps
from snapshot import position, position_steps
from server import Server

def drain(steps):
    while True:
        try:
            next(steps)
        except StopIteration as done:
            return done.value

def fixture():
    text = "x" * (3 * 1024 * 1024) + "\r\n日本😀e\u0301"
    start = len(text[:-1].encode("utf-8"))
    end = len(text.encode("utf-8"))
    item = {"path": "file:///sample.mgn", "start": start, "end": end,
            "phase": "parse", "message": "fixture", "related": [
                {"path": "file:///other.mgn", "start": 0, "end": 4, "message": "related"}]}
    return ({"root": None, "sources": {"file:///sample.mgn": text, "file:///other.mgn": "😀"}},
            {"diagnostics": [item] * 200, "tokens": {}})

def bare_server():
    server = Server.__new__(Server)
    server.state = "running"
    server.generation = 1
    server.snapshot, result = fixture()
    server.documents, server.pending, server.published = {}, {}, set()
    server.refresh = False
    server.mapping, server.modifier_mapping = {}, {}
    server.worker, server.retiring = None, []
    server.events = queue.Queue()
    server.memory = SimpleNamespace(check=lambda: None)
    server.sent = []
    server.send = server.sent.append
    server.accept(result)
    return server

class ProjectionTests(unittest.TestCase):
    def test_shared_offsets_multibyte_and_crlf(self):
        text = "日😀e\u0301\t\r\nabc\rz\n"
        offsets = [len(text[:i].encode()) for i in range(len(text) + 1)]
        actual = drain(position_steps(text, offsets))
        self.assertEqual(actual, {offset: position(text, offset) for offset in offsets})

    def test_large_result_is_linear_and_projection_quanta_are_bounded(self):
        server = bare_server()
        started = time.monotonic()
        turns = []
        while server.projection:
            before = time.monotonic()
            server.supervise()
            turns.append(time.monotonic() - before)
        elapsed = time.monotonic() - started
        published = [m for m in server.sent if m.get("method") == "textDocument/publishDiagnostics"]
        self.assertEqual(len(published), 1)
        diagnostics = published[0]["params"]["diagnostics"]
        self.assertEqual(len(diagnostics), 200)
        self.assertEqual(diagnostics[0]["range"], {"start": {"line": 1, "character": 5},
                                                  "end": {"line": 1, "character": 6}})
        self.assertEqual(diagnostics[0]["relatedInformation"][0]["location"]["range"]["end"]["character"], 2)
        self.assertGreater(len(turns), 1)
        self.assertLess(max(turns), 0.2)
        self.assertLess(elapsed, 3)
        print(f"Projection: 3 MiB / 200 diagnostics in {elapsed:.3f}s; max quantum={max(turns):.4f}s")

    def test_edit_invalidates_in_progress_projection(self):
        server = bare_server()
        server.supervise()
        self.assertIsNotNone(server.projection)
        server.changed()
        server.supervise()
        self.assertFalse(server.sent)
        self.assertIsNone(server.result)
        self.assertIsNone(server.projection)

    def test_projection_remains_inside_analysis_deadline(self):
        server = bare_server()
        steps, result, generation, _ = server.projection
        server.projection = (steps, result, generation, time.monotonic() - 1)
        server.pending = {50: "file:///sample.mgn"}
        server.supervise()
        while server.pending:
            server.supervise()
        self.assertIsNone(server.projection)
        self.assertTrue(any(m.get("method") == "window/showMessage" for m in server.sent))
        self.assertEqual(next(m for m in server.sent if m.get("id") == 50)["result"]["data"], [])

    def peer(self, parent=None):
        # Use the actual coordinator run loop; only the worker result is supplied by the fixture.
        script = """import runpy,sys
m=runpy.run_path(sys.argv[1])
class Observed(m['Server']):
 def advance_projection(self):
  super().advance_projection()
  if self.projection and not getattr(self,'announced',False):
   self.announced=True; self.notify('fixture/progress',{})
s=Observed(None,{'version':'0.15.0'})
s.initialize(1,{'rootUri':None,'processId':int(sys.argv[2]) if sys.argv[2]!='none' else None})
s.state='running'; s.snapshot,result=m['fixture'](); s.pending[50]='file:///sample.mgn'
s.accept(result)
raise SystemExit(s.run())
"""
        p = subprocess.Popen([sys.executable, "-c", script, str(Path(__file__).resolve()),
                              str(parent) if parent else "none"], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        messages = queue.Queue()
        def read():
            try:
                while True:
                    line = p.stdout.readline()
                    if not line:
                        return
                    length = int(line.split(b":", 1)[1])
                    self.assertEqual(p.stdout.readline(), b"\r\n")
                    messages.put(json.loads(p.stdout.read(length)))
            except Exception as error:
                messages.put(error)
        threading.Thread(target=read, daemon=True).start()
        self.addCleanup(lambda: self.cleanup(p))
        while messages.get(timeout=3).get("method") != "fixture/progress":
            pass
        return p, messages

    def cleanup(self, p):
        if p.poll() is None:
            p.kill()
        p.wait(timeout=3)
        for stream in (p.stdin, p.stdout, p.stderr):
            stream.close()

    def test_cancel_and_shutdown_are_processed_during_projection(self):
        p, messages = self.peer()
        started = time.monotonic()
        p.stdin.write(encode({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 50}}) +
                      encode({"jsonrpc": "2.0", "id": 51, "method": "shutdown"}))
        p.stdin.flush()
        received = []
        while not any(m.get("id") == 51 for m in received):
            received.append(messages.get(timeout=1))
        self.assertEqual(next(m for m in received if m.get("id") == 50)["error"]["code"], -32800)
        self.assertFalse(any(m.get("method") == "textDocument/publishDiagnostics" for m in received))
        self.assertLess(time.monotonic() - started, 1)
        p.stdin.write(encode({"jsonrpc": "2.0", "method": "exit"})); p.stdin.flush()
        self.assertEqual(p.wait(timeout=1), 0)

    def test_parent_disappearance_interrupts_projection(self):
        parent = subprocess.Popen(["sleep", "30"])
        try:
            p, messages = self.peer(parent.pid)
            parent.terminate(); parent.wait()
            self.assertEqual(p.wait(timeout=1), 1)
            received = []
            while not messages.empty():
                received.append(messages.get())
            self.assertFalse(any(m.get("method") == "textDocument/publishDiagnostics" for m in received))
        finally:
            if parent.poll() is None:
                parent.kill()
            parent.wait()

if __name__ == "__main__":
    unittest.main()
