#!/usr/bin/env python3
"""Create an immutable compiler/LSP payload with one build-time identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
INPUTS = ("VERSION", "mognitio.asd", "src", "bin", "scripts", "tools", "packaging")

def canonical(record):
    return json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def source_digest(root):
    entries = []
    for name in INPUTS:
        path = root / name
        if not path.exists():
            continue
        paths = sorted(path.rglob("*")) if path.is_dir() else [path]
        for entry in paths:
            if any(part in ("__pycache__", ".cache") for part in entry.parts):
                continue
            if entry.is_symlink():
                raise ValueError("Build inputs must not be symlinks")
            if not entry.is_file():
                continue
            entries.append((entry.relative_to(root).as_posix(), entry))
    h = hashlib.sha256()
    for name, path in sorted(entries):
        for value in (name.encode(), str(stat.S_IMODE(path.stat().st_mode)).encode(), path.read_bytes()):
            h.update(len(value).to_bytes(8, "big"))
            h.update(value)
    return h.hexdigest()

def identity(root, mode, runtime, core, image, notice):
    version = (root / "VERSION").read_text().strip()
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("VERSION must be a plain release version")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=root))
    if mode == "release" and dirty:
        raise ValueError("Release build requires a clean source tree")
    runtime_version = subprocess.check_output([str(runtime), "--core", str(core), "--version"], text=True).strip()
    record = {"schema": 1, "commit": commit, "baseVersion": version, "mode": mode,
              "prerelease": "dev.0" if mode == "development" else "", "dirty": dirty,
              "source": source_digest(root), "runtimeVersion": runtime_version,
              "runtimeDigest": digest(runtime), "inputCoreDigest": digest(core),
              "imageDigest": image, "target": "linux-amd64", "flags": ["--no-userinit", "--no-sysinit"],
              "runtimeNoticeDigest": digest(notice), "generator": 1}
    if mode == "release":
        lock = json.loads((root / "packaging/build-lock.json").read_text())
        for key in ("imageDigest", "runtimeVersion", "runtimeDigest", "inputCoreDigest", "runtimeNoticeDigest"):
            if record[key] != lock[key]:
                raise ValueError("Release build input differs from lock: " + key)
    build = hashlib.sha256(canonical(record)).hexdigest()
    wire = version if mode == "release" else (
        version + "-dev.0+g" + commit + (".dirty" if dirty else "") +
        ".s" + record["source"] + ".b" + build)
    return {"schema": 1, "version": wire, "build": build, "inputs": record,
            "components": {name: build for name in ("compiler", "frontend", "stdlib", "lsp")}}

def lisp_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

def build(args):
    runtime, core = args.runtime.resolve(), args.core.resolve()
    ident = identity(ROOT, args.mode, runtime, core, args.image_digest, args.runtime_notice)
    destination = args.output.resolve() / ident["build"]
    if destination.exists():
        if json.loads((destination / "identity.json").read_text()) != ident:
            raise ValueError("Immutable build directory collision")
        verify(destination)
        print(destination)
        return
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".build-", dir=args.output) as tmp:
        staging = Path(tmp)
        (staging / "bin").mkdir()
        (staging / "runtime").mkdir()
        shutil.copy2(runtime, staging / "runtime/sbcl")
        shutil.copytree(ROOT / "tools/lsp", staging / "lsp", ignore=shutil.ignore_patterns("__pycache__"))
        (staging / "identity.json").write_bytes(canonical(ident) + b"\n")
        commands = "\n".join([
            "(require :asdf)",
            "(asdf:load-asd " + lisp_string(str(ROOT / "mognitio.asd")) + ")",
            '(asdf:load-system "mognitio")',
            "(setf mognitio.identity:*manifest* " + lisp_string(canonical(ident).decode()) + ")",
            "(setf mognitio.identity:*version* " + lisp_string(ident["version"]) + ")",
            "(sb-ext:save-lisp-and-die " + lisp_string(str(staging / "runtime/mognitio.core")) +
            " :toplevel #'mognitio.identity:main :purify t)",
        ])
        program = staging / "build.lisp"
        program.write_text(commands + "\n")
        env = dict(os.environ)
        env["SBCL_HOME"] = str(core.parent)
        subprocess.run([str(runtime), "--core", str(core), "--noinform", "--no-sysinit",
                        "--no-userinit", "--script", str(program)], cwd=ROOT, env=env, check=True,
                       stdout=subprocess.DEVNULL)
        program.unlink()
        # The core contains the loaded standard catalog and Lisp dependencies.
        # SB-POSIX uses the system C library; it has no separate saved .so.
        shutil.copy2(args.runtime_notice, staging / "THIRD_PARTY_NOTICES.txt")
        (staging / "bin/mgn").write_text((ROOT / "packaging/mgn").read_text())
        (staging / "bin/mognitio-lsp").write_text((ROOT / "packaging/mognitio-lsp").read_text())
        for path in (staging / "bin").iterdir():
            path.chmod(0o755)
        files = {str(p.relative_to(staging)): {"sha256": digest(p), "size": p.stat().st_size}
                 for p in sorted(staging.rglob("*")) if p.is_file()}
        (staging / "payload.json").write_bytes(canonical({"identity": ident, "files": files}) + b"\n")
        verify(staging)
        staging.rename(destination)
    print(destination)

def verify(path):
    manifest = json.loads((path / "payload.json").read_text())
    for name, item in manifest["files"].items():
        member = path / name
        if member.is_symlink() or digest(member) != item["sha256"] or member.stat().st_size != item["size"]:
            raise ValueError("Payload checksum mismatch: " + name)
    command = [str(path / "runtime/sbcl"), "--core", str(path / "runtime/mognitio.core"),
               "--noinform", "--no-sysinit", "--no-userinit", "--mognitio-identity"]
    actual = json.loads(subprocess.check_output(command, timeout=10))
    if actual != manifest["identity"]:
        raise ValueError("Embedded component identity mismatch")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--image-digest", required=True)
    parser.add_argument("--runtime-notice", type=Path, required=True)
    parser.add_argument("--mode", choices=["development", "release"], default="development")
    parser.add_argument("--output", type=Path, default=ROOT / ".cache/toolchain")
    build(parser.parse_args())
