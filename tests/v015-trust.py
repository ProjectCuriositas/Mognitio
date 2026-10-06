#!/usr/bin/env python3
"""Offline trust/rotation and APT tamper acceptance with disposable test keys."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument("--artifacts",type=Path,required=True)
parser.add_argument("--userland",type=Path,action="append",required=True)
args=parser.parse_args()
def run(cmd,env=None,ok=True):
    p=subprocess.run(list(map(str,cmd)),env=env,capture_output=True,text=True,timeout=90)
    if ok:assert p.returncode==0,(cmd,p.stdout[-1800:],p.stderr[-1800:])
    else:assert p.returncode!=0,(cmd,p.stdout,p.stderr)
    return p
with tempfile.TemporaryDirectory(prefix="mognitio-trust-") as temporary, contextlib.ExitStack() as cleanup:
    temp=Path(temporary);home=temp/"gnupg";home.mkdir(mode=0o700)
    env=dict(os.environ,GNUPGHOME=str(home))
    cleanup.callback(subprocess.run,["gpgconf","--homedir",str(home),"--kill","gpg-agent"],capture_output=True)
    def gpg(*cmd):return run(["gpg","--batch","--pinentry-mode","loopback","--passphrase","",*cmd],env)
    keys=[]
    for label in ("Old acceptance key","New acceptance key"):
        gpg("--quick-gen-key",label,"ed25519","cert","0")
        listing=gpg("--with-colons","--list-keys",label).stdout
        primary=next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
        gpg("--quick-add-key",primary,"ed25519","sign","0")
        gpg("--quick-add-key",primary,"ed25519","sign","0")
        fps=[line.split(":")[9] for line in gpg("--with-colons","--list-keys",primary).stdout.splitlines() if line.startswith("fpr:")]
        keys.append(fps)
    def export(name,key):
        target=temp/name
        target.write_bytes(subprocess.check_output(["gpg","--batch","--export",key],env=env))
        return target
    oldring=export("old.gpg",keys[0][0]);newring=export("new.gpg",keys[1][0])
    bundle=temp/"bundle";bundle.mkdir()
    manifest=json.loads((args.artifacts/"manifest.json").read_text())
    for item in manifest["artifacts"]:shutil.copy2(args.artifacts/item["filename"],bundle/item["filename"])
    m=bundle/"manifest.json";shutil.copy2(args.artifacts/"manifest.json",m)
    def sign(key,path):
        sig=path.with_suffix(path.suffix+".asc")
        gpg("--yes","--armor","--local-user",key+"!","--output",str(sig),"--detach-sign",str(path))
        return sig
    signature=sign(keys[0][2],m)
    oldsignature=signature.read_bytes()
    def verify(ring,fingerprint,ok=True):
        return run(["python3",ROOT/"scripts/verify-bundle.py","--manifest",m,"--signature",signature,
                    "--keyring",ring,"--fingerprint",fingerprint],ok=ok)
    verify(oldring,keys[0][0])
    verify(newring,keys[0][0],False)
    verify(oldring,keys[1][0],False)
    missing=temp/"absent.gpg"
    verify(missing,keys[0][0],False)
    artifact=bundle/manifest["artifacts"][0]["filename"]
    original=artifact.read_bytes();artifact.write_bytes(original[:-1]+bytes([original[-1]^1]))
    verify(oldring,keys[0][0],False);artifact.write_bytes(original)
    original_manifest=m.read_bytes();m.write_bytes(original_manifest+b" ")
    verify(oldring,keys[0][0],False);m.write_bytes(original_manifest)
    signature=sign(keys[1][2],m)
    verify(oldring,keys[1][0],False);verify(newring,keys[1][0])
    print("PASS bundle: valid signature/hash; unknown/missing/incorrect trust, modified artifact/manifest rejected; rotation requires new external keyring",flush=True)
    deb=args.artifacts/"mognitio_0.15.0-1_amd64.deb"
    run(["python3",ROOT/"scripts/apt-repository.py","--output",temp/"repo-old","--signing-key",keys[0][1]+"!",deb],env)
    # Revocation is imported into current key material; frozen offline material stays stale.
    certificate=home/"openpgp-revocs.d"/(keys[0][0]+".rev")
    text=certificate.read_text();text=text[text.index(":-----BEGIN"):].replace(":-----BEGIN","-----BEGIN",1)
    rev=temp/"rev.asc";rev.write_text(text);gpg("--import",str(rev))
    assert any(line.startswith("pub:r:") for line in gpg("--with-colons","--list-keys",keys[0][0]).stdout.splitlines())
    revokedring=export("revoked.gpg",keys[0][0])
    # Reuse the valid detached signature made before revocation.
    signature.write_bytes(oldsignature)
    verify(oldring,keys[0][0])
    # gpgv intentionally does not implement revocation freshness policy.
    verify(revokedring,keys[0][0])
    verify(newring,keys[0][0],False)
    signature=sign(keys[1][2],m);verify(newring,keys[1][0])
    print("PASS stale offline and revoked-key gpgv success cannot authorize installation; removing old trust rejects it; independent replacement restores verification",flush=True)
    print("PASS current trust material marks old primary revoked; replacement primary independently selected",flush=True)
    deb=args.artifacts/"mognitio_0.15.0-1_amd64.deb"
    repos=[]
    # Use only the still valid replacement key for APT repo creation.
    for index in range(2):
        repo=temp/("repo"+str(index))
        run(["python3",ROOT/"scripts/apt-repository.py","--output",repo,"--signing-key",keys[1][1]+"!",deb],env)
        repos.append(repo)
    for userland in args.userland:
        case=temp/("apt-"+userland.name);case.mkdir();(case/"lists/partial").mkdir(parents=True)
        (case/"downloads").mkdir();(case/"sources.list").write_text("")
        prefix=["bwrap","--unshare-user","--uid","0","--gid","0","--ro-bind",userland,"/","--tmpfs","/tmp",
                "--bind",case,"/tmp/case","--ro-bind",temp,"/tmp/fixtures","--dev","/dev","--proc","/proc",
                "--setenv","HOME","/tmp","--setenv","LC_ALL","C.UTF-8","--chdir","/tmp/case/downloads","--"]
        options=["-o","APT::Sandbox::User=root","-o","Dir::Etc::sourcelist=/tmp/case/sources.list",
                 "-o","Dir::Etc::sourceparts=-","-o","Dir::State::lists=/tmp/case/lists","-o","APT::Update::Error-Mode=any"]
        def apt(*cmd,ok=True):return run(prefix+["apt-get",*options,*cmd],ok=ok)
        apt("update");apt("download","mognitio",ok=False)
        (case/"sources.list").write_text("deb [signed-by=/tmp/fixtures/old.gpg] file:/tmp/fixtures/repo-old stable main\n")
        apt("update");apt("download","mognitio")
        (case/"downloads"/deb.name).unlink()
        (case/"sources.list").write_text("deb [signed-by=/tmp/fixtures/revoked.gpg] file:/tmp/fixtures/repo-old stable main\n")
        apt("update",ok=False)
        (case/"sources.list").write_text("deb [signed-by=/tmp/fixtures/old.gpg] file:/tmp/fixtures/repo0 stable main\n")
        apt("update",ok=False)
        (case/"sources.list").write_text("deb [signed-by=/tmp/fixtures/new.gpg] file:/tmp/fixtures/repo0 stable main\n")
        apt("update");apt("download","mognitio")
        downloaded=case/"downloads"/deb.name
        assert hashlib.sha256(downloaded.read_bytes()).digest()==hashlib.sha256(deb.read_bytes()).digest()
        downloaded.unlink()
        modified=repos[0]/"pool/main/m/mognitio"/deb.name
        original=modified.read_bytes();modified.write_bytes(original[:-1]+bytes([original[-1]^1]))
        failure=apt("download","mognitio",ok=False)
        assert "Hash Sum mismatch" in failure.stderr+failure.stdout
        modified.write_bytes(original)
        release=repos[1]/"dists/stable/InRelease";original=release.read_bytes()
        release.write_bytes(original.replace(b"Origin: ProjectCuriositas",b"Origin: TamperedProject"))
        (case/"sources.list").write_text("deb [signed-by=/tmp/fixtures/new.gpg] file:/tmp/fixtures/repo1 stable main\n")
        apt("update",ok=False);release.write_bytes(original)
        apt("update");apt("download","mognitio")
        print("PASS APT "+userland.name+": stale old key permits old signature; refreshed revoked key, unregistered package, unknown key, modified package hash, tampered metadata rejected; authenticated replacement key succeeds",flush=True)
