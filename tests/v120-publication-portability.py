#!/usr/bin/env python3
"""Real unverified-filesystem observations, with an optional mounted NTFS fixture."""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--ntfs-root", type=Path)
parser.add_argument("--evidence", type=Path)
args = parser.parse_args()
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
checks = 0
records = []
imports = "namespace App;use Std\\Numeric\\{Bits};use Std\\Binary\\{Bytes,bytesFromBits,publishFile,BinaryFileMode,BinaryOutputError,BinaryOutputErrorKind,BinaryOutputPhase,BinaryPublicationState};"
kinds = ["InvalidPath", "AlreadyExists", "NotFound", "PermissionDenied", "UnsupportedTarget", "ResourceExhausted", "Other"]
phases = ["Input", "Target", "Body", "Publish", "Cleanup"]
states = ["NotPublished", "Published", "Unknown"]

def enum(expr, typ, names):
    return "branch on " + expr + "{" + ",".join(f"{typ}::{name}=>{i}" for i, name in enumerate(names)) + "}"

def run(command, expected=0):
    global checks
    p = subprocess.run(list(map(str, command)), capture_output=True, timeout=60)
    checks += 1
    assert (p.returncode, p.stdout, p.stderr) == (expected, b"", b""), (command, p.returncode, p.stdout, p.stderr)

def mechanism(directory):
    source = directory / "probe-source"
    target = directory / "probe-target"
    source.write_bytes(b"probe")
    fd = os.open(directory, os.O_PATH | os.O_DIRECTORY)
    try:
        result = libc.syscall(ctypes.c_long(316), ctypes.c_long(fd),
                              ctypes.c_char_p(os.fsencode(source.name)), ctypes.c_long(fd),
                              ctypes.c_char_p(os.fsencode(target.name)), ctypes.c_long(1))
        error = ctypes.get_errno() if result < 0 else 0
        assert error in (0, errno.ENOSYS, errno.EOPNOTSUPP, errno.EINVAL), error
        assert (target if error == 0 else source).read_bytes() == b"probe"
        return error
    finally:
        os.close(fd)
        for path in (source, target):
            if path.exists():
                path.unlink()

with tempfile.TemporaryDirectory(prefix="mgn-portability-") as temp:
    project = Path(temp)
    (project / "src").mkdir()
    manifest = project / "mognitio.toml"
    manifest.write_text('[project]\nname="app"\nroot_namespace="App"\n')
    image = project / "program"
    cases = [(ROOT, "checkout-filesystem", "output")]
    if args.ntfs_root:
        assert args.ntfs_root.is_dir()
        cases.append((args.ntfs_root, "ntfs-long-component", "\u3042" * 100))
    for parent, label, name in cases:
        with tempfile.TemporaryDirectory(prefix=".mgn-portability-", dir=parent) as output:
            directory = Path(output)
            target = directory / name
            # NTFS admits the name at lookup: this is not a truncated fixture.
            try:
                target.lstat()
                raise AssertionError("fixture must be absent")
            except FileNotFoundError:
                pass
            unsupported = mechanism(directory)
            expected = 0 if not unsupported else 30 + 4 * 15 + 3 * 3 + (0 if unsupported == errno.ENOSYS else 2)
            for mode, permissions in (("Data", 0o644), ("Executable", 0o755)):
                body = "branch on publishFile(" + json.dumps(str(target), ensure_ascii=False) + ",bytesFromBits(List<Bits<8>>[Bits<8>{0},Bits<8>{128},Bits<8>{255}]),BinaryFileMode::" + mode + "){Result<Unit,BinaryOutputError>::Ok=>0,Result<Unit,BinaryOutputError>::Err(e:BinaryOutputError)=>30+(" + enum("e->kind", "BinaryOutputErrorKind", kinds) + ")*15+(" + enum("e->phase", "BinaryOutputPhase", phases) + ")*3+(" + enum("e->publication", "BinaryPublicationState", states) + ")}"
                (project / "src/app.mgn").write_text(imports + "let main:Function(List<String>):Int=function(args:List<String>):Int{" + body + "};")
                run([ROOT / "bin/mgn", "build", manifest, "-o", image])
                for backend in ("host", "native"):
                    command = [ROOT / "bin/mgn", "run", manifest] if backend == "host" else [image]
                    previous = os.umask(0o022)
                    try:
                        run(command, expected)
                    finally:
                        os.umask(previous)
                    if not unsupported:
                        assert target.read_bytes() == bytes([0, 128, 255])
                        assert stat.S_IMODE(target.stat().st_mode) == permissions
                        run(command, 30 + 1 * 15 + 1 * 3)
                        assert target.read_bytes() == bytes([0, 128, 255])
                        assert stat.S_IMODE(target.stat().st_mode) == permissions
                        target.unlink()
                    else:
                        # Existence protection precedes optional evidence and commit support.
                        target.write_bytes(b"existing")
                        target.chmod(0o640)
                        original_mode = stat.S_IMODE(target.stat().st_mode)
                        run(command, 30 + 1 * 15 + 1 * 3)
                        assert target.read_bytes() == b"existing"
                        assert stat.S_IMODE(target.stat().st_mode) == original_mode
                        target.unlink()
                    assert list(directory.iterdir()) == []
                    records.append(dict(fixture=label, backend=backend, mode=mode,
                                        name_bytes=len(name.encode()), mechanism_errno=unsupported,
                                        result="Ok" if not unsupported else "UnsupportedTarget/Publish/" + ("NotPublished" if unsupported == errno.ENOSYS else "Unknown")))
if args.evidence:
    args.evidence.write_text(json.dumps(records, indent=2) + "\n")
print(f"PUBLICATION_PORTABILITY_OK checks={checks} ntfs={'observed' if args.ntfs_root else 'not-requested'}")
