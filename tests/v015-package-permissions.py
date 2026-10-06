#!/usr/bin/env python3
"""Inspect real Debian/bundle modes under permissive and restrictive umasks."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def modes(archive):
    result = {}
    for item in archive.getmembers():
        assert item.isdir() or item.isfile(), item.name
        expected = 0o755 if item.isdir() or item.mode & 0o111 else 0o644
        assert item.mode == expected, (item.name, oct(item.mode), oct(expected))
        result[item.name] = item.mode
    return result

def check(payload):
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        source = root / "private-payload"
        shutil.copytree(payload, source)
        # Reproduce mkdtemp's private root and a restrictive build umask.
        for path in [source, *source.rglob("*")]:
            path.chmod(0o700 if path.is_dir() or path.stat().st_mode & 0o111 else 0o600)
        original = {str(x.relative_to(source)): (stat.S_IMODE(x.stat().st_mode),
                    hashlib.sha256(x.read_bytes()).hexdigest() if x.is_file() else None)
                    for x in [source, *source.rglob("*")]}
        version = json.loads((source / "identity.json").read_text())["version"]
        for mask in (0o022, 0o077):
            output = root / str(mask)
            subprocess.run(["python3", str(ROOT / "scripts/package-toolchain.py"),
                            str(source), "--output", str(output)], check=True, umask=mask)
            deb = output / ("mognitio_" + version + "-1_amd64.deb")
            data = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", str(deb)])
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                modes(archive)
                assert all(x.uid == 0 and x.gid == 0 for x in archive.getmembers())
                deb_files = {x.name.split("/mognitio/", 1)[1].split("/", 1)[1]:
                             archive.extractfile(x).read() for x in archive.getmembers()
                             if x.isfile() and "/lib/mognitio/" in x.name}
            with tarfile.open(output / ("mognitio-" + version + "-linux-amd64.tar.gz")) as archive:
                modes(archive)
                bundle_files = {x.name.removeprefix("mognitio/payload/"):
                                archive.extractfile(x).read() for x in archive.getmembers()
                                if x.isfile() and x.name.startswith("mognitio/payload/")}
            assert deb_files == bundle_files
            assert {name: hashlib.sha256(data).hexdigest() for name, data in deb_files.items()} == {
                name: value[1] for name, value in original.items() if value[1] is not None}
        after = {str(x.relative_to(source)): (stat.S_IMODE(x.stat().st_mode),
                 hashlib.sha256(x.read_bytes()).hexdigest() if x.is_file() else None)
                 for x in [source, *source.rglob("*")]}
        assert original == after, "Packaging mutated the source payload"
    print("PASS: Debian/bundle modes, root ownership, identical bytes, source immutability, umasks 022/077")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", type=Path, required=True)
    check(parser.parse_args().payload.resolve())
