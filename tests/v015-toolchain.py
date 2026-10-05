#!/usr/bin/env python3
"""Independent process, protocol, snapshot and identity regression checks."""
import argparse
import importlib.util
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

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools/lsp"))
from framing import Framer, FrameError, ParseError, encode
from snapshot import position, token_data, discover, InputError
PAYLOAD = None

class Peer:
    def __init__(self, root=None, parent=None, capabilities=None):
        self.process = subprocess.Popen([str(PAYLOAD / "bin/mognitio-lsp"), "--stdio"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.messages = queue.Queue()
        self.events = []
        def read():
            try:
                while True:
                    length = None
                    while True:
                        line = self.process.stdout.readline()
                        if not line:
                            self.messages.put(RuntimeError("server EOF"))
                            return
                        if line == b"\r\n":
                            break
                        key, value = line.split(b":", 1)
                        if key.lower() == b"content-length":
                            length = int(value)
                    self.messages.put(json.loads(self.process.stdout.read(length)))
            except Exception as error:
                self.messages.put(error)
        threading.Thread(target=read, daemon=True).start()
        self.send({"id": 1, "method": "initialize", "params": {
            "rootUri": root.as_uri() if root else None, "processId": parent,
            "capabilities": capabilities or {}}})
        self.initialize = self.wait(lambda m: m.get("id") == 1)
        self.send({"method": "initialized", "params": {}})

    def send(self, msg):
        self.process.stdin.write(encode({"jsonrpc": "2.0", **msg}))
        self.process.stdin.flush()

    def wait(self, predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(value, Exception):
                raise value
            self.events.append(value)
            if predicate(value):
                return value
        raise TimeoutError("Expected protocol event")

    def open(self, uri, text, version=1):
        self.send({"method": "textDocument/didOpen", "params": {"textDocument": {
            "uri": uri, "languageId": "mognitio", "version": version, "text": text}}})

    def change(self, uri, text, version):
        self.send({"method": "textDocument/didChange", "params": {"textDocument": {
            "uri": uri, "version": version}, "contentChanges": [{"text": text}]}})

    def tokens(self, uri, id=20):
        self.send({"id": id, "method": "textDocument/semanticTokens/full", "params": {"textDocument": {"uri": uri}}})
        return self.wait(lambda m: m.get("id") == id)

    def close(self):
        if self.process.poll() is None:
            self.send({"id": 999, "method": "shutdown"})
            self.wait(lambda m: m.get("id") == 999)
            self.send({"method": "exit"})
        code = self.process.wait(timeout=5)
        error = self.process.stderr.read().decode()
        if code != 0:
            raise AssertionError((code, error))

class FramingTests(unittest.TestCase):
    def test_utf8_fragmented_and_concatenated(self):
        f = Framer()
        wire = encode({"jsonrpc": "2.0", "method": "日本語"})
        values = []
        for byte in wire + wire:
            values.extend(f.feed(bytes([byte])))
        self.assertEqual(len(values), 2)
        self.assertIsNone(f.progress)

    def test_parse_error_resynchronizes(self):
        f = Framer()
        values = f.feed(b"Content-Length: 1\r\n\r\n{" + encode({"id": 3}))
        self.assertIsInstance(values[0], ParseError)
        self.assertEqual(values[1], {"id": 3})

    def test_invalid_lengths_and_stalls(self):
        for wire in [b"Content-Length: -1\r\n\r\n", b"Content-Length: 1\r\nContent-Length: 1\r\n\r\n",
                     b"Content-Length: 33554433\r\n\r\n", b"x" * 16385]:
            with self.assertRaises(FrameError):
                Framer().feed(wire)
        f = Framer()
        f.feed(b"C")
        f.progress -= 5.1
        with self.assertRaises(FrameError):
            f.check_deadline()
        f = Framer()
        f.feed(b"Content-Length: 9\r\n\r\n")
        f.progress -= 10.1
        with self.assertRaises(FrameError):
            f.check_deadline()
        idle = Framer()
        idle.check_deadline()

    def test_utf16_positions(self):
        text = "日本😀e\u0301\t\r\nabc\rz"
        self.assertEqual(position(text, len("日本😀e\u0301\t".encode())), {"line": 0, "character": 7})
        self.assertEqual(position(text, len("日本😀e\u0301\t\r\nab".encode())), {"line": 1, "character": 2})
        self.assertEqual(position(text, len(text.encode())), {"line": 2, "character": 1})

class SupervisionTests(unittest.TestCase):
    def test_unacknowledged_cancel_is_bounded(self):
        from server import Server
        from types import SimpleNamespace
        child = subprocess.Popen([sys.executable, "-c",
            "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(30)"],
            stdout=subprocess.PIPE)
        self.assertEqual(child.stdout.readline().strip(), b"ready")
        server = Server.__new__(Server)
        server.worker = (child, 1, time.monotonic())
        server.retiring = []
        server.events = queue.Queue()
        server.memory = SimpleNamespace(check=lambda: None)
        started = time.monotonic()
        server.cancel_worker()
        try:
            with self.assertRaisesRegex(RuntimeError, "cancellation deadline"):
                while time.monotonic() - started < 1.5:
                    server.supervise()
                    time.sleep(0.01)
            self.assertLess(time.monotonic() - started, 1.3)
            child.wait(timeout=1)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            child.stdout.close()

class ToolchainTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="mognitio-lsp-test-")
        self.root = Path(self.directory.name)
        (self.root / "src").mkdir()
        (self.root / "mognitio.toml").write_text('[project]\nname="sample"\nroot_namespace="Example"\n')
        self.uri = (self.root / "src/sample.mgn").as_uri()
        (self.root / "src/sample.mgn").write_text("namespace Example;\nlet value: Int = 1;\n")
        self.peers = []

    def tearDown(self):
        for peer in self.peers:
            if peer.process.poll() is None:
                peer.close()
            for stream in (peer.process.stdin, peer.process.stdout, peer.process.stderr):
                stream.close()
        self.directory.cleanup()

    def peer(self, root=True, **kwargs):
        p = Peer(self.root if root else None, **kwargs)
        self.peers.append(p)
        return p

    def test_identity_and_entry_independent_profile(self):
        identity = json.loads((PAYLOAD / "identity.json").read_text())
        for tool in ["mgn", "mognitio-lsp"]:
            result = subprocess.run([str(PAYLOAD / "bin" / tool), "--version"], capture_output=True, text=True, cwd="/")
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, tool + " " + identity["version"] + "\n")
            self.assertEqual(result.stderr, "")
        p = self.peer()
        self.assertEqual(p.initialize["result"]["serverInfo"]["version"], identity["version"])
        response = p.tokens(self.uri)
        self.assertGreater(len(response["result"]["data"]), 0)

    def test_unsaved_error_and_correction(self):
        p = self.peer()
        p.open(self.uri, "namespace Example;\nlet value: Int = false;\n")
        diagnostic = p.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"].get("version") == 1)
        self.assertTrue(diagnostic["params"]["diagnostics"])
        p.change(self.uri, "namespace Example;\nlet value: Int = 2;\n", 2)
        corrected = p.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"].get("version") == 2)
        self.assertEqual(corrected["params"]["diagnostics"], [])

    def test_invalid_unicode_does_not_restore_disk(self):
        p = self.peer()
        p.open(self.uri, "namespace Example;\nlet value: Int = 1;\n")
        p.tokens(self.uri)
        p.change(self.uri, "\ud800", 2)
        self.assertEqual(p.tokens(self.uri, 21)["result"]["data"], [])
        p.change(self.uri, "namespace Example;\nlet value: Int = 2;\n", 3)
        self.assertTrue(p.tokens(self.uri, 22)["result"]["data"])

    def test_invalid_rootless_file_does_not_hide_other_files(self):
        p = self.peer(root=False)
        (self.root / "other.mgn").write_text("let value: Int = 1;")
        other = (self.root / "other.mgn").as_uri()
        p.open(self.uri, "let value: Int = 1;")
        p.open(other, "let other: Int = 2;")
        self.assertTrue(p.tokens(other)["result"]["data"])
        p.change(self.uri, "\\ud800", 2)
        self.assertEqual(p.tokens(self.uri, 21)["result"]["data"], [])
        self.assertTrue(p.tokens(other, 22)["result"]["data"])

    def test_stale_version_ignored(self):
        p = self.peer()
        p.open(self.uri, "namespace Example;\nlet value: Int = 1;\n", 4)
        self.assertTrue(p.tokens(self.uri)["result"]["data"])
        p.change(self.uri, "broken", 3)
        self.assertTrue(p.tokens(self.uri, 21)["result"]["data"])

    def test_rootless_independence_and_incomplete_recovery(self):
        p = self.peer(root=False)
        p.open(self.uri, 'let value: String = "unfinished')
        p.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["diagnostics"])
        (self.root / "other.mgn").write_text("let value: Int = 1;")
        other = (self.root / "other.mgn").as_uri()
        p.open(other, "let value: Int = 1;")
        self.assertTrue(p.tokens(other)["result"]["data"])
        p.change(self.uri, 'let value: String = "fixed";', 2)
        p.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == self.uri and m["params"].get("version") == 2)
        self.assertTrue(p.tokens(self.uri, 21)["result"]["data"])

    def test_invalid_initialize_shapes_allow_a_corrected_request(self):
        for capabilities in (["bad"], {"workspace": []}, {"textDocument": None},
                             {"general": {"positionEncodings": 42}},
                             {"textDocument": {"semanticTokens": {"tokenTypes": "variable"}}}):
            p = self.peer(capabilities=capabilities)
            self.assertEqual(p.initialize["error"]["code"], -32602)
            p.send({"id": 2, "method": "initialize", "params": {
                "rootUri": self.root.as_uri(), "processId": os.getpid(), "capabilities": {}}})
            self.assertIn("result", p.wait(lambda m: m.get("id") == 2))
            p.send({"method": "initialized", "params": {}})
            self.assertTrue(p.tokens(self.uri)["result"]["data"])

    def test_initialize_retry_replaces_all_negotiated_mappings(self):
        p = self.peer(parent=-1)
        self.assertEqual(p.initialize["error"]["code"], -32602)
        p.send({"id": 2, "method": "initialize", "params": {
            "rootUri": self.root.as_uri(), "processId": None,
            "capabilities": {"textDocument": {"semanticTokens": {
                "tokenTypes": ["variable"], "tokenModifiers": []}}}}})
        result = p.wait(lambda m: m.get("id") == 2)["result"]
        legend = result["capabilities"]["semanticTokensProvider"]["legend"]
        self.assertEqual(legend, {"tokenTypes": ["variable"], "tokenModifiers": []})
        p.send({"method": "initialized", "params": {}})
        data = p.tokens(self.uri)["result"]["data"]
        self.assertTrue(data)
        self.assertTrue(all(kind == 0 for kind in data[3::5]))
        self.assertTrue(all(modifier == 0 for modifier in data[4::5]))

    def test_missing_manifest_syntax_and_project_transitions(self):
        manifest = self.root / "mognitio.toml"
        valid = manifest.read_text()
        manifest.unlink()
        p = self.peer()
        p.open(self.uri, 'let value: String = "unfinished')
        p.tokens(self.uri)
        self.assertTrue(any(m.get("method") == "textDocument/publishDiagnostics"
                            and m["params"]["uri"] == self.uri and m["params"]["diagnostics"]
                            for m in p.events))
        p.change(self.uri, "namespace Example;\nlet value: Int = false;", 2)
        p.tokens(self.uri, 21)
        latest = [m["params"] for m in p.events if m.get("method") == "textDocument/publishDiagnostics"
                  and m["params"]["uri"] == self.uri][-1]
        self.assertEqual(latest["diagnostics"], [])
        for index, contents in enumerate((valid, None, valid, "[project]\nname = 123\n", valid)):
            if contents is None:
                manifest.unlink()
            else:
                manifest.write_text(contents)
            p.send({"method": "workspace/didChangeWatchedFiles", "params": {
                "changes": [{"uri": manifest.as_uri(), "type": 2}]}})
            p.tokens(self.uri, 30 + index)
            latest = [m["params"] for m in p.events if m.get("method") == "textDocument/publishDiagnostics"
                      and m["params"]["uri"] == self.uri][-1]
            self.assertEqual(bool(latest["diagnostics"]), contents == valid)
        self.assertTrue(any(m.get("method") == "textDocument/publishDiagnostics"
                            and m["params"]["uri"] == manifest.as_uri() and m["params"]["diagnostics"]
                            for m in p.events))

    def test_syntax_input_kinds_and_isolation(self):
        link = self.root / "link.mgn"
        link.symlink_to(self.root / "src/sample.mgn")
        fifo = self.root / "fifo.mgn"
        os.mkfifo(fifo)
        directory = self.root / "directory.mgn"
        directory.mkdir()
        parent = self.root / "linked-directory"
        parent.symlink_to(self.root / "src", target_is_directory=True)
        uris = [p.as_uri() for p in (link, fifo, directory, parent / "sample.mgn")]
        p = self.peer(root=False)
        for uri in [self.uri, *uris]:
            p.open(uri, "let value: Int = 1;")
        self.assertTrue(p.tokens(self.uri)["result"]["data"])
        for index, uri in enumerate(uris):
            self.assertEqual(p.tokens(uri, 30 + index)["result"]["data"], [])
        documents = {uri: {"version": 1, "text": "let value: Int = 1;"} for uri in [self.uri, *uris]}
        result = discover(None, documents)
        self.assertEqual(set(result["sources"]), {self.uri})
        self.assertEqual(set(result["unavailable"]), set(uris))
        (self.root / "mognitio.toml").unlink()
        (self.root / "src/link.mgn").symlink_to("sample.mgn")
        docs = {**documents, (self.root / "src/link.mgn").as_uri(): {"version": 1, "text": "let x: Int = 1;"}}
        result = discover(str(self.root), docs)
        self.assertEqual(set(result["sources"]), {self.uri})
        self.assertIn((self.root / "src/link.mgn").as_uri(), result["unavailable"])

    def test_manifest_access_error_is_not_missing(self):
        from unittest.mock import patch
        original = Path.lstat
        def inspect(path, *args, **kwargs):
            if path.name == "mognitio.toml":
                raise PermissionError("fixture")
            return original(path, *args, **kwargs)
        with patch.object(Path, "lstat", inspect):
            with self.assertRaisesRegex(InputError, "Cannot inspect workspace"):
                discover(str(self.root), {self.uri: {"version": 1, "text": "let x: Int = 1;"}})

    def test_protocol_errors_and_notifications(self):
        p = self.peer()
        p.send({"id": 30, "method": "unknown"})
        self.assertEqual(p.wait(lambda m: m.get("id") == 30)["error"]["code"], -32601)
        p.process.stdin.write(b"Content-Length: 1\r\n\r\n{")
        p.process.stdin.flush()
        self.assertEqual(p.wait(lambda m: m.get("id", 1) is None)["error"]["code"], -32700)
        p.send({"method": "textDocument/didOpen", "params": {"textDocument": {"uri": "untitled:test", "version": 1, "text": "bad"}}})
        p.send({"id": 31, "method": "unknown"})
        self.assertEqual(p.wait(lambda m: m.get("id") == 31)["error"]["code"], -32601)
        self.assertFalse(any(m.get("id") is None and m.get("error", {}).get("code") == -32602 for m in p.events))

    def test_cancel_request_once(self):
        p = self.peer()
        p.send({"id": 41, "method": "textDocument/semanticTokens/full", "params": {"textDocument": {"uri": self.uri}}})
        p.send({"method": "$/cancelRequest", "params": {"id": 41}})
        answer = p.wait(lambda m: m.get("id") == 41)
        self.assertEqual(answer["error"]["code"], -32800)
        p.tokens(self.uri, 42)
        self.assertEqual(sum(m.get("id") == 41 for m in p.events), 1)

    def test_live_session_survives_old_payload_reclamation(self):
        global PAYLOAD
        import shutil
        original = PAYLOAD
        copied = self.root / "old-payload"
        shutil.copytree(original, copied)
        try:
            PAYLOAD = copied
            p = self.peer()
            before = p.initialize["result"]["serverInfo"]["version"]
            self.assertTrue(p.tokens(self.uri)["result"]["data"])
            shutil.rmtree(copied)
            p.open(self.uri, "namespace Example;\nlet value: Int = false;\n")
            result = p.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"].get("version") == 1)
            self.assertTrue(result["params"]["diagnostics"])
            p.change(self.uri, "namespace Example;\nlet value: Int = 2;\n", 2)
            corrected = p.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"].get("version") == 2)
            self.assertEqual(corrected["params"]["diagnostics"], [])
            self.assertTrue(p.tokens(self.uri, 24)["result"]["data"])
            self.assertEqual(before, json.loads((original / "identity.json").read_text())["version"])
        finally:
            PAYLOAD = original

    def test_component_mismatch(self):
        import shutil
        copy = self.root / "payload"
        shutil.copytree(PAYLOAD, copy)
        identity = json.loads((copy / "identity.json").read_text())
        identity["version"] = "0.15.99"
        (copy / "identity.json").write_text(json.dumps(identity))
        for tool in ["mgn", "mognitio-lsp"]:
            result = subprocess.run([str(copy / "bin" / tool), "--version"], capture_output=True)
            self.assertEqual(result.returncode, 3)
            self.assertEqual(result.stdout, b"")

    def test_parent_disappearance_and_null_eof(self):
        parent = subprocess.Popen(["sleep", "30"])
        p = self.peer(parent=parent.pid)
        parent.terminate()
        parent.wait()
        self.assertEqual(p.process.wait(timeout=5), 1)
        p = self.peer(parent=None)
        p.process.stdin.close()
        self.assertEqual(p.process.wait(timeout=5), 1)

    def test_source_limits_and_links(self):
        with self.assertRaises(InputError):
            discover(str(self.root), {self.uri: {"text": None, "version": 1}})
        (self.root / "src/link.mgn").symlink_to("sample.mgn")
        with self.assertRaises(InputError):
            discover(str(self.root), {})

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    PAYLOAD = args.payload.resolve()
    unittest.main(argv=[sys.argv[0], *remaining])
