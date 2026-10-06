#!/usr/bin/env python3
"""Sign only a frozen release manifest with the separately managed bundle subkey."""
import argparse
import contextlib
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent.parent

def run(args, **kwargs):
    env=dict(kwargs.pop("env",os.environ))
    for name in ("BUNDLE_SIGNING_KEY","BUNDLE_SIGNING_PASSPHRASE","GH_TOKEN","GITHUB_TOKEN"):
        env.pop(name,None)
    return subprocess.run(list(map(str,args)),check=True,capture_output=True,env=env,**kwargs).stdout

def validate_public_keys(directory, keyfile, config):
    home=directory/"public-check";home.mkdir(mode=0o700)
    env=dict(os.environ,GNUPGHOME=str(home))
    run(["gpg","--batch","--import"],input=keyfile.read_bytes(),env=env)
    listing=run(["gpg","--batch","--with-colons","--list-keys"],env=env).decode()
    records={};pending=None;primary=None
    for line in listing.splitlines():
        fields=line.split(":")
        if fields[0] in ("pub","sub"):
            pending=fields
        elif fields[0]=="fpr" and pending:
            if pending[0]=="pub":primary=fields[9]
            records[fields[9]]=(pending,primary);pending=None
    now=int(datetime.now(timezone.utc).timestamp())
    for field,kind in [("primary_fingerprint","pub"),("signing_fingerprint","sub")]:
        row,parent=records[config[field]]
        if row[0]!=kind or parent!=config["primary_fingerprint"] or row[1] in ("r","e","d","i"):
            raise ValueError("Public key is revoked, expired, invalid, or bound to another primary")
        if row[6] and int(row[6])<=now:
            raise ValueError("Public key has expired")
        if kind=="sub" and "s" not in row[11]:
            raise ValueError("Configured subkey cannot sign")

def key_environment(directory, config, secret, public=None):
    home = directory / "gnupg"
    home.mkdir(mode=0o700)
    env = dict(os.environ, GNUPGHOME=str(home))
    # Never forward key material to any subsequent child environment.
    env.pop("BUNDLE_SIGNING_KEY",None)
    env.pop("BUNDLE_SIGNING_PASSPHRASE",None)
    run(["gpg","--batch","--import"],input=secret.encode(),env=env)
    if public is not None:
        run(["gpg","--batch","--import"],input=public.read_bytes(),env=env)
    listing = run(["gpg","--batch","--with-colons","--list-secret-keys"],env=env).decode()
    primary_rows = [line.split(":") for line in listing.splitlines() if line.startswith("sec:")]
    if len(primary_rows) != 1 or primary_rows[0][14] != "#":
        raise ValueError("Signing must contain a stub primary, never the offline primary secret")
    fingerprints = [line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:")]
    available=[];pending=None
    for line in listing.splitlines():
        row=line.split(":")
        if row[0] in ("sec","ssb"):pending=row
        elif row[0]=="fpr" and pending:
            if pending[0]=="ssb" and pending[14]!="#":available.append(row[9])
            pending=None
    if fingerprints[0] != config["primary_fingerprint"] or available != [config["signing_fingerprint"]]:
        raise ValueError("Only the designated bundle secret subkey may be imported")
    return env


def sign(directory, expected_digest, expected_commit):
    manifest=directory/"manifest.json"
    if manifest.is_symlink() or hashlib.sha256(manifest.read_bytes()).hexdigest()!=expected_digest:
        raise ValueError("Manifest differs from the approved digest")
    record=json.loads(manifest.read_text());identity=record["identity"]
    version=(ROOT/"VERSION").read_text().strip()
    if (identity["version"]!=version or identity["inputs"]["commit"]!=expected_commit
            or identity["inputs"]["mode"]!="release" or identity["inputs"]["dirty"]
            or identity["inputs"]["target"]!="linux-amd64"):
        raise ValueError("Unexpected formal release identity")
    names=[item["filename"] for item in record["artifacts"]]
    if len(names)!=len(set(names)) or not names:
        raise ValueError("Duplicate or empty artifact set")
    for item in record["artifacts"]:
        name=item["filename"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*",name):raise ValueError("Unsafe artifact name")
        path=directory/name
        if path.is_symlink() or path.stat().st_size!=item["size"] or hashlib.sha256(path.read_bytes()).hexdigest()!=item["sha256"]:
            raise ValueError("Artifact mismatch: "+name)
    required={"mognitio-"+version+"-linux-amd64.tar.gz","mognitio_"+version+"-1_amd64.deb"}
    if not required.issubset(names):raise ValueError("Missing toolchain artifacts")
    signature=manifest.with_suffix(".json.asc")
    if signature.exists():raise ValueError("Do not replace an existing signature")
    config=json.loads((ROOT/"packaging/signing.json").read_text());public=ROOT/"packaging/mognitio.asc"
    secret=os.environ.get("BUNDLE_SIGNING_KEY","");password=os.environ.get("BUNDLE_SIGNING_PASSPHRASE","")
    if not secret or not password:raise ValueError("Bundle signing secrets are missing")
    with tempfile.TemporaryDirectory(prefix="bundle-signing-") as tmp,contextlib.ExitStack() as cleanup:
        path=Path(tmp)
        for home in ("public-check","gnupg"):
            cleanup.callback(subprocess.run,["gpgconf","--homedir",str(path/home),"--kill","gpg-agent"],capture_output=True)
        validate_public_keys(path,public,config)
        env=key_environment(path,config,secret,public)
        staged=path/"manifest.json.asc"
        run(["gpg","--batch","--pinentry-mode","loopback","--passphrase-fd","0","--armor",
             "--local-user",config["signing_fingerprint"]+"!","--output",staged,"--detach-sign",manifest],
            input=(password+"\n").encode(),env=env)
        keyring=path/"public.gpg";keyring.write_bytes(run(["gpg","--batch","--dearmor"],input=public.read_bytes()))
        status=run(["gpgv","--status-fd","1","--keyring",keyring,staged,manifest]).decode()
        sigs=[line.split() for line in status.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
        if len(sigs)!=1 or sigs[0][2]!=config["signing_fingerprint"] or sigs[0][-1]!=config["primary_fingerprint"]:
            raise ValueError("Unexpected bundle signature")
        signature.write_bytes(staged.read_bytes())
    print("Frozen release manifest signed and verified with the bundle subkey.")

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("directory",type=Path)
    parser.add_argument("--manifest-sha256",required=True)
    parser.add_argument("--commit",required=True)
    args=parser.parse_args()
    sign(args.directory.resolve(),args.manifest_sha256,args.commit)
