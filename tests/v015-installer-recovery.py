#!/usr/bin/env python3
"""Real installer interruption recovery with disposable, tiny payload fixtures."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.prefix = self.root / "prefix"
        self.bundles = []
        for patch in (0, 1):
            bundle = self.root / str(patch)
            payload = bundle / "payload"
            (payload / "bin").mkdir(parents=True)
            identity = {"version": "0.15." + str(patch), "build": str(patch) * 64,
                        "inputs": {"target": "linux-amd64"}}
            (payload / "identity.json").write_text(json.dumps(identity))
            for tool in ("mgn", "mognitio-lsp"):
                path = payload / "bin" / tool
                path.write_text("#!/bin/sh\necho " + tool + " " + identity["version"] + "\n")
                path.chmod(0o755)
            files = {str(p.relative_to(payload)): {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
                       "size": p.stat().st_size} for p in payload.rglob("*") if p.is_file()}
            (payload / "payload.json").write_text(json.dumps({"identity": identity, "files": files}))
            shutil.copy2(ROOT / "packaging/install.py", bundle / "install.py")
            # Different management bytes exercise an actual rollback on upgrade.
            with (bundle / "install.py").open("a") as stream:
                stream.write("\n# Fixture generation " + str(patch) + "\n")
            self.bundles.append(bundle)
    def tearDown(self):
        self.temp.cleanup()
    def run_install(self, version=0, fault=None):
        env = dict(os.environ)
        if fault:
            env["MOGNITIO_INSTALL_FAULT"] = fault
        return subprocess.run([sys.executable, "-I", str(self.bundles[version] / "install.py"),
                               "--prefix", str(self.prefix)], env=env, capture_output=True)
    def test_changed_entries_are_preserved_on_initial_install_and_upgrade(self):
        for upgrade in (False, True):
            for phase in ("prepared", "entries"):
                for mutation in ("replace", "edit", "symlink", "mode"):
                    with self.subTest(upgrade=upgrade, phase=phase, mutation=mutation):
                        self.prefix = self.root / f"p-{upgrade}-{phase}-{mutation}"
                        if upgrade:
                            self.assertEqual(self.run_install().returncode, 0)
                        self.assertEqual(self.run_install(int(upgrade), phase).returncode, 2)
                        path = self.prefix / "bin/mgn"
                        path.parent.mkdir(exist_ok=True)
                        victim = self.root / "unrelated"
                        victim.write_bytes(b"preserve unrelated bytes")
                        victim.chmod(0o640)
                        if mutation == "symlink":
                            path.unlink(missing_ok=True)
                            path.symlink_to(victim)
                        elif mutation == "replace":
                            path.unlink(missing_ok=True)
                            path.write_bytes(b"user replacement")
                        elif mutation == "edit":
                            with path.open("ab") as stream:
                                stream.write(b"user edit")
                        else:
                            if not path.exists():
                                path.write_bytes(b"user created")
                            path.chmod(0o600)
                        before = path.read_bytes()
                        mode = path.stat().st_mode
                        result = self.run_install(int(upgrade))
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertEqual(path.read_bytes(), before)
                        self.assertEqual(path.stat().st_mode, mode)
                        self.assertEqual(path.is_symlink(), mutation == "symlink")
                        self.assertEqual(victim.read_bytes(), b"preserve unrelated bytes")
                        self.assertEqual(victim.stat().st_mode & 0o777, 0o640)
                        self.assertTrue((self.prefix / "lib/mognitio/journal.json").exists())
    def test_unmodified_recovery_all_phases_initial_and_upgrade(self):
        for upgrade in (False, True):
            for phase in ("prepared", "entries", "switched", "cleaned"):
                with self.subTest(upgrade=upgrade, phase=phase):
                    self.prefix = self.root / f"clean-{upgrade}-{phase}"
                    if upgrade:
                        self.assertEqual(self.run_install().returncode, 0)
                    self.assertEqual(self.run_install(int(upgrade), phase).returncode, 2)
                    result = self.run_install(int(upgrade))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse((self.prefix / "lib/mognitio/journal.json").exists())
    def test_rollback_preflights_all_entries_before_changing_any(self):
        self.assertEqual(self.run_install(0, "entries").returncode, 2)
        management = self.prefix / "lib/mognitio"
        (management / "uninstall.sh").write_bytes(b"last conflict")
        original = (self.prefix / "bin/mgn").read_bytes()
        self.assertEqual(self.run_install().returncode, 2)
        self.assertEqual((self.prefix / "bin/mgn").read_bytes(), original)

if __name__ == "__main__":
    unittest.main()
