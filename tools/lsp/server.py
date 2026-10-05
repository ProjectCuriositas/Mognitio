#!/usr/bin/env python3
"""LSP coordinator. Compiler work runs in an isolated, bounded Lisp worker."""
import hashlib
import json
import os
from pathlib import Path
import queue
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from framing import Framer, FrameError, ParseError, encode
from snapshot import InputError, discover, path_from_uri, uri_from_path, valid_text, position, token_data

TYPES = ["namespace", "type", "interface", "typeParameter", "function", "variable",
         "parameter", "property", "method", "enumMember", "keyword"]
MODIFIERS = ["declaration", "readonly", "defaultLibrary"]
FALLBACK = {"interface": "type", "typeParameter": "type", "function": "variable",
            "parameter": "variable", "property": "variable", "method": "function",
            "enumMember": "variable", "namespace": "variable"}

from payload import payload_identity
from budget import MemoryBudget

class Server:
    def __init__(self, payload, identity):
        self.payload, self.identity = payload, identity
        self.state, self.root = "created", None
        self.documents, self.pending, self.result, self.published = {}, {}, None, set()
        self.generation = 0
        self.dirty = False
        self.worker = None
        self.retiring = []
        self.events = queue.Queue()
        self.snapshot = None
        self.refresh = False
        self.refresh_id = 0
        self.mapping = {}
        self.modifier_mapping = {}
        self.parent_fd = None
        self.selector = selectors.DefaultSelector()
        self.selector.register(0, selectors.EVENT_READ, "input")
        self.framer = Framer()
        self.memory = MemoryBudget()
        self.log("Memory enforcement: " + ("cgroup hard limit" if self.memory.group else "best-effort process-tree RSS"))

    def send(self, value):
        sys.stdout.buffer.write(encode(value))
        sys.stdout.buffer.flush()

    def response(self, id, result=None, error=None):
        self.send({"jsonrpc": "2.0", "id": id, **({"error": error} if error else {"result": result})})

    def error(self, id, code, message):
        self.response(id, error={"code": code, "message": message})

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def log(self, message):
        print("mognitio-lsp: " + message, file=sys.stderr, flush=True)

    def initialize(self, id, params):
        if self.state != "created":
            self.error(id, -32600, "Already initialized")
            return
        root = params.get("rootUri")
        root = path_from_uri(root) if root is not None else None
        folders = params.get("workspaceFolders")
        if folders is not None and not isinstance(folders, list):
            raise InputError("Workspace folders must be an array or null")
        if folders:
            if not isinstance(folders, list) or len(folders) != 1 or path_from_uri(folders[0]["uri"]) != root:
                raise InputError("One workspace folder matching rootUri is required")
        if root is not None and not os.path.isdir(root):
            raise InputError("Workspace root is not a directory")
        caps = params.get("capabilities", {})
        def object_member(value, key):
            member = value.get(key, {})
            if not isinstance(member, dict):
                raise InputError("Capability " + key + " must be an object")
            return member
        if not isinstance(caps, dict):
            raise InputError("Capabilities must be an object")
        document_caps = object_member(caps, "textDocument")
        workspace_caps = object_member(caps, "workspace")
        general = object_member(caps, "general")
        semantic = object_member(document_caps, "semanticTokens")
        workspace_semantic = object_member(workspace_caps, "semanticTokens")
        encodings = general.get("positionEncodings", ["utf-16"])
        if not isinstance(encodings, list) or not all(isinstance(value, str) for value in encodings):
            raise InputError("Position encodings must be an array of strings")
        supported = semantic.get("tokenTypes", TYPES)
        supported_modifiers = semantic.get("tokenModifiers", MODIFIERS)
        if any(not isinstance(values, list) or not all(isinstance(value, str) for value in values)
               for values in (supported, supported_modifiers)):
            raise InputError("Token capabilities must be arrays of strings")
        refresh = workspace_semantic.get("refreshSupport", False)
        if not isinstance(refresh, bool):
            raise InputError("Refresh support must be a boolean")
        legend = []
        mapping = {}
        for index, kind in enumerate(TYPES):
            candidate = kind
            while candidate not in supported and candidate in FALLBACK:
                candidate = FALLBACK[candidate]
            if candidate in supported:
                if candidate not in legend:
                    legend.append(candidate)
                mapping[index] = legend.index(candidate)
        modifiers = [value for value in MODIFIERS if value in supported_modifiers]
        modifier_mapping = {1 << i: 1 << modifiers.index(value)
                                 for i, value in enumerate(MODIFIERS) if value in modifiers}
        parent_fd = None
        parent = params.get("processId")
        if parent is not None:
            if not isinstance(parent, int) or isinstance(parent, bool) or parent <= 0:
                raise InputError("Invalid processId")
            try:
                parent_fd = os.pidfd_open(parent)
                self.selector.register(parent_fd, selectors.EVENT_READ, "parent")
            except (OSError, ValueError, KeyError) as error:
                if parent_fd is not None:
                    os.close(parent_fd)
                raise InputError("Cannot establish parent monitoring") from error
        self.mapping, self.modifier_mapping = mapping, modifier_mapping
        self.parent_fd = parent_fd
        self.refresh = refresh
        self.root, self.state = root, "initializing"
        self.response(id, {
            "serverInfo": {"name": "mognitio-lsp", "version": self.identity["version"]},
            "capabilities": {"positionEncoding": "utf-16",
                "textDocumentSync": {"openClose": True, "change": 1, "save": {"includeText": False}},
                "semanticTokensProvider": {"legend": {"tokenTypes": legend, "tokenModifiers": modifiers},
                                          "full": True, "range": False},
                "workspace": {"workspaceFolders": {"supported": False, "changeNotifications": False}}}})

    def cancel_worker(self):
        if self.worker:
            process, generation, started = self.worker
            # The coordinator starts the deadline before signaling; no worker ack is required.
            deadline = time.monotonic() + 1
            try:
                process.terminate()
            except ProcessLookupError:
                pass
            self.retiring.append((process, deadline))
            self.worker = None

    def changed(self):
        self.generation += 1
        self.result = None
        self.dirty = True
        self.cancel_worker()
        for id in list(self.pending):
            self.error(id, -32801, "Content modified")
        self.pending.clear()

    def document(self, method, params):
        item = params["textDocument"]
        uri = uri_from_path(path_from_uri(item["uri"]))
        path = path_from_uri(uri)
        if not path.endswith(".mgn"):
            return
        if self.root is not None and not path.startswith(self.root.rstrip("/") + "/src/"):
            raise InputError("Document is outside this project")
        if method == "textDocument/didClose":
            self.documents.pop(uri, None)
            self.changed()
            self.notify("textDocument/publishDiagnostics", {"uri": uri, "diagnostics": []})
            self.published.discard(uri)
            return
        if method == "textDocument/didSave":
            self.changed()
            return
        version = item.get("version")
        if not isinstance(version, int) or isinstance(version, bool):
            raise InputError("Document version must be an integer")
        previous = self.documents.get(uri)
        if method == "textDocument/didChange":
            if previous is None or version <= previous["version"]:
                self.log("Ignored unopened or non-increasing document version")
                return
            changes = params["contentChanges"]
            if not isinstance(changes, list) or len(changes) != 1 or "range" in changes[0]:
                raise InputError("Expected one Full text change")
            text = changes[0].get("text")
        else:
            text = item.get("text")
        self.changed()
        self.documents[uri] = {"version": version, "text": None}
        # Even invalid text advances state and invalidates dependent results.
        self.documents[uri]["text"] = valid_text(text)

    def message(self, msg):
        if isinstance(msg, ParseError):
            self.error(None, -32700, "Parse error")
            return
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
            self.error(None, -32600, "Invalid Request")
            return
        if "method" not in msg and "id" in msg:
            return  # Client response to a server refresh request.
        method = msg.get("method")
        id = msg.get("id")
        request = "id" in msg
        if not isinstance(method, str) or (request and (not isinstance(id, (int, str)) or isinstance(id, bool))):
            self.error(None, -32600, "Invalid Request")
            return
        params = msg.get("params", {})
        try:
            if not isinstance(params, dict):
                raise InputError("Expected object params")
            if method == "exit":
                return 0 if self.state == "shutdown" else 1
            if self.state == "shutdown":
                if request:
                    self.error(id, -32600, "Server is shut down")
                return
            if method == "initialize" and request:
                self.initialize(id, params)
                return
            if self.state == "created":
                if request:
                    self.error(id, -32002, "Server not initialized")
                return
            if method == "initialized":
                self.state = "running"
                self.changed()
            elif method == "shutdown" and request:
                self.cancel_worker()
                for pending in list(self.pending):
                    self.error(pending, -32800, "Server shutting down")
                self.pending.clear()
                self.state = "shutdown"
                self.response(id)
            elif method == "$/cancelRequest":
                target = params.get("id")
                if target in self.pending:
                    del self.pending[target]
                    self.error(target, -32800, "Request cancelled")
            elif method in ("textDocument/didOpen", "textDocument/didChange",
                            "textDocument/didSave", "textDocument/didClose"):
                self.document(method, params)
            elif method == "workspace/didChangeWatchedFiles":
                self.changed()
            elif method == "textDocument/semanticTokens/full" and request:
                uri = uri_from_path(path_from_uri(params["textDocument"]["uri"]))
                if self.result is None:
                    if id in self.pending:
                        raise InputError("Duplicate pending request id")
                    self.pending[id] = uri
                else:
                    self.respond_tokens(id, uri)
            elif request:
                self.error(id, -32601, "Method not found")
        except (InputError, KeyError, TypeError, ValueError, UnicodeError) as error:
            if request:
                self.error(id, -32602, str(error))
            else:
                self.log("Invalid notification: " + str(error))

    def run_analysis(self):
        if not self.dirty or self.state != "running" or self.retiring:
            return
        self.dirty = False
        try:
            snapshot = discover(self.root, self.documents)
        except InputError as error:
            self.log(str(error))
            self.notify("window/showMessage", {"type": 2, "message": str(error)})
            self.snapshot = {"root": self.root, "sources": {}}
            self.accept({"diagnostics": [], "tokens": {}, "complete": False})
            return
        self.snapshot = snapshot
        for uri, reason in snapshot.get("unavailable", {}).items():
            self.notify("window/showMessage", {"type": 2, "message": reason + ": " + uri})
        generation = self.generation
        command = [sys.executable, "-I", "-B", str(self.payload / "lsp/worker_exec.py"), str(os.getpid()),
                   str(self.payload / "runtime/sbcl"), "--core", str(self.payload / "runtime/mognitio.core"),
                   "--noinform", "--no-sysinit", "--no-userinit", "--mognitio-worker"]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.worker = (process, generation, time.monotonic())
        body = (json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")) + "\n").encode()

        def communicate():
            stdout, stderr = process.communicate(body)
            self.events.put((process, generation, stdout, stderr))
        threading.Thread(target=communicate, daemon=True).start()

    def accept(self, result):
        self.result = result
        grouped = {}
        sources = self.snapshot["sources"]
        texts = dict(sources)
        if "manifest" in self.snapshot:
            texts["mognitio.toml"] = self.snapshot["manifest"]
        truncated = len(result["diagnostics"]) > 2000
        for diagnostic in result["diagnostics"][:2000]:
            path = diagnostic.get("path")
            text = texts.get(path)
            if text is None or diagnostic.get("start") is None:
                self.notify("window/showMessage", {"type": 2, "message": diagnostic["message"]})
                continue
            uri = uri_from_path(Path(self.snapshot["root"]) / path) if self.snapshot["root"] else path
            rows = grouped.setdefault(uri, [])
            if len(rows) >= 200:
                truncated = True
                continue
            rows.append({"range": {"start": position(text, diagnostic["start"]),
                                   "end": position(text, diagnostic["end"] or diagnostic["start"])},
                         "severity": 1, "source": "Mognitio", "code": diagnostic["phase"],
                         "message": diagnostic["message"]})
            related = []
            for item in diagnostic.get("related", []):
                other = texts.get(item.get("path"))
                if other is None or item.get("start") is None:
                    continue
                location = uri_from_path(Path(self.snapshot["root"]) / item["path"]) if self.snapshot["root"] else item["path"]
                related.append({"location": {"uri": location, "range": {
                    "start": position(other, item["start"]), "end": position(other, item["end"])}},
                    "message": item["message"]})
            if related:
                rows[-1]["relatedInformation"] = related
        if truncated or result.get("truncated"):
            self.notify("window/showMessage", {"type": 2, "message": "Diagnostic limit reached; analysis is incomplete"})
        current = set(grouped)
        for uri in sorted(self.published | current | set(self.documents)):
            params = {"uri": uri, "diagnostics": grouped.get(uri, [])}
            if uri in self.documents:
                params["version"] = self.documents[uri]["version"]
            self.notify("textDocument/publishDiagnostics", params)
        self.published = current
        for id, uri in list(self.pending.items()):
            self.respond_tokens(id, uri)
        self.pending.clear()
        if self.refresh:
            self.refresh_id += 1
            self.send({"jsonrpc": "2.0", "id": "refresh:" + str(self.refresh_id),
                       "method": "workspace/semanticTokens/refresh"})

    def respond_tokens(self, id, uri):
        path = os.path.relpath(path_from_uri(uri), self.snapshot["root"]) if self.snapshot["root"] else uri
        text = self.snapshot["sources"].get(path, "")
        rows = self.result["tokens"].get(path, [])
        projected = [[a, b, c, sum(target for bit, target in self.modifier_mapping.items() if mods & bit)]
                     for a, b, c, mods in rows]
        self.response(id, {"resultId": str(self.generation), "data": token_data(text, projected, self.mapping)})

    def supervise(self):
        now = time.monotonic()
        for process, deadline in list(self.retiring):
            if process.poll() is not None:
                self.retiring.remove((process, deadline))
            elif now >= deadline:
                process.kill()
                raise RuntimeError("Worker cancellation deadline exceeded")
        if self.worker and now - self.worker[2] >= 10:
            self.cancel_worker()
            self.notify("window/showMessage", {"type": 2, "message": "Analysis time budget exceeded"})
            self.accept({"diagnostics": [], "tokens": {}, "complete": False})
        while not self.events.empty():
            process, generation, stdout, stderr = self.events.get()
            if generation != self.generation or self.worker is None or process is not self.worker[0]:
                continue
            self.worker = None
            if process.returncode:
                raise RuntimeError("Analysis worker failed")
            self.accept(json.loads(stdout))
        self.memory.check()

    def run(self):
        try:
            while True:
                for key, _ in self.selector.select(0.025):
                    if key.data == "parent":
                        return 1
                    data = os.read(0, 65536)
                    if not data:
                        self.framer.eof()
                        return 0 if self.state == "shutdown" else 1
                    for message in self.framer.feed(data):
                        result = self.message(message)
                        if result is not None:
                            return result
                self.framer.check_deadline()
                self.supervise()
                self.run_analysis()
        finally:
            if self.worker:
                self.worker[0].kill()
                self.worker[0].wait(timeout=1)
            for process, _ in self.retiring:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=1)
            if self.parent_fd is not None:
                os.close(self.parent_fd)
            self.selector.close()
            self.memory.close()

def main():
    if sys.argv[1:] not in (["--stdio"], ["--version"]):
        print("usage: mognitio-lsp --stdio | --version", file=sys.stderr)
        return 2
    payload = Path(__file__).resolve().parent.parent
    try:
        identity = payload_identity(payload)
        if sys.argv[1:] == ["--version"]:
            print("mognitio-lsp " + identity["version"])
            return 0
        if os.getpgrp() != os.getpid():
            os.setsid()
        # A private verified session copy survives APT removing old payload paths.
        with tempfile.TemporaryDirectory(prefix="mognitio-lsp-") as temporary:
            session = Path(temporary) / "payload"
            shutil.copytree(payload, session)
            payload_identity(session)
            return Server(session, identity).run()
    except (FrameError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("mognitio-lsp: " + str(error), file=sys.stderr)
        return 3

if __name__ == "__main__":
    sys.exit(main())
