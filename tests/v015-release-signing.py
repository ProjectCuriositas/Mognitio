#!/usr/bin/env python3
"""Release signing checks using disposable keys; no production secrets."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location("signing",ROOT/"scripts/sign-release.py")
signing=importlib.util.module_from_spec(spec);spec.loader.exec_module(signing)
PASSWORD="disposable-release-signing-test"
COMMIT="a"*40

class SigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();cls.root=Path(cls.tmp.name)
        cls.home=cls.root/"keys";cls.home.mkdir(mode=0o700)
        cls.env=dict(os.environ,GNUPGHOME=str(cls.home))
        def gpg(*args):return signing.run(["gpg","--batch","--pinentry-mode","loopback","--passphrase-fd","0",*args],input=(PASSWORD+"\n").encode(),env=cls.env)
        cls.gpg=staticmethod(gpg)
        def fingerprints():return [x.split(":")[9] for x in gpg("--with-colons","--list-keys").decode().splitlines() if x.startswith("fpr:")]
        gpg("--quick-gen-key","Disposable release fixture","ed25519","cert","1d");cls.primary=fingerprints()[0]
        gpg("--quick-add-key",cls.primary,"ed25519","sign","1d");cls.bundle=fingerprints()[1]
        gpg("--quick-add-key",cls.primary,"ed25519","sign","1d");cls.other=fingerprints()[2]
        cls.secret=gpg("--armor","--export-secret-subkeys",cls.bundle+"!").decode()
        (cls.root/"VERSION").write_text("0.15.0\n");(cls.root/"packaging").mkdir()
        (cls.root/"packaging/mognitio.asc").write_bytes(gpg("--armor","--export",cls.primary))
        (cls.root/"packaging/signing.json").write_text(json.dumps({"primary_fingerprint":cls.primary,"signing_fingerprint":cls.bundle}))

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf","--homedir",str(cls.home),"--kill","gpg-agent"],capture_output=True)
        cls.tmp.cleanup()

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.output=Path(self.temp.name)
        artifacts=[]
        for name in ("mognitio-0.15.0-linux-amd64.tar.gz","mognitio_0.15.0-1_amd64.deb"):
            data=b"disposable bytes for signing boundary";path=self.output/name;path.write_bytes(data)
            artifacts.append({"filename":name,"size":len(data),"sha256":hashlib.sha256(data).hexdigest()})
        self.manifest=self.output/"manifest.json"
        self.manifest.write_text(json.dumps({"schema":1,"identity":{"version":"0.15.0","inputs":{"commit":COMMIT,"mode":"release","dirty":False,"target":"linux-amd64"}},"artifacts":artifacts}))
        self.digest=hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        self.patch=patch.object(signing,"ROOT",self.root);self.patch.start();self.addCleanup(self.patch.stop)
        self.envpatch=patch.dict(os.environ,BUNDLE_SIGNING_KEY=self.secret,BUNDLE_SIGNING_PASSPHRASE=PASSWORD);self.envpatch.start();self.addCleanup(self.envpatch.stop)

    def test_success_and_existing_signature_is_not_replaced(self):
        signing.sign(self.output,self.digest,COMMIT)
        signature=self.output/"manifest.json.asc";before=signature.read_bytes()
        with self.assertRaisesRegex(ValueError,"existing signature"):signing.sign(self.output,self.digest,COMMIT)
        self.assertEqual(before,signature.read_bytes())

    def test_tampered_artifact_is_not_signed(self):
        (self.output/"mognitio_0.15.0-1_amd64.deb").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError,"Artifact mismatch"):signing.sign(self.output,self.digest,COMMIT)
        self.assertFalse((self.output/"manifest.json.asc").exists())

    def test_wrong_manifest_digest_or_commit_is_not_signed(self):
        for digest,commit in [("0"*64,COMMIT),(self.digest,"b"*40)]:
            with self.assertRaises(ValueError):signing.sign(self.output,digest,commit)
        self.assertFalse((self.output/"manifest.json.asc").exists())

    def test_primary_secret_or_other_subkey_is_rejected(self):
        for secret in [self.gpg("--armor","--export-secret-keys",self.primary).decode(),self.gpg("--armor","--export-secret-subkeys",self.other+"!").decode()]:
            with patch.dict(os.environ,BUNDLE_SIGNING_KEY=secret),self.assertRaises(ValueError):signing.sign(self.output,self.digest,COMMIT)
        self.assertFalse((self.output/"manifest.json.asc").exists())

    def test_wrong_password_is_not_signed(self):
        with patch.dict(os.environ,BUNDLE_SIGNING_PASSPHRASE="wrong-fixture-password"),self.assertRaises(subprocess.CalledProcessError):signing.sign(self.output,self.digest,COMMIT)
        self.assertFalse((self.output/"manifest.json.asc").exists())

if __name__=="__main__":unittest.main()
