#!/usr/bin/env python3
"""Prepare a signed static APT tree. Does not upload or publish it."""
import argparse
from pathlib import Path
import shutil
import subprocess

def run(args):
    if args.output.exists():
        raise ValueError("Use a new output directory for each repository staging tree")
    pool = args.output / "pool/main/m/mognitio"
    pool.mkdir(parents=True)
    for package in args.packages:
        shutil.copy2(package, pool / package.name)
    binary = args.output / "dists/stable/main/binary-amd64"
    binary.mkdir(parents=True)
    index = subprocess.check_output(["dpkg-scanpackages", "--multiversion", "pool"], cwd=args.output)
    binary.joinpath("Packages").write_bytes(index)
    release = subprocess.check_output(["apt-ftparchive",
        "-o", "APT::FTPArchive::Release::Origin=ProjectCuriositas",
        "-o", "APT::FTPArchive::Release::Label=Mognitio",
        "-o", "APT::FTPArchive::Release::Suite=stable",
        "-o", "APT::FTPArchive::Release::Codename=stable",
        "-o", "APT::FTPArchive::Release::Architectures=amd64",
        "-o", "APT::FTPArchive::Release::Components=main",
        "release", "dists/stable"], cwd=args.output)
    path = args.output / "dists/stable/Release"
    path.write_bytes(release)
    for mode, target in [("--clearsign", "InRelease"), ("--detach-sign", "Release.gpg")]:
        subprocess.run(["gpg", "--batch", "--local-user", args.signing_key, "--output",
                        str(path.with_name(target)), mode, str(path)], check=True)
    print("Signed staging tree prepared. Verify the complete tree before publication.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--signing-key", required=True)
    parser.add_argument("packages", nargs="+", type=Path)
    run(parser.parse_args())
