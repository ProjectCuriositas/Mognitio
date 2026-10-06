#!/usr/bin/env python3
"""Check a root-installed package using an unrelated unprivileged process."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def check(version, label, expect_denied):
    if os.geteuid() != 0:
        raise SystemExit("Run as root in a disposable system with mognitio installed")
    assert Path("/usr/bin/mgn").stat().st_uid == 0
    assert all(path.stat().st_uid == 0 for path in Path("/usr/lib/mognitio").iterdir())
    with tempfile.TemporaryDirectory(prefix="mognitio-nonowner-") as temp:
        work = Path(temp)
        os.chown(work, 65534, 65534)
        options = dict(user=65534, group=65534, extra_groups=[], cwd=work,
                       env={"PATH": "/usr/bin:/bin", "HOME": str(work), "LC_ALL": "C.UTF-8"})
        probe = subprocess.run(["/usr/bin/mgn", "--version"], **options, capture_output=True, text=True)
        if expect_denied:
            assert probe.returncode != 0 and "/usr/bin/mgn:" in probe.stderr and "Permission denied" in probe.stderr, probe
            print("PASS: original installed package denies unrelated UID")
            return
        assert probe.returncode == 0, (probe.stdout, probe.stderr)
        assert probe.stdout == label + " " + version + "\n", probe.stdout
        script = r'''import os,subprocess,json,sys
from pathlib import Path
assert os.geteuid()==65534 and os.getegid()==65534
assert os.getgroups()==[]
status=Path('/proc/self/status').read_text()
assert all(int(line.split()[1],16)==0 for line in status.splitlines() if line.startswith(('CapEff:','CapAmb:')))
version,source=sys.argv[1:]
assert subprocess.check_output(['mognitio-lsp','--version'],text=True)=='mognitio-lsp '+version+'\n'
subprocess.run(['mgn','run',source+'/examples/modules/mognitio.toml'],check=True)
subprocess.run(['mgn','test',source+'/examples/testing/mognitio.toml'],check=True)
subprocess.run(['mgn','build',source+'/examples/modules/mognitio.toml','-o','program'],check=True)
subprocess.run(['./program'],check=True)
p=subprocess.Popen(['mognitio-lsp','--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def send(message):
 raw=json.dumps(dict(jsonrpc='2.0',**message)).encode()
 p.stdin.write(b'Content-Length: '+str(len(raw)).encode()+b'\r\n\r\n'+raw);p.stdin.flush()
def receive():
 length=None
 while True:
  line=p.stdout.readline()
  assert line,p.stderr.read().decode()
  if line==b'\r\n':break
  if line.lower().startswith(b'content-length:'):length=int(line.split(b':')[1])
 return json.loads(p.stdout.read(length))
send({'id':1,'method':'initialize','params':{'rootUri':None,'processId':os.getpid(),'capabilities':{}}})
assert receive()['result']['serverInfo']['version']==version
send({'method':'initialized','params':{}})
send({'id':2,'method':'shutdown'})
while receive().get('id')!=2:pass
send({'method':'exit'})
assert p.wait(timeout=10)==0
'''
        subprocess.run(["python3", "-c", script, version, str(ROOT)], **options, check=True, timeout=90)
        print("PASS: root-installed package versions/run/build/test/LSP as unrelated UID 65534")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-label", default="Mognitio")
    parser.add_argument("--expect-denied", action="store_true")
    args = parser.parse_args()
    check(args.expected_version, args.expected_label, args.expect_denied)
