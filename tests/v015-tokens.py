#!/usr/bin/env python3
"""Semantic projection tests; live loop with real inputs and injected worker rows."""
import json
import os
from pathlib import Path
import queue
import select
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(os.environ.get("MOGNITIO_TEST_SOURCE", Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(ROOT / "tools/lsp"))
import server as coordinator
from framing import encode
from snapshot import discover
import snapshot
token_steps = getattr(snapshot, "token_steps", None)
from server import Server

def drain(steps):
    while True:
        try:
            next(steps)
        except StopIteration as done:
            return done.value

def fixture_peer(where, parent):
    # Both revisions run the production input loop. Only compiler output is injected.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "src").mkdir()
        (root / "mognitio.toml").write_text('[package]\nname = "fixture"\n')
        size = 3 * 1024 * 1024
        text = "let //" + "x" * (size - 6) if where == "front" else "//" + "x" * (size - 6) + "\nlet"
        for i in range(16):
            (root / "src" / f"{i:02}.mgn").write_text(text)
        snapshot = discover(str(root), {})
        assert len(snapshot["sources"]) == 16
        assert sum(len(s.encode()) for s in snapshot["sources"].values()) == 48 * 1024 * 1024
        class FixtureServer(Server):
            def run_analysis(self):
                self.dirty = False
        server = FixtureServer(None, {"version": "0.15.0"})
        server.initialize(1, {"rootUri": root.as_uri(), "processId": parent})
        server.state = "running"
        server.snapshot = snapshot
        start = 0 if where == "front" else size - 3
        result = {"diagnostics": [], "tokens": {key: [[start, start + 3, 10, 0]]
                                              for key in snapshot["sources"]}}
        for i, key in enumerate(snapshot["sources"]):
            server.pending[50 + i] = (root / key).as_uri()
        name = "token_steps" if hasattr(coordinator, "token_steps") else "token_data"
        original = getattr(coordinator, name)
        announced = False
        def observe(*args, **kwargs):
            nonlocal announced
            if not announced:
                announced = True
                server.notify("fixture/progress", {})
                # Ensure the control event is queued at the conversion boundary.
                watched = [0] + ([server.parent_fd] if server.parent_fd is not None else [])
                if not select.select(watched, [], [], 3)[0]:
                    raise RuntimeError("Fixture control event was not supplied")
            return original(*args, **kwargs)
        setattr(coordinator, name, observe)
        server.accept(result)
        return server.run()

class TokenTests(unittest.TestCase):
    def test_utf16_rows_and_modifiers(self):
        text = "日😀e\u0301\t\r\nlet x"
        rows = [[0, 3, 0, 1], [3, 7, 1, 6], [7, 10, 1, 0],
                [len(text[:-5].encode()), len(text[:-2].encode()), 10, 0]]
        data = drain(token_steps(text, rows, {0: 2, 1: 0, 10: 1}, {1: 2, 4: 1}))
        self.assertEqual(data, [0, 0, 1, 2, 2, 0, 1, 2, 0, 1, 0, 2, 2, 0, 0,
                                1, 0, 3, 1, 0])

    def test_front_offsets_stop_before_unused_tail(self):
        steps = token_steps("let //" + "x" * (3 * 1024 * 1024), [[0, 3, 10, 0]], {10: 0})
        with self.assertRaises(StopIteration) as done:
            next(steps)
        self.assertEqual(done.exception.value, [0, 0, 3, 0, 0])

    def test_cache_shared_and_generation_invalidates(self):
        server = Server.__new__(Server)
        server.state, server.generation, server.worker = "running", 1, None
        server.snapshot = {"root": None, "sources": {"file:///a.mgn": "//" + "x" * 100000 + "\nlet"}}
        server.mapping, server.modifier_mapping = {10: 0}, {}
        server.sent = []
        server.send = server.sent.append
        server.pending = {1: "file:///a.mgn", 2: "file:///a.mgn"}
        server.accept({"diagnostics": [], "tokens": {"file:///a.mgn": [[100003, 100006, 10, 0]]}})
        server.result = server.projection[1]
        with patch.object(coordinator, "token_steps", wraps=token_steps) as conversion:
            while server.pending:
                server.advance_tokens()
            self.assertEqual(conversion.call_count, 1)
        self.assertEqual(server.sent[0]["result"], server.sent[1]["result"])
        server.changed()
        self.assertEqual(server.token_cache, {})
        self.assertIsNone(server.token_job)

    def test_cancel_discards_in_progress_job_and_deadline_is_bounded(self):
        server = Server.__new__(Server)
        server.state, server.generation = "running", 1
        server.snapshot = {"root": None, "sources": {"file:///a.mgn": "x" * (3 * 1024 * 1024)}}
        server.mapping, server.modifier_mapping = {10: 0}, {}
        server.sent, server.pending = [], {1: "file:///a.mgn"}
        server.send = server.sent.append
        server.accept({"diagnostics": [], "tokens": {"file:///a.mgn": [[3000000, 3000003, 10, 0]]}})
        server.result = server.projection[1]
        server.advance_tokens()
        self.assertIsNotNone(server.token_job)
        server.message({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 1}})
        server.advance_tokens()
        self.assertIsNone(server.token_job)
        self.assertEqual(server.sent[0]["error"]["code"], -32800)
        server.pending[2] = "file:///a.mgn"
        server.advance_tokens()
        uri, generation, steps, _ = server.token_job
        server.token_job = (uri, generation, steps, time.monotonic() - 1)
        server.advance_tokens()
        server.advance_tokens()
        self.assertEqual(server.sent[-1]["result"]["data"], [])

    def peer(self, where, parent=None):
        p = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--peer", where,
                              str(parent) if parent else "none"], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.cleanup, p)
        messages = queue.Queue()
        def read():
            while line := p.stdout.readline():
                length = int(line.split(b":", 1)[1])
                assert p.stdout.readline() == b"\r\n"
                messages.put(json.loads(p.stdout.read(length)))
        threading.Thread(target=read, daemon=True).start()
        while messages.get(timeout=5).get("method") != "fixture/progress":
            pass
        return p, messages

    @staticmethod
    def cleanup(p):
        if p.poll() is None:
            p.kill()
        p.wait(timeout=3)
        for stream in (p.stdin, p.stdout, p.stderr):
            stream.close()

    def test_live_cancel_shutdown_front_and_tail(self):
        for where in ("front", "tail"):
            with self.subTest(where=where):
                p, messages = self.peer(where)
                started = time.monotonic()
                p.stdin.write(encode({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 65}}) +
                              encode({"jsonrpc": "2.0", "id": 99, "method": "shutdown"}))
                p.stdin.flush()
                received = []
                while not any(m.get("id") == 99 for m in received):
                    received.append(messages.get(timeout=1))
                elapsed = time.monotonic() - started
                print(f"16 x 3 MiB {where} token cancel/shutdown: {elapsed:.4f}s")
                self.assertEqual(next(m for m in received if m.get("id") == 65).get("error", {}).get("code"), -32800)
                self.assertLess(elapsed, 1)
                p.stdin.write(encode({"jsonrpc": "2.0", "method": "exit"})); p.stdin.flush()
                self.assertEqual(p.wait(timeout=1), 0)

    def test_live_edit_abandons_tail_conversion(self):
        p, messages = self.peer("tail")
        p.stdin.write(encode({"jsonrpc": "2.0", "method": "workspace/didChangeWatchedFiles", "params": {}}) +
                      encode({"jsonrpc": "2.0", "id": 99, "method": "shutdown"}))
        p.stdin.flush()
        received = []
        while not any(m.get("id") == 99 for m in received):
            received.append(messages.get(timeout=1))
        replies = [m for m in received if isinstance(m.get("id"), int) and 50 <= m["id"] <= 65]
        self.assertEqual(len(replies), 16)
        self.assertTrue(all(m.get("error", {}).get("code") == -32801 for m in replies))
        p.stdin.write(encode({"jsonrpc": "2.0", "method": "exit"})); p.stdin.flush()
        self.assertEqual(p.wait(timeout=1), 0)

    def test_live_parent_exit_interrupts_tail_conversion(self):
        parent = subprocess.Popen(["sleep", "30"])
        try:
            p, messages = self.peer("tail", parent.pid)
            parent.terminate(); parent.wait()
            self.assertEqual(p.wait(timeout=1), 1)
            self.assertFalse(any(m.get("result", {}).get("data") for m in list(messages.queue)))
        finally:
            if parent.poll() is None:
                parent.kill()
            parent.wait()

if __name__ == "__main__":
    if sys.argv[1:2] == ["--peer"]:
        raise SystemExit(fixture_peer(sys.argv[2], None if sys.argv[3] == "none" else int(sys.argv[3])))
    unittest.main()
