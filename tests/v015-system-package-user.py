#!/usr/bin/env python3
"""Root-only disposable package acceptance with an unrelated UID (65534)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def check(deb, rootfs, expect_denied=False):
    if os.geteuid() != 0:
        raise SystemExit("Run as root to install root-owned files and drop to UID 65534")
    with tempfile.TemporaryDirectory(prefix="mognitio-system-user-") as temp:
        work = Path(temp)
        package = work / "package"
        subprocess.run(["dpkg-deb", "-x", str(deb), str(package)], check=True)
        payloads = list((package / "usr/lib/mognitio").iterdir())
        assert len(payloads) == 1
        payload = payloads[0]
        assert payload.stat().st_uid == 0
        identity = json.loads((payload / "identity.json").read_text())
        scratch = work / "work"
        scratch.mkdir(mode=0o700)
        os.chown(scratch, 65534, 65534)
        command = ["bwrap", "--ro-bind", str(rootfs), "/", "--dev", "/dev", "--proc", "/proc",
                   "--tmpfs", "/tmp", "--ro-bind", str(package / "usr/lib/mognitio"),
                   "/usr/lib/mognitio", "--ro-bind", str(ROOT), "/source",
                   "--bind", str(scratch), "/work", "--chdir", "/work",
                   "--setenv", "HOME", "/work", "--setenv", "LC_ALL", "C.UTF-8",
                   "--setenv", "PATH", "/usr/bin:/bin", "--uid", "65534", "--gid", "65534",
                   "--cap-drop", "ALL"]
        for name in ("mgn", "mognitio-lsp"):
            command += ["--ro-bind", str(package / "usr/bin" / name), "/usr/bin/" + name]
        probe = subprocess.run(command + ["--", "/usr/bin/mgn", "--version"], capture_output=True, text=True)
        if expect_denied:
            assert probe.returncode != 0 and "Permission denied" in probe.stderr, probe
            print("PASS: original package denies unrelated UID as expected")
            return
        assert probe.returncode == 0, (probe.stdout, probe.stderr)
        assert probe.stdout.strip().split(" ", 1)[-1] == identity["version"]
        script = r'''import os,subprocess,json
assert os.geteuid()==65534 and os.getegid()==65534
for tool in ('mgn','mognitio-lsp'):
 subprocess.run([tool,'--version'],check=True)
subprocess.run(['mgn','run','/source/examples/modules/mognitio.toml'],check=True)
subprocess.run(['mgn','test','/source/examples/testing/mognitio.toml'],check=True)
subprocess.run(['mgn','build','/source/examples/modules/mognitio.toml','-o','/work/program'],check=True)
subprocess.run(['/work/program'],check=True)
p=subprocess.Popen(['mognitio-lsp','--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def send(message):
 raw=json.dumps(dict(jsonrpc='2.0',**message)).encode()
 p.stdin.write(b'Content-Length: '+str(len(raw)).encode()+b'\r\n\r\n'+raw);p.stdin.flush()
def receive():
 length=None
 while True:
  line=p.stdout.readline()
  assert line, p.stderr.read().decode()
  if line==b'\r\n':break
  if line.lower().startswith(b'content-length:'):length=int(line.split(b':')[1])
 return json.loads(p.stdout.read(length))
send({'id':1,'method':'initialize','params':{'rootUri':None,'processId':os.getpid(),'capabilities':{}}})
assert 'result' in receive()
send({'method':'initialized','params':{}})
send({'id':2,'method':'shutdown'})
while receive().get('id')!=2:pass
send({'method':'exit'})
assert p.wait(timeout=10)==0
'''
        subprocess.run(command + ["--", "python3", "-c", script], check=True, timeout=90)
        print("PASS: root-owned package CLI/run/build/test/LSP as unrelated UID 65534")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--deb", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, default=Path("/"))
    parser.add_argument("--expect-denied", action="store_true")
    args = parser.parse_args()
    check(args.deb.resolve(), args.rootfs.resolve(), args.expect_denied)
