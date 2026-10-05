#!/usr/bin/env python3
"""Produce a Debian package and offline bundle from the identical payload."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(args):
    payload = args.payload.resolve()
    spec = importlib.util.spec_from_file_location("payload_validation", ROOT / "tools/lsp/payload.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    identity = module.payload_identity(payload)
    version = identity["version"]
    if identity["inputs"]["mode"] != "release":
        raise ValueError("Distribution packages require an explicit release-mode build")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mognitio-package-") as directory:
        staging = Path(directory)
        bundle = staging / "mognitio"
        bundle.mkdir()
        shutil.copytree(payload, bundle / "payload")
        for name in ("install.py", "install.sh"):
            shutil.copy2(ROOT / "packaging" / name, bundle / name)
        bundle_file = args.output / ("mognitio-" + version + "-linux-amd64.tar.gz")
        with tarfile.open(bundle_file, "w:gz") as archive:
            archive.add(bundle, arcname="mognitio")
        deb = staging / "deb"
        control = deb / "DEBIAN"
        control.mkdir(parents=True)
        installed = deb / "usr/lib/mognitio" / identity["build"]
        shutil.copytree(payload, installed)
        binary = deb / "usr/bin"
        binary.mkdir()
        for name in ("mgn", "mognitio-lsp"):
            wrapper = binary / name
            wrapper.write_text("#!/bin/sh\nexec /usr/lib/mognitio/" + identity["build"] +
                               "/bin/" + name + ' "$@"\n')
            wrapper.chmod(0o755)
        control.joinpath("control").write_text(
            "Package: mognitio\nVersion: " + version + "-1\nArchitecture: amd64\n"
            "Maintainer: ProjectCuriositas\nSection: devel\nPriority: optional\n"
            "Depends: libc6 (>= 2.34), libzstd1, python3 (>= 3.12), util-linux\n"
            "Description: Mognitio compiler and language server\n"
            " A fixed compiler, frontend, standard library, and stdio language server.\n")
        deb_file = args.output / ("mognitio_" + version + "-1_amd64.deb")
        subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(deb), str(deb_file)], check=True)
        manifest = {"schema": 1, "identity": identity,
                    "artifacts": [{"filename": p.name, "size": p.stat().st_size, "sha256": sha(p)}
                                  for p in (bundle_file, deb_file)]}
        args.output.joinpath("manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    print("Artifacts created; signing, external verification, and publication are separate.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("payload", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    run(parser.parse_args())
