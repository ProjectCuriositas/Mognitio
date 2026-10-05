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
    for name, record in manifest["files"].items():
        path = root / name
        if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError("Payload component mismatch")
    if any(value != identity["build"] for value in identity["components"].values()):
        raise ValueError("Component identity mismatch")
    embedded = json.loads(subprocess.check_output(
        [str(root / "runtime/sbcl"), "--core", str(root / "runtime/mognitio.core"),
         "--noinform", "--no-sysinit", "--no-userinit", "--mognitio-identity"], timeout=10))
    if embedded != identity:
        raise ValueError("Embedded identity mismatch")
    return identity

