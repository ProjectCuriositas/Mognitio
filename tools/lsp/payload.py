"""Immutable component validation shared by both launchers."""
import hashlib
import json
from pathlib import Path
import subprocess

def payload_identity(root):
    identity = json.loads((root / "identity.json").read_text())
    manifest = json.loads((root / "payload.json").read_text())
    if manifest["identity"] != identity:
        raise ValueError("Payload identity mismatch")
    files = manifest["files"]
    paths = list(root.rglob("*"))
    if any(path.is_symlink() for path in paths):
        raise ValueError("Payload links are forbidden")
    if {path.relative_to(root).as_posix() for path in paths if path.is_file()} != set(files) | {"payload.json"}:
        raise ValueError("Payload file closure mismatch")
    for name, record in files.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unsafe payload path")
        path = root / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size != record["size"] or hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError("Payload component mismatch")
    if any(value != identity["build"] for value in identity["components"].values()):
        raise ValueError("Component identity mismatch")
    embedded = json.loads(subprocess.check_output(
        [str(root / "runtime/sbcl"), "--core", str(root / "runtime/mognitio.core"),
         "--noinform", "--no-sysinit", "--no-userinit", "--mognitio-identity"], timeout=10))
    if embedded != identity:
        raise ValueError("Embedded identity mismatch")
    return identity

