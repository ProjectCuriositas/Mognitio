#!/usr/bin/env python3
"""Register only the encrypted release bundle signing subkey from offline transfer."""
import argparse
import contextlib
import getpass
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location("sign_release",root/"scripts/sign-release.py")
signing=importlib.util.module_from_spec(spec);spec.loader.exec_module(signing)
parser=argparse.ArgumentParser();parser.add_argument("transfer",type=Path);args=parser.parse_args()
config=json.loads((root/"packaging/signing.json").read_text())
transfer=json.loads((args.transfer/"fingerprints.json").read_text())
if config["primary_fingerprint"]!=transfer["primary_fingerprint"] or config["signing_fingerprint"]!=transfer["bundle_signing_fingerprint"]:
    raise ValueError("Transferred fingerprints differ from the reviewed release key")
secret=(args.transfer/"bundle-subkey.asc").read_text()
with tempfile.TemporaryDirectory(prefix="bundle-registration-") as tmp,contextlib.ExitStack() as cleanup:
    path=Path(tmp)
    cleanup.callback(subprocess.run,["gpgconf","--homedir",str(path/"gnupg"),"--kill","gpg-agent"],capture_output=True)
    env=signing.key_environment(path,config,secret,root/"packaging/mognitio.asc")
    password=getpass.getpass("Bundle subkey passphrase (registered as an environment secret): ")
    probe=path/"probe";probe.write_bytes(b"Mognitio bundle signing registration probe\n")
    signing.run(["gpg","--batch","--pinentry-mode","loopback","--passphrase-fd","0","--local-user",config["signing_fingerprint"]+"!","--detach-sign",probe],input=(password+"\n").encode(),env=env)
    for name,value in [("BUNDLE_SIGNING_KEY",secret),("BUNDLE_SIGNING_PASSPHRASE",password)]:
        subprocess.run(["gh","secret","set",name,"--repo","ProjectCuriositas/Mognitio","--env","release-signing"],input=value.encode(),capture_output=True,check=True)
print("Bundle signing environment secrets registered. No primary secret was uploaded.")
