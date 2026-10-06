#!/usr/bin/env python3
"""Installer failure boundaries preserve an existing disposable installation."""
import errno
import fcntl
import importlib.util
import json
from pathlib import Path
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location("recovery",Path(__file__).with_name("v015-installer-recovery.py"))
recovery=importlib.util.module_from_spec(spec);spec.loader.exec_module(recovery)

class FailureTests(unittest.TestCase):
    setUp=recovery.RecoveryTests.setUp
    tearDown=recovery.RecoveryTests.tearDown
    run_install=recovery.RecoveryTests.run_install

    def snapshot(self):
        return {str(p.relative_to(self.prefix)):("link",str(p.readlink())) if p.is_symlink()
                else ("file",p.read_bytes(),p.stat().st_mode&0o777)
                for p in self.prefix.rglob("*") if p.is_file() or p.is_symlink()}

    def test_lock_downgrade_and_nonwritable_management(self):
        self.assertEqual(self.run_install(1).returncode,0)
        before=self.snapshot()
        self.assertEqual(self.run_install(0).returncode,1)
        self.assertEqual(self.snapshot(),before)
        with (self.prefix/"lib/mognitio/lock").open("a+") as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            rejected=self.run_install(1)
            self.assertEqual(rejected.returncode,1)
            self.assertIn(b"holds the lock",rejected.stderr)
        self.assertEqual(self.snapshot(),before)
        lock=self.prefix/"lib/mognitio/lock";lock.chmod(0o400)
        try:self.assertEqual(self.run_install(1).returncode,1)
        finally:lock.chmod(before["lib/mognitio/lock"][2])
        self.assertEqual(self.snapshot(),before)

    def test_wrong_arch_digest_and_traversal(self):
        self.assertEqual(self.run_install().returncode,0);before=self.snapshot()
        payload=self.bundles[1]/"payload"
        entry=payload/"bin/mgn";original=entry.read_bytes()
        entry.write_bytes(original+b"tampered")
        self.assertEqual(self.run_install(1).returncode,1);entry.write_bytes(original)
        manifest=payload/"payload.json";original_manifest=manifest.read_bytes()
        document=json.loads(original_manifest)
        document["files"]["../escape"]={"sha256":"0"*64,"size":1}
        manifest.write_text(json.dumps(document))
        self.assertEqual(self.run_install(1).returncode,1);manifest.write_bytes(original_manifest)
        identity=payload/"identity.json";record=json.loads(identity.read_text())
        record["inputs"]["target"]="linux-arm64";identity.write_text(json.dumps(record))
        import hashlib
        document=json.loads(original_manifest);document["identity"]=record
        document["files"]["identity.json"]={"sha256":hashlib.sha256(identity.read_bytes()).hexdigest(),"size":identity.stat().st_size}
        manifest.write_text(json.dumps(document))
        rejected=self.run_install(1);self.assertEqual(rejected.returncode,1);self.assertIn(b"Wrong payload target",rejected.stderr)
        self.assertEqual(self.snapshot(),before)

    def test_capacity_preflight_and_enospc_staging_preserve_current(self):
        self.assertEqual(self.run_install().returncode,0);before=self.snapshot()
        spec=importlib.util.spec_from_file_location("installer_failure",self.bundles[1]/"install.py")
        installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
        args=types.SimpleNamespace(prefix=str(self.prefix),uninstall=False,version=None)
        with patch.object(installer.shutil,"disk_usage",return_value=types.SimpleNamespace(free=0)):
            with self.assertRaisesRegex(ValueError,"Insufficient free space"):installer.run(args)
        self.assertEqual(self.snapshot(),before)
        with patch.object(installer.shutil,"copytree",side_effect=OSError(errno.ENOSPC,"No space left")):
            with self.assertRaises(OSError):installer.run(args)
        self.assertEqual(self.snapshot(),before)
        self.assertEqual(self.run_install(1).returncode,0)

if __name__=="__main__":unittest.main()
