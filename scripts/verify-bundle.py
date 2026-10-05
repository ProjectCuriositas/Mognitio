#!/usr/bin/env python3
"""Verify a signed release manifest and artifacts before extracting/installing."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

def verify(args):
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", args.fingerprint):
        raise ValueError("An independently obtained full primary-key fingerprint is required")
    completed = subprocess.run(["gpgv", "--status-fd", "1", "--keyring", str(args.keyring.resolve()),
                                str(args.signature), str(args.manifest)],
                               capture_output=True, text=True)
    if completed.returncode:
        raise ValueError("Signature verification failed")
    signatures = [line.split() for line in completed.stdout.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
    if len(signatures) != 1 or args.fingerprint.upper() not in (signatures[0][2].upper(), signatures[0][-1].upper()):
        raise ValueError("Unexpected signing identity")
    manifest = json.loads(args.manifest.read_text())
    for artifact in manifest["artifacts"]:
        name = artifact["filename"]
        if Path(name).name != name or name in ("", ".", ".."):
            raise ValueError("Unsafe artifact name")
        path = args.manifest.parent / name
        if path.is_symlink() or path.stat().st_size != artifact["size"] or hashlib.sha256(path.read_bytes()).hexdigest() != artifact["sha256"]:
            raise ValueError("Artifact digest mismatch: " + name)
    print("Signature and artifact digests verified. Confirm key validity using current independent trust information.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--signature", type=Path, required=True)
    parser.add_argument("--keyring", type=Path, required=True)
    parser.add_argument("--fingerprint", required=True)
    verify(parser.parse_args())
